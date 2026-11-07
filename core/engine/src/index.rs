//! Set preprocessing: immutable source signatures, reusable per-block spectra,
//! and one ordered retrieval index. Cache writes never touch the Set document.
use super::{
    diagnostics::{Level, Stage},
    document::{Entry, Set},
    runtime::{log, publish},
    Engine,
};
use anyhow::{bail, Context, Result};
use kvj_recognize::{LiveFeatures, LiveIndex, LIVE_FEATURE_REVISION};
use std::{
    collections::HashSet,
    fs,
    hash::{Hash, Hasher},
    io::{BufReader, BufWriter},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::SystemTime,
};
/// Set indexes kept on disk besides the one in use, the most recently used.
const KEPT_INDEXES: usize = 4;


#[derive(Clone)]
pub struct Recording {
    pub entry: Entry,
    pub signature: String,
}
#[derive(Clone)]
pub struct Target {
    pub recording: usize,
    pub start: f64,
    pub end: f64,
    pub path: PathBuf,
}
pub struct PreparedSet {
    pub key: String,
    pub recordings: Vec<Recording>,
    pub targets: Vec<Target>,
    pub index: Mutex<LiveIndex>,
}
pub fn signature(path: &Path) -> Result<String> {
    let m = fs::metadata(path).with_context(|| format!("素材文件不存在或无法读取：{}", path.display()))?;
    Ok(format!(
        "{}:{}",
        m.len(),
        m.modified()?
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos()
    ))
}
/// What is indexed: the entries placed on the timeline, on any track. The
/// rest of the library is not, so a big library costs no memory or waiting;
/// one placed while following is indexed then (`grow`) and followed once it is.
pub(super) fn used(set: &Set) -> Set {
    let mut used = set.clone();
    used.entries.retain(|e| e.enabled);
    used
}
fn key(set: &Set) -> Result<String> {
    // Whatever track an entry is on, so moving it to another keeps the index.
    let mut indexed = used(set);
    for e in &mut indexed.entries {
        e.track = 0;
    }
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (
        "live-set-landmarks-v6",
        LIVE_FEATURE_REVISION,
        serde_json::to_vec(&indexed)?,
    )
        .hash(&mut h);
    for e in &indexed.entries {
        signature(Path::new(&e.path))?.hash(&mut h);
    }
    Ok(format!("{:016x}", h.finish()))
}
/// The index on disk depends only on the files placed, in order, and their
/// lengths: renaming an entry or changing how it is shown keeps it (five hours
/// of them make an index of hundreds of MiB).
pub(super) fn disk_key(set: &Set) -> Result<String> {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    ("live-set-landmarks-v6", LIVE_FEATURE_REVISION).hash(&mut h);
    for e in &used(set).entries {
        (&e.path, signature(Path::new(&e.path))?, e.duration.to_bits()).hash(&mut h);
    }
    Ok(format!("{:016x}", h.finish()))
}
/// The cached features of one block of an entry.
fn block_path(cache: &Path, entry: &Entry, signature: &str, start: f64, end: f64) -> PathBuf {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (
        "live-vj-landmarks-v6",
        LIVE_FEATURE_REVISION,
        &entry.path,
        signature,
        start.to_bits(),
        end.to_bits(),
    )
        .hash(&mut h);
    cache.join(format!("{:016x}.afp", h.finish()))
}
/// Blocks of about five minutes, overlapping by eight seconds: (start, end).
/// None for a silent entry: there is nothing to hear it by.
fn blocks(entry: &Entry) -> impl Iterator<Item = (f64, f64)> + '_ {
    let heard = if entry.silent { 0 } else { entry.duration.ceil() as usize };
    (0..heard).step_by(300).map(|core| {
        ((core as f64 - 8.).max(0.), (core as f64 + 308.).min(entry.duration))
    })
}
/// Written in full and on the disk before it takes the name: power lost on
/// the way leaves the old file or none, never a cut one every later start trips on.
fn save(path: &Path, write: impl FnOnce(&mut BufWriter<fs::File>) -> Result<()>) -> Result<()> {
    let temp = path.with_extension("part");
    let saved = (|| -> Result<()> {
        let mut f = BufWriter::new(fs::File::create(&temp)?);
        write(&mut f)?;
        f.into_inner().map_err(|e| e.into_error())?.sync_all()?;
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if saved.is_err() {
        let _ = fs::remove_file(&temp);
    }
    saved
}
/// Drop what no Set needs any more: indexes beyond the most recently used,
/// features of files that changed or left every Set, and unfinished writes.
/// Features are only judged when every file of every Set can be seen (a
/// drive away keeps its entries' features).
fn prune(cache: &Path, current: &Path, sets: &[Set]) {
    let Ok(dir) = fs::read_dir(cache) else { return };
    let files: Vec<_> = dir.filter_map(|e| e.ok()).map(|e| e.path()).collect();
    let mut indexes: Vec<(SystemTime, &PathBuf)> = files
        .iter()
        .filter(|p| p.as_path() != current && p.extension().is_some_and(|x| x == "lvi"))
        .map(|p| (fs::metadata(p).and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH), p))
        .collect();
    indexes.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, path) in indexes.iter().skip(KEPT_INDEXES) {
        let _ = fs::remove_file(path);
    }
    for path in files.iter().filter(|p| p.extension().is_some_and(|x| x == "part")) {
        let _ = fs::remove_file(path);
    }
    let mut needed = HashSet::new();
    for entry in sets.iter().flat_map(|s| &s.entries) {
        let Ok(signature) = signature(Path::new(&entry.path)) else { return };
        for (start, end) in blocks(entry) {
            needed.insert(block_path(cache, entry, &signature, start, end));
        }
    }
    for path in files.iter().filter(|p| p.extension().is_some_and(|x| x == "afp")) {
        if !needed.contains(path) {
            let _ = fs::remove_file(path);
        }
    }
}
/// One block into `index`: its features from the cache, else decoded (and
/// cached).
#[allow(clippy::too_many_arguments)]
fn add(
    engine: &Engine,
    session: &str,
    index: &mut LiveIndex,
    id: usize,
    total: usize,
    target: &Target,
    recording: &Recording,
    cancel: &AtomicBool,
) -> Result<()> {
    let entry = &recording.entry;
    let cached = fs::File::open(&target.path)
        .ok()
        .and_then(|f| LiveFeatures::read_from(BufReader::new(f)).ok());
    let summary = if let Some(summary) = cached {
        log(
            engine,
            session,
            Level::Info,
            Stage::Index,
            format!("{} · 复用指纹，加入整套索引", entry.title),
        );
        summary
    } else {
        log(
            engine,
            session,
            Level::Info,
            Stage::Index,
            format!(
                "{} · {:.1}–{:.1} 秒 · 提取音频特征",
                entry.title, target.start, target.end
            ),
        );
        let audio = super::decode::decode_audio_from_cancellable(
            Path::new(&entry.path),
            8000,
            Some(target.end - target.start),
            target.start,
            &|| cancel.load(Ordering::Relaxed),
        )?
        .context("已停止")?;
        let features = LiveFeatures::prepare(&audio.samples, &|| cancel.load(Ordering::Relaxed))?;
        anyhow::ensure!(
            signature(Path::new(&entry.path))? == recording.signature,
            "素材已变化：{}",
            entry.title
        );
        save(&target.path, |f| features.write_to(f))?;
        features
    };
    index.add(id, &summary)?;
    log(
        engine,
        session,
        Level::Info,
        Stage::Index,
        format!(
            "索引区块 {}/{} · {} 条地标 · {:.1} MiB",
            id + 1,
            total,
            index.landmark_count(),
            index.memory_bytes() as f64 / 1_048_576.
        ),
    );
    Ok(())
}
/// Entries placed while following (`set` is the Set as it is now), indexed
/// beside the running session: a copy of its index with theirs added after,
/// so every recording and block keeps its number and the session swaps it in
/// between two rounds. None when every placed entry is in it already.
pub(super) fn grow(
    engine: &Engine,
    session: &str,
    old: &PreparedSet,
    set: &Set,
    cache: &Path,
    cancel: &AtomicBool,
) -> Result<Option<PreparedSet>> {
    let have: HashSet<&str> = old.recordings.iter().map(|r| r.entry.id.as_str()).collect();
    let new: Vec<Entry> = used(set)
        .entries
        .into_iter()
        .filter(|e| !have.contains(e.id.as_str()))
        .collect();
    let mut recordings = old.recordings.clone();
    let mut targets = old.targets.clone();
    let first = targets.len();
    for entry in new {
        let Ok(before) = signature(Path::new(&entry.path)) else {
            log(engine, session, Level::Warn, Stage::Index, format!("素材文件不可用，暂不加入索引：{}", entry.title));
            continue;
        };
        for (start, end) in blocks(&entry) {
            targets.push(Target {
                recording: recordings.len(),
                start,
                end,
                path: block_path(cache, &entry, &before, start, end),
            });
        }
        log(engine, session, Level::Info, Stage::Index, format!("{} · 放上轨道，正在加入索引", entry.title));
        recordings.push(Recording { entry, signature: before });
    }
    if recordings.len() == old.recordings.len() {
        return Ok(None);
    }
    fs::create_dir_all(cache)?;
    let mut index = old.index.lock().unwrap().duplicate()?;
    for id in first..targets.len() {
        if cancel.load(Ordering::Relaxed) {
            bail!("已停止")
        }
        let target = &targets[id];
        add(engine, session, &mut index, id, targets.len(), target, &recordings[target.recording], cancel)?;
    }
    index.warm(&|| cancel.load(Ordering::Relaxed))?;
    // The key of exactly these entries, in this order: a session started on
    // the same placed entries in the same order reuses it.
    let mut indexed = set.clone();
    indexed.entries = recordings.iter().map(|r| r.entry.clone()).collect();
    for e in &mut indexed.entries {
        e.enabled = true;
    }
    Ok(Some(PreparedSet {
        key: key(&indexed)?,
        recordings,
        targets,
        index: Mutex::new(index),
    }))
}
pub fn prepare(
    engine: &Engine,
    session: &str,
    set: &Set,
    cache: &Path,
    cancel: &AtomicBool,
) -> Result<Arc<PreparedSet>> {
    let set = &used(set);
    let key = key(set)?;
    if let Some(ready) = engine
        .prepared
        .lock()
        .unwrap()
        .as_ref()
        .filter(|p| p.key == key)
        .cloned()
    {
        publish(engine, session, |v| {
            v.indexed = set.entries.len();
            v.preparing = None;
        });
        log(
            engine,
            session,
            Level::Info,
            Stage::Index,
            "复用整套短窗特征索引，无需重新解码".into(),
        );
        return Ok(ready);
    }
    // Sessions cannot overlap. Release a different Set before constructing its
    // replacement, rather than retaining two resident indexes at peak usage.
    engine.prepared.lock().unwrap().take();
    fs::create_dir_all(cache)?;
    let mut recordings = Vec::new();
    let mut targets = Vec::new();
    for (i, entry) in set.entries.iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            bail!("已停止")
        }
        let before = signature(Path::new(&entry.path))?;
        for (start, end) in blocks(entry) {
            targets.push(Target {
                recording: i,
                start,
                end,
                path: block_path(cache, entry, &before, start, end),
            });
        }
        recordings.push(Recording {
            entry: entry.clone(),
            signature: before,
        });
    }
    let index_path = cache.join(format!("set-{}.lvi", disk_key(set)?));
    let disk_index = fs::File::open(&index_path)
        .ok()
        .and_then(|f| LiveIndex::read_from(BufReader::new(f)).ok())
        .filter(|index| {
            index.targets() == (0..targets.len()).collect::<Vec<_>>()
                && targets.iter().all(|t| t.path.is_file())
        });
    let mut index = if let Some(index) = disk_index {
        log(
            engine,
            session,
            Level::Info,
            Stage::Index,
            format!(
                "读取整套特征索引 · {} 个素材 / {} 个区块 · 顺序及素材签名一致",
                recordings.len(),
                targets.len()
            ),
        );
        index
    } else {
        let mut index = LiveIndex::default();
        for (id, target) in targets.iter().enumerate() {
            if cancel.load(Ordering::Relaxed) {
                bail!("已停止")
            }
            let recording = &recordings[target.recording];
            let entry = &recording.entry;
            publish(engine, session, |v| {
                v.phase = "indexing".into();
                v.preparing = Some(entry.id.clone());
                v.indexed = target.recording;
            });
            add(engine, session, &mut index, id, targets.len(), target, recording, cancel)?;
        }
        save(&index_path, |f| index.write_to(f))?;
        index
    };
    // Most recently used first when old indexes are dropped.
    if let Ok(file) = fs::File::options().write(true).open(&index_path) {
        let _ = file.set_modified(SystemTime::now());
    }
    if let Ok(sets) = engine.with_store(|s| Ok(s.doc.sets.clone())) {
        prune(cache, &index_path, &sets);
    }
    anyhow::ensure!(self::key(set)? == key, "预处理期间素材已变化，请重试");
    index.warm(&|| cancel.load(Ordering::Relaxed))?;
    let landmark_count = index.landmark_count();
    let index_mib = index.memory_bytes() as f64 / 1_048_576.;
    let ready = Arc::new(PreparedSet {
        key,
        recordings,
        targets,
        index: Mutex::new(index),
    });
    *engine.prepared.lock().unwrap() = Some(ready.clone());
    publish(engine, session, |v| {
        v.indexed = set.entries.len();
        v.preparing = None;
    });
    log(
        engine,
        session,
        Level::Info,
        Stage::Index,
        format!(
            "整套预处理完成 · {} 个素材 · {} 条地标 · {:.1} MiB · 常驻倒排索引已就绪",
            set.entries.len(),
            landmark_count,
            index_mib
        ),
    );
    Ok(ready)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_placed_entries_are_indexed_on_whatever_track() {
        let dir = std::env::temp_dir().join(format!("kvj-index-key-{}", super::super::document::id()));
        fs::create_dir_all(&dir).unwrap();
        let (a, b) = (dir.join("a.mp4"), dir.join("b.mp4"));
        fs::write(&a, b"x").unwrap();
        fs::write(&b, b"yy").unwrap();
        let mut set: Set = serde_json::from_value(serde_json::json!({
            "id": "s", "name": "Set 1",
            "entries": [
                {"id": "a", "path": a, "title": "a", "duration": 60.0, "video": true, "presentation": "video"},
                {"id": "b", "path": b, "title": "b", "duration": 60.0, "video": true, "presentation": "video", "enabled": false}
            ]
        }))
        .unwrap();
        assert_eq!(used(&set).entries.len(), 1);
        let on = key(&set).unwrap();
        let disk = disk_key(&set).unwrap();
        // Moving a placed entry to another track keeps the index.
        set.entries[0].track = 2;
        assert_eq!(key(&set).unwrap(), on);
        // What is only in the library is not in it: changing it changes nothing.
        set.entries[1].title = "renamed".into();
        set.entries[1].track = 1;
        assert_eq!(key(&set).unwrap(), on);
        assert_eq!(disk_key(&set).unwrap(), disk);
        // Placing it, or taking one off, is another index.
        set.entries[1].enabled = true;
        assert_ne!(key(&set).unwrap(), on);
        assert_ne!(disk_key(&set).unwrap(), disk);
        set.entries[1].enabled = false;
        set.entries[0].enabled = false;
        assert_ne!(key(&set).unwrap(), on);
        set.entries[0].enabled = true;
        // Renaming a placed entry is a new key; the index on disk, the same files', is kept.
        set.entries[0].title = "renamed".into();
        assert_ne!(key(&set).unwrap(), on);
        assert_eq!(disk_key(&set).unwrap(), disk);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn pruning_keeps_what_a_set_needs_and_recent_indexes() {
        let dir = std::env::temp_dir().join(format!("kvj-prune-{}", super::super::document::id()));
        let cache = dir.join("cache");
        fs::create_dir_all(&cache).unwrap();
        let path = dir.join("a.mp4");
        fs::write(&path, b"x").unwrap();
        let set: Set = serde_json::from_value(serde_json::json!({
            "id": "s", "name": "Set 1",
            "entries": [{"id": "a", "path": path, "title": "a", "duration": 400.0, "video": true, "presentation": "video"}]
        }))
        .unwrap();
        let signature = signature(&path).unwrap();
        let needed: Vec<_> = blocks(&set.entries[0])
            .map(|(start, end)| block_path(&cache, &set.entries[0], &signature, start, end))
            .collect();
        assert_eq!(needed.len(), 2);
        for p in &needed {
            fs::write(p, b"f").unwrap();
        }
        fs::write(cache.join("0000000000000000.afp"), b"old").unwrap();
        fs::write(cache.join("x.part"), b"cut").unwrap();
        let current = cache.join("set-current.lvi");
        fs::write(&current, b"i").unwrap();
        for n in 0..6 {
            let old = cache.join(format!("set-{n}.lvi"));
            fs::write(&old, b"i").unwrap();
            let at = SystemTime::now() - std::time::Duration::from_secs(100 - n);
            fs::File::options().write(true).open(&old).unwrap().set_modified(at).unwrap();
        }
        prune(&cache, &current, std::slice::from_ref(&set));
        assert!(needed.iter().all(|p| p.is_file()));
        assert!(current.is_file());
        assert!(!cache.join("0000000000000000.afp").exists());
        assert!(!cache.join("x.part").exists());
        let kept: Vec<_> = (0..6).filter(|n| cache.join(format!("set-{n}.lvi")).exists()).collect();
        assert_eq!(kept, vec![2, 3, 4, 5]);
        // A file out of sight keeps every feature.
        fs::write(cache.join("1111111111111111.afp"), b"f").unwrap();
        let mut away = set.clone();
        away.entries[0].path = dir.join("gone.mp4").to_string_lossy().into_owned();
        prune(&cache, &current, &[set, away]);
        assert!(cache.join("1111111111111111.afp").exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
