//! 提前分析 (analysing ahead): videos of the library analysed before the show,
//! one at a time on one background thread, into the caches the show reads:
//! the index's features (`index`), the waveform and the tempo sections. None
//! of it stays in memory; placed on a track while following, a video so
//! analysed is indexed in seconds instead of being decoded first.
//!
//! `analysed.json`, beside the features, lists the files so done as they were
//! (signature, length, sound, what was made): pruning keeps their features,
//! and the library tells them done without opening them.
use super::{
    decode,
    document::{self, Entry},
    index, rhythm, waveform, Engine,
};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
};

const MANIFEST: &str = "analysed.json";
/// How a file's sound is told: 1 since the system's decoders read what
/// symphonia cannot (`system_sound`). A file found silent before is looked at again.
const HEARING: u32 = 1;
/// Videos, as `Engine::import` takes them.
const VIDEO: &[&str] = &["mp4", "m4v", "mkv", "mov", "webm"];
/// One request adds at most this many files.
const MOST: usize = 5000;

/// A file analysed ahead, as it was then.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub(crate) struct Done {
    pub signature: String,
    pub duration: f64,
    pub silent: bool,
    /// Whether a waveform and a tempo came of it (a file whose sound cannot
    /// be read for them has none, and is not asked for them again).
    pub wave: bool,
    pub tempo: bool,
    /// `HEARING` when it was analysed (0 before there was one).
    #[serde(default)]
    pub hearing: u32,
}

/// What the analysis is doing, for the window.
#[derive(Clone, Default, Serialize)]
pub struct Progress {
    pub running: bool,
    /// The file being analysed now.
    pub current: Option<String>,
    /// Files waiting, done and failed since the queue was last empty.
    pub waiting: usize,
    pub done: usize,
    pub failed: usize,
    /// Why the last one failed.
    pub error: String,
    /// Goes up whenever a file is done: what is analysed may have changed.
    pub revision: u64,
}

#[derive(Default)]
struct State {
    waiting: VecDeque<PathBuf>,
    current: Option<PathBuf>,
    done: usize,
    failed: usize,
    error: String,
    running: bool,
    /// Read from disk once, then kept here and written on every change.
    manifest: Option<BTreeMap<String, Done>>,
}

#[derive(Default)]
pub(crate) struct Analysis {
    state: Mutex<State>,
    cancel: Arc<AtomicBool>,
    revision: AtomicU64,
    /// Held while the manifest is written: the last to write writes the newest.
    saving: Mutex<()>,
}

fn cache(engine: &Engine) -> PathBuf {
    engine.data_dir.join("cache").join("live")
}
/// Where the host keeps waveforms and tempi (WaveStrip.cpp).
fn wave_cache(engine: &Engine) -> PathBuf {
    engine.data_dir.join("cache").join("wave")
}
fn is_video(path: &Path) -> bool {
    path.extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .is_some_and(|e| VIDEO.contains(&e.as_str()))
}
fn key(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}
/// The entry `Engine::import` would make of the file: its features are kept
/// under the same names.
fn entry_of(path: &Path, duration: f64, silent: bool) -> Result<Entry> {
    let mut entry = Entry::new(path, is_video(path), 0., duration)?;
    entry.silent = silent;
    Ok(entry)
}

impl Analysis {
    fn manifest<'a>(&self, state: &'a mut State, cache: &Path) -> &'a mut BTreeMap<String, Done> {
        state.manifest.get_or_insert_with(|| {
            fs::read(cache.join(MANIFEST))
                .ok()
                .and_then(|data| serde_json::from_slice(&data).ok())
                .unwrap_or_default()
        })
    }
    /// The manifest as it is now onto the disk, outside the state's lock
    /// (the window reads the progress through it, and a write waits for the disk).
    fn persist(&self, cache: &Path) {
        let _saving = self.saving.lock().unwrap();
        let manifest = {
            let mut state = self.state.lock().unwrap();
            self.manifest(&mut state, cache).clone()
        };
        Self::save_manifest(&manifest, cache);
    }
    fn save_manifest(manifest: &BTreeMap<String, Done>, cache: &Path) {
        // Lost, it only costs analysing those files again.
        let _ = fs::create_dir_all(cache)
            .map_err(anyhow::Error::from)
            .and_then(|_| index::save(&cache.join(MANIFEST), |f| Ok(serde_json::to_writer(f, manifest)?)));
    }
    pub fn progress(&self) -> Progress {
        let state = self.state.lock().unwrap();
        Progress {
            running: state.running,
            current: state.current.as_deref().map(key),
            waiting: state.waiting.len(),
            done: state.done,
            failed: state.failed,
            error: state.error.clone(),
            revision: self.revision.load(Ordering::Relaxed),
        }
    }
    /// The files analysed ahead whose features pruning keeps, as entries;
    /// None while one of them is on a drive out of sight (nothing is judged
    /// then). Those deleted or changed since are let go.
    pub fn kept(&self, cache: &Path) -> Option<Vec<Entry>> {
        // Looked at outside the lock: the window asks for the progress
        // meanwhile, and a slow drive must not hold it up.
        let manifest_before = {
            let mut state = self.state.lock().unwrap();
            self.manifest(&mut state, cache).clone()
        };
        let mut kept = Vec::new();
        let mut forget = Vec::new();
        for (path, done) in &manifest_before {
            let file = Path::new(path);
            match index::signature(file) {
                Ok(signature) if signature == done.signature => {
                    if let Ok(entry) = entry_of(file, done.duration, done.silent) {
                        kept.push(entry);
                    }
                }
                Ok(_) => forget.push(path.clone()),
                Err(_) if document::volume_present(file) => forget.push(path.clone()),
                Err(_) => return None,
            }
        }
        if !forget.is_empty() {
            {
                let mut state = self.state.lock().unwrap();
                let manifest = self.manifest(&mut state, cache);
                for path in &forget {
                    // Unless analysed again meanwhile.
                    if manifest.get(path) == manifest_before.get(path) {
                        manifest.remove(path);
                    }
                }
            }
            self.persist(cache);
        }
        Some(kept)
    }
}

impl Engine {
    /// The files analysed ahead (and the entries of every Set whose
    /// features, waveform and tempo are all kept): `paths` in order, true
    /// for each so done as it is now.
    pub fn analysed(&self, paths: &[String]) -> Result<Vec<bool>> {
        let cache = cache(self);
        let waves = wave_cache(self);
        let known: HashMap<String, (f64, bool)> = self.with_store(|s| {
            Ok(s.doc
                .sets
                .iter()
                .flat_map(|set| &set.entries)
                .map(|e| (e.path.clone(), (e.duration, e.silent)))
                .collect())
        })?;
        let manifest = {
            let mut state = self.analysis.state.lock().unwrap();
            self.analysis.manifest(&mut state, &cache).clone()
        };
        Ok(paths
            .iter()
            .map(|path| {
                let file = Path::new(path);
                let Ok(signature) = index::signature(file) else { return false };
                let (duration, silent, wave, tempo) = match manifest.get(path) {
                    Some(done) if done.signature == signature && (!done.silent || done.hearing >= HEARING) => {
                        (done.duration, done.silent, done.wave, done.tempo)
                    }
                    _ => match known.get(path) {
                        Some(&(duration, silent)) => (duration, silent, !silent, !silent),
                        None => return false,
                    },
                };
                let Ok(entry) = entry_of(file, duration, silent) else { return false };
                index::blocks(&entry).all(|(start, end)| index::block_path(&cache, &entry, &signature, start, end).is_file())
                    && (!wave || waveform::cache_file(file, &signature, &waves).is_file())
                    && (!tempo || rhythm::cached(file, &signature, &waves))
            })
            .collect())
    }

    /// Files and folders (searched through) to analyse ahead, after those
    /// waiting; those analysed already or waiting are passed over.
    pub fn analyse(self: &Arc<Self>, paths: &[String]) -> Result<Progress> {
        let mut files = Vec::new();
        let mut pending: Vec<PathBuf> = paths.iter().rev().map(PathBuf::from).collect();
        while let Some(path) = pending.pop() {
            if files.len() >= MOST {
                break;
            }
            if path.is_dir() {
                let Ok(dir) = fs::read_dir(&path) else { continue };
                let mut children: Vec<_> = dir
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')))
                    .collect();
                children.sort();
                pending.extend(children.into_iter().rev());
            } else if is_video(&path) {
                files.push(path);
            }
        }
        let names: Vec<String> = files.iter().map(|p| key(p)).collect::<Vec<_>>();
        let done = self.analysed(&names)?;
        let start = {
            let mut state = self.analysis.state.lock().unwrap();
            for (file, done) in files.into_iter().zip(done) {
                if !done && state.current.as_ref() != Some(&file) && !state.waiting.contains(&file) {
                    state.waiting.push_back(file);
                }
            }
            // Asked again after a stop: what waits now is analysed.
            if !state.waiting.is_empty() {
                self.analysis.cancel.store(false, Ordering::Relaxed);
            }
            let start = !state.running && !state.waiting.is_empty();
            if start {
                state.running = true;
                state.done = 0;
                state.failed = 0;
                state.error.clear();
            }
            start
        };
        if start {
            let engine = self.clone();
            let spawned = std::thread::Builder::new()
                .name("kvj-analyse".into())
                .spawn(move || engine.analyse_queue());
            if let Err(error) = spawned {
                self.analysis.state.lock().unwrap().running = false;
                return Err(error.into());
            }
        }
        Ok(self.analysis.progress())
    }

    /// Stops the analysis: the file under way is left (what of it is done is
    /// kept), the rest no longer waits.
    pub fn analysis_stop(&self) -> Progress {
        {
            let mut state = self.analysis.state.lock().unwrap();
            state.waiting.clear();
            if state.running {
                self.analysis.cancel.store(true, Ordering::Relaxed);
            }
        }
        self.analysis.progress()
    }

    fn analyse_queue(self: Arc<Self>) {
        let _background = super::qos::prefer_background();
        let cache = cache(&self);
        let waves = wave_cache(&self);
        loop {
            let next = {
                let mut state = self.analysis.state.lock().unwrap();
                let next = if self.analysis.cancel.load(Ordering::Relaxed) {
                    None
                } else {
                    state.waiting.pop_front()
                };
                state.current = next.clone();
                if next.is_none() {
                    state.running = false;
                }
                next
            };
            let Some(path) = next else { break };
            let cancel = self.analysis.cancel.clone();
            let cancelled = move || cancel.load(Ordering::Relaxed);
            let result = analyse_file(&path, &cache, &waves, &cancelled);
            let mut state = self.analysis.state.lock().unwrap();
            match result {
                Ok(Some(done)) => {
                    state.done += 1;
                    self.analysis.manifest(&mut state, &cache).insert(key(&path), done);
                    drop(state);
                    self.analysis.persist(&cache);
                    state = self.analysis.state.lock().unwrap();
                }
                Ok(None) => {}
                Err(error) => {
                    state.failed += 1;
                    state.error = format!(
                        "{}：{error:#}",
                        path.file_name().map_or_else(|| key(&path), |n| n.to_string_lossy().into_owned())
                    );
                    tracing::debug!("提前分析：{}", state.error);
                }
            }
            drop(state);
            self.analysis.revision.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// Everything of one file into the caches; None when stopped on the way.
fn analyse_file(
    path: &Path,
    cache: &Path,
    waves: &Path,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Result<Option<Done>> {
    let signature = index::signature(path)?;
    let probe = decode::probe(path).with_context(|| format!("无法读取：{}", path.display()))?;
    let duration = probe.duration.context("无法读取时长")?;
    let silent = !probe.audio;
    let entry = entry_of(path, duration, silent)?;
    fs::create_dir_all(cache)?;
    for (start, end) in index::blocks(&entry) {
        if cancelled() {
            return Ok(None);
        }
        let file = index::block_path(cache, &entry, &signature, start, end);
        if index::read_block(&file).is_none() {
            index::extract(&entry, &signature, start, end, &file, cancelled)?;
        }
    }
    let (mut wave, mut tempo) = (false, false);
    if !silent {
        wave = waveform::load(path, waves, cancelled)?.is_some();
        if cancelled() {
            return Ok(None);
        }
        tempo = rhythm::load(path, waves, cancelled)?.is_some();
        if cancelled() {
            return Ok(None);
        }
    }
    anyhow::ensure!(index::signature(path)? == signature, "分析期间文件已变化");
    Ok(Some(Done { signature, duration, silent, wave, tempo, hearing: HEARING }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_manifest_keeps_what_is_there_and_forgets_what_changed() {
        let dir = std::env::temp_dir().join(format!("kvj-analysed-{}", document::id()));
        let cache = dir.join("cache");
        fs::create_dir_all(&cache).unwrap();
        let (a, b, c) = (dir.join("a.mp4"), dir.join("b.mp4"), dir.join("c.mp4"));
        for p in [&a, &b, &c] {
            fs::write(p, b"x").unwrap();
        }
        let done = |p: &Path| Done {
            signature: index::signature(p).unwrap(),
            duration: 400.,
            silent: false,
            wave: true,
            tempo: true,
            hearing: HEARING,
        };
        let mut manifest = BTreeMap::new();
        manifest.insert(key(&a), done(&a));
        manifest.insert(key(&b), done(&b));
        manifest.insert(key(&c), done(&c));
        Analysis::save_manifest(&manifest, &cache);
        // b changed, c deleted (its folder is there: it is gone, not away).
        fs::write(&b, b"changed").unwrap();
        fs::remove_file(&c).unwrap();
        let kept = Analysis::default().kept(&cache).unwrap();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].path, key(&a));
        let saved: BTreeMap<String, Done> = serde_json::from_slice(&fs::read(cache.join(MANIFEST)).unwrap()).unwrap();
        assert_eq!(saved.keys().cloned().collect::<Vec<_>>(), vec![key(&a)]);
        let _ = fs::remove_dir_all(&dir);
    }
}
