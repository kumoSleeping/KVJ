//! The Set document (`kvj-sets.json`). Unknown fields round-trip; a document this
//! build cannot write back without losing keys, or of another version, stays untouched.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    pub path: String,
    pub title: String,
    pub duration: f64,
    pub video: bool,
    #[serde(default)]
    pub audio_offset: f64,
    pub presentation: String,
    /// Followed only while on. The DJ turns entries on and off during the show,
    /// so this may change while a session runs and never touches the index.
    #[serde(default = "on")]
    pub enabled: bool,
    #[serde(flatten)]
    extra: BTreeMap<String, Value>,
}
fn on() -> bool {
    true
}
impl Entry {
    pub fn new(path: &Path, video: bool, audio_offset: f64, duration: f64) -> Result<Self> {
        anyhow::ensure!(
            duration.is_finite() && duration > 0. && duration <= 21600. && audio_offset.is_finite(),
            "素材时长无效或超过六小时"
        );
        Ok(Self {
            id: id(),
            path: path.to_string_lossy().into_owned(),
            title: path
                .file_stem()
                .map_or_else(String::new, |s| s.to_string_lossy().into_owned()),
            duration,
            video,
            audio_offset,
            presentation: if video { "video" } else { "audio" }.into(),
            enabled: true,
            extra: BTreeMap::new(),
        })
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Set {
    pub id: String,
    pub name: String,
    pub entries: Vec<Entry>,
    #[serde(flatten)]
    extra: BTreeMap<String, Value>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Standby {
    pub path: String,
    pub name: String,
    pub kind: String,
    #[serde(flatten)]
    extra: BTreeMap<String, Value>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Document {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub standby: Option<Standby>,
    pub version: u32,
    pub revision: u64,
    pub sets: Vec<Set>,
    #[serde(flatten)]
    extra: BTreeMap<String, Value>,
}
impl Default for Document {
    fn default() -> Self {
        Self {
            version: 1,
            standby: None,
            revision: 0,
            sets: vec![],
            extra: BTreeMap::new(),
        }
    }
}
pub fn id() -> String {
    use std::hash::{BuildHasher, Hasher};
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let state = std::collections::hash_map::RandomState::new();
    let mut words = [0u64; 2];
    for (i, word) in words.iter_mut().enumerate() {
        let mut h = state.build_hasher();
        h.write_u64(COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        h.write_u128(SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos());
        h.write_usize(i);
        *word = h.finish();
    }
    format!("{:016x}{:016x}", words[0], words[1])
}
fn lost_paths(raw: &Value, saved: &Value, path: &str, lost: &mut Vec<String>) {
    match (raw, saved) {
        (Value::Object(a), Value::Object(b)) => {
            for (key, value) in a {
                let p = format!("{path}/{key}");
                match b.get(key) {
                    Some(v) => lost_paths(value, v, &p, lost),
                    None => lost.push(p),
                }
            }
        }
        (Value::Array(a), Value::Array(b)) => {
            for (i, value) in a.iter().enumerate() {
                let p = format!("{path}/{i}");
                match b.get(i) {
                    Some(v) => lost_paths(value, v, &p, lost),
                    None => lost.push(p),
                }
            }
        }
        _ => {}
    }
}
pub struct Store {
    path: PathBuf,
    pub doc: Document,
    disk: Option<Vec<u8>>,
}
impl Store {
    pub fn open(data: &Path) -> Result<Self> {
        let path = data.join("kvj-sets.json");
        if path.exists() && fs::metadata(&path)?.len() > 32 * 1024 * 1024 {
            bail!("Set 数据超过读取上限，原文件未修改")
        }
        let disk = match fs::read(&path) {
            Ok(v) => Some(v),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(e.into()),
        };
        let doc = if let Some(bytes) = &disk {
            let raw: Value =
                serde_json::from_slice(bytes).context("Set 数据无法读取，原文件未修改")?;
            let doc: Document = serde_json::from_value(raw.clone())?;
            if doc.version != 1 {
                bail!("Set 数据版本不支持，原文件未修改")
            }
            doc.validate()?;
            let mut lost = vec![];
            lost_paths(&raw, &serde_json::to_value(&doc)?, "", &mut lost);
            if !lost.is_empty() {
                bail!("Set 数据只读，无法保留字段：{}", lost.join("、"))
            }
            doc
        } else {
            Document::default()
        };
        Ok(Self { path, doc, disk })
    }
    pub fn commit(&mut self, mut next: Document) -> Result<Document> {
        let actual = match fs::read(&self.path) {
            Ok(v) => Some(v),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(e.into()),
        };
        if actual != self.disk {
            bail!("Set 数据已被其他进程修改，请重启后重试")
        }
        next.validate()?;
        next.revision = self.doc.revision.checked_add(1).context("版本号溢出")?;
        fs::create_dir_all(self.path.parent().unwrap())?;
        if let Some(bytes) = &actual {
            let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
            let root = self.path.parent().unwrap().join("backups");
            for (kind, name, gap) in [
                ("auto", format!("kvj-sets-{now:020}.json"), 600),
                ("daily", format!("kvj-sets-{:010}.json", now / 86400), 86400),
            ] {
                let dir = root.join(kind);
                fs::create_dir_all(&dir)?;
                let recent = fs::read_dir(&dir)?
                    .filter_map(|e| e.ok())
                    .filter(|e| e.file_name().to_string_lossy().starts_with("kvj-sets-"))
                    .filter_map(|e| e.metadata().ok()?.modified().ok())
                    .max();
                let target = dir.join(name);
                if (kind == "daily" && !target.exists())
                    || (kind == "auto"
                        && recent
                            .and_then(|t| SystemTime::now().duration_since(t).ok())
                            .is_none_or(|age| age.as_secs() >= gap))
                {
                    use std::io::Write;
                    let mut file = fs::OpenOptions::new()
                        .create_new(true)
                        .write(true)
                        .open(target)?;
                    file.write_all(bytes)?;
                    file.sync_all()?;
                }
            }
        }
        let bytes = serde_json::to_vec(&next)?;
        let tmp = self.path.with_extension(format!("{}.part", id()));
        use std::io::Write;
        let result = (|| -> Result<()> {
            let mut file = fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&tmp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            replace(&tmp, &self.path)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result?;
        self.disk = Some(bytes);
        self.doc = next.clone();
        Ok(next)
    }
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Edit {
    Create {
        name: String,
    },
    Rename {
        set_id: String,
        name: String,
    },
    Delete {
        set_id: String,
    },
    Remove {
        set_id: String,
        entry_id: String,
    },
    Move {
        set_id: String,
        entry_id: String,
        before_id: Option<String>,
    },
}
#[cfg(not(windows))]
fn replace(tmp: &Path, target: &Path) -> std::io::Result<()> {
    fs::rename(tmp, target)
}
#[cfg(windows)]
fn replace(tmp: &Path, target: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let from: Vec<u16> = tmp.as_os_str().encode_wide().chain(Some(0)).collect();
    let to: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    // Both NUL-terminated UTF-16 buffers outlive the call. Replacement is on the
    // same volume and never removes the original before the rename can succeed.
    if unsafe {
        MoveFileExW(
            from.as_ptr(),
            to.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}
impl Document {
    fn validate(&self) -> Result<()> {
        if let Some(asset) = &self.standby {
            anyhow::ensure!(Path::new(&asset.path).is_absolute() && ["image", "video"].contains(&asset.kind.as_str()) && asset.name.len() <= 1024,
                "默认投放素材格式不支持，原文件未修改");
        }
        let mut ids = std::collections::HashSet::new();
        if self.sets.len() > 200 {
            bail!("Set 数量超过上限")
        }
        for set in &self.sets {
            if !ids.insert(&set.id)
                || set.id.is_empty()
                || set.entries.len() > 1000
                || set.name.len() > 512
            {
                bail!("Set 数据无效")
            }
            let mut entries = std::collections::HashSet::new();
            for entry in &set.entries {
                if !entries.insert(&entry.id)
                    || entry.id.is_empty()
                    || !entry.duration.is_finite()
                    || entry.duration <= 0.
                    || entry.duration > 21600.
                    || !Path::new(&entry.path).is_absolute()
                    || !entry.audio_offset.is_finite()
                    || entry.audio_offset.abs() > 21600.
                    || entry.presentation != if entry.video { "video" } else { "audio" }
                {
                    bail!("素材数据或表现形式不支持，原文件未修改")
                }
            }
        }
        Ok(())
    }
    pub fn edit(&mut self, edit: Edit) -> Result<()> {
        match edit {
            Edit::Create { name } => self.sets.push(Set {
                id: id(),
                name,
                entries: vec![],
                extra: BTreeMap::new(),
            }),
            Edit::Delete { set_id } => self.sets.retain(|s| s.id != set_id),
            Edit::Rename { set_id, name } => self.set_mut(&set_id)?.name = name,
            Edit::Remove { set_id, entry_id } => {
                self.set_mut(&set_id)?.entries.retain(|e| e.id != entry_id)
            }
            Edit::Move {
                set_id,
                entry_id,
                before_id,
            } => {
                if before_id.as_deref() == Some(&entry_id) {
                    return Ok(());
                }
                let entries = &mut self.set_mut(&set_id)?.entries;
                let from = entries
                    .iter()
                    .position(|e| e.id == entry_id)
                    .context("素材不存在")?;
                let item = entries.remove(from);
                let target = match before_id {
                    Some(id) => entries
                        .iter()
                        .position(|e| e.id == id)
                        .context("排序目标不存在")?,
                    None => entries.len(),
                };
                entries.insert(target, item);
            }
        }
        Ok(())
    }
    /// Turns entries of one Set on or off for following.
    pub fn enable(&mut self, set_id: &str, entry_ids: &[String], on: bool) -> Result<()> {
        let set = self.set_mut(set_id)?;
        for id in entry_ids {
            set.entries
                .iter_mut()
                .find(|e| &e.id == id)
                .context("素材不存在")?
                .enabled = on;
        }
        Ok(())
    }
    pub fn set_mut(&mut self, id: &str) -> Result<&mut Set> {
        self.sets
            .iter_mut()
            .find(|s| s.id == id)
            .context("Set 不存在")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_are_on_unless_turned_off() {
        // Documents written before the switch existed load with every entry on.
        let raw = r#"{"version":1,"revision":3,"sets":[{"id":"s","name":"Set 1","entries":[
            {"id":"a","path":"/a.mp4","title":"a","duration":60,"video":true,"presentation":"video"},
            {"id":"b","path":"/b.mp4","title":"b","duration":60,"video":true,"presentation":"video"}]}]}"#;
        let mut doc: Document = serde_json::from_str(raw).unwrap();
        assert!(doc.sets[0].entries.iter().all(|e| e.enabled));
        doc.enable("s", &["b".into()], false).unwrap();
        assert!(doc.sets[0].entries[0].enabled && !doc.sets[0].entries[1].enabled);
        let back: Document = serde_json::from_value(serde_json::to_value(&doc).unwrap()).unwrap();
        assert!(!back.sets[0].entries[1].enabled);
        assert!(doc.enable("s", &["missing".into()], true).is_err());
    }
}
