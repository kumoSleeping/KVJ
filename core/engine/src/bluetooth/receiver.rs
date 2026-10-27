//! One native run-loop owns every inbound channel. Connections are standby
//! until the operator selects a DJ; neither reconnect nor STREAM can select it.
//! The operator's choice outlives the link: a DJ whose link drops (or who
//! stops sending) stays chosen, and is granted again once back.
use super::{
    protocol::*,
    transport::{canceled, report, Connection, Native},
    Inbox, LinkStatus, Observation, PeerStatus,
};
use crate::{
    clock_ms,
    diagnostics::{InputState, InputStatus, Level, Stage},
    Engine,
};
use anyhow::{bail, Context, Result};
use kvj_recognize::LiveFeatures;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, Weak,
    },
    time::{Duration, Instant},
};
pub struct Receiver {
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Receiver {
    pub fn start(engine: Weak<Engine>) -> Result<Self> {
        let inbox = engine.upgrade().context("引擎已关闭")?.connections.inbox.clone();
        {
            let mut inbox = inbox.lock().unwrap();
            *inbox = Inbox { receiving: inbox.receiving, ..Inbox::default() };
        }
        let stop = Arc::new(AtomicBool::new(false));
        let cancel = stop.clone();
        let shared = inbox.clone();
        let worker = std::thread::Builder::new()
            .name("vj-rfcomm-receive".into())
            .spawn(move || {
                let mut delay = 2;
                let mut rejected = Rejected::default();
                while !cancel.load(Ordering::Relaxed) {
                    let started = Instant::now();
                    let result = run(&engine, &shared, &cancel, &mut rejected);
                    let mut state = shared.lock().unwrap();
                    state.listening = false;
                    state.reset_source();
                    for peer in state.peers.values_mut() {
                        peer.link.state = "disconnected".into();
                        peer.selected = false;
                    }
                    if let Err(error) = result {
                        if !cancel.load(Ordering::Relaxed) {
                            state.error = format!("{error:#}；正在重新监听");
                        }
                    }
                    drop(state);
                    route_changed(&engine);
                    if started.elapsed() > Duration::from_secs(30) {
                        delay = 2;
                    }
                    let deadline = Instant::now() + Duration::from_secs(delay);
                    while !cancel.load(Ordering::Relaxed) && Instant::now() < deadline {
                        std::thread::sleep(Duration::from_millis(50));
                    }
                    delay = (delay * 2).min(10);
                }
            })?;
        Ok(Self {
            stop,
            worker: Some(worker),
        })
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
struct Peer {
    id: String,
    connection: Connection,
    ready: bool,
    selected: bool,
    streaming: bool,
    lease: u64,
    seen: Instant,
    ping_at: Instant,
    ping: Option<f64>,
    clock: Clock,
    window: LiveFeatures,
    next: Option<(u64, u64)>,
    endpoint: Option<f64>,
    generation: u64,
    /// From its HELLO: the sender's pairing token and name.
    token: String,
    name: String,
    /// Remembered, or allowed by the operator: only then can it be chosen.
    paired: bool,
    forgotten: u64,
}
impl Peer {
    fn new(id: String, native: Native) -> Self {
        Self {
            id,
            connection: Connection::new(native),
            ready: false,
            selected: false,
            streaming: false,
            lease: 0,
            seen: Instant::now(),
            ping_at: Instant::now().checked_sub(Duration::from_secs(2)).unwrap_or_else(Instant::now),
            ping: None,
            clock: Clock::default(),
            window: LiveFeatures::default(),
            next: None,
            endpoint: None,
            generation: 1,
            token: String::new(),
            name: String::new(),
            paired: false,
            forgotten: 0,
        }
    }
    /// Paired: tell the sender, remember it, keep it the chosen DJ if it was so
    /// under an old id, and choose it when nobody is chosen while receiving.
    fn pair(&mut self, engine: &Weak<Engine>, shared: &Mutex<Inbox>, cancel: &AtomicBool) -> Result<bool> {
        self.connection.send(PAIR, &[1], cancel)?;
        self.connection.send(SELECT, &[0; 9], cancel)?;
        self.paired = true;
        if let Some(engine) = engine.upgrade() {
            engine.connections.remember(&self.token, &self.name, "dj", &self.id);
            self.forgotten = engine.connections.forgotten.load(Ordering::Relaxed);
        }
        let mut inbox = shared.lock().unwrap();
        let peer = inbox.peers.get_mut(&self.id).context("设备已移除")?;
        peer.known = true;
        peer.link.state = "connected".into();
        // A Mac reconnecting under a new private address comes back with a new
        // id: the chosen DJ, gone under its old one, is this computer again.
        let moved = inbox.selected.clone().filter(|chosen| {
            *chosen != self.id
                && inbox.peers.get(chosen).is_some_and(|old| old.link.state == "disconnected" && old.token == self.token)
        });
        if let Some(old) = moved {
            inbox.selected = Some(self.id.clone());
            inbox.peers.remove(&old);
            drop(inbox);
            note(engine, format!("蓝牙：{} 以新 id 回来（{old} → {}），仍是当前 DJ", self.name, self.id));
            return Ok(false);
        }
        if inbox.receiving && inbox.selected.is_none() {
            inbox.reset_source();
            inbox.lease = super::random_lease();
            inbox.selected = Some(self.id.clone());
            drop(inbox);
            note(engine, format!("蓝牙：{} 是记住的 DJ，已设为当前 DJ", self.name));
            return Ok(true);
        }
        Ok(false)
    }
    fn reset(&mut self) {
        self.window = LiveFeatures::default();
        self.next = None;
        self.endpoint = None;
        self.generation += 1;
    }
    fn tick(&mut self, engine: &Weak<Engine>, shared: &Mutex<Inbox>, cancel: &AtomicBool) -> Result<bool> {
        anyhow::ensure!(
            self.seen.elapsed() < Duration::from_secs(6),
            "蓝牙设备心跳超时"
        );
        if self.ready && !self.paired {
            let decision = shared.lock().unwrap().decisions.remove(&self.id);
            match decision {
                Some(true) => {
                    note(engine, format!("蓝牙：已允许 {} 连接并记住", self.name));
                    return self.pair(engine, shared, cancel);
                }
                Some(false) => {
                    self.connection.send(PAIR, &[0], cancel)?;
                    bail!("已拒绝这台电脑");
                }
                None => {}
            }
        }
        if self.paired {
            if let Some(engine) = engine.upgrade() {
                let epoch = engine.connections.forgotten.load(Ordering::Relaxed);
                if epoch != self.forgotten {
                    self.forgotten = epoch;
                    anyhow::ensure!(engine.connections.knows(&self.token, "dj"), "已删除这台电脑的配对");
                }
            }
        }
        let (selected, lease) = {
            let inbox = shared.lock().unwrap();
            (inbox.selected.as_deref() == Some(&self.id), inbox.lease)
        };
        if self.ready && self.paired && (self.selected != selected || selected && self.lease != lease) {
            let mut grant = vec![u8::from(selected)];
            grant.extend(if selected { lease } else { 0 }.to_le_bytes());
            self.connection.send(SELECT, &grant, cancel)?;
            note(engine, format!("蓝牙：{} {}当前 DJ", self.id, if selected { "设为" } else { "不再是" }));
            self.selected = selected;
            self.lease = if selected { lease } else { 0 };
            self.streaming = false;
            self.reset();
            if let Some(peer) = shared.lock().unwrap().peers.get_mut(&self.id) {
                peer.link.state = "connected".into();
            }
        }
        if self.ready && self.ping.is_none() && self.ping_at.elapsed() >= Duration::from_secs(1) {
            let sent = clock_ms();
            self.connection.send(PING, &sent.to_le_bytes(), cancel)?;
            self.ping = Some(sent);
            self.ping_at = Instant::now();
        }
        anyhow::ensure!(
            self.ping.is_none() || self.ping_at.elapsed() < Duration::from_secs(4),
            "蓝牙时钟应答超时"
        );
        let Some((kind, body)) = self.connection.receive()? else {
            return Ok(false);
        };
        self.seen = Instant::now();
        if !self.ready {
            anyhow::ensure!(kind == HELLO, "蓝牙握手失败");
            let (token, name) = check_hello(&body, 1)?;
            let engine_ = engine.upgrade().context("引擎已关闭")?;
            self.connection.send(HELLO, &hello(2, &engine_.connections.token()), cancel)?;
            let known = engine_.connections.knows(&token, "dj");
            drop(engine_);
            self.ready = true;
            self.name = if name.is_empty() { "KVJ".into() } else { name.clone() };
            self.token = token.clone();
            {
                let mut inbox = shared.lock().unwrap();
                let peer = inbox.peers.get_mut(&self.id).context("设备已移除")?;
                peer.device.name = self.name.clone();
                peer.token = token;
                peer.link.error.clear();
                // Not paired yet: the operator is asked (Allow / Refuse).
                peer.link.state = if known { "connected" } else { "asking" }.into();
            }
            note(engine, format!("蓝牙：{} 握手完成（{}）{}", self.id, self.name, if known { "" } else { "，请求连接" }));
            if known {
                return self.pair(engine, shared, cancel);
            }
            return Ok(false);
        }
        match kind {
            PONG => {
                anyhow::ensure!(body.len() == 24, "蓝牙时钟消息无效");
                let t1 = number(&body[..8])?;
                anyhow::ensure!(self.ping == Some(t1), "蓝牙时钟序号无效");
                self.ping = None;
                if self.clock.observe(
                    t1,
                    number(&body[8..16])?,
                    number(&body[16..])?,
                    clock_ms(),
                )? {
                    self.reset();
                }
                if let Some(peer) = shared.lock().unwrap().peers.get_mut(&self.id) {
                    peer.link.rtt_ms = Some(self.clock.rtt);
                    peer.link.clock_uncertainty_ms = Some(self.clock.rtt / 2.);
                }
            }
            STREAM => {
                anyhow::ensure!(body.len() == 9 && body[0] <= 1, "发送状态无效");
                let lease = u64::from_le_bytes(body[1..].try_into()?);
                if !self.selected || lease != self.lease {
                    return Ok(false);
                }
                self.streaming = body[0] == 1;
                self.reset();
                let mut inbox = shared.lock().unwrap();
                if let Some(peer) = inbox.peers.get_mut(&self.id) {
                    peer.link.state = if self.streaming {
                        "receiving"
                    } else {
                        "connected"
                    }
                    .into();
                }
                // Stopping keeps the DJ chosen: sending again needs nobody here.
                if inbox.selected.as_deref() == Some(&self.id) && inbox.lease == lease {
                    inbox.reset_source();
                    inbox.streaming = self.streaming;
                    return Ok(true);
                }
            }
            FEATURES => {
                anyhow::ensure!(body.len() >= 52, "蓝牙特征消息过短");
                let lease = u64::from_le_bytes(body[..8].try_into()?);
                let gen = u64::from_le_bytes(body[8..16].try_into()?);
                let first = u64::from_le_bytes(body[16..24].try_into()?);
                let captured = number(&body[24..32])?;
                let rms = f32::from_le_bytes(body[32..36].try_into()?) as f64;
                let peak = f32::from_le_bytes(body[36..40].try_into()?) as f64;
                anyhow::ensure!(
                    rms.is_finite()
                        && peak.is_finite()
                        && (-240. ..=120.).contains(&rms)
                        && (-240. ..=120.).contains(&peak),
                    "输入电平无效"
                );
                let count = u32::from_le_bytes(body[48..52].try_into()?) as usize;
                anyhow::ensure!(
                    (1..=100).contains(&count) && body.len() == 52 + count * 72,
                    "蓝牙特征帧数无效"
                );
                let chunk = LiveFeatures::read_from(&body[40..])?;
                let end = first.checked_add(count as u64).context("特征序号溢出")?;
                self.connection.send(ACK, &end.to_le_bytes(), cancel)?;
                if !self.selected || !self.streaming || lease != self.lease {
                    return Ok(false);
                }
                let Some(offset) = self.clock.offset else {
                    return Ok(false);
                };
                let endpoint = captured + offset;
                let age = clock_ms() - endpoint;
                if age > 750. || age < -100. || self.clock.rtt > 300. {
                    self.reset();
                    let mut inbox = shared.lock().unwrap();
                    inbox.latest = None;
                    if let Some(peer) = inbox.peers.get_mut(&self.id) {
                        peer.link.gaps += 1;
                        peer.link.error = "数据过期或时钟误差过大，正在重新同步".into();
                    }
                    return Ok(false);
                }
                let at = if age >= 0. {
                    Instant::now() - Duration::from_secs_f64(age / 1000.)
                } else {
                    Instant::now() + Duration::from_secs_f64(-age / 1000.)
                };
                let gap = self.next.is_some_and(|n| n != (gen, first))
                    || self
                        .endpoint
                        .is_some_and(|old| (endpoint - old - count as f64 * 10.).abs() > 20.);
                if gap {
                    self.reset();
                }
                self.next = Some((gen, end));
                self.endpoint = Some(endpoint);
                self.window.append(chunk, 100);
                let mut inbox = shared.lock().unwrap();
                // Selection may have changed while a native write was in progress.
                if inbox.selected.as_deref() != Some(&self.id) || inbox.lease != lease {
                    return Ok(false);
                }
                let peer = inbox.peers.get_mut(&self.id).context("设备已移除")?;
                peer.link.packets += 1;
                peer.link.bytes += body.len() as u64 + 5;
                peer.link.data_age_ms = Some(age.max(0.));
                peer.link.error.clear();
                if gap {
                    peer.link.gaps += 1;
                }
                let query = self.window.recent(0.55);
                let input = InputStatus {
                    state: if rms < -70. {
                        InputState::Quiet
                    } else if query.is_some() {
                        InputState::Receiving
                    } else {
                        InputState::Buffering
                    },
                    source: format!("蓝牙接收 · {}", peer.device.name),
                    sample_rate: 8000,
                    channels: vec![],
                    rms_dbfs: Some(rms),
                    peak_dbfs: Some(peak),
                    buffered_seconds: self.window.duration_ms() / 1000.,
                    packet_age_ms: Some(age.max(0.)),
                    packets: peer.link.packets,
                    gaps: peer.link.gaps,
                };
                inbox.input = Some(input);
                inbox.captured_at = Some(at);
                inbox.received_at = Some(Instant::now());
                inbox.latest = query.filter(|_| rms >= -70.).map(|query| Observation {
                    query,
                    at,
                    generation: self.generation,
                });
            }
            _ => bail!("蓝牙消息类型无效"),
        }
        Ok(false)
    }
}
/// Bluetooth became the input: a remembered DJ already connected is chosen
/// when nobody is.
pub(super) fn choose_remembered(engine: &Arc<Engine>) {
    let mut inbox = engine.connections.inbox.lock().unwrap();
    if !inbox.receiving || inbox.selected.is_some() {
        return;
    }
    let Some(id) = inbox.peers.iter().find(|(_, p)| p.known && p.link.state == "connected").map(|(id, _)| id.clone()) else {
        return;
    };
    inbox.reset_source();
    inbox.lease = super::random_lease();
    inbox.selected = Some(id);
    drop(inbox);
    super::route_changed(engine);
}
/// A line in the running session's log (none without a session).
fn note(engine: &Weak<Engine>, message: String) {
    if let Some(engine) = engine.upgrade() {
        let session = engine.view.lock().unwrap().session.clone();
        engine.log(&session, Level::Info, Stage::Input, message);
    }
}
fn route_changed(engine: &Weak<Engine>) {
    if let Some(engine) = engine.upgrade() {
        super::route_changed(&engine);
    }
}
/// Peers let go for another protocol or feature version. Such a sender comes
/// back every half minute or so, all day, and its two lines each time once
/// filled most of a day's log: said once a peer every 10 minutes, with how
/// often it came meanwhile.
#[derive(Default)]
struct Rejected(HashMap<String, (Instant, u32)>);
const REJECTED_QUIET: Duration = Duration::from_secs(600);
impl Rejected {
    /// Let go for its version within the last 10 minutes: its link lines are left out.
    fn quiet(&self, id: &str) -> bool {
        self.0.get(id).is_some_and(|(since, _)| since.elapsed() < REJECTED_QUIET)
    }
    /// Let go for its version just now: what to add to the line, or nothing to say.
    fn mismatch(&mut self, id: &str) -> Option<String> {
        if let Some((since, count)) = self.0.get_mut(id) {
            if since.elapsed() < REJECTED_QUIET {
                *count += 1;
                return None;
            }
            let before = std::mem::replace(count, 1);
            *since = Instant::now();
            return Some(if before > 1 { format!("（10 分钟内 {before} 次）") } else { String::new() });
        }
        if self.0.len() >= 16 {
            let oldest = self.0.iter().min_by_key(|(_, (since, _))| *since).map(|(id, _)| id.clone());
            if let Some(oldest) = oldest {
                self.0.remove(&oldest);
            }
        }
        self.0.insert(id.to_owned(), (Instant::now(), 1));
        Some(String::new())
    }
    /// Its HELLO passed (updated since): said in full again.
    fn passed(&mut self, id: &str) {
        if !self.0.is_empty() {
            self.0.remove(id);
        }
    }
}
fn run(engine: &Weak<Engine>, shared: &Mutex<Inbox>, cancel: &AtomicBool, rejected: &mut Rejected) -> Result<()> {
    let mut listener = Native::listen()?;
    {
        let mut inbox = shared.lock().unwrap();
        inbox.listening = true;
        inbox.error.clear();
    }
    let mut peers: Vec<Peer> = Vec::new();
    let started = Instant::now();
    let mut announced = false;
    let mut reported = Instant::now();
    loop {
        canceled(cancel)?;
        // Advertising normally starts within a second; after three, say why not.
        if !announced && started.elapsed() > Duration::from_secs(3) {
            let waiting = listener.waiting();
            announced = waiting.is_none();
            shared.lock().unwrap().error = waiting.unwrap_or_default();
        }
        if reported.elapsed() >= Duration::from_secs(30) {
            reported = Instant::now();
            if let Some(line) = report() {
                note(engine, line);
            }
        }
        if let Some((native, id)) = listener.accept()? {
            // A new link for an id is only offered once its old one has closed:
            // the old peer is stale, so the new link replaces it. Dropping the new
            // one instead would wedge that DJ until its link changes again.
            let stale = peers.iter().position(|p| p.id == id);
            if !rejected.quiet(&id) {
                note(engine, format!("蓝牙：{id} 连入{}", if stale.is_some() { "（替换已断开的旧连接）" } else { "" }));
            }
            if let Some(stale) = stale {
                peers.remove(stale);
            }
            if peers.len() < 8 {
                // The sender names itself in its HELLO.
                let device = super::Device {
                    id: id.clone(),
                    name: "KVJ".into(),
                };
                let mut inbox = shared.lock().unwrap();
                if inbox.peers.len() >= 32 {
                    if let Some(key) = inbox
                        .peers
                        .iter()
                        .find(|(_, p)| p.link.state == "disconnected")
                        .map(|(id, _)| id.clone())
                    {
                        inbox.peers.remove(&key);
                    }
                }
                inbox.peers.insert(
                    id.clone(),
                    PeerStatus {
                        device,
                        selected: false,
                        token: String::new(),
                        known: false,
                        link: LinkStatus {
                            state: "connecting".into(),
                            peer: Some(id.clone()),
                            ..Default::default()
                        },
                    },
                );
                peers.push(Peer::new(id, native));
            }
        }
        let mut index = 0;
        while index < peers.len() {
            match peers[index].tick(engine, shared, cancel) {
                Ok(changed) => {
                    if changed {
                        route_changed(engine);
                    }
                    if peers[index].ready {
                        rejected.passed(&peers[index].id);
                    }
                    index += 1;
                }
                Err(error) => {
                    let peer = peers.remove(index);
                    let message = format!("{error:#}");
                    let said = if message.contains(MISMATCH) { rejected.mismatch(&peer.id) } else { Some(String::new()) };
                    if let Some(count) = said {
                        note(engine, format!("蓝牙：{} 断开：{message}{count}", peer.id));
                    }
                    let mut inbox = shared.lock().unwrap();
                    if let Some(status) = inbox.peers.get_mut(&peer.id) {
                        status.link.state = "disconnected".into();
                        status.link.error = message;
                    }
                    // Still chosen: the same DJ back is granted again (tick).
                    let changed = inbox.selected.as_deref() == Some(&peer.id);
                    if changed {
                        inbox.reset_source();
                    }
                    drop(inbox);
                    if changed {
                        route_changed(engine);
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
