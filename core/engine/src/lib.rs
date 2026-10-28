//! KVJ engine: the Set document, indexing, native audio capture and the live
//! following session. It knows nothing about windows or video; a host (the Qt
//! app through `ffi`, or the CLI example) reads `View` and draws the picture.
//! Ported from KDJ's Live VJ (`src-tauri/src/live_vj` at 00f377a) without Tauri.
pub mod decode;
mod audio_input;
mod bluetooth;
#[cfg(target_os = "macos")]
mod capture;
mod diagnostics;
mod document;
mod feature_input;
pub mod ffi;
mod index;
#[cfg(target_os = "macos")]
mod output_tap;
mod qos;
pub mod report;
pub mod rhythm;
mod runtime;
pub mod sound;
pub mod update;
pub mod waveform;

pub use audio_input::{InputDevice, Selection};
pub use bluetooth::Device as BluetoothDevice;
pub use diagnostics::{Level, LogEntry, Stage};
pub use document::{Document, Edit, Entry, Set};

use anyhow::{bail, Context, Result};
use diagnostics::{Diagnostics, InputStatus, ListenerStatus, ScanResult};
use document::Store;
use serde::Serialize;
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{Instant, SystemTime, UNIX_EPOCH},
};

pub fn now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        * 1000.
}
/// Monotonic milliseconds shared with the host. `Match::clock_at_ms` is on this
/// clock, so the picture can extrapolate a position to the frame it is drawing.
pub fn clock_ms() -> f64 {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    ORIGIN.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.
}

#[derive(Clone, Serialize)]
pub struct Match {
    pub entry: Entry,
    /// Recording position (seconds) at `clock_at_ms`.
    pub position: f64,
    pub observed_at_ms: f64,
    pub clock_at_ms: f64,
    pub rate: f64,
    /// Acoustic similarity and competitor margin, not calibrated probabilities.
    pub confidence: f64,
    pub margin: f64,
    pub rate_confidence: f64,
    /// Rescue owns discontinuities. Fine corrections never advance this revision.
    pub lock_revision: u64,
}
#[derive(Clone, Default, Serialize)]
pub struct View {
    pub session: String,
    /// "vj" (recognize and project) or "send" (stream features over Bluetooth).
    pub mode: String,
    pub bluetooth: Option<bluetooth::LinkStatus>,
    pub connections: bluetooth::ConnectionStatus,
    pub send_target: Option<String>,
    pub presentation_epoch: u64,
    pub input_device: String,
    pub input_channel_start: u16,
    pub revision: u64,
    pub clock_ms: f64,
    pub set_id: String,
    /// The track followed (0 the main one): only its entries are matched.
    pub track: u8,
    pub phase: String,
    pub error: String,
    pub indexed: usize,
    pub total: usize,
    pub preparing: Option<String>,
    pub matched: Option<Match>,
    pub candidate: Option<Match>,
    pub priority: Vec<String>,
    pub scan: u64,
    pub scan_ms: f64,
    pub rescue: Option<ListenerStatus>,
    pub tracking: Option<ListenerStatus>,
    pub scanned: Vec<ScanResult>,
    pub scanning: Option<String>,
    pub input: Option<InputStatus>,
}
#[derive(Serialize)]
pub struct Status {
    #[serde(flatten)]
    pub view: View,
    pub logs: Vec<LogEntry>,
}
struct Session {
    cancel: Arc<AtomicBool>,
    worker: std::thread::JoinHandle<()>,
}
/// Called from the recognition thread whenever the presented match changes.
pub type Notify = Box<dyn Fn(&View) + Send + Sync>;

pub struct Engine {
    data_dir: PathBuf,
    store: Mutex<Option<Store>>,
    view: Mutex<View>,
    diagnostics: Mutex<Diagnostics>,
    prepared: Mutex<Option<Arc<index::PreparedSet>>>,
    // Entries of the running Set that are turned off; read every round.
    off: Mutex<std::collections::HashSet<String>>,
    session: Mutex<Option<Session>>,
    gate: Mutex<()>,
    connections: bluetooth::Hub,
    reports: report::Reports,
    notify: Notify,
}
// Only videos go into a Set: KVJ projects pictures. Their sound is what is
// followed.
const VIDEO: &[&str] = &["mp4", "m4v", "mkv", "mov", "webm"];

impl Engine {
    pub fn new(data_dir: PathBuf, notify: Notify) -> Arc<Self> {
        let connections = bluetooth::Hub::open(&data_dir);
        Arc::new(Self {
            data_dir,
            store: Mutex::new(None),
            view: Mutex::new(View::default()),
            diagnostics: Mutex::new(Diagnostics::default()),
            prepared: Mutex::new(None),
            off: Mutex::new(Default::default()),
            session: Mutex::new(None),
            gate: Mutex::new(()),
            connections,
            reports: report::Reports::default(),
            notify,
        })
    }
    /// A scrubbed bug report built from the logs on disk, to be read in full
    /// before `report_submit` sends exactly it.
    pub fn report_prepare(&self, note: &str) -> Result<report::Preview> {
        self.reports.prepare(&self.data_dir, note)
    }
    pub fn report_submit(&self, id: &str) -> Result<String> {
        self.reports.submit(id)
    }
    /// The in-app update (`update`), which keeps its files in `<data>/updates`.
    pub fn update_download(&self) -> Result<()> {
        update::download(&self.data_dir)
    }
    pub fn update_install(&self) -> Result<()> {
        update::install(&self.data_dir)
    }
    pub fn update_settle(&self) -> String {
        update::settle(&self.data_dir)
    }
    fn with_store<T>(&self, f: impl FnOnce(&mut Store) -> Result<T>) -> Result<T> {
        let mut store = self.store.lock().unwrap();
        if store.is_none() {
            *store = Some(Store::open(&self.data_dir)?);
        }
        f(store.as_mut().unwrap())
    }
    fn running(&self) -> bool {
        self.session
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|s| !s.worker.is_finished())
    }
    fn update(&self, id: &str, edit: impl FnOnce(&mut View)) {
        let mut v = self.view.lock().unwrap();
        if v.session == id && v.phase != "stopped" {
            edit(&mut v);
            v.revision += 1;
        }
    }
    fn present(&self, id: &str, edit: impl FnOnce(&mut View)) {
        let snapshot = {
            let mut view = self.view.lock().unwrap();
            if view.session != id || view.phase == "stopped" {
                return;
            }
            edit(&mut view);
            view.revision += 1;
            view.clock_ms = clock_ms();
            view.clone()
        };
        (self.notify)(&snapshot);
    }
    fn log(&self, session: &str, level: Level, stage: Stage, message: String) {
        self.diagnostics
            .lock()
            .unwrap()
            .push(session, level, stage, message);
    }
    fn invalidate_prepared(&self) {
        self.prepared.lock().unwrap().take();
        let mut view = self.view.lock().unwrap();
        if view.phase == "prepared" {
            view.phase.clear();
            view.indexed = 0;
            self.log(
                &view.session,
                Level::Info,
                Stage::Index,
                "Set 已修改，预处理索引已失效".into(),
            );
        }
    }

    pub fn document(&self) -> Result<Document> {
        self.with_store(|s| Ok(s.doc.clone()))
    }
    /// Applied to the Set as it is now, whatever revision the caller last saw
    /// (`_revision`): an edit names its entries by id and is checked against
    /// the current Set, so two quick edits, or an on/off between them, no
    /// longer turn the second away.
    pub fn edit(&self, _revision: u64, edit: Edit) -> Result<Document> {
        let _gate = self.gate.lock().unwrap();
        if self.running() {
            bail!("请先停止跟随再编辑 Set");
        }
        let document = self.with_store(|s| {
            let mut next = s.doc.clone();
            next.edit(edit)?;
            s.commit(next)
        })?;
        self.invalidate_prepared();
        Ok(document)
    }
    /// Turns entries on or off for following; allowed while following, when the
    /// running session takes it at its next round.
    pub fn enable(&self, set_id: &str, entry_ids: &[String], on: bool) -> Result<Document> {
        // Not between a starting session reading its Set and taking what is off.
        let _gate = self.gate.lock().unwrap();
        let document = self.with_store(|s| {
            let mut next = s.doc.clone();
            next.enable(set_id, entry_ids, on)?;
            s.commit(next)
        })?;
        let view = self.view.lock().unwrap();
        if view.set_id == set_id {
            let mut off = self.off.lock().unwrap();
            for id in entry_ids {
                if on {
                    off.remove(id);
                } else {
                    off.insert(id.clone());
                }
            }
        }
        Ok(document)
    }
    /// Files and folders (searched recursively) become entries of one Set, on `track`.
    /// `placed`: the new entries are on (on the timeline, followed) or only
    /// in the Set, to be placed later.
    /// Added to the Set as it is then, like `edit`, whatever revision the
    /// caller last saw.
    pub fn import(&self, set_id: &str, _revision: u64, paths: &[String], track: u8, placed: bool) -> Result<Document> {
        anyhow::ensure!(track <= document::LAST_TRACK, "轨道不存在");
        let _gate = self.gate.lock().unwrap();
        if self.running() {
            bail!("请先停止跟随再导入素材");
        }
        self.with_store(|s| s.doc.set_mut(set_id).map(|_| ()))?;
        let mut files = vec![];
        let mut pending: Vec<PathBuf> = paths.iter().rev().map(PathBuf::from).collect();
        while let Some(path) = pending.pop() {
            anyhow::ensure!(files.len() < 1000, "一次最多导入 1000 个素材");
            if path.is_dir() {
                let mut children: Vec<_> = std::fs::read_dir(&path)
                    .with_context(|| format!("无法读取文件夹：{}", path.display()))?
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')))
                    .collect();
                children.sort();
                pending.extend(children.into_iter().rev());
            } else if extension(&path).is_some_and(|e| VIDEO.contains(&e.as_str())) {
                files.push(path);
            }
        }
        anyhow::ensure!(!files.is_empty(), "没有可导入的视频文件（只导入 mp4、m4v、mkv、mov、webm）");
        let entries = files
            .iter()
            .map(|path| {
                let probe = decode::probe(path).with_context(|| format!("无法读取：{}", path.display()))?;
                let duration = probe
                    .duration
                    .with_context(|| format!("无法读取时长：{}", path.display()))?;
                let video = extension(path).is_some_and(|e| VIDEO.contains(&e.as_str()));
                let mut entry = Entry::new(path, video, 0., duration)?;
                entry.silent = !probe.audio;
                entry.track = track;
                entry.enabled = placed;
                Ok(entry)
            })
            .collect::<Result<Vec<_>>>()?;
        let document = self.with_store(|s| {
            let mut next = s.doc.clone();
            let set = next.set_mut(set_id)?;
            // A file already there: into the library only, it stays as it
            // is; onto a track, it is made anew there, except where it is
            // placed on another track, which keeps it (one video may play on
            // two tracks).
            let entries: Vec<_> = entries
                .into_iter()
                .filter(|n| placed || !set.entries.iter().any(|e| e.path == n.path))
                .collect();
            set.entries.retain(|e| {
                !entries
                    .iter()
                    .any(|n| n.path == e.path && (e.track == track || !e.enabled))
            });
            set.entries.extend(entries);
            s.commit(next)
        })?;
        self.invalidate_prepared();
        Ok(document)
    }
    pub fn devices(&self) -> Result<Vec<InputDevice>> {
        let mut devices = audio_input::devices()?;
        if cfg!(any(target_os = "macos", windows)) {
            devices.push(InputDevice::bluetooth());
        }
        Ok(devices)
    }
    /// A stopped worker exits at its next cancellation check; wait for it.
    fn join_stopped(&self) {
        let stopped = {
            let mut session = self.session.lock().unwrap();
            if session.as_ref().is_some_and(|s| s.cancel.load(Ordering::Relaxed)) {
                session.take()
            } else {
                None
            }
        };
        if let Some(s) = stopped {
            let _ = s.worker.join();
        }
    }
    /// Index the Set (reusing caches) and, unless `prepare_only`, start listening
    /// for the entries on `track`.
    pub fn start(self: &Arc<Self>, set_id: &str, input: Selection, prepare_only: bool, track: u8) -> Result<View> {
        anyhow::ensure!(track <= document::LAST_TRACK, "轨道不存在");
        // Bluetooth is an explicit, mutually exclusive source with nothing to open yet.
        if !prepare_only && input.device != "bluetooth" {
            input.validate()?;
        }
        let _gate = self.gate.lock().unwrap();
        self.join_stopped();
        if self.running() {
            bail!("请先停止当前会话");
        }
        let set = self.with_store(|s| {
            Ok(s.doc
                .sets
                .iter()
                .find(|s| s.id == set_id)
                .context("Set 不存在")?
                .clone())
        })?;
        anyhow::ensure!(!set.entries.is_empty(), "Set 没有素材");
        anyhow::ensure!(set.entries.iter().any(|e| !e.silent), "Set 里的素材都没有声音，无从跟随");
        // Every entry is indexed, but only the followed track's are listened for.
        anyhow::ensure!(
            set.entries.iter().any(|e| e.track == track && !e.silent),
            "{}上的素材都没有声音，无从跟随",
            track_name(track)
        );
        *self.off.lock().unwrap() = set
            .entries
            .iter()
            .filter(|e| !e.enabled)
            .map(|e| e.id.clone())
            .collect();
        let session = document::id();
        // A DJ selected (or already streaming) before Start is the current source:
        // its matches must be presented, not wait for the next route change.
        let presentation_epoch = if input.device == "bluetooth" {
            self.connections.inbox.lock().unwrap().epoch
        } else {
            0
        };
        let view = View {
            session: session.clone(),
            mode: "vj".into(),
            presentation_epoch,
            input_device: input.device.clone(),
            input_channel_start: input.channel_start,
            set_id: set_id.into(),
            track,
            phase: "indexing".into(),
            total: set.entries.len(),
            ..Default::default()
        };
        self.diagnostics.lock().unwrap().reset(&session);
        *self.view.lock().unwrap() = view.clone();
        self.log(
            &session,
            Level::Info,
            Stage::Session,
            format!(
                "会话开始 · {} · {} 个素材 · 跟随{}（{} 个，{} 个启用）",
                set.name,
                set.entries.len(),
                track_name(track),
                set.entries.iter().filter(|e| e.track == track).count(),
                set.entries.iter().filter(|e| e.track == track && e.enabled).count()
            ),
        );
        let cancel = Arc::new(AtomicBool::new(false));
        let worker = {
            let engine = self.clone();
            let cancel = cancel.clone();
            let cache = self.data_dir.join("cache").join("live");
            std::thread::Builder::new()
                .name("kvj-follow".into())
                .spawn(move || runtime::run(&engine, session, set, cache, cancel, prepare_only, input, track))?
        };
        *self.session.lock().unwrap() = Some(Session { cancel, worker });
        Ok(view)
    }
    pub fn stop(&self) -> View {
        if let Some(s) = self.session.lock().unwrap().as_ref() {
            s.cancel.store(true, Ordering::Relaxed);
        }
        let snapshot = {
            let mut v = self.view.lock().unwrap();
            if !v.session.is_empty() && v.phase != "stopped" {
                self.log(&v.session, Level::Info, Stage::Session, "会话已停止".into());
            }
            v.phase = "stopped".into();
            if let Some(link) = &mut v.bluetooth {
                link.state = "stopped".into();
            }
            v.scanning = None;
            v.matched = None;
            v.candidate = None;
            v.preparing = None;
            v.revision += 1;
            v.clock_ms = clock_ms();
            v.clone()
        };
        (self.notify)(&snapshot);
        snapshot
    }
    pub fn status(&self, after_log_id: Option<u64>) -> Status {
        let mut view = self.view.lock().unwrap().clone();
        let logs = self
            .diagnostics
            .lock()
            .unwrap()
            .since(&view.session, after_log_id);
        view.clock_ms = clock_ms();
        view.connections = self.connections.snapshot();
        Status { view, logs }
    }
    /// Stop and wait for the worker, so `notify` is never called afterwards.
    /// Call from the host thread, never from inside `notify`.
    pub fn shutdown(&self) {
        let session = self.session.lock().unwrap().take();
        if let Some(s) = session {
            s.cancel.store(true, Ordering::Relaxed);
            let _ = s.worker.join();
        }
        self.connections.shutdown();
    }
}
/// What the app calls a track: the main one, then 画面 2..4.
fn track_name(track: u8) -> String {
    if track == 0 {
        "主轨".into()
    } else {
        format!("画面 {}", track + 1)
    }
}
fn extension(path: &Path) -> Option<String> {
    path.extension().map(|e| e.to_string_lossy().to_lowercase())
}
