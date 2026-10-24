//! C ABI for hosts (the Qt app). Every command is one JSON request and one JSON
//! reply, `{"ok": …}` or `{"error": "…"}`. The engine also pushes the presented
//! View as JSON through `on_event` from its worker thread; the host must hand it
//! to its own UI thread and must not call back into the engine from inside it.
use super::{audio_input::Selection, clock_ms, Edit, Engine};
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
            Request::Devices => json!(e.devices()?),
            Request::Start { set_id, device, channel_start, prepare_only } => {
                json!(e.start(&set_id, Selection { device, channel_start }, prepare_only)?)
            }
            Request::Stop => json!(e.stop()),
            Request::Status { after_log_id } => json!(e.status(after_log_id)),
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
