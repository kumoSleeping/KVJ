//! Selected native audio input and bounded, timestamped recognition PCM.
//! Device enumeration never opens a stream; capture starts only on Start.
use super::diagnostics::{InputChannel, InputState, InputStatus};
use anyhow::{bail, Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::{collections::VecDeque, sync::{Arc, Mutex}, time::{Duration, Instant}};

pub struct Ring {
    samples: VecDeque<f32>,
    pub end: Instant,
    pub sequence: u64,
    pub error: Option<String>,
    /// Last backend continuity break since the previous poll, for the diagnostics log.
    pub notice: Option<String>,
    /// The next packet's capture time is unreliable (WASAPI TIMESTAMP_ERROR).
    untimed: bool,
    source: String,
    sample_rate: u32,
    generation: u64,
    received_at: Instant,
    expected: Option<Instant>,
    buffered: usize,
    channels: Vec<InputChannel>,
    rms_dbfs: Option<f64>,
    peak_dbfs: Option<f64>,
    gaps: u64,
    history: Vec<f32>,
    filter: Vec<f32>,
    cursor: usize,
    phase: u32,
    stats: Stats,
}
/// Why the evidence window keeps restarting, for one diagnostics line now and then:
/// a level meter moves on every packet even when no query is ever completed.
#[derive(Default)]
struct Stats {
    since: Option<Instant>,
    reported: u32,
    packets: u64,
    frames: u64,
    jumps: u64,
    overflows: u64,
    interrupts: u64,
    stale: u64,
    taken: u64,
    arrival_timed: u64,
    latency_ms: Option<(f64, f64)>,
}
impl Ring {
    pub fn new(source: String, sample_rate: u32) -> Self {
        // Approximately the same 1.3ms low-pass window at every device rate.
        let taps = ((sample_rate as usize * 63 / 48000).max(31)) | 1;
        let mut filter = vec![0.; taps];
        for (i, value) in filter.iter_mut().enumerate() {
            let x = i as f64 - (taps - 1) as f64 / 2.;
            let cutoff = 3500. / sample_rate as f64;
            let sinc = if x == 0. { 2. * cutoff } else {
                (std::f64::consts::TAU * cutoff * x).sin() / (std::f64::consts::PI * x)
            };
            *value = (sinc * (0.5 - 0.5 * (std::f64::consts::TAU * i as f64 / (taps - 1) as f64).cos())) as f32;
        }
        let sum: f32 = filter.iter().sum();
        for value in &mut filter { *value /= sum; }
        Self { samples: VecDeque::with_capacity(48000), end: Instant::now(), sequence: 0, error: None, notice: None, untimed: false,
            source, sample_rate, generation: 0, received_at: Instant::now(), expected: None,
            buffered: 0, channels: vec![], rms_dbfs: None, peak_dbfs: None, gaps: 0,
            history: vec![0.; taps + 1], filter, cursor: 0, phase: 0, stats: Stats::default() }
    }
    pub fn status(&self) -> InputStatus {
        let state = if self.sequence == 0 { InputState::Waiting }
            else if self.received_at.elapsed() >= Duration::from_secs(1) { InputState::Stalled }
            else if self.rms_dbfs.is_some_and(|db| db < -70.) { InputState::Quiet }
            else if self.buffered < 5520 { InputState::Buffering } else { InputState::Receiving };
        InputStatus { state, source: self.source.clone(), sample_rate: self.sample_rate, channels: self.channels.clone(),
            rms_dbfs: self.rms_dbfs, peak_dbfs: self.peak_dbfs, buffered_seconds: self.samples.len() as f64 / 8000.,
            packet_age_ms: (self.sequence > 0).then(|| self.received_at.elapsed().as_secs_f64() * 1000.),
            packets: self.sequence, gaps: self.gaps }
    }
    pub fn take(&mut self) -> Option<(Vec<f32>, Instant, u64)> {
        if self.samples.is_empty() { return None; }
        if self.end.elapsed() >= Duration::from_secs(1) { self.stats.stale += 1; return None; }
        self.stats.taken += 1;
        Some((self.samples.drain(..).collect(), self.end, self.generation))
    }
    /// One line about the capture timeline: 3 s after the first packet, then every 30 s.
    pub fn report(&mut self) -> Option<String> {
        let since = self.stats.since?;
        let due = if self.stats.reported == 0 { 3 } else { 30 };
        if since.elapsed() < Duration::from_secs(due) { return None; }
        let s = std::mem::take(&mut self.stats);
        self.stats = Stats { since: Some(Instant::now()), reported: s.reported + 1, ..Stats::default() };
        let latency = s.latency_ms.map_or("—".into(), |(lo, hi)| format!("{lo:.1}–{hi:.1} ms"));
        Some(format!(
            "采集时间线 · {:.0} 秒内 {} 包 · 每包 {} 帧 · 延迟 {latency} · 按到达计时 {} · 跳变重来 {} · 溢出重来 {} · 驱动中断 {} · 过期未取 {} · 已取 {}",
            since.elapsed().as_secs_f64(), s.packets, if s.packets > 0 { s.frames / s.packets } else { 0 },
            s.arrival_timed, s.jumps, s.overflows, s.interrupts, s.stale, s.taken))
    }
    /// Where an untrusted packet starts: right after the previous one unless that is
    /// in the future or more than 200 ms behind its arrival.
    fn continued(&self, arrived: Instant) -> Instant {
        self.expected.filter(|&expected| expected <= arrived + Duration::from_millis(5)
            && arrived.saturating_duration_since(expected) < Duration::from_millis(200)).unwrap_or(arrived)
    }
    fn latency(&mut self, latency: Duration, arrival_timed: bool) {
        let ms = latency.as_secs_f64() * 1000.;
        self.stats.latency_ms = Some(self.stats.latency_ms.map_or((ms, ms), |(lo, hi)| (lo.min(ms), hi.max(ms))));
        self.stats.arrival_timed += u64::from(arrival_timed);
    }
    fn restart(&mut self) {
        self.gaps += 1; self.generation += 1; self.buffered = 0;
        self.samples.clear(); self.history.fill(0.); self.phase = 0; self.cursor = 0;
    }
    /// The backend reported that audio is no longer continuous (for example WASAPI
    /// DATA_DISCONTINUITY). Drop the evidence window and start a new
    /// generation; the next packet starts it without being compared to the old timeline.
    /// Several notices before that packet count as one gap.
    pub fn interrupt(&mut self, reason: String) {
        if self.expected.take().is_some() { self.restart(); self.stats.interrupts += 1; }
        self.notice = Some(reason);
    }
    /// Route a backend stream error. The vendored CPAL WASAPI patch
    /// (vendor/cpal-0.18.1/KDJ-PATCH.md) reports flagged packets as Xrun on the capture
    /// thread right before their data callback. A timestamp error only makes that packet's
    /// capture time unreliable, so the packet continues the current timeline; every other
    /// Xrun breaks continuity. Neither stops capture or switches devices.
    pub fn backend_error(&mut self, error: &cpal::Error) {
        if error.kind() != cpal::ErrorKind::Xrun {
            self.error = Some(format!("声音输入失败：{error}"));
        } else if error.to_string().contains("AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR") {
            self.untimed = true;
        } else {
            self.interrupt(format!("声音输入不连续，已丢弃当前识别窗口：{error}"));
        }
    }
    pub fn push(&mut self, values: &[f32], channels: Vec<InputChannel>, first: Instant, received: Instant) -> Result<()> {
        // An untimed packet is placed right after the previous one; with no timeline to
        // continue it is dropped.
        let first = match (std::mem::take(&mut self.untimed), self.expected) {
            (false, _) => first,
            (true, Some(expected)) => expected,
            (true, None) => return Ok(()),
        };
        if values.is_empty() { return Ok(()); }
        anyhow::ensure!(values.len() <= self.sample_rate as usize && values.iter().all(|v| v.is_finite()), "捕获音频包无效");
        let rate = self.sample_rate as f64;
        self.stats.since.get_or_insert_with(Instant::now);
        self.stats.packets += 1;
        self.stats.frames += values.len() as u64;
        // A packet's own clock may wander by part of its length (WASAPI loopback
        // stamps packets by the render engine's pass), never by a whole packet.
        let tolerance = Duration::from_millis(5).max(Duration::from_secs_f64(values.len() as f64 / rate / 2.));
        let jumped = self.expected.is_some_and(|expected| {
            first.saturating_duration_since(expected).max(expected.saturating_duration_since(first)) > tolerance
        });
        let overflow = self.samples.len() + (self.phase as usize + values.len() * 8000) / self.sample_rate as usize > 48000;
        if jumped || overflow {
            self.stats.jumps += u64::from(jumped);
            self.stats.overflows += u64::from(overflow && !jumped);
            self.restart();
        }
        self.expected = Some(first + Duration::from_secs_f64(values.len() as f64 / rate));
        self.channels = channels;
        let mut power = 0f64;
        let mut peak = 0f64;
        let mut produced = 0;
        let n = self.history.len();
        for &value in values {
            power += (value as f64).powi(2); peak = peak.max(value.abs() as f64);
            self.history[self.cursor] = value;
            self.cursor = (self.cursor + 1) % n;
            self.phase += 8000;
            if self.phase >= self.sample_rate {
                self.phase -= self.sample_rate;
                // Interpolate adjacent filtered samples at the exact 8kHz grid.
                // This also supports 44.1kHz devices without resetting per packet.
                let fraction = self.phase as f32 / 8000.;
                let mut filtered = 0.;
                for (i, &coefficient) in self.filter.iter().enumerate() {
                    let current = self.history[(self.cursor + n - 1 - i) % n];
                    let previous = self.history[(self.cursor + n - 2 - i) % n];
                    filtered += coefficient * (current + fraction * (previous - current));
                }
                self.samples.push_back(filtered); produced += 1;
            }
        }
        // Exclusive endpoint after FIR group delay and fractional decimation phase.
        let endpoint = (values.len() as f64 - 1. - (self.filter.len() - 1) as f64 / 2. - self.phase as f64 / 8000.) / rate + 1. / 8000.;
        self.end = if endpoint >= 0. { first + Duration::from_secs_f64(endpoint) }
            else { first - Duration::from_secs_f64(-endpoint) };
        self.received_at = received;
        self.buffered = (self.buffered + produced).min(48000);
        self.rms_dbfs = Some(10. * (power / values.len() as f64).max(1e-12).log10());
        self.peak_dbfs = Some(20. * peak.max(1e-6).log10());
        self.sequence += 1;
        Ok(())
    }
}

#[derive(serde::Serialize)]
pub struct InputDevice {
    pub id: String,
    pub label: String,
    pub channels: u16,
    pub kind: &'static str,
    // Pin the device advertised by Automatic when Start is pressed.
    pub resolved_id: Option<String>,
    pub error: Option<String>,
}
impl InputDevice {
    /// Features streamed by another computer's KVJ instead of local capture.
    pub fn bluetooth() -> Self {
        Self { id: "bluetooth".into(), label: "蓝牙接收 · 另一台电脑发送".into(), channels: 0, kind: "bluetooth", resolved_id: None, error: None }
    }
    fn native(id: String, label: String, device: Result<cpal::Device>, loopback: bool) -> Self {
        match device.and_then(|device| native_config(&device, loopback)) {
            Ok(config) => Self { id, label, channels: config.channels(), kind: if loopback { "output" } else { "input" }, resolved_id: None, error: None },
            // One unavailable endpoint must not hide the other input choices.
            Err(error) => Self { id, label, channels: 0, kind: if loopback { "output" } else { "input" }, resolved_id: None, error: Some(format!("{error:#}")) },
        }
    }
}

// Query the same shared/native configuration used by capture, without opening a
// stream. Do not advertise ASIO-only channels or configs we cannot actually open.
fn native_config(device: &cpal::Device, loopback: bool) -> Result<cpal::SupportedStreamConfig> {
    let config = if loopback { device.default_output_config() } else { device.default_input_config() }
        .context("读取声音设备格式失败，请刷新设备后重试")?;
    anyhow::ensure!((8000..=192000).contains(&config.sample_rate()) && (1..=32).contains(&config.channels()), "声音输入格式不支持");
    anyhow::ensure!(matches!(config.sample_format(), cpal::SampleFormat::F32 | cpal::SampleFormat::F64
        | cpal::SampleFormat::I16 | cpal::SampleFormat::I24 | cpal::SampleFormat::I32 | cpal::SampleFormat::I64
        | cpal::SampleFormat::U8 | cpal::SampleFormat::U16), "声音输入采样格式不支持：{}", config.sample_format());
    Ok(config)
}

pub fn devices() -> Result<Vec<InputDevice>> {
    let host = cpal::default_host();
    #[cfg(target_os = "macos")]
    let automatic = InputDevice { id: "auto".into(), label: "自动 · 系统混音".into(), channels: 2, kind: "system", resolved_id: Some("system".into()), error: None };
    // 自动 hears what the computer plays, as on macOS: a DJ computer's default
    // input is usually a silent or missing microphone.
    #[cfg(windows)]
    let automatic = InputDevice { resolved_id: Some("system".into()), ..InputDevice::native("auto".into(),
        "自动 · 默认播放设备 · WASAPI 回环".into(), host.default_output_device().context("没有可用系统声音输出设备"), true) };
    #[cfg(not(any(target_os = "macos", windows)))]
    let automatic = InputDevice::native("auto".into(), "自动 · 默认声音输入".into(),
        host.default_input_device().context("没有可用声音输入设备"), false);
    let mut choices = vec![automatic];
    #[cfg(target_os = "macos")]
    {
        if super::output_tap::available() {
            let outputs = super::output_tap::sources().map(|sources| sources.iter().map(|s| s.choice()).collect::<Vec<_>>());
            let error = match &outputs {
                Ok(outputs) => {
                    if let Some(first) = outputs.iter().find(|d| d.error.is_none()) {
                        choices[0] = InputDevice { id: "auto".into(), label: format!("自动 · {}", first.label), channels: first.channels,
                            kind: "output", resolved_id: Some(first.id.clone()), error: None };
                        None
                    } else { Some("没有可用的输出设备捕获，请选择系统混音或录音输入".into()) }
                }
                Err(error) => Some(format!("{error:#}")),
            };
            if let Some(error) = error {
                choices[0] = InputDevice { id: "auto".into(), label: "自动 · 输出设备".into(), channels: 0,
                    kind: "output", resolved_id: None, error: Some(error) };
            }
            if let Ok(outputs) = outputs { choices.extend(outputs); }
        }
        choices.push(InputDevice { id: "system".into(), label: "系统混音 · ScreenCaptureKit".into(), channels: 2,
            kind: "system", resolved_id: None, error: None });
    }
    #[cfg(windows)]
    {
        choices.push(InputDevice::native("system".into(), "默认播放设备 · WASAPI 回环".into(),
            host.default_output_device().context("没有可用系统声音输出设备"), true));
        for device in host.output_devices()? {
            let (Ok(id), Ok(description)) = (device.id(), device.description()) else { continue };
            choices.push(InputDevice::native(format!("loopback:{id}"), format!("{} · WASAPI 回环", description.name()), Ok(device), true));
        }
    }
    for device in host.input_devices()? {
        let (Ok(id), Ok(description)) = (device.id(), device.description()) else { continue };
        choices.push(InputDevice::native(format!("device:{id}"), description.name().into(), Ok(device), false));
    }
    Ok(choices)
}

pub struct Selection {
    pub device: String,
    /// Zero-based first channel of an adjacent pair; 0 means CH 1/2 (or mono).
    pub channel_start: u16,
    /// 现场模式: the input hears a reverberant room (a microphone), so rescue also
    /// accepts weaker evidence once it corroborates itself over time.
    pub room: bool,
}
impl Selection {
    fn resolved(&self) -> Result<Self> {
        #[cfg(target_os = "macos")]
        if self.device == "auto" {
            let automatic = devices()?.into_iter().find(|d| d.id == "auto").context("自动捕获设备不可用")?;
            if let Some(error) = automatic.error { bail!("{error}"); }
            return Ok(Self { device: automatic.resolved_id.context("自动捕获设备不可用")?, channel_start: self.channel_start, room: self.room });
        }
        #[cfg(windows)]
        if self.device == "auto" {
            return Ok(Self { device: "system".into(), channel_start: self.channel_start, room: self.room });
        }
        Ok(Self { device: self.device.clone(), channel_start: self.channel_start, room: self.room })
    }
    pub fn validate(&self) -> Result<()> {
        if self.device == TEST_SIGNAL {
            return Ok(());
        }
        let resolved = self.resolved()?;
        #[cfg(target_os = "macos")]
        {
            if resolved.device == "system" { return channel_range(resolved.channel_start, 2).map(|_| ()); }
            if resolved.device.starts_with("tap:") { return super::output_tap::validate(&resolved.device, resolved.channel_start); }
        }
        let (device, loopback) = resolved.native_device()?;
        channel_range(resolved.channel_start, native_config(&device, loopback)?.channels()).map(|_| ())
    }
    fn native_device(&self) -> Result<(cpal::Device, bool)> {
        let host = cpal::default_host();
        // Building an input stream on a WASAPI render endpoint enables loopback.
        // Never replace an unavailable selected endpoint with a microphone.
        let input = self.device.as_str();
        let loopback = cfg!(windows) && (input == "system" || input.starts_with("loopback:"));
        let device = if loopback {
            if input == "system" {
                host.default_output_device().context("没有可用系统声音输出设备")?
            } else {
                let id = input.strip_prefix("loopback:").context("系统声音设备无效")?;
                host.output_devices()?.find(|device| device.id().is_ok_and(|found| found.to_string() == id))
                    .context("系统声音输出设备已断开")?
            }
        } else if input == "auto" {
            host.default_input_device().context("没有可用声音输入设备")?
        } else {
            let id = input.strip_prefix("device:").context("声音输入设备无效")?;
            host.input_devices()?.find(|device| device.id().is_ok_and(|found| found.to_string() == id))
                .context("声音输入设备已断开")?
        };
        Ok((device, loopback))
    }
}
pub(super) fn channel_range(start: u16, channels: u16) -> Result<std::ops::Range<usize>> {
    anyhow::ensure!(start % 2 == 0 && start < channels, "所选输入声道不可用，请刷新设备并重新选择");
    Ok(start as usize..(start as usize + 2).min(channels as usize))
}
pub(super) fn channel_label(selected: &std::ops::Range<usize>) -> String {
    if selected.len() == 1 { format!("CH {}", selected.start + 1) }
    else { format!("CH {}/{}", selected.start + 1, selected.end) }
}

/// A synthetic music-like input for checks that must not need a microphone or
/// recording permission. Never listed among the devices.
pub const TEST_SIGNAL: &str = "test-signal";
pub struct TestSignal {
    stop: Arc<std::sync::atomic::AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Drop for TestSignal {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
impl TestSignal {
    fn start(ring: Arc<Mutex<Ring>>) -> Result<Self> {
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let running = stop.clone();
        let worker = std::thread::Builder::new().name("kvj-test-signal".into()).spawn(move || {
            let mut state = 7u32;
            let mut random = move || {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                state as f32 / u32::MAX as f32
            };
            let (rate, block) = (48000usize, 480usize);
            let started = Instant::now();
            let mut note = (220f32, 0.3f32);
            let mut produced = 0usize;
            while !running.load(std::sync::atomic::Ordering::Relaxed) {
                let mut mono = Vec::with_capacity(block);
                for i in produced..produced + block {
                    if i % (rate / 8) == 0 {
                        note = (220. * 2f32.powf((random() * 24.).floor() / 12.), 0.2 + 0.3 * random());
                    }
                    let t = i as f32 / rate as f32;
                    let attack = (1. - (t * 8.).fract()).powi(2);
                    mono.push(note.1 * attack * (std::f32::consts::TAU * note.0 * t).sin() + (random() - 0.5) * 0.01);
                }
                let first = started + Duration::from_secs_f64(produced as f64 / rate as f64);
                produced += block;
                let due = started + Duration::from_secs_f64(produced as f64 / rate as f64);
                if let Some(wait) = due.checked_duration_since(Instant::now()) {
                    std::thread::sleep(wait);
                }
                let _ = ring.lock().unwrap().push(&mono, vec![], first, Instant::now());
            }
        })?;
        Ok(Self { stop, worker: Some(worker) })
    }
}

pub enum Capture {
    Test { _signal: TestSignal },
    #[cfg(target_os = "macos")]
    System { _capture: super::capture::Capture },
    #[cfg(target_os = "macos")]
    Output { _capture: super::output_tap::Capture },
    Device { _stream: cpal::Stream },
}
impl Capture {
    pub fn start(input: &Selection) -> Result<(Self, Arc<Mutex<Ring>>)> {
        if input.device == TEST_SIGNAL {
            let ring = Arc::new(Mutex::new(Ring::new("测试信号".into(), 48000)));
            let signal = TestSignal::start(ring.clone())?;
            return Ok((Self::Test { _signal: signal }, ring));
        }
        let resolved = input.resolved()?;
        let input = &resolved;
        #[cfg(target_os = "macos")]
        {
            if input.device == "system" {
                channel_range(input.channel_start, 2)?;
                let ring = Arc::new(Mutex::new(Ring::new("系统混音 · ScreenCaptureKit · L/R".into(), 48000)));
                let capture = super::capture::Capture::start(ring.clone())?;
                return Ok((Self::System { _capture: capture }, ring));
            }
            if input.device.starts_with("tap:") {
                let (capture, ring) = super::output_tap::Capture::start(&input.device, input.channel_start)?;
                return Ok((Self::Output { _capture: capture }, ring));
            }
        }
        let (device, loopback) = input.native_device()?;
        let config = native_config(&device, loopback)?;
        // Revalidate after indexing: the device layout may have changed since
        // enumeration/start. Never silently revert CH 3/4 to CH 1/2.
        let selected = channel_range(input.channel_start, config.channels())?;
        let name = device.description()?.name().to_owned();
        let source = if loopback { format!("系统混音 · WASAPI · {name}") }
            else if cfg!(windows) { format!("声音输入 · WASAPI · {name}") } else { name };
        let source = format!("{source} · {}", channel_label(&selected));
        let ring = Arc::new(Mutex::new(Ring::new(source, config.sample_rate())));
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => stream::<f32>(&device, config.config(), selected, ring.clone()),
            cpal::SampleFormat::F64 => stream::<f64>(&device, config.config(), selected, ring.clone()),
            // WASAPI mix formats also include unsigned 8-bit and signed
            // 24/64-bit PCM; use CPAL's sample conversion for these devices.
            cpal::SampleFormat::I16 => stream::<i16>(&device, config.config(), selected, ring.clone()),
            cpal::SampleFormat::I24 => stream::<cpal::I24>(&device, config.config(), selected, ring.clone()),
            cpal::SampleFormat::I32 => stream::<i32>(&device, config.config(), selected, ring.clone()),
            cpal::SampleFormat::I64 => stream::<i64>(&device, config.config(), selected, ring.clone()),
            cpal::SampleFormat::U8 => stream::<u8>(&device, config.config(), selected, ring.clone()),
            cpal::SampleFormat::U16 => stream::<u16>(&device, config.config(), selected, ring.clone()),
            other => bail!("声音输入采样格式不支持：{other}"),
        }.with_context(|| if loopback { "创建 WASAPI 系统声音回环失败，请检查输出设备及独占模式" }
            else { "创建声音输入失败，请检查麦克风权限和设备占用" })?;
        stream.play().with_context(|| if loopback { "启动 WASAPI 系统声音回环失败，请刷新设备后重试" }
            else { "启动声音输入失败，请检查麦克风权限和设备占用" })?;
        Ok((Self::Device { _stream: stream }, ring))
    }
}
/// Longer than any shared-mode buffer a capture packet can have waited in.
const MAX_LATENCY: Duration = Duration::from_millis(500);
fn stream<T>(device: &cpal::Device, config: cpal::StreamConfig, selected: std::ops::Range<usize>, ring: Arc<Mutex<Ring>>) -> Result<cpal::Stream>
where T: cpal::SizedSample, f32: cpal::FromSample<T> {
    let channels = config.channels as usize;
    let rate = config.sample_rate as f64;
    let selected_count = selected.len();
    let errors = ring.clone();
    Ok(device.build_input_stream::<T, _, _>(config, move |data, info| {
        let received = Instant::now();
        let timestamp = info.timestamp();
        let latency = timestamp.callback.duration_since(timestamp.capture);
        let result = (|| -> Result<()> {
            let frames = data.len() / channels;
            if frames == 0 { return Ok(()); }
            let mut mono = Vec::with_capacity(frames);
            let mut power = vec![0f64; selected_count];
            let mut peak = vec![0f64; selected_count];
            for frame in data.chunks_exact(channels) {
                let mut value = 0.;
                // Exclude cue/other deck channels before downmixing, filtering,
                // level measurement and recognition; they never enter the ring.
                for (i, sample) in frame[selected.clone()].iter().enumerate() {
                    let sample: f32 = sample.to_sample();
                    anyhow::ensure!(sample.is_finite(), "捕获音频包含无效数值");
                    value += sample / selected_count as f32;
                    power[i] += (sample as f64).powi(2); peak[i] = peak[i].max(sample.abs() as f64);
                }
                mono.push(value);
            }
            let levels = (0..selected_count).map(|i| InputChannel { name: format!("CH {}", selected.start + i + 1),
                rms_dbfs: 10. * (power[i] / frames as f64).max(1e-12).log10(), peak_dbfs: 20. * peak[i].max(1e-6).log10() }).collect();
            let mut ring = ring.lock().unwrap();
            // A flagged WASAPI timestamp is not usable for latency validation either.
            // push() continues the previous timeline, or drops the packet if none exists.
            let first = if ring.untimed { received } else {
                // A capture clock that claims the packet is older than any real
                // buffering (seen as "levels move, nothing is ever recognised") is
                // not trusted: the packet continues the timeline, or is timed by its
                // arrival when there is none or it has drifted away.
                let implausible = latency > MAX_LATENCY;
                ring.latency(latency, implausible);
                if implausible {
                    let arrived = received.checked_sub(Duration::from_secs_f64(frames as f64 / rate)).context("声音输入时钟无效")?;
                    ring.continued(arrived)
                } else {
                    received.checked_sub(latency).context("声音输入时钟无效")?
                }
            };
            ring.push(&mono, levels, first, received)
        })();
        if let Err(error) = result { ring.lock().unwrap().error = Some(error.to_string()); }
    }, move |error| errors.lock().unwrap().backend_error(&error), Some(Duration::from_secs(5)))?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interrupt_starts_a_new_generation_once() {
        let mut ring = Ring::new("test".into(), 48000);
        let packet = vec![0.25f32; 480];
        let start = Instant::now();
        ring.push(&packet, vec![], start, start).unwrap();
        ring.push(&packet, vec![], start + Duration::from_millis(10), start).unwrap();
        assert_eq!((ring.generation, ring.gaps), (0, 0));
        assert!(!ring.samples.is_empty());

        ring.interrupt("timestamp".into());
        ring.interrupt("discontinuity".into());
        assert_eq!((ring.generation, ring.gaps), (1, 1));
        assert!(ring.samples.is_empty());
        assert_eq!(ring.notice.take().as_deref(), Some("discontinuity"));

        // The first packet after the break is far from the old timeline; it must not
        // count as a second gap.
        ring.push(&packet, vec![], start + Duration::from_secs(3), start).unwrap();
        assert_eq!((ring.generation, ring.gaps), (1, 1));
        assert_eq!(ring.take().map(|(_, _, generation)| generation), Some(1));
    }

    #[test]
    fn packet_clock_jitter_within_half_a_packet_keeps_the_window() {
        let mut ring = Ring::new("test".into(), 48000);
        let packet = vec![0.25f32; 480]; // 10 ms
        let start = Instant::now();
        ring.push(&packet, vec![], start, start).unwrap();
        // 4 ms late, then 4 ms early: loopback stamps wander, the timeline goes on.
        ring.push(&packet, vec![], start + Duration::from_millis(14), start).unwrap();
        ring.push(&packet, vec![], start + Duration::from_millis(20), start).unwrap();
        assert_eq!((ring.generation, ring.stats.jumps), (0, 0));
        // A whole packet off is a break.
        ring.push(&packet, vec![], start + Duration::from_millis(50), start).unwrap();
        assert_eq!((ring.generation, ring.stats.jumps), (1, 1));
    }

    #[test]
    fn backend_errors_are_routed_by_kind_and_message() {
        // The literal KDJ matches must stay in the vendored CPAL patch that emits it.
        assert!(include_str!("../../../vendor/cpal-0.18.1/src/host/wasapi/stream.rs")
            .contains("\"WASAPI capture: AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR "));
        let mut ring = Ring::new("test".into(), 48000);
        let packet = vec![0.25f32; 480];
        let start = Instant::now();
        ring.push(&packet, vec![], start, start).unwrap();

        // Timestamp error: the packet's own (wrong) time is ignored and the window keeps growing.
        ring.backend_error(&cpal::Error::with_message(cpal::ErrorKind::Xrun,
            "WASAPI capture: AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR (packet timestamp is unreliable)"));
        ring.push(&packet, vec![], start + Duration::from_secs(3), start).unwrap();
        ring.push(&packet, vec![], start + Duration::from_millis(20), start).unwrap();
        assert_eq!((ring.generation, ring.gaps, ring.notice.is_none()), (0, 0, true));

        ring.backend_error(&cpal::Error::with_message(cpal::ErrorKind::Xrun,
            "WASAPI capture: AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY (captured audio is not continuous)"));
        assert_eq!((ring.generation, ring.gaps, ring.notice.is_some()), (1, 1, true));
        // Untimed with no timeline to continue: dropped.
        ring.backend_error(&cpal::Error::with_message(cpal::ErrorKind::Xrun,
            "WASAPI capture: AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR (packet timestamp is unreliable)"));
        ring.push(&packet, vec![], start, start).unwrap();
        assert!(ring.samples.is_empty() && ring.expected.is_none());

        assert!(ring.error.is_none());
        ring.backend_error(&cpal::Error::with_message(cpal::ErrorKind::DeviceNotAvailable, "gone"));
        assert!(ring.error.is_some());
    }
}
