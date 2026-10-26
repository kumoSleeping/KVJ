//! Connection lifetime is independent of capture. Heartbeats continue through
//! microphone consent, standby, stop and bounded reconnect attempts. A lost
//! link keeps the capture: sending goes on by itself once the receiver grants
//! this DJ again.
use super::{
    protocol::*,
    transport::{canceled, Connection, Native},
    Device, LinkStatus, PeerStatus,
};
use crate::{audio_input, clock_ms, Engine, View};
use anyhow::{bail, Context, Result};
use kvj_recognize::LiveFeatureStream;
use std::{
    collections::VecDeque,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, Weak,
    },
    time::{Duration, Instant},
};
struct Packet {
    body: Vec<u8>,
    end: u64,
    at: Instant,
}
struct Stream {
    session: String,
    lease: u64,
    cancel: Arc<AtomicBool>,
    ready: bool,
    queue: VecDeque<Packet>,
}
pub(crate) struct Shared {
    pub status: PeerStatus,
    lease: u64,
    stream: Option<Stream>,
    /// Why this connection gave up for good (refused, or not the remembered
    /// computer); it is not retried.
    pub ended: Option<String>,
}
pub struct Sender {
    pub(super) shared: Arc<Mutex<Shared>>,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Sender {
    /// `remembered_only`: connecting by itself to a receiver found by name or
    /// address; anything but the remembered computer is left alone.
    pub fn connect(engine: Weak<Engine>, device: Device, remembered_only: bool) -> Result<Self> {
        let shared = Arc::new(Mutex::new(Shared {
            status: PeerStatus {
                device: device.clone(),
                selected: false,
                link: LinkStatus {
                    state: "connecting".into(),
                    peer: Some(device.name.clone()),
                    ..Default::default()
                },
                token: String::new(),
                known: false,
            },
            lease: 0,
            stream: None,
            ended: None,
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let cancel = stop.clone();
        let state = shared.clone();
        let worker = std::thread::Builder::new()
            .name("vj-rfcomm-connect".into())
            .spawn(move || {
                let mut delay = 2;
                while !cancel.load(Ordering::Relaxed) {
                    let connected_at = Instant::now();
                    let result = connection_loop(&engine, &device, &state, &cancel, remembered_only);
                    if connected_at.elapsed() > Duration::from_secs(30) {
                        delay = 2;
                    }
                    let message = result.err().map(|e| format!("{e:#}")).unwrap_or_default();
                    // A sending session keeps capturing through the outage.
                    let (session, ended) = {
                        let mut s = state.lock().unwrap();
                        s.status.selected = false;
                        s.status.link.state = if let Some(state) = &s.ended {
                            state.clone()
                        } else if cancel.load(Ordering::Relaxed) {
                            "disconnected".into()
                        } else {
                            "reconnecting".into()
                        };
                        s.status.link.error = message.clone();
                        (s.stream.as_ref().map(|stream| stream.session.clone()), s.ended.is_some())
                    };
                    if let Some(session) = session {
                        let link = state.lock().unwrap().status.link.clone();
                        update(&engine, &session, |v| v.bluetooth = Some(link));
                    }
                    if ended {
                        break;
                    }
                    let deadline = Instant::now() + Duration::from_secs(delay);
                    while !cancel.load(Ordering::Relaxed) && Instant::now() < deadline {
                        std::thread::sleep(Duration::from_millis(50));
                    }
                    delay = (delay * 2).min(10);
                }
            })?;
        Ok(Self {
            shared,
            stop,
            worker: Some(worker),
        })
    }
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(stream) = &self.shared.lock().unwrap().stream {
            stream.cancel.store(true, Ordering::Relaxed);
        }
    }
    pub fn ready(&self) -> Result<Arc<Mutex<Shared>>> {
        let s = self.shared.lock().unwrap();
        anyhow::ensure!(
            s.status.link.state == "connected",
            "请先连接设备并等待握手完成"
        );
        anyhow::ensure!(s.status.selected, "请先在接收端将本设备指定为当前 DJ");
        Ok(self.shared.clone())
    }
}
impl Drop for Sender {
    fn drop(&mut self) {
        self.stop();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn connection_loop(
    engine: &Weak<Engine>,
    device: &Device,
    shared: &Mutex<Shared>,
    cancel: &AtomicBool,
    remembered_only: bool,
) -> Result<()> {
    let hub = |engine: &Weak<Engine>| engine.upgrade().context("引擎已关闭");
    let own = hub(engine)?.connections.token();
    let mut connection = Connection::new(Native::connect(&device.id, cancel)?);
    connection.send(HELLO, &hello(1, &own), cancel)?;
    let start = Instant::now();
    let (token, name) = loop {
        canceled(cancel)?;
        anyhow::ensure!(start.elapsed() < Duration::from_secs(6), "KVJ 蓝牙握手超时");
        if let Some((kind, body)) = connection.receive()? {
            anyhow::ensure!(kind == HELLO, "对方不是 KVJ 接收端");
            break check_hello(&body, 2)?;
        }
    };
    let known = hub(engine)?.connections.knows(&token, "receiver");
    if remembered_only && !known {
        let engine = hub(engine)?;
        engine.connections.strangers.lock().unwrap().insert(super::device_key(&device.id));
        shared.lock().unwrap().ended = Some("stranger".into());
        bail!("不是记住的接收电脑");
    }
    {
        let mut s = shared.lock().unwrap();
        // Paired once the receiver says so (at once for a remembered computer).
        s.status.link.state = "asking".into();
        s.status.link.error.clear();
        s.status.selected = false;
        s.status.token = token.clone();
        s.status.known = known;
        if !name.is_empty() {
            s.status.device.name = name.clone();
        }
    }
    let mut paired = false;
    let mut seen = Instant::now();
    // Feature packets in flight, oldest first. A window rather than stop-and-wait:
    // one BLE round trip is about as long as the 50 ms between packets.
    let mut pending: VecDeque<(u64, Instant)> = VecDeque::new();
    const WINDOW: usize = 4;
    let mut streaming: Option<u64> = None;
    // The receiver chose this DJ on this connection: only a choice taken back
    // after that ends the sending session, never the SELECT 0 of a handshake.
    let mut granted = false;
    loop {
        canceled(cancel)?;
        anyhow::ensure!(
            seen.elapsed() < Duration::from_secs(6),
            "蓝牙接收端心跳超时"
        );
        anyhow::ensure!(
            pending.front().is_none_or(|(_, sent)| sent.elapsed() < Duration::from_millis(3000)),
            "蓝牙发送积压，正在重新连接"
        );
        if let Some((kind, body)) = connection.receive()? {
            seen = Instant::now();
            match kind {
                PING => pong(&mut connection, body, cancel)?,
                ACK => {
                    let end = u64::from_le_bytes(body.as_slice().try_into()?);
                    anyhow::ensure!(
                        pending.front().is_some_and(|(expected, _)| *expected == end),
                        "蓝牙应答序号无效"
                    );
                    pending.pop_front();
                }
                PAIR => {
                    anyhow::ensure!(body.len() == 1 && body[0] <= 1, "配对消息无效");
                    if body[0] == 0 {
                        shared.lock().unwrap().ended = Some("refused".into());
                        bail!("对方拒绝了连接");
                    }
                    if !paired {
                        paired = true;
                        let label = if name.is_empty() { device.name.as_str() } else { name.as_str() };
                        hub(engine)?.connections.remember(&token, label, "receiver", &device.id);
                        let mut s = shared.lock().unwrap();
                        s.status.known = true;
                        s.status.link.state = "connected".into();
                    }
                }
                SELECT => {
                    anyhow::ensure!(paired, "尚未配对就收到 DJ 选择");
                    anyhow::ensure!(body.len() == 9 && body[0] <= 1, "DJ 选择消息无效");
                    let mut s = shared.lock().unwrap();
                    s.status.selected = body[0] == 1;
                    s.lease = u64::from_le_bytes(body[1..].try_into()?);
                    let (selected, lease) = (s.status.selected, s.lease);
                    if let Some(stream) = &mut s.stream {
                        if selected {
                            // Chosen again (a receiver that restarted gives a new
                            // lease): the capture carries on under it.
                            stream.lease = lease;
                        } else if granted {
                            stream.cancel.store(true, Ordering::Relaxed);
                        }
                    }
                    granted |= selected;
                }
                _ => bail!("蓝牙接收端消息无效"),
            }
        }
        let (wanted, packet) = {
            let mut s = shared.lock().unwrap();
            let selected = s.status.selected;
            let wanted = s
                .stream
                .as_ref()
                .filter(|stream| {
                    stream.ready
                        && !stream.cancel.load(Ordering::Relaxed)
                        && selected
                        && stream.lease == s.lease
                })
                .map(|stream| stream.lease);
            let packet = if wanted.is_some() && pending.len() < WINDOW {
                s.stream
                    .as_mut()
                    .and_then(|stream| stream.queue.pop_front())
            } else {
                None
            };
            (wanted, packet)
        };
        if wanted != streaming {
            let mut message = vec![u8::from(wanted.is_some())];
            message.extend(wanted.or(streaming).unwrap_or(0).to_le_bytes());
            connection.send(STREAM, &message, cancel)?;
            streaming = wanted;
            shared.lock().unwrap().status.link.state = if wanted.is_some() {
                "sending"
            } else {
                "connected"
            }
            .into();
        }
        if let Some(packet) = packet.filter(|p| p.at.elapsed() < Duration::from_millis(500)) {
            connection.send(FEATURES, &packet.body, cancel)?;
            pending.push_back((packet.end, Instant::now()));
            let mut s = shared.lock().unwrap();
            s.status.link.packets += 1;
            s.status.link.bytes += packet.body.len() as u64 + 5;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
pub(super) fn reserve(
    shared: &Mutex<Shared>,
    session: &str,
    cancel: Arc<AtomicBool>,
) -> Result<()> {
    let mut s = shared.lock().unwrap();
    anyhow::ensure!(
        s.status.selected && s.status.link.state == "connected",
        "设备尚未连接或未被指定为当前 DJ"
    );
    anyhow::ensure!(s.stream.is_none(), "当前发送尚未结束");
    s.stream = Some(Stream {
        session: session.into(),
        lease: s.lease,
        cancel,
        ready: false,
        queue: VecDeque::new(),
    });
    Ok(())
}
fn update(engine: &Weak<Engine>, session: &str, edit: impl FnOnce(&mut View)) {
    if let Some(engine) = engine.upgrade() {
        engine.update(session, edit);
    }
}
pub(super) fn capture(
    engine: Weak<Engine>,
    session: String,
    input: audio_input::Selection,
    shared: Arc<Mutex<Shared>>,
    cancel: Arc<AtomicBool>,
) {
    let result = canceled(&cancel)
        .and_then(|_| reserve(&shared, &session, cancel.clone()))
        .and_then(|_| capture_inner(&engine, &session, &input, &shared, &cancel));
    {
        let mut s = shared.lock().unwrap();
        if s.stream.as_ref().is_some_and(|s| s.session == session) {
            s.stream = None;
        }
    }
    update(&engine, &session, |v| {
        if v.phase != "failed" {
            v.phase = if cancel.load(Ordering::Relaxed) {
                "stopped"
            } else {
                "failed"
            }
            .into();
        }
        if !cancel.load(Ordering::Relaxed) {
            if let Err(error) = result {
                v.error = format!("{error:#}");
            }
        }
    });
}
fn capture_inner(
    engine: &Weak<Engine>,
    session: &str,
    input: &audio_input::Selection,
    shared: &Mutex<Shared>,
    cancel: &AtomicBool,
) -> Result<()> {
    let _ = clock_ms();
    update(engine, session, |v| v.phase = "permission".into());
    // Opened once here (a refusal ends the session); lost later, it is opened
    // again while the link and the session stay.
    let mut capture = Some(audio_input::Capture::start(input)?);
    let mut reopen_at = Instant::now();
    canceled(cancel)?;
    {
        let mut s = shared.lock().unwrap();
        anyhow::ensure!(s.status.selected, "当前 DJ 已切换");
        let stream = s.stream.as_mut().context("发送已取消")?;
        stream.ready = true;
    }
    update(engine, session, |v| v.phase = "sending".into());
    let mut features = LiveFeatureStream::new(100);
    let mut generation = 0;
    let mut captured = Instant::now();
    let mut seen = Instant::now();
    let mut sent = Instant::now();
    let mut published = Instant::now() - Duration::from_secs(1);
    loop {
        canceled(cancel)?;
        let polled = capture.as_ref().map(|(_, ring)| {
            let mut ring = ring.lock().unwrap();
            match ring.error.clone() {
                Some(error) => Err(error),
                None => Ok((ring.take(), ring.status())),
            }
        });
        let (packet, status) = match polled {
            Some(Ok(polled)) if seen.elapsed() < Duration::from_secs(3) => polled,
            lost => {
                // An unplugged interface or a driver hiccup must not end
                // sending during a show.
                if capture.is_some() {
                    capture = None;
                    reopen_at = Instant::now() + Duration::from_secs(2);
                    let reason = match lost {
                        Some(Err(error)) => error,
                        _ => "声音输入已断流".into(),
                    };
                    update(engine, session, |v| v.error = format!("{reason}；正在重新打开"));
                } else if Instant::now() >= reopen_at {
                    match audio_input::Capture::start(input) {
                        Ok(reopened) => {
                            capture = Some(reopened);
                            features.reset();
                            generation = u64::MAX;
                            seen = Instant::now();
                            update(engine, session, |v| v.error.clear());
                            continue;
                        }
                        Err(_) => reopen_at = Instant::now() + Duration::from_secs(2),
                    }
                }
                std::thread::sleep(Duration::from_millis(50));
                continue;
            }
        };
        if let Some((pcm, at, next)) = packet {
            if next != generation {
                features.reset();
                generation = next;
            }
            features.push(&pcm, &|| cancel.load(Ordering::Relaxed))?;
            captured = at;
            seen = Instant::now();
        }
        if sent.elapsed() >= Duration::from_millis(50) {
            if let Some((chunk, first, tail)) = features.take_committed() {
                let at = captured - Duration::from_secs_f64(tail);
                let mut body = Vec::with_capacity(8192);
                // The lease is the stream's when queued (it changes when chosen again).
                body.extend(0u64.to_le_bytes());
                body.extend(generation.to_le_bytes());
                body.extend(first.to_le_bytes());
                body.extend((clock_ms() - at.elapsed().as_secs_f64() * 1000.).to_le_bytes());
                body.extend((status.rms_dbfs.unwrap_or(-120.) as f32).to_le_bytes());
                body.extend((status.peak_dbfs.unwrap_or(-120.) as f32).to_le_bytes());
                let end = first + chunk.frame_count() as u64;
                chunk.write_to(&mut body)?;
                let mut s = shared.lock().unwrap();
                let stream = s.stream.as_mut().context("发送已取消")?;
                body[..8].copy_from_slice(&stream.lease.to_le_bytes());
                if stream.queue.len() >= 16 {
                    stream.queue.pop_front();
                }
                stream.queue.push_back(Packet { body, end, at });
                sent = Instant::now();
            }
        }
        if published.elapsed() >= Duration::from_millis(250) {
            let link = shared.lock().unwrap().status.link.clone();
            update(engine, session, |v| {
                v.input = Some(status);
                v.bluetooth = Some(link);
            });
            published = Instant::now();
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
