//! Bluetooth Low Energy link between a DJ computer that only sends live audio
//! features and the projecting computer that recognizes and shows video. The
//! projector advertises the KVJ service while 蓝牙接收 is chosen; senders list
//! only such receivers and need no system pairing.
//! Connection preparation is separate from audio capture and from following.
//! The operator owns the active DJ selection; the only automatic choice is a
//! remembered DJ when nobody is chosen yet. Pairing is confirmed once on the
//! receiver (`pairing`); remembered computers reconnect and are let in by
//! themselves.
//! Ported from KDJ's Live VJ (`src-tauri/src/live_vj/bluetooth` at 00f377a).
mod pairing;
mod protocol;
mod receiver;
mod sender;
mod transport;
use super::{diagnostics::InputStatus, Engine};
use anyhow::Result;
use kvj_recognize::LiveFeatures;
pub use receiver::Receiver;
use serde::Serialize;
use std::{
    collections::{BTreeMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Instant,
};
pub use pairing::Known;
use pairing::Pairing;
pub use transport::Device;
#[derive(Clone, Default, Serialize)]
pub struct LinkStatus {
    pub state: String,
    pub peer: Option<String>,
    pub error: String,
    pub packets: u64,
    pub bytes: u64,
    pub rtt_ms: Option<f64>,
    pub clock_uncertainty_ms: Option<f64>,
    pub data_age_ms: Option<f64>,
    pub gaps: u64,
}
#[derive(Clone, Serialize)]
pub struct PeerStatus {
    pub device: Device,
    pub selected: bool,
    pub link: LinkStatus,
    /// The other install's pairing token, once its HELLO came.
    #[serde(default)]
    pub token: String,
    /// Remembered: it is let in (or connected to) without asking.
    #[serde(default)]
    pub known: bool,
}
#[derive(Clone, Default, Serialize)]
pub struct ConnectionStatus {
    pub listening: bool,
    pub selected: Option<String>,
    pub incoming: Vec<PeerStatus>,
    pub outgoing: Vec<PeerStatus>,
    pub error: String,
    /// Paired computers, newest first.
    pub known: Vec<Known>,
}
pub struct Observation {
    pub query: LiveFeatures,
    pub at: Instant,
    pub generation: u64,
}
#[derive(Default)]
pub struct Inbox {
    pub listening: bool,
    pub error: String,
    pub peers: BTreeMap<String, PeerStatus>,
    pub selected: Option<String>,
    pub lease: u64,
    pub streaming: bool,
    pub epoch: u64,
    pub input: Option<InputStatus>,
    pub latest: Option<Observation>,
    pub received_at: Option<Instant>,
    pub captured_at: Option<Instant>,
    /// Bluetooth is the chosen input: a remembered DJ may be chosen by itself.
    pub receiving: bool,
    /// The operator's answers to pairing requests, by peer id.
    pub decisions: BTreeMap<String, bool>,
}
impl Inbox {
    pub fn reset_source(&mut self) {
        self.epoch += 1;
        self.streaming = false;
        self.input = None;
        self.latest = None;
        self.received_at = None;
        self.captured_at = None;
    }
}
pub struct Hub {
    pub inbox: Arc<Mutex<Inbox>>,
    senders: Mutex<BTreeMap<String, sender::Sender>>,
    /// Advertising and accepting senders, independent of any session.
    listener: Mutex<Option<Receiver>>,
    dir: PathBuf,
    pairing: Mutex<Pairing>,
    /// Bumped when a computer is forgotten, so live links check again.
    pub(super) forgotten: AtomicU64,
    /// Receivers not connected to by themselves again this run: found by name
    /// but another computer, or disconnected by hand.
    strangers: Mutex<HashSet<String>>,
}
impl Hub {
    pub fn open(dir: &Path) -> Self {
        Self {
            inbox: Arc::default(),
            senders: Mutex::default(),
            listener: Mutex::default(),
            dir: dir.to_owned(),
            pairing: Mutex::new(Pairing::open(dir)),
            forgotten: AtomicU64::new(0),
            strangers: Mutex::default(),
        }
    }
    pub(super) fn token(&self) -> String {
        self.pairing.lock().unwrap().token.clone()
    }
    pub(super) fn knows(&self, token: &str, role: &str) -> bool {
        self.pairing.lock().unwrap().knows(token, role)
    }
    /// Remember a computer that was just paired (or refresh its name and id).
    pub(super) fn remember(&self, token: &str, name: &str, role: &str, id: &str) {
        let mut pairing = self.pairing.lock().unwrap();
        pairing.remember(Known { token: token.into(), name: name.into(), role: role.into(), id: id.into(), at_ms: crate::clock_ms() });
        if let Err(error) = pairing.save(&self.dir) {
            tracing::warn!("saving the Bluetooth pairing failed: {error:#}");
        }
    }
    pub fn snapshot(&self) -> ConnectionStatus {
        let inbox = self.inbox.lock().unwrap();
        let mut incoming: Vec<_> = inbox.peers.values().cloned().collect();
        for peer in &mut incoming {
            peer.selected =
                inbox.selected.as_deref() == Some(&peer.link.peer.clone().unwrap_or_default());
        }
        let result = ConnectionStatus {
            listening: inbox.listening,
            selected: inbox.selected.clone(),
            incoming,
            error: inbox.error.clone(),
            known: self.pairing.lock().unwrap().known.clone(),
            ..Default::default()
        };
        drop(inbox);
        ConnectionStatus {
            outgoing: self
                .senders
                .lock()
                .unwrap()
                .values()
                .map(|s| s.shared.lock().unwrap().status.clone())
                // Found by name but another computer: not listed as a connection.
                .filter(|status| status.link.state != "stranger")
                .collect(),
            ..result
        }
    }
    /// Stops and joins every outgoing connection and the listener.
    pub fn shutdown(&self) {
        let senders = std::mem::take(&mut *self.senders.lock().unwrap());
        drop(senders);
        let listener = self.listener.lock().unwrap().take();
        drop(listener);
    }
    fn prepare_send(&self, id: &str) -> Result<Arc<Mutex<sender::Shared>>> {
        let senders = self.senders.lock().unwrap();
        let sender = senders
            .get(&device_key(id))
            .ok_or_else(|| anyhow::anyhow!("请先连接目标设备"))?;
        sender.ready()
    }
}
pub(super) fn device_key(id: &str) -> String {
    id.replace([':', '-'], "").to_ascii_uppercase()
}
/// The selected DJ changed: drop what the previous source presented.
pub(super) fn route_changed(engine: &Engine) {
    let epoch = engine.connections.inbox.lock().unwrap().epoch;
    let session = engine.view.lock().unwrap().session.clone();
    engine.present(&session, |v| {
        // Local capture always presents epoch 0; Bluetooth routing never touches it.
        if v.mode == "vj" && v.input_device == "bluetooth" && v.presentation_epoch < epoch {
            v.presentation_epoch = epoch;
            v.matched = None;
            v.candidate = None;
            v.priority.clear();
            if ["matched", "searching"].contains(&v.phase.as_str()) {
                v.phase = "listening".into();
            }
        }
    });
}
fn random_lease() -> u64 {
    u64::from_str_radix(&super::document::id()[..16], 16).unwrap_or(1).max(1)
}

static SCAN_GATE: Mutex<()> = Mutex::new(());
impl Engine {
    /// What the current DJ's stream delivers to recognition (diagnostics).
    pub fn connections_input(&self) -> String {
        let inbox = self.connections.inbox.lock().unwrap();
        format!(
            "{} window={}",
            inbox.input.as_ref().map_or_else(|| "none".into(), |i| serde_json::json!({
                "state": i.state, "buffered": (i.buffered_seconds * 100.).round() / 100.,
                "rms": i.rms_dbfs.map(|v| v.round()), "age_ms": i.packet_age_ms.map(|v| v.round()),
            }).to_string()),
            inbox.latest.is_some()
        )
    }
    /// KVJ receivers advertising nearby (a three-second listen; nothing else is
    /// listed). Remembered receivers among them are connected to by themselves.
    pub fn bluetooth_scan(self: &Arc<Self>) -> Result<Vec<Device>> {
        let _scan = SCAN_GATE
            .try_lock()
            .map_err(|_| anyhow::anyhow!("蓝牙扫描正在进行"))?;
        let found = transport::receivers()?;
        let known: Vec<Known> = self.connections.pairing.lock().unwrap().known.iter()
            .filter(|k| k.role == "receiver").cloned().collect();
        let listed = |id: &str| found.iter().any(|d| device_key(&d.id) == device_key(id));
        for device in &found {
            // By id; by name only for a remembered receiver not seen under its
            // own id (a Mac back under a new address), and never by the name
            // every host without one has. Its HELLO's token decides anyway.
            let remembered = known.iter().any(|k| device_key(&k.id) == device_key(&device.id))
                || (!["", "KVJ"].contains(&device.name.as_str()) && known.iter().any(|k| k.name == device.name && !listed(&k.id)));
            let stranger = self.connections.strangers.lock().unwrap().contains(&device_key(&device.id));
            if remembered && !stranger && !self.connections.senders.lock().unwrap().contains_key(&device_key(&device.id)) {
                if let Err(error) = self.connect_to(device.clone(), true) {
                    tracing::debug!("reconnecting to a remembered receiver failed: {error:#}");
                }
            }
        }
        Ok(found)
    }
    /// On the projecting computer: advertise and accept senders, or stop.
    /// `receiving`: Bluetooth is the chosen input, so a remembered DJ that is
    /// connected may become the current DJ when nobody is.
    pub fn bluetooth_listen(self: &Arc<Self>, on: bool, receiving: bool) -> Result<()> {
        anyhow::ensure!(!on || cfg!(any(target_os = "macos", windows)), "此平台不支持蓝牙接收");
        let mut listener = self.connections.listener.lock().unwrap();
        self.connections.inbox.lock().unwrap().receiving = on && receiving;
        if on && listener.is_none() {
            *listener = Some(Receiver::start(Arc::downgrade(self))?);
        } else if on {
            drop(listener);
            receiver::choose_remembered(self);
        } else if !on {
            let stopped = listener.take();
            drop(listener);
            // Joins the listening worker outside the lock.
            drop(stopped);
            route_changed(self);
        }
        Ok(())
    }
    /// Prepares a standby connection to a receiving computer (at most eight). A
    /// computer not paired yet asks its operator to allow this one.
    pub fn bluetooth_connect(self: &Arc<Self>, device: Device) -> Result<()> {
        self.connections.strangers.lock().unwrap().remove(&device_key(&device.id));
        self.connect_to(device, false)
    }
    fn connect_to(self: &Arc<Self>, device: Device, remembered_only: bool) -> Result<()> {
        let key = device_key(&device.id);
        anyhow::ensure!(
            (1..=64).contains(&key.len()) && key.bytes().all(|b| b.is_ascii_alphanumeric()) && device.name.len() <= 512,
            "蓝牙设备无效"
        );
        let _gate = self.gate.lock().unwrap();
        let mut senders = self.connections.senders.lock().unwrap();
        // One that gave up (refused, or another computer) may be tried again by hand.
        if senders.get(&key).is_some_and(|s| s.shared.lock().unwrap().ended.is_some()) {
            if remembered_only {
                return Ok(());
            }
            let ended = senders.remove(&key);
            drop(senders);
            drop(ended);
            senders = self.connections.senders.lock().unwrap();
        }
        if senders.contains_key(&key) {
            return Ok(());
        }
        // Another computer found by name keeps no slot (it is not listed
        // either); the strangers set keeps it from being tried by itself.
        let strangers: Vec<String> = senders
            .iter()
            .filter(|(_, s)| s.shared.lock().unwrap().ended.as_deref() == Some("stranger"))
            .map(|(id, _)| id.clone())
            .collect();
        if !strangers.is_empty() {
            let ended: Vec<_> = strangers.iter().filter_map(|id| senders.remove(id)).collect();
            drop(senders);
            drop(ended);
            senders = self.connections.senders.lock().unwrap();
        }
        anyhow::ensure!(senders.len() < 8, "最多准备 8 台设备连接");
        senders.insert(key, sender::Sender::connect(Arc::downgrade(self), device, remembered_only)?);
        Ok(())
    }
    /// On the receiving computer: allow (and remember) or refuse a DJ asking to pair.
    pub fn bluetooth_pair(&self, id: &str, allow: bool) -> Result<()> {
        let mut inbox = self.connections.inbox.lock().unwrap();
        anyhow::ensure!(
            inbox.peers.get(id).is_some_and(|p| p.link.state == "asking"),
            "这台设备没有在请求连接"
        );
        inbox.decisions.insert(id.to_owned(), allow);
        Ok(())
    }
    /// Forget a paired computer on this side: its link ends and it has to be
    /// allowed (or connected to) again.
    pub fn bluetooth_forget(self: &Arc<Self>, token: &str) -> Result<()> {
        let hub = &self.connections;
        {
            let mut pairing = hub.pairing.lock().unwrap();
            pairing.forget(token);
            pairing.save(&hub.dir)?;
        }
        hub.forgotten.fetch_add(1, Ordering::Relaxed);
        let ids: Vec<String> = hub.senders.lock().unwrap().iter()
            .filter(|(_, s)| s.shared.lock().unwrap().status.token == token)
            .map(|(id, _)| id.clone()).collect();
        for id in ids {
            self.bluetooth_disconnect(&id);
        }
        let mut inbox = hub.inbox.lock().unwrap();
        let chosen = inbox.selected.as_ref().and_then(|id| inbox.peers.get(id)).is_some_and(|p| p.token == token);
        inbox.peers.retain(|_, p| p.token != token || p.link.state != "disconnected");
        if chosen {
            inbox.selected = None;
            inbox.reset_source();
            drop(inbox);
            route_changed(self);
        }
        Ok(())
    }
    /// Ends a connection; a remembered receiver is then not connected to by
    /// itself again until connected to by hand.
    pub fn bluetooth_disconnect(&self, id: &str) {
        self.connections.strangers.lock().unwrap().insert(device_key(id));
        let _gate = self.gate.lock().unwrap();
        let sender = self.connections.senders.lock().unwrap().remove(&device_key(id));
        // Joins the connection worker.
        drop(sender);
    }
    /// On the receiving computer: make one connected DJ the current source.
    pub fn bluetooth_select(&self, id: Option<String>) -> Result<()> {
        let mut inbox = self.connections.inbox.lock().unwrap();
        anyhow::ensure!(inbox.listening, "请先把声音输入选为蓝牙接收");
        if let Some(id) = &id {
            anyhow::ensure!(
                inbox
                    .peers
                    .get(id)
                    .is_some_and(|p| ["connected", "receiving"].contains(&p.link.state.as_str())),
                "设备尚未连接"
            );
        }
        if inbox.selected == id {
            return Ok(());
        }
        inbox.reset_source();
        inbox.lease = if id.is_some() { random_lease() } else { 0 };
        inbox.selected = id;
        drop(inbox);
        route_changed(self);
        Ok(())
    }
    /// Sender-only session: capture the chosen input and stream its features to
    /// the connected receiver. No Set, index or video is loaded.
    pub fn send_start(
        self: &Arc<Self>,
        peer: &str,
        input: super::audio_input::Selection,
    ) -> Result<super::View> {
        anyhow::ensure!(cfg!(any(target_os = "macos", windows)), "蓝牙发送目前支持 macOS 和 Windows");
        input.validate()?;
        let _gate = self.gate.lock().unwrap();
        self.join_stopped();
        anyhow::ensure!(!self.running(), "请先停止当前运行");
        let shared = self.connections.prepare_send(peer)?;
        let name = shared.lock().unwrap().status.device.name.clone();
        let session = super::document::id();
        let view = super::View {
            session: session.clone(),
            mode: "send".into(),
            phase: "connecting".into(),
            input_device: input.device.clone(),
            input_channel_start: input.channel_start,
            send_target: Some(peer.into()),
            bluetooth: Some(LinkStatus {
                state: "connecting".into(),
                peer: Some(name),
                ..Default::default()
            }),
            ..Default::default()
        };
        self.diagnostics.lock().unwrap().reset(&session);
        *self.view.lock().unwrap() = view.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let worker = {
            let engine = Arc::downgrade(self);
            let cancel = cancel.clone();
            std::thread::Builder::new()
                .name("kvj-send".into())
                .spawn(move || sender::capture(engine, session, input, shared, cancel))?
        };
        *self.session.lock().unwrap() = Some(super::Session { cancel, worker });
        Ok(view)
    }
}
