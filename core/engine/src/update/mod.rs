//! In-app update. The release `report::check_update` found is downloaded into
//! `<data>/updates`, checked against its size and SHA-256 (GitHub's digest of
//! the asset, or a `<asset>.sha256` published beside it), and unpacked there.
//! Once the operator restarts, a small script (`kvj-update.sh` on macOS,
//! `kvj-update.ps1` on Windows) waits for this KVJ to quit, moves the installed
//! one aside, puts the new one in its place and starts it. The new KVJ says it
//! is up (`started-<version>`, `settle`); until then the old one is kept, and
//! without that word in time the script puts it back, starts it, and leaves
//! why in `result.txt` for it to show.
//!
//! What goes wrong is said in `Status::error` and, line by line, in
//! `Status::lines`, which the app writes to its session log; the script writes
//! its own lines to the same log file.
mod sha256;

use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::{Duration, SystemTime},
};

/// This platform's package in a release, if KVJ updates itself here.
pub fn asset_name() -> Option<&'static str> {
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Some("KVJ-macos-arm64.dmg")
    } else if cfg!(all(windows, target_arch = "x86_64")) {
        Some("KVJ-windows-x64.zip")
    } else {
        None
    }
}

/// A release's package for this platform, as GitHub lists it.
#[derive(Clone, Serialize)]
pub struct Asset {
    pub name: String,
    pub url: String,
    pub size: u64,
    /// Lowercase hex; GitHub's own digest of the upload, when it has one.
    pub sha256: Option<String>,
    /// A `<name>.sha256` published with it, read when there is no digest.
    pub sha256_url: Option<String>,
}
impl Asset {
    /// This platform's package among a release's assets (GitHub's JSON).
    pub fn find(release: &serde_json::Value) -> Option<Self> {
        let name = asset_name()?;
        let assets = release["assets"].as_array()?;
        let named = |n: &str| assets.iter().find(|a| a["name"].as_str() == Some(n));
        let asset = named(name)?;
        let sha256 = asset["digest"]
            .as_str()
            .and_then(|d| d.strip_prefix("sha256:"))
            .filter(|h| is_hex256(h))
            .map(str::to_ascii_lowercase);
        let sha256_url = named(&format!("{name}.sha256"))
            .and_then(|a| a["browser_download_url"].as_str())
            .map(str::to_owned);
        Some(Self {
            name: name.into(),
            url: asset["browser_download_url"].as_str()?.into(),
            size: asset["size"].as_u64().filter(|&s| s > 0)?,
            sha256,
            sha256_url,
        })
    }
}
fn is_hex256(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| b.is_ascii_hexdigit())
}

#[derive(Clone, Default, Serialize)]
pub struct Status {
    /// "" (nothing under way), "downloading", "verifying", "unpacking",
    /// "ready" (waits for the restart), "installing" (KVJ is quitting) or "failed".
    pub phase: String,
    pub version: String,
    pub received: u64,
    pub total: u64,
    pub error: String,
    /// Session-log lines ("[level] text") not yet handed out.
    pub lines: Vec<String>,
}
struct Offer {
    version: String,
    asset: Asset,
}
struct Job {
    status: Status,
    offer: Option<Offer>,
    /// What `ready` unpacked: the new KVJ.app, or the folder replacing the install's.
    staged: Option<PathBuf>,
}
static JOB: Mutex<Job> = Mutex::new(Job { status: empty(), offer: None, staged: None });
static CANCEL: AtomicBool = AtomicBool::new(false);
const fn empty() -> Status {
    Status { phase: String::new(), version: String::new(), received: 0, total: 0, error: String::new(), lines: Vec::new() }
}
fn busy(phase: &str) -> bool {
    matches!(phase, "downloading" | "verifying" | "unpacking" | "installing")
}

/// The release the last check found newer, kept for `download` (only what the
/// engine itself found is ever fetched).
pub(crate) fn offer(version: &str, asset: Option<Asset>) {
    let mut job = JOB.lock().unwrap();
    job.offer = asset.map(|asset| Offer { version: version.into(), asset });
}

/// Taken out, so each line reaches the log once.
pub fn status() -> Status {
    let mut job = JOB.lock().unwrap();
    let status = job.status.clone();
    job.status.lines.clear();
    status
}
fn set(edit: impl FnOnce(&mut Status)) {
    edit(&mut JOB.lock().unwrap().status);
}
fn line(level: &str, text: impl AsRef<str>) {
    set(|s| s.lines.push(format!("[{level}] 更新：{}", text.as_ref())));
}

/// Where this KVJ is installed: the .app bundle (macOS) or the folder holding
/// `bin` (Windows), and the executable's path inside it. A build that was not
/// packaged (a developer's) is not updated in place, nor one that cannot be
/// written to: both are told to use the download page.
pub struct Installed {
    pub root: PathBuf,
    pub exe: PathBuf,
}
pub fn installed() -> Result<Installed> {
    let exe = std::env::current_exe().context("找不到 KVJ 的位置")?;
    let exe = exe.canonicalize().unwrap_or(exe);
    #[cfg(target_os = "macos")]
    {
        let root = exe.ancestors().nth(3).context("找不到 KVJ.app")?.to_path_buf();
        let text = root.to_string_lossy();
        if root.extension().and_then(|e| e.to_str()) != Some("app")
            || !root.join("Contents/Frameworks/QtCore.framework").exists()
        {
            bail!("这是开发版，不能在应用内更新");
        }
        if text.contains("/AppTranslocation/") || text.starts_with("/Volumes/") {
            bail!("KVJ 正从下载的磁盘映像或下载位置直接运行：先把它拖进「应用程序」再更新");
        }
        let parent = root.parent().context("找不到 KVJ.app 所在的文件夹")?;
        writable(parent)?;
        // Nothing is written inside the signed bundle, not even a probe.
        let path = std::ffi::CString::new(text.as_bytes()).context("KVJ.app 的路径无效")?;
        if unsafe { libc::access(path.as_ptr(), libc::W_OK) } != 0 {
            bail!("没有权限改动 {}", root.display());
        }
        Ok(Installed { root, exe })
    }
    #[cfg(windows)]
    {
        let bin = exe.parent().context("找不到 KVJ 的文件夹")?;
        if !bin.file_name().is_some_and(|n| n.eq_ignore_ascii_case("bin")) || !bin.join("Qt6Core.dll").exists() {
            bail!("这是开发版，不能在应用内更新");
        }
        let root = bin.parent().context("找不到 KVJ 的安装文件夹")?.to_path_buf();
        writable(&root)?;
        writable(bin)?;
        Ok(Installed { root, exe })
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = exe;
        bail!("这个平台不能在应用内更新")
    }
}
#[cfg(any(target_os = "macos", windows))]
fn writable(dir: &Path) -> Result<()> {
    let probe = dir.join(format!(".kvj-update-probe-{}", std::process::id()));
    match fs::File::create(&probe) {
        Ok(_) => {
            let _ = fs::remove_file(&probe);
            Ok(())
        }
        Err(_) => bail!("没有权限写入 KVJ 的安装位置（{}）", dir.display()),
    }
}

/// Starts fetching the offered release on a thread of its own; `status`
/// follows it. A package already downloaded and still matching is reused.
pub fn download(data_dir: &Path) -> Result<()> {
    let (version, asset) = {
        let mut job = JOB.lock().unwrap();
        anyhow::ensure!(!busy(&job.status.phase), "更新正在进行");
        let offer = job.offer.as_ref().context("没有可下载的新版本，请先检查更新")?;
        let picked = (offer.version.clone(), offer.asset.clone());
        let lines = std::mem::take(&mut job.status.lines);
        job.status = Status { phase: "downloading".into(), version: picked.0.clone(), total: picked.1.size, lines, ..empty() };
        job.staged = None;
        picked
    };
    CANCEL.store(false, Ordering::SeqCst);
    let dir = data_dir.join("updates");
    std::thread::Builder::new()
        .name("kvj-update".into())
        .spawn(move || {
            line("info", format!("开始下载 v{version}（{}，{} 字节）", asset.name, asset.size));
            match fetch(&dir, &version, &asset) {
                Ok(staged) => {
                    line("info", format!("v{version} 已下载并校验，等待重启"));
                    let mut job = JOB.lock().unwrap();
                    job.staged = Some(staged);
                    job.status.phase = "ready".into();
                }
                Err(error) if CANCEL.load(Ordering::SeqCst) => {
                    let _ = error;
                    line("info", "已取消下载");
                    set(|s| s.phase.clear());
                }
                Err(error) => {
                    let text = format!("{error:#}");
                    line("error", format!("v{version} 失败：{text}"));
                    set(|s| {
                        s.phase = "failed".into();
                        s.error = text;
                    });
                }
            }
        })
        .context("无法开始下载")?;
    Ok(())
}
pub fn cancel() {
    CANCEL.store(true, Ordering::SeqCst);
    let mut job = JOB.lock().unwrap();
    if matches!(job.status.phase.as_str(), "ready" | "failed") {
        job.status.phase.clear();
        job.staged = None;
    }
}

fn agent() -> ureq::Agent {
    let builder = ureq::AgentBuilder::new();
    let builder = match native_tls::TlsConnector::new() {
        Ok(tls) => builder.tls_connector(std::sync::Arc::new(tls)),
        Err(_) => builder,
    };
    // GitHub hands a release's files out from another host, by redirect. A
    // package takes as long as it takes; only a stalled read gives up.
    builder
        .redirects(5)
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(60))
        .user_agent(&format!("KVJ/{}", crate::report::VERSION))
        .build()
}
fn get(url: &str) -> Result<ureq::Response> {
    anyhow::ensure!(url.starts_with("https://"), "下载地址不是 HTTPS");
    agent().get(url).call().map_err(|error| match error {
        ureq::Error::Status(code, _) => anyhow::anyhow!("下载失败：服务器返回 HTTP {code}"),
        ureq::Error::Transport(t) => anyhow::anyhow!("下载失败：无法连接（{}）", t.kind()),
    })
}

/// Download, check and unpack; the unpacked app or folder.
fn fetch(dir: &Path, version: &str, asset: &Asset) -> Result<PathBuf> {
    fs::create_dir_all(dir).with_context(|| format!("无法创建 {}", dir.display()))?;
    sweep(dir, version);
    let expected = match (&asset.sha256, &asset.sha256_url) {
        (Some(hash), _) => Some(hash.clone()),
        (None, Some(url)) => Some(published_hash(url)?),
        (None, None) => {
            line("warn", "这个版本没有发布 SHA-256，只核对了大小");
            None
        }
    };
    let package = dir.join(format!("{version}-{}", asset.name));
    let reused = package.exists() && {
        set(|s| s.phase = "verifying".into());
        let ok = file_hash(&package).is_ok_and(|(size, hash)| {
            size == asset.size && expected.as_ref().is_none_or(|e| *e == hash)
        });
        if !ok {
            let _ = fs::remove_file(&package);
        }
        ok
    };
    if reused {
        set(|s| s.received = asset.size);
        line("info", "沿用此前下载好的安装包");
    } else {
        set(|s| s.phase = "downloading".into());
        let part = dir.join(format!("{version}-{}.part", asset.name));
        let result = save(&asset.url, &part, asset.size);
        let (size, hash) = match result {
            Ok(done) => done,
            Err(error) => {
                let _ = fs::remove_file(&part);
                return Err(error);
            }
        };
        set(|s| s.phase = "verifying".into());
        if size != asset.size {
            let _ = fs::remove_file(&part);
            bail!("大小不符：应为 {} 字节，收到 {size} 字节", asset.size);
        }
        if let Some(expected) = &expected {
            if *expected != hash {
                let _ = fs::remove_file(&part);
                bail!("SHA-256 不符，安装包已删除（应为 {expected}，实为 {hash}）");
            }
        }
        fs::rename(&part, &package).context("无法保存安装包")?;
    }
    set(|s| s.phase = "unpacking".into());
    unpack(dir, version, &package)
}
/// The hex digest in a `.sha256` file (`<hex>  <name>` or just `<hex>`).
fn published_hash(url: &str) -> Result<String> {
    let mut text = String::new();
    get(url)?.into_reader().take(4096).read_to_string(&mut text).context("无法读取 SHA-256 文件")?;
    text.split_whitespace()
        .next()
        .filter(|h| is_hex256(h))
        .map(str::to_ascii_lowercase)
        .context("SHA-256 文件无效")
}
fn save(url: &str, to: &Path, size: u64) -> Result<(u64, String)> {
    let response = get(url)?;
    let mut reader = response.into_reader();
    let mut out = fs::File::create(to).with_context(|| format!("无法写入 {}", to.display()))?;
    let mut hasher = sha256::Sha256::new();
    let mut buffer = vec![0u8; 256 * 1024];
    let mut received = 0u64;
    loop {
        if CANCEL.load(Ordering::SeqCst) {
            bail!("已取消");
        }
        let n = reader.read(&mut buffer).context("下载中断")?;
        if n == 0 {
            break;
        }
        received += n as u64;
        // A package larger than listed is not this release's.
        anyhow::ensure!(received <= size, "收到的数据比安装包大，已停止");
        hasher.update(&buffer[..n]);
        out.write_all(&buffer[..n]).context("无法写入安装包（磁盘满了？）")?;
        set(|s| s.received = received);
    }
    out.sync_all().context("无法写入安装包")?;
    Ok((received, hasher.hex()))
}
fn file_hash(path: &Path) -> Result<(u64, String)> {
    let mut file = fs::File::open(path)?;
    let mut hasher = sha256::Sha256::new();
    let mut buffer = vec![0u8; 256 * 1024];
    let mut size = 0u64;
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        size += n as u64;
        hasher.update(&buffer[..n]);
    }
    Ok((size, hasher.hex()))
}
/// What an earlier version's update left: packages, unpacked copies, a mount
/// point. The script, `pending.json` and `result.txt` stay for their own readers.
fn sweep(dir: &Path, version: &str) {
    let Ok(read) = fs::read_dir(dir) else { return };
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let ours = name.starts_with(&format!("{version}-")) || name == format!("stage-{version}");
        let old = name.starts_with("stage-") || name.starts_with("mount-") || name.ends_with(".part")
            || name.ends_with(".dmg") || name.ends_with(".zip");
        if old && !ours || name.ends_with(".part") {
            let path = entry.path();
            let _ = if path.is_dir() { fs::remove_dir_all(&path) } else { fs::remove_file(&path) };
        }
    }
}

fn run(program: &str, args: &[&std::ffi::OsStr], what: &str) -> Result<String> {
    let mut command = std::process::Command::new(program);
    command.args(args).stdin(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let output = command.output().with_context(|| format!("{what}：无法运行 {program}"))?;
    if !output.status.success() {
        let said = String::from_utf8_lossy(&output.stderr);
        let said: String = said.trim().chars().take(300).collect();
        bail!("{what}失败（{program} {}）：{said}", output.status);
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(target_os = "macos")]
fn unpack(dir: &Path, version: &str, package: &Path) -> Result<PathBuf> {
    let stage = dir.join(format!("stage-{version}"));
    let mount = dir.join(format!("mount-{version}"));
    let _ = fs::remove_dir_all(&stage);
    fs::create_dir_all(&stage)?;
    fs::create_dir_all(&mount)?;
    run(
        "/usr/bin/hdiutil",
        &["attach".as_ref(), "-nobrowse".as_ref(), "-noautoopen".as_ref(), "-readonly".as_ref(),
          "-mountpoint".as_ref(), mount.as_os_str(), package.as_os_str()],
        "挂载安装包",
    )?;
    let copied = (|| {
        let app = mount.join("KVJ.app");
        anyhow::ensure!(app.join("Contents/MacOS/KVJ").exists(), "安装包里没有 KVJ.app");
        run("/usr/bin/ditto", &[app.as_os_str(), stage.join("KVJ.app").as_os_str()], "复制新版")?;
        Ok(())
    })();
    if run("/usr/bin/hdiutil", &["detach".as_ref(), mount.as_os_str()], "卸载安装包").is_err() {
        let _ = run("/usr/bin/hdiutil", &["detach".as_ref(), "-force".as_ref(), mount.as_os_str()], "卸载安装包");
    }
    let _ = fs::remove_dir(&mount);
    copied?;
    let app = stage.join("KVJ.app");
    // Nothing KVJ writes is quarantined, but a copy that is would be stopped
    // by Gatekeeper on its first start, with no one there to allow it.
    let _ = run("/usr/bin/xattr", &["-dr".as_ref(), "com.apple.quarantine".as_ref(), app.as_os_str()], "清除隔离属性");
    let plist = app.join("Contents/Info.plist");
    let said = run(
        "/usr/libexec/PlistBuddy",
        &["-c".as_ref(), "Print :CFBundleShortVersionString".as_ref(), plist.as_os_str()],
        "读取新版版本号",
    )?;
    anyhow::ensure!(said.trim() == version, "安装包的版本是 {}，不是 v{version}", said.trim());
    // A bundle whose signature does not hold is killed on Apple silicon at start.
    run("/usr/bin/codesign", &["--verify".as_ref(), "--deep".as_ref(), "--strict".as_ref(), app.as_os_str()], "核对新版签名")?;
    Ok(app)
}
#[cfg(windows)]
fn unpack(dir: &Path, version: &str, package: &Path) -> Result<PathBuf> {
    let stage = dir.join(format!("stage-{version}"));
    let _ = fs::remove_dir_all(&stage);
    fs::create_dir_all(&stage)?;
    // tar.exe ships with Windows 10 (1803) and later and reads ZIP; PowerShell's
    // Expand-Archive is the slower fallback.
    let system = std::env::var_os("SystemRoot").map_or_else(|| PathBuf::from(r"C:\Windows"), PathBuf::from);
    let tar = system.join(r"System32\tar.exe");
    let unpacked = run(&tar.to_string_lossy(), &["-xf".as_ref(), package.as_os_str(), "-C".as_ref(), stage.as_os_str()], "解压安装包")
        .or_else(|first| {
            let _ = fs::remove_dir_all(&stage);
            fs::create_dir_all(&stage)?;
            let shell = system.join(r"System32\WindowsPowerShell\v1.0\powershell.exe");
            let script = "Expand-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force";
            run(&shell.to_string_lossy(),
                &["-NoProfile".as_ref(), "-NonInteractive".as_ref(), "-Command".as_ref(), script.as_ref(),
                  package.as_os_str(), stage.as_os_str()],
                "解压安装包")
                .map_err(|second| anyhow::anyhow!("{first:#}；{second:#}"))
        });
    unpacked?;
    // The package's top level is what the install folder holds (`bin`, …); one
    // wrapped in a single folder is taken from inside it.
    let mut root = stage.clone();
    if !root.join(r"bin\KVJ.exe").exists() {
        let only: Vec<PathBuf> = fs::read_dir(&stage)?.flatten().map(|e| e.path()).collect();
        if let [single] = only.as_slice() {
            root = single.clone();
        }
    }
    anyhow::ensure!(root.join(r"bin\KVJ.exe").exists(), "安装包里没有 bin\\KVJ.exe");
    Ok(root)
}
#[cfg(not(any(target_os = "macos", windows)))]
fn unpack(_: &Path, _: &str, _: &Path) -> Result<PathBuf> {
    bail!("这个平台不能在应用内更新")
}

/// Starts the script that swaps the unpacked release in once this process
/// has quit; the app quits right after. Nothing has changed on disk when this
/// fails.
pub fn install(data_dir: &Path) -> Result<()> {
    let (version, staged) = {
        let job = JOB.lock().unwrap();
        anyhow::ensure!(job.status.phase == "ready", "新版本还没有准备好");
        (job.status.version.clone(), job.staged.clone().context("新版本还没有准备好")?)
    };
    let result = launch(data_dir, &version, &staged);
    match &result {
        Ok(()) => {
            line("info", format!("重启以安装 v{version}"));
            set(|s| s.phase = "installing".into());
        }
        Err(error) => line("error", format!("无法开始安装 v{version}：{error:#}")),
    }
    result
}
fn launch(data_dir: &Path, version: &str, staged: &Path) -> Result<()> {
    let installed = installed()?;
    let dir = data_dir.join("updates");
    for name in ["result.txt", &format!("started-{version}")] {
        let _ = fs::remove_file(dir.join(name));
    }
    let pending = serde_json::json!({
        "version": version,
        "from": crate::report::VERSION,
        "at": SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_secs(),
    });
    fs::write(dir.join("pending.json"), pending.to_string()).context("无法写入更新记录")?;
    let mut command = script(&dir, &installed, staged, data_dir, version)?;
    command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    let spawned = command.spawn();
    #[cfg(windows)]
    let spawned = spawned.or_else(|_| {
        // Not every job object lets a child break away.
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW | 0x0000_0200).spawn()
    });
    spawned.context("无法启动更新脚本")?;
    Ok(())
}
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
#[cfg(target_os = "macos")]
fn script(dir: &Path, installed: &Installed, staged: &Path, data_dir: &Path, version: &str) -> Result<std::process::Command> {
    use std::os::unix::process::CommandExt;
    let script = dir.join("kvj-update.sh");
    fs::write(&script, include_str!("kvj-update.sh")).context("无法写入更新脚本")?;
    let mut command = std::process::Command::new("/bin/sh");
    command
        .arg(&script)
        .arg(std::process::id().to_string())
        .arg(&installed.root)
        .arg(staged)
        .arg(data_dir)
        .arg(version)
        .arg(crate::report::VERSION);
    // A session of its own: quitting KVJ must not take the script with it.
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    Ok(command)
}
#[cfg(windows)]
fn script(dir: &Path, installed: &Installed, staged: &Path, data_dir: &Path, version: &str) -> Result<std::process::Command> {
    use std::os::windows::process::CommandExt;
    let script = dir.join("kvj-update.ps1");
    // Windows PowerShell 5.1 reads a script without a BOM in the ANSI code page.
    fs::write(&script, format!("\u{feff}{}", include_str!("kvj-update.ps1"))).context("无法写入更新脚本")?;
    let exe = installed.exe.strip_prefix(&installed.root).unwrap_or(Path::new(r"bin\KVJ.exe"));
    let system = std::env::var_os("SystemRoot").map_or_else(|| PathBuf::from(r"C:\Windows"), PathBuf::from);
    let mut command = std::process::Command::new(system.join(r"System32\WindowsPowerShell\v1.0\powershell.exe"));
    command
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File"])
        .arg(&script)
        .arg("-KvjPid")
        .arg(std::process::id().to_string())
        .arg("-Root")
        .arg(&installed.root)
        .arg("-Stage")
        .arg(staged)
        .arg("-Exe")
        .arg(exe)
        .arg("-DataDir")
        .arg(data_dir)
        .arg("-Version")
        .arg(version)
        .arg("-From")
        .arg(crate::report::VERSION);
    // No console, a process group of its own, and out of KVJ's job if it has one.
    command.creation_flags(CREATE_NO_WINDOW | 0x0000_0200 | 0x0100_0000);
    Ok(command)
}
#[cfg(not(any(target_os = "macos", windows)))]
fn script(_: &Path, _: &Installed, _: &Path, _: &Path, _: &str) -> Result<std::process::Command> {
    bail!("这个平台不能在应用内更新")
}

/// Once the window is up: tells a waiting script that this version started,
/// and says what the last update did ("" when there is nothing to say).
pub fn settle(data_dir: &Path) -> String {
    let dir = data_dir.join("updates");
    let version = crate::report::VERSION;
    if let Ok(text) = fs::read_to_string(dir.join("result.txt")) {
        let _ = fs::remove_file(dir.join("result.txt"));
        let mut lines = text.lines();
        let (wanted, why) = (lines.next().unwrap_or_default(), lines.next().unwrap_or_default());
        return format!("更新到 v{wanted} 没有成功，仍是 v{version}：{why}");
    }
    let Ok(text) = fs::read_to_string(dir.join("pending.json")) else { return String::new() };
    let pending: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
    if pending["version"].as_str() != Some(version) {
        return String::new();
    }
    let _ = fs::write(dir.join(format!("started-{version}")), b"");
    // A script that was cut off (the computer shut down) leaves it behind:
    // only a fresh one is news.
    let at = pending["at"].as_u64().unwrap_or(0);
    let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_secs();
    if now.saturating_sub(at) > 10 * 60 {
        let _ = fs::remove_file(dir.join("pending.json"));
        return String::new();
    }
    format!("已更新到 v{version}")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn finds_this_platforms_asset_and_its_digest() {
        let Some(name) = asset_name() else { return };
        let hash = "AB".repeat(32);
        let release = serde_json::json!({ "assets": [
            { "name": "other.zip", "browser_download_url": "https://x/other.zip", "size": 1 },
            { "name": name, "browser_download_url": format!("https://x/{name}"), "size": 1234, "digest": format!("sha256:{hash}") },
            { "name": format!("{name}.sha256"), "browser_download_url": format!("https://x/{name}.sha256"), "size": 90 },
        ]});
        let asset = Asset::find(&release).unwrap();
        assert_eq!(asset.size, 1234);
        assert_eq!(asset.sha256.as_deref(), Some("ab".repeat(32).as_str()));
        assert!(asset.sha256_url.unwrap().ends_with(".sha256"));
        let bare = serde_json::json!({ "assets": [{ "name": name, "browser_download_url": "https://x/a", "size": 5, "digest": null }]});
        assert!(Asset::find(&bare).unwrap().sha256.is_none());
    }
    /// Mounts a disk image like a release's and copies its app out; run by
    /// hand (`--ignored`): it uses hdiutil and codesign.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore]
    fn unpacks_a_release_disk_image() {
        let dir = std::env::temp_dir().join(format!("kvj-unpack-{}", crate::document::id()));
        let app = dir.join("src/KVJ.app/Contents");
        fs::create_dir_all(app.join("MacOS")).unwrap();
        fs::copy("/bin/echo", app.join("MacOS/KVJ")).unwrap();
        let plist = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
             <key>CFBundleExecutable</key><string>KVJ</string>\
             <key>CFBundleIdentifier</key><string>com.kumo.kvj.test</string>\
             <key>CFBundleShortVersionString</key><string>{}</string></dict></plist>\n",
            crate::report::VERSION
        );
        fs::write(app.join("Info.plist"), plist).unwrap();
        let bundle = dir.join("src/KVJ.app");
        run("/usr/bin/codesign", &["--force".as_ref(), "--sign".as_ref(), "-".as_ref(), bundle.as_os_str()], "签名").unwrap();
        let dmg = dir.join("pkg.dmg");
        run(
            "/usr/bin/hdiutil",
            &["create".as_ref(), "-volname".as_ref(), "KVJ".as_ref(), "-srcfolder".as_ref(), bundle.as_os_str(),
              "-format".as_ref(), "UDZO".as_ref(), dmg.as_os_str()],
            "制作磁盘映像",
        )
        .unwrap();
        let unpacked = unpack(&dir, crate::report::VERSION, &dmg).unwrap();
        assert!(unpacked.join("Contents/MacOS/KVJ").exists());
        assert!(!dir.join(format!("mount-{}", crate::report::VERSION)).exists());
        let wrong = unpack(&dir, "9.9.9", &dmg).unwrap_err();
        assert!(format!("{wrong:#}").contains("不是 v9.9.9"), "{wrong:#}");
        fs::remove_dir_all(&dir).unwrap();
    }
    #[test]
    fn settle_reports_a_rollback_once_and_marks_a_fresh_start() {
        let dir = std::env::temp_dir().join(format!("kvj-update-{}", crate::document::id()));
        fs::create_dir_all(dir.join("updates")).unwrap();
        fs::write(dir.join("updates/result.txt"), "9.9.9\n新版没有启动\n").unwrap();
        assert!(settle(&dir).contains("v9.9.9 没有成功"));
        assert_eq!(settle(&dir), "");
        let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_secs();
        let pending = serde_json::json!({ "version": crate::report::VERSION, "from": "0.0.1", "at": now });
        fs::write(dir.join("updates/pending.json"), pending.to_string()).unwrap();
        assert!(settle(&dir).starts_with("已更新到"));
        assert!(dir.join(format!("updates/started-{}", crate::report::VERSION)).exists());
        fs::remove_dir_all(&dir).unwrap();
    }
}
