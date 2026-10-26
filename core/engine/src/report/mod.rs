//! Bug reports and the update check, after KDJ's (`crates/kdj-server/src/
//! diagnostics/reports.rs`, `crates/kdj-providers/src/update.rs`).
//!
//! A report is built only when asked, from the session logs on disk
//! (`<data>/logs/kvj-*.log`) and recorded panics, scrubbed (`redact`), shown in
//! full, and sent only once the operator confirms that exact text. There is no
//! scheduler, no retry and no saved consent; a retry sends the same report id,
//! which the collector stores once.
mod redact;
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::{
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const ENDPOINT: &str = "https://bug.kvj.kumo.ltd/v1/reports";
const RELEASES: &str = "https://api.github.com/repos/kumoSleeping/KVJ/releases?per_page=20";
const MAX_REPORT_BYTES: usize = 256 * 1024;
/// How much of the newest log files is read; the collector keeps 300 entries.
const READ_BYTES: u64 = 384 * 1024;
const MAX_ENTRIES: usize = 300;
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Serialize)]
struct Entry {
    timestamp: String,
    session: String,
    level: String,
    category: String,
    source: String,
    message: String,
}
struct Prepared {
    id: String,
    body: String,
    expires: Instant,
    uploading: bool,
    receipt: Option<String>,
}
#[derive(Default)]
pub struct Reports {
    pending: Mutex<Option<Prepared>>,
}
#[derive(Serialize)]
pub struct Preview {
    pub id: String,
    pub body: String,
    pub bytes: usize,
    pub destination: &'static str,
}

/// Panics are caught at the C ABI and fail one call; the hook also writes them
/// where a report can find them (and the previous hook still prints them).
pub fn record_panics(dir: &Path) {
    static ONCE: std::sync::Once = std::sync::Once::new();
    let file = dir.join("logs").join("panics.log");
    ONCE.call_once(move || {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let backtrace = std::backtrace::Backtrace::force_capture();
            let line = format!("{} {info}\n{backtrace}", local_stamp());
            let line: String = line.chars().take(8000).collect();
            // Kept small: a file that grew past 256 KiB starts again.
            if fs::metadata(&file).is_ok_and(|m| m.len() > 256 * 1024) {
                let _ = fs::remove_file(&file);
            }
            if let Some(parent) = file.parent() {
                let _ = fs::create_dir_all(parent);
            }
            if let Ok(mut out) = fs::OpenOptions::new().create(true).append(true).open(&file) {
                use std::io::Write;
                let _ = writeln!(out, "{}\n\u{1e}", line.replace('\u{1e}', ""));
            }
            previous(info);
        }));
    });
}

impl Reports {
    pub fn prepare(&self, dir: &Path, note: &str) -> Result<Preview> {
        let mut pending = self.pending.lock().unwrap();
        anyhow::ensure!(!pending.as_ref().is_some_and(|p| p.uploading), "报告正在上传");
        let id = crate::document::id();
        let mut entries = log_entries(&dir.join("logs"))?;
        let total = entries.len();
        let mut report = serde_json::json!({
            "schema": 1, "id": id, "app_version": VERSION,
            "created_at": utc_stamp(SystemTime::now()),
            "os": std::env::consts::OS, "arch": std::env::consts::ARCH,
            "cpu_threads": std::thread::available_parallelism().map_or(0, |n| n.get()),
            "dropped": 0, "note": redact::text(note, 2_000),
            "entries": [], "omitted": 0
        });
        let body = loop {
            report["omitted"] = (total - entries.len()).into();
            report["entries"] = serde_json::to_value(&entries)?;
            let body = serde_json::to_string_pretty(&report)?;
            if body.len() <= MAX_REPORT_BYTES {
                break body;
            }
            if entries.is_empty() {
                bail!("报告过大");
            }
            let drop = (entries.len() / 10).max(1);
            entries.drain(..drop);
        };
        *pending = Some(Prepared {
            id: id.clone(),
            body: body.clone(),
            expires: Instant::now() + Duration::from_secs(15 * 60),
            uploading: false,
            receipt: None,
        });
        Ok(Preview { id, bytes: body.len(), body, destination: ENDPOINT })
    }
    /// Sends exactly the previewed report. Never retried by itself.
    pub fn submit(&self, id: &str) -> Result<String> {
        let body = {
            let mut pending = self.pending.lock().unwrap();
            let prepared = pending
                .as_mut()
                .filter(|p| p.id == id && Instant::now() < p.expires)
                .context("预览已过期，请重新生成并核对")?;
            if let Some(receipt) = &prepared.receipt {
                return Ok(receipt.clone());
            }
            anyhow::ensure!(!prepared.uploading, "报告正在上传");
            prepared.uploading = true;
            prepared.body.clone()
        };
        let result = send(&body, id);
        if let Some(p) = self.pending.lock().unwrap().as_mut().filter(|p| p.id == id) {
            p.uploading = false;
            if result.is_ok() {
                p.receipt = Some(id.to_owned());
            }
        }
        result.map(|()| id.to_owned())
    }
}

fn agent() -> ureq::Agent {
    let builder = ureq::AgentBuilder::new();
    let builder = match native_tls::TlsConnector::new() {
        Ok(tls) => builder.tls_connector(std::sync::Arc::new(tls)),
        Err(_) => builder,
    };
    builder
        .redirects(0)
        .timeout_connect(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .user_agent(&format!("KVJ/{VERSION}"))
        .build()
}
fn send(body: &str, id: &str) -> Result<()> {
    let response = match agent().post(ENDPOINT).set("Content-Type", "application/json").send_string(body) {
        Ok(response) => response,
        Err(ureq::Error::Status(code, _)) => bail!("收集器返回 HTTP {code}，未自动重试"),
        Err(_) => bail!("上报连接失败或超时，未自动重试；可手动重试同一报告"),
    };
    let mut bytes = Vec::new();
    response.into_reader().take(4097).read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() <= 4096, "收集器回执过大");
    let receipt: serde_json::Value = serde_json::from_slice(&bytes).context("收集器回执无效")?;
    anyhow::ensure!(receipt["id"].as_str() == Some(id), "收集器回执不匹配");
    Ok(())
}

/// The newest entries of the session logs (today's and the day before), then
/// recorded panics, oldest first, each scrubbed.
fn log_entries(dir: &Path) -> Result<Vec<Entry>> {
    let mut files: Vec<PathBuf> = fs::read_dir(dir)
        .map(|read| read.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    files.retain(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("kvj-") && n.ends_with(".log")));
    files.sort();
    let mut entries = Vec::new();
    let mut budget = READ_BYTES;
    let mut days: Vec<(PathBuf, String, bool)> = Vec::new();
    for path in files.iter().rev().take(2) {
        let len = fs::metadata(path).map_or(0, |m| m.len());
        let take = len.min(budget);
        budget -= take;
        let mut file = fs::File::open(path)?;
        file.seek(SeekFrom::Start(len - take))?;
        let mut bytes = Vec::new();
        file.take(take).read_to_end(&mut bytes)?;
        days.push((path.clone(), String::from_utf8_lossy(&bytes).into_owned(), take < len));
    }
    for (path, text, cut) in days.iter().rev() {
        let day = path.file_stem().and_then(|n| n.to_str()).and_then(|n| n.strip_prefix("kvj-")).unwrap_or("1970-01-01");
        let session = crate::document::id();
        // The first line is cut where reading started.
        let skip = usize::from(*cut);
        for line in text.lines().skip(skip) {
            let Some((time, rest)) = line.split_once(' ') else { continue };
            let (level, message) = match rest.strip_prefix('[').and_then(|r| r.split_once("] ")) {
                Some((level, message)) => (level, message),
                None => ("info", rest),
            };
            let level = match level { "error" => "error", "warn" => "warn", _ => "info" };
            entries.push(Entry {
                timestamp: format!("{day}T{time}"),
                session: session.clone(),
                level: level.into(),
                category: "log".into(),
                source: "kvj".into(),
                message: redact::text(message, 8_000),
            });
        }
    }
    if let Ok(text) = fs::read_to_string(dir.join("panics.log")) {
        let session = crate::document::id();
        for panic in text.split('\u{1e}').map(str::trim).filter(|p| !p.is_empty()) {
            let (stamp, message) = panic.split_once(' ').unwrap_or(("1970-01-01T00:00:00.000", panic));
            entries.push(Entry {
                timestamp: stamp.into(),
                session: session.clone(),
                level: "error".into(),
                category: "panic".into(),
                source: "kvj-engine".into(),
                message: redact::text(message, 8_000),
            });
        }
    }
    let excess = entries.len().saturating_sub(MAX_ENTRIES);
    entries.drain(..excess);
    Ok(entries)
}

#[derive(Serialize)]
pub struct Update {
    pub current: String,
    pub latest: String,
    pub newer: bool,
    pub url: String,
    pub name: String,
    pub published_at: String,
}
/// The newest published KVJ release. Every KVJ release so far is a
/// pre-release, which GitHub's `releases/latest` skips, so the list is read
/// and the highest version taken.
pub fn check_update() -> Result<Update> {
    let response = agent()
        .get(RELEASES)
        .set("Accept", "application/vnd.github+json")
        .call()
        .map_err(|error| match error {
            ureq::Error::Status(code, _) => anyhow::anyhow!("检查更新失败：GitHub 返回 HTTP {code}"),
            _ => anyhow::anyhow!("检查更新失败：无法连接 GitHub"),
        })?;
    let mut bytes = Vec::new();
    response.into_reader().take(2 * 1024 * 1024).read_to_end(&mut bytes)?;
    let releases: Vec<serde_json::Value> = serde_json::from_slice(&bytes).context("检查更新失败：GitHub 回复无效")?;
    let current = semver::Version::parse(VERSION)?;
    let best = releases
        .iter()
        .filter(|r| !r["draft"].as_bool().unwrap_or(false))
        .filter_map(|r| {
            let tag = r["tag_name"].as_str()?;
            Some((semver::Version::parse(tag.trim_start_matches('v')).ok()?, r))
        })
        .max_by(|a, b| {
            if is_newer(&a.0, &b.0) { std::cmp::Ordering::Less } else if is_newer(&b.0, &a.0) { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Equal }
        });
    let Some((latest, release)) = best else {
        return Ok(Update { current: VERSION.into(), latest: VERSION.into(), newer: false, url: String::new(), name: String::new(), published_at: String::new() });
    };
    let text = |key: &str| release[key].as_str().unwrap_or_default().to_owned();
    Ok(Update {
        current: VERSION.into(),
        newer: is_newer(&current, &latest),
        latest: latest.to_string(),
        url: text("html_url"),
        name: text("name"),
        published_at: text("published_at"),
    })
}
/// KDJ's comparison (`src-tauri/src/release_version.rs`): `rcN` counts as
/// `rc.N`, so rc10 comes after rc9 and every rc before the release itself.
fn normalized(version: &semver::Version) -> semver::Version {
    let mut version = version.clone();
    for stage in ["alpha", "beta", "rc"] {
        let Some(sequence) = version.pre.as_str().strip_prefix(stage) else { continue };
        if !sequence.is_empty() && sequence.bytes().all(|b| b.is_ascii_digit()) {
            if let Ok(pre) = semver::Prerelease::new(&format!("{stage}.{sequence}")) {
                version.pre = pre;
            }
        }
        break;
    }
    version
}
pub fn is_newer(current: &semver::Version, candidate: &semver::Version) -> bool {
    normalized(candidate) > normalized(current)
}

/// Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}
fn utc_stamp(at: SystemTime) -> String {
    let ms = at.duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64;
    let (secs, ms) = (ms.div_euclid(1000), ms.rem_euclid(1000));
    let (y, mo, d) = civil(secs.div_euclid(86_400));
    let t = secs.rem_euclid(86_400);
    format!("{y:04}-{mo:02}-{d:02}T{:02}:{:02}:{:02}.{ms:03}Z", t / 3600, t / 60 % 60, t % 60)
}
/// A panic's time, in UTC like the report itself.
fn local_stamp() -> String {
    utc_stamp(SystemTime::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rc_sequence_crosses_digit_boundaries_without_downgrading() {
        for (current, candidate, expected) in [
            ("0.1.0-rc2", "0.1.0-rc10", true),
            ("0.1.0-rc10", "0.1.0-rc9", false),
            ("0.1.0-rc3", "0.1.0-rc3", false),
            ("0.1.0-rc3", "0.1.0", true),
            ("0.1.0", "0.1.0-rc9", false),
            ("0.1.0-rc3", "0.2.0-rc1", true),
        ] {
            assert_eq!(is_newer(&current.parse().unwrap(), &candidate.parse().unwrap()), expected, "{current} -> {candidate}");
        }
    }
    #[test]
    fn utc_stamps_are_iso() {
        assert_eq!(utc_stamp(UNIX_EPOCH + Duration::from_millis(1_793_059_200_123)), "2026-10-27T00:00:00.123Z");
        assert_eq!(utc_stamp(UNIX_EPOCH), "1970-01-01T00:00:00.000Z");
    }
    #[test]
    fn a_report_carries_scrubbed_log_lines_within_its_limit() {
        let dir = std::env::temp_dir().join(format!("kvj-report-{}", crate::document::id()));
        fs::create_dir_all(dir.join("logs")).unwrap();
        let mut log = String::new();
        for i in 0..5000 {
            log.push_str(&format!("10:00:{:02}.000 [warn] 素材不可用：/Users/kumo/Music/{i}.mp4\n", i % 60));
        }
        fs::write(dir.join("logs").join("kvj-2026-10-27.log"), log).unwrap();
        let reports = Reports::default();
        let preview = reports.prepare(&dir, "画面卡住 me@example.com").unwrap();
        assert!(preview.bytes <= MAX_REPORT_BYTES);
        let report: serde_json::Value = serde_json::from_str(&preview.body).unwrap();
        let entries = report["entries"].as_array().unwrap();
        assert!(!entries.is_empty() && entries.len() <= MAX_ENTRIES);
        assert_eq!(entries[0]["level"], "warn");
        assert!(entries[0]["timestamp"].as_str().unwrap().starts_with("2026-10-27T10:00:"));
        assert!(!preview.body.contains("/Users/kumo") && !preview.body.contains("me@example.com"));
        assert!(reports.submit("0123").is_err());
        let _ = fs::remove_dir_all(dir);
    }
}
