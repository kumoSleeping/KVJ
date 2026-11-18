//! Sound the built-in decoders (symphonia) cannot read, or cannot be trusted
//! to read, read by the system's: AVFoundation on macOS, Media Foundation on
//! Windows, through a converter the host registers (`kvj_sound_system`).
//!
//! Such a file's sound is decoded once into a WAV under the host's cache, and
//! every reader here (the waveform, the tempo, the index, playing) reads that
//! in its place. What symphonia reads well is never converted.
//!
//! Examples, as found by decoding the same tone in each: PCM in MP4 as
//! ISO 23003-5 writes it (`ipcm`/`fpcm`, what FFmpeg writes now), AC-3 and
//! E-AC-3, Opus in MP4, AAC of more than two channels, PCM of more than two
//! channels in MOV (the container is not even read), ALAC, μ-law and IMA in
//! MOV. Big-endian 24-bit and float PCM in MOV is read by symphonia as
//! little-endian, a full-scale noise: PCM wider than 16 bits in MP4 or MOV is
//! therefore never trusted to it while the system is there.
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CString};
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, RwLock};

/// The host's converter. With `wav` null it only tells whether the system
/// reads a sound in `path`; with one, it also writes that sound there as a
/// WAV (float or 16-bit, mono or stereo, at the sound's own rate, starting at
/// the file's time 0). Returns the sound's length in seconds, or 0 (or less)
/// when the system reads none. Called from any thread.
pub type ConvertFn = extern "C" fn(user: *mut c_void, path: *const c_char, wav: *const c_char) -> f64;

struct Host {
    convert: ConvertFn,
    user: usize,
    dir: PathBuf,
}

static HOST: RwLock<Option<Host>> = RwLock::new(None);
/// What each file was last read from, as it was then (its signature): the
/// WAV made of it, or None when symphonia reads it or the system cannot.
static CHOSEN: Mutex<Option<HashMap<PathBuf, (String, Option<PathBuf>)>>> = Mutex::new(None);
/// One conversion at a time: two readers of the same file wait for one WAV.
static CONVERTING: Mutex<()> = Mutex::new(());

/// Lets the system read what symphonia cannot, into WAVs kept under `dir`.
pub fn register(convert: ConvertFn, user: *mut c_void, dir: PathBuf) {
    // Left by a conversion cut short (the app quit or crashed during one); not
    // one another KVJ may be writing now.
    if let Ok(files) = fs::read_dir(&dir) {
        for file in files.flatten() {
            let old = file
                .metadata()
                .and_then(|m| m.modified())
                .is_ok_and(|at| at.elapsed().is_ok_and(|age| age.as_secs() > 3600));
            if old && file.file_name().to_string_lossy().ends_with(".part") {
                let _ = fs::remove_file(file.path());
            }
        }
    }
    *HOST.write().unwrap() = Some(Host { convert, user: user as usize, dir });
    *CHOSEN.lock().unwrap() = None;
}

fn host<T>(f: impl FnOnce(&Host) -> T) -> Option<T> {
    HOST.read().unwrap().as_ref().map(f)
}

pub(crate) fn available() -> bool {
    host(|_| ()).is_some()
}

/// Seconds of sound the system reads in `path`; None without a host or a sound.
pub(crate) fn readable(path: &Path) -> Option<f64> {
    let source = CString::new(path.to_string_lossy().as_bytes()).ok()?;
    let seconds = host(|h| (h.convert)(h.user as *mut c_void, source.as_ptr(), std::ptr::null()))?;
    (seconds.is_finite() && seconds > 0.).then_some(seconds)
}

/// The file to read `path`'s sound from: `path` itself, or the WAV the system
/// made of it when symphonia cannot read it (made now, the first time; that
/// takes as long as decoding it).
pub(crate) fn source(path: &Path) -> PathBuf {
    if !available() {
        return path.to_path_buf();
    }
    let Ok(signature) = crate::index::signature(path) else {
        return path.to_path_buf();
    };
    let chosen = |signature: &str| {
        let chosen = CHOSEN.lock().unwrap();
        match chosen.as_ref()?.get(path) {
            Some((was, wav)) if was == signature => Some(wav.clone()),
            _ => None,
        }
    };
    if let Some(wav) = chosen(&signature) {
        return wav.unwrap_or_else(|| path.to_path_buf());
    }
    let wav = if crate::decode::builtin_reads(path) {
        None
    } else {
        let _one = CONVERTING.lock().unwrap();
        match chosen(&signature) {
            Some(wav) => wav,
            None => convert(path, &signature),
        }
    };
    CHOSEN
        .lock()
        .unwrap()
        .get_or_insert_with(HashMap::new)
        .insert(path.to_path_buf(), (signature, wav.clone()));
    wav.unwrap_or_else(|| path.to_path_buf())
}

fn hash(value: impl Hash) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    ("kvj-sound", value).hash(&mut h);
    h.finish()
}

/// The WAV of `path` as it is now (`signature`), made unless it is there.
fn convert(path: &Path, signature: &str) -> Option<PathBuf> {
    let (convert, user, dir) = host(|h| (h.convert, h.user, h.dir.clone()))?;
    let stem = format!("{:016x}", hash(path));
    let file = dir.join(format!("{stem}-{:016x}.wav", hash(signature)));
    if file.is_file() {
        return Some(file);
    }
    fs::create_dir_all(&dir).ok()?;
    // The file changed: what was made of it before goes.
    if let Ok(files) = fs::read_dir(&dir) {
        for old in files.flatten() {
            let name = old.file_name().to_string_lossy().into_owned();
            if name.starts_with(&format!("{stem}-")) && name.ends_with(".wav") {
                let _ = fs::remove_file(old.path());
            }
        }
    }
    let part = file.with_extension(format!("{}.part", crate::document::id()));
    let source = CString::new(path.to_string_lossy().as_bytes()).ok()?;
    let target = CString::new(part.to_string_lossy().as_bytes()).ok()?;
    let started = std::time::Instant::now();
    let seconds = convert(user as *mut c_void, source.as_ptr(), target.as_ptr());
    if seconds.is_finite() && seconds > 0. && fs::rename(&part, &file).is_ok() {
        tracing::info!(
            "声音由系统解码：{}（{seconds:.0} 秒，用时 {:.1} 秒）",
            path.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned()),
            started.elapsed().as_secs_f64()
        );
        return Some(file);
    }
    let _ = fs::remove_file(&part);
    None
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    pub(crate) static TEST_LOCK: Mutex<()> = Mutex::new(());
    static CALLS: AtomicUsize = AtomicUsize::new(0);

    /// A stand-in for the system: a file named `system.mp4` has a second of a
    /// 441 Hz tone at 44.1 kHz, mono, 16-bit.
    extern "C" fn fake(_user: *mut c_void, path: *const c_char, wav: *const c_char) -> f64 {
        let path = unsafe { std::ffi::CStr::from_ptr(path) }.to_string_lossy().into_owned();
        if !path.ends_with("system.mp4") {
            return 0.;
        }
        if !wav.is_null() {
            CALLS.fetch_add(1, Ordering::SeqCst);
            let wav = unsafe { std::ffi::CStr::from_ptr(wav) }.to_string_lossy().into_owned();
            let frames = 44_100u32;
            let mut bytes = Vec::new();
            bytes.extend_from_slice(b"RIFF");
            bytes.extend_from_slice(&(36 + frames * 2).to_le_bytes());
            bytes.extend_from_slice(b"WAVEfmt ");
            bytes.extend_from_slice(&16u32.to_le_bytes());
            bytes.extend_from_slice(&1u16.to_le_bytes());
            bytes.extend_from_slice(&1u16.to_le_bytes());
            bytes.extend_from_slice(&44_100u32.to_le_bytes());
            bytes.extend_from_slice(&88_200u32.to_le_bytes());
            bytes.extend_from_slice(&2u16.to_le_bytes());
            bytes.extend_from_slice(&16u16.to_le_bytes());
            bytes.extend_from_slice(b"data");
            bytes.extend_from_slice(&(frames * 2).to_le_bytes());
            for i in 0..frames {
                let v = (i as f32 * 441. / 44_100. * std::f32::consts::TAU).sin() * 16_000.;
                bytes.extend_from_slice(&(v as i16).to_le_bytes());
            }
            fs::write(wav, bytes).unwrap();
        }
        1.
    }

    #[test]
    fn what_symphonia_cannot_read_is_read_from_the_systems_wav() {
        let _lock = TEST_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!("kvj-system-sound-{}", crate::document::id()));
        fs::create_dir_all(&dir).unwrap();
        // Not a container symphonia knows, so only the system reads it.
        let video = dir.join("system.mp4");
        fs::write(&video, b"not a container symphonia knows").unwrap();
        let silent = dir.join("silent.mp4");
        fs::write(&silent, b"nor this one").unwrap();

        assert!(crate::decode::probe(&video).is_err(), "without the system it cannot be read");
        register(fake, std::ptr::null_mut(), dir.join("sound"));

        let probe = crate::decode::probe(&video).unwrap();
        assert!(probe.audio);
        assert_eq!(probe.duration, Some(1.));
        assert!(crate::decode::probe(&silent).is_err());

        let calls = CALLS.load(Ordering::SeqCst);
        let wav = source(&video);
        assert_ne!(wav, video);
        assert_eq!(source(&video), wav, "made once");
        assert_eq!(CALLS.load(Ordering::SeqCst), calls + 1);
        assert_eq!(source(&silent), silent);

        let mut sound = crate::sound::SoundStream::open(&video).unwrap();
        assert_eq!(sound.rate(), 44_100);
        let mut out = vec![0f32; 2 * 50_000];
        assert_eq!(sound.read(&mut out), 44_100);
        assert!(out.iter().any(|v| v.abs() > 0.4));
        let decoded = crate::decode::decode_audio_native(&video, None).unwrap();
        assert_eq!(decoded.samples.len(), 44_100);

        // Changed, it is made anew and the old WAV goes.
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(&video, b"not a container symphonia knows, changed").unwrap();
        let again = source(&video);
        assert_ne!(again, wav);
        assert!(again.is_file() && !wav.exists());

        *HOST.write().unwrap() = None;
        let _ = fs::remove_dir_all(&dir);
    }
}
