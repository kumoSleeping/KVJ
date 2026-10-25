//! C ABI for hosts (the Qt app). Every command is one JSON request and one JSON
//! reply, `{"ok": …}` or `{"error": "…"}`. The engine also pushes the presented
//! View as JSON through `on_event` from its worker thread; the host must hand it
//! to its own UI thread and must not call back into the engine from inside it.
use super::{audio_input::Selection, clock_ms, sound::SoundStream, BluetoothDevice, Edit, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::Arc,
};

pub type EventFn = extern "C" fn(user: *mut c_void, json: *const c_char);
pub struct KvjEngine {
    engine: Arc<Engine>,
}
struct Callback {
    on_event: EventFn,
    user: *mut c_void,
}
// The host promises `user` may be used from any thread for the engine's lifetime.
unsafe impl Send for Callback {}
unsafe impl Sync for Callback {}

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
enum Request {
    Document,
    Edit { revision: u64, edit: Edit },
    Import { set_id: String, revision: u64, paths: Vec<String> },
    Enable { set_id: String, entry_ids: Vec<String>, on: bool },
    Devices,
    Start {
        set_id: String,
        #[serde(default = "auto")]
        device: String,
        #[serde(default)]
        channel_start: u16,
        #[serde(default)]
        prepare_only: bool,
    },
    Stop,
    Status { after_log_id: Option<u64> },
    BluetoothScan,
    BluetoothListen { on: bool },
    BluetoothConnect { device: BluetoothDevice },
    BluetoothDisconnect { id: String },
    BluetoothSelect { id: Option<String> },
    SendStart {
        peer: String,
        #[serde(default = "auto")]
        device: String,
        #[serde(default)]
        channel_start: u16,
    },
}
fn auto() -> String {
    "auto".into()
}
impl KvjEngine {
    fn call(&self, request: Request) -> anyhow::Result<Value> {
        let e = &self.engine;
        Ok(match request {
            Request::Document => json!(e.document()?),
            Request::Edit { revision, edit } => json!(e.edit(revision, edit)?),
            Request::Import { set_id, revision, paths } => json!(e.import(&set_id, revision, &paths)?),
            Request::Enable { set_id, entry_ids, on } => json!(e.enable(&set_id, &entry_ids, on)?),
            Request::Devices => json!(e.devices()?),
            Request::Start { set_id, device, channel_start, prepare_only } => {
                json!(e.start(&set_id, Selection { device, channel_start }, prepare_only)?)
            }
            Request::Stop => json!(e.stop()),
            Request::Status { after_log_id } => json!(e.status(after_log_id)),
            Request::BluetoothScan => json!(e.bluetooth_scan()?),
            Request::BluetoothListen { on } => json!(e.bluetooth_listen(on)?),
            Request::BluetoothConnect { device } => json!(e.bluetooth_connect(device)?),
            Request::BluetoothDisconnect { id } => json!(e.bluetooth_disconnect(&id)),
            Request::BluetoothSelect { id } => json!(e.bluetooth_select(id)?),
            Request::SendStart { peer, device, channel_start } => {
                json!(e.send_start(&peer, Selection { device, channel_start })?)
            }
        })
    }
}
fn reply(value: Value) -> *mut c_char {
    CString::new(value.to_string()).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// Creates an engine storing its Set document and caches under `data_dir` (UTF-8).
/// # Safety
/// `data_dir` is a NUL-terminated string; `on_event`/`user` stay valid until `kvj_engine_free`.
#[no_mangle]
pub unsafe extern "C" fn kvj_engine_new(
    data_dir: *const c_char,
    on_event: Option<EventFn>,
    user: *mut c_void,
) -> *mut KvjEngine {
    if data_dir.is_null() {
        return std::ptr::null_mut();
    }
    let dir = PathBuf::from(CStr::from_ptr(data_dir).to_string_lossy().into_owned());
    let callback = on_event.map(|on_event| Callback { on_event, user });
    let engine = Engine::new(
        dir,
        Box::new(move |view| {
            if let Some(cb) = &callback {
                if let Ok(text) = CString::new(serde_json::to_string(view).unwrap_or_default()) {
                    (cb.on_event)(cb.user, text.as_ptr());
                }
            }
        }),
    );
    Box::into_raw(Box::new(KvjEngine { engine }))
}

/// Stops any session, waits for its worker and frees the engine.
/// # Safety
/// `engine` came from `kvj_engine_new` and is not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn kvj_engine_free(engine: *mut KvjEngine) {
    if !engine.is_null() {
        let engine = Box::from_raw(engine);
        engine.engine.shutdown();
    }
}

/// Runs one JSON command. The reply must be released with `kvj_string_free`.
/// Commands may block (indexing is asynchronous, but importing probes files).
/// # Safety
/// `engine` is live and `request` is a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn kvj_call(engine: *mut KvjEngine, request: *const c_char) -> *mut c_char {
    if engine.is_null() || request.is_null() {
        return reply(json!({"error": "无效调用"}));
    }
    let engine = &*engine;
    let text = CStr::from_ptr(request).to_string_lossy();
    let result = catch_unwind(AssertUnwindSafe(|| {
        serde_json::from_str::<Request>(&text)
            .map_err(anyhow::Error::from)
            .and_then(|request| engine.call(request))
    }));
    reply(match result {
        Ok(Ok(value)) => json!({ "ok": value }),
        Ok(Err(error)) => json!({ "error": format!("{error:#}") }),
        Err(_) => json!({ "error": "引擎内部错误" }),
    })
}

/// # Safety
/// `text` came from `kvj_call` (or is null).
#[no_mangle]
pub unsafe extern "C" fn kvj_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(CString::from_raw(text));
    }
}

/// The engine's monotonic clock in milliseconds; `matched.clock_at_ms` is on it.
#[no_mangle]
pub extern "C" fn kvj_clock_ms() -> f64 {
    clock_ms()
}

/// Asked now and then during `kvj_waveform`; true abandons it.
pub type StopFn = extern "C" fn(user: *mut c_void) -> bool;

/// The timeline waveform of a media file (see `waveform`): `*columns` columns at
/// `waveform::RATE` a second, as heights then R, G and B, one byte per column
/// each, made once and kept under `cache_dir`. Blocks for seconds the first time.
/// Null (and 0 columns) when the file has no audio or `stop` said so; release
/// the bytes with `kvj_bytes_free`.
/// # Safety
/// `path` and `cache_dir` are NUL-terminated UTF-8; `columns` is writable.
#[no_mangle]
pub unsafe extern "C" fn kvj_waveform(
    path: *const c_char,
    cache_dir: *const c_char,
    stop: Option<StopFn>,
    user: *mut c_void,
    columns: *mut usize,
) -> *mut u8 {
    if columns.is_null() {
        return std::ptr::null_mut();
    }
    *columns = 0;
    if path.is_null() || cache_dir.is_null() {
        return std::ptr::null_mut();
    }
    let path = PathBuf::from(CStr::from_ptr(path).to_string_lossy().into_owned());
    let cache = PathBuf::from(CStr::from_ptr(cache_dir).to_string_lossy().into_owned());
    let user = user as usize;
    let cancelled = move || stop.is_some_and(|stop| stop(user as *mut c_void));
    match catch_unwind(AssertUnwindSafe(|| super::waveform::load(&path, &cache, &cancelled))) {
        Ok(Ok(Some(wave))) if wave.columns > 0 => {
            *columns = wave.columns;
            Box::into_raw(wave.bytes.into_boxed_slice()) as *mut u8
        }
        Ok(Err(error)) => {
            tracing::debug!("波形：{}：{error:#}", path.display());
            std::ptr::null_mut()
        }
        _ => std::ptr::null_mut(),
    }
}

/// # Safety
/// `bytes` came from `kvj_waveform` with `columns` columns (or is null).
#[no_mangle]
pub unsafe extern "C" fn kvj_bytes_free(bytes: *mut u8, columns: usize) {
    if !bytes.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, columns * 4)));
    }
}

/// The picture's sound, read for playing (see `sound`): `*rate` frames a
/// second of interleaved stereo f32, `*duration` seconds (0 if unknown). Null
/// when the file has no audio it can decode. Free with `kvj_sound_free`.
/// # Safety
/// `path` is NUL-terminated UTF-8; `rate` and `duration` are writable.
#[no_mangle]
pub unsafe extern "C" fn kvj_sound_open(path: *const c_char, rate: *mut u32, duration: *mut f64) -> *mut SoundStream {
    if path.is_null() || rate.is_null() || duration.is_null() {
        return std::ptr::null_mut();
    }
    let path = PathBuf::from(CStr::from_ptr(path).to_string_lossy().into_owned());
    match catch_unwind(AssertUnwindSafe(|| SoundStream::open(&path))) {
        Ok(Ok(sound)) => {
            *rate = sound.rate();
            *duration = sound.duration();
            Box::into_raw(Box::new(sound))
        }
        Ok(Err(error)) => {
            tracing::debug!("声音：{}：{error:#}", path.display());
            std::ptr::null_mut()
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// Reads on from `seconds`; false when the file cannot seek.
/// # Safety
/// `sound` came from `kvj_sound_open` and is used by one thread at a time.
#[no_mangle]
pub unsafe extern "C" fn kvj_sound_seek(sound: *mut SoundStream, seconds: f64) -> bool {
    match sound.as_mut() {
        Some(sound) => catch_unwind(AssertUnwindSafe(|| sound.seek(seconds))).unwrap_or(false),
        None => false,
    }
}

/// Up to `frames` stereo frames into `out` (2 × `frames` floats); fewer only
/// at the end.
/// # Safety
/// As `kvj_sound_seek`; `out` holds 2 × `frames` floats.
#[no_mangle]
pub unsafe extern "C" fn kvj_sound_read(sound: *mut SoundStream, out: *mut f32, frames: usize) -> usize {
    let Some(sound) = sound.as_mut() else { return 0 };
    if out.is_null() || frames == 0 {
        return 0;
    }
    let out = std::slice::from_raw_parts_mut(out, frames * 2);
    catch_unwind(AssertUnwindSafe(|| sound.read(out))).unwrap_or(0)
}

/// # Safety
/// `sound` came from `kvj_sound_open` (or is null) and is not used again.
#[no_mangle]
pub unsafe extern "C" fn kvj_sound_free(sound: *mut SoundStream) {
    if !sound.is_null() {
        drop(Box::from_raw(sound));
    }
}
