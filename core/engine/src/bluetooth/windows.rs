//! Windows Bluetooth Low Energy transport through WinRT. The receiving KVJ
//! publishes the KVJ GATT service and advertises it; a sending KVJ watches for
//! that service only, connects, writes without response to the inbound
//! characteristic and subscribes to notifications on the outbound one. No
//! system pairing is involved. WinRT callbacks run on the thread pool and only
//! touch the shared buffers.
use super::*;
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    sync::{Arc, Mutex, Once},
};
use windows::{
    core::{Ref, GUID},
    Devices::Bluetooth::{
        Advertisement::{
            BluetoothLEAdvertisementReceivedEventArgs, BluetoothLEAdvertisementWatcher,
            BluetoothLEAdvertisementWatcherStatus, BluetoothLEScanningMode,
        },
        BluetoothCacheMode, BluetoothConnectionStatus, BluetoothError, BluetoothLEDevice,
        GenericAttributeProfile::{
            GattCharacteristic, GattCharacteristicProperties, GattClientCharacteristicConfigurationDescriptorValue,
            GattCommunicationStatus, GattLocalCharacteristic, GattLocalCharacteristicParameters,
            GattProtectionLevel, GattServiceProvider, GattServiceProviderAdvertisementStatus,
            GattServiceProviderAdvertisingParameters, GattSession, GattSubscribedClient, GattValueChangedEventArgs,
            GattWriteOption, GattWriteRequestedEventArgs,
        },
    },
    Foundation::TypedEventHandler,
    Storage::Streams::{DataReader, DataWriter, IBuffer},
    Win32::System::Com::CoIncrementMTAUsage,
};

const SERVICE: GUID = GUID::from_u128(0xd148ef97_f0ea_4e9e_aa99_959b9856283e);
const INBOUND: GUID = GUID::from_u128(0xd148ef97_f0ea_4e9e_aa99_959b98562801);
const OUTBOUND: GUID = GUID::from_u128(0xd148ef97_f0ea_4e9e_aa99_959b98562802);
// A peer that stops reading is dropped rather than buffered without bound.
const BUFFER_LIMIT: usize = 64 * 1024;

/// WinRT needs an apartment; keep the process MTA alive for every worker thread.
fn initialize() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| unsafe {
        let _ = CoIncrementMTAUsage();
    });
}
fn bytes_of(buffer: &IBuffer) -> windows::core::Result<Vec<u8>> {
    let reader = DataReader::FromBuffer(buffer)?;
    let mut bytes = vec![0; buffer.Length()? as usize];
    reader.ReadBytes(&mut bytes)?;
    Ok(bytes)
}
fn buffer_of(bytes: &[u8]) -> windows::core::Result<IBuffer> {
    let writer = DataWriter::new()?;
    writer.WriteBytes(bytes)?;
    writer.DetachBuffer()
}
fn address_text(address: u64) -> String {
    format!("{address:012X}")
}
fn parse_address(id: &str) -> Result<u64> {
    let compact = id.replace([':', '-'], "");
    anyhow::ensure!(
        compact.len() == 12 && compact.bytes().all(|b| b.is_ascii_hexdigit()),
        "蓝牙设备无效"
    );
    Ok(u64::from_str_radix(&compact, 16)?)
}

pub fn host_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "KVJ".into())
}

/// KVJ receivers advertising nearby, found by their service UUID alone.
pub fn scan(duration: Duration) -> Result<Vec<Device>> {
    initialize();
    let watcher = BluetoothLEAdvertisementWatcher::new()?;
    watcher.SetScanningMode(BluetoothLEScanningMode::Active)?;
    watcher
        .AdvertisementFilter()?
        .Advertisement()?
        .ServiceUuids()?
        .Append(SERVICE)?;
    let found: Arc<Mutex<BTreeMap<u64, String>>> = Arc::default();
    let sink = found.clone();
    let token = watcher.Received(&TypedEventHandler::new(
        move |_, args: Ref<BluetoothLEAdvertisementReceivedEventArgs>| {
            if let Some(args) = args.as_ref() {
                let address = args.BluetoothAddress()?;
                let name = args.Advertisement()?.LocalName()?.to_string();
                let mut found = sink.lock().unwrap();
                let entry = found.entry(address).or_default();
                if !name.is_empty() {
                    *entry = name;
                }
            }
            Ok(())
        },
    ))?;
    watcher.Start()?;
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if watcher.Status()? == BluetoothLEAdvertisementWatcherStatus::Aborted {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let aborted = watcher.Status()? == BluetoothLEAdvertisementWatcherStatus::Aborted;
    let _ = watcher.Stop();
    let _ = watcher.RemoveReceived(token);
    anyhow::ensure!(!aborted, "蓝牙未开启或不可用");
    let found = found.lock().unwrap();
    Ok(found
        .iter()
        .map(|(address, name)| Device {
            id: address_text(*address),
            name: if name.is_empty() { address_text(*address) } else { name.clone() },
        })
        .collect())
}

#[derive(Default)]
struct Buffer {
    inbox: Vec<u8>,
    closed: bool,
}
impl Buffer {
    fn receive(&mut self, bytes: &[u8]) {
        if self.inbox.len() + bytes.len() > BUFFER_LIMIT {
            self.closed = true;
        } else if !self.closed {
            self.inbox.extend_from_slice(bytes);
        }
    }
}
type Shared = Arc<Mutex<Buffer>>;

/// One accepted central on the receiving side.
#[derive(Default)]
struct Peer {
    buffer: Shared,
    client: Option<GattSubscribedClient>,
}
#[derive(Default)]
struct Accepting {
    peers: HashMap<String, Peer>,
    pending: VecDeque<(String, Shared)>,
}
pub struct Server {
    provider: GattServiceProvider,
    outbound: GattLocalCharacteristic,
    state: Arc<Mutex<Accepting>>,
}
pub struct Central {
    device: BluetoothLEDevice,
    session: GattSession,
    inbound: GattCharacteristic,
    _outbound: GattCharacteristic,
}
enum Kind {
    Server(Server),
    // Accepted on the receiving side: notify this subscribed central.
    Accepted {
        server: (GattLocalCharacteristic, Arc<Mutex<Accepting>>),
        id: String,
    },
    Central(Central),
}
pub struct Native {
    kind: Kind,
    buffer: Shared,
}
impl Drop for Native {
    fn drop(&mut self) {
        self.buffer.lock().unwrap().closed = true;
        match &self.kind {
            Kind::Server(server) => {
                let _ = server.provider.StopAdvertising();
            }
            Kind::Accepted { server, id } => {
                server.1.lock().unwrap().peers.remove(id);
            }
            Kind::Central(central) => {
                let _ = central.session.Close();
                let _ = central.device.Close();
            }
        }
    }
}
impl Native {
    /// Publish the KVJ service and advertise it.
    pub fn listen() -> Result<Self> {
        initialize();
        let created = GattServiceProvider::CreateAsync(SERVICE)?.get()?;
        anyhow::ensure!(
            created.Error()? == BluetoothError::Success,
            "这台电脑的蓝牙不支持作为接收端（{:?}）",
            created.Error()?
        );
        let provider = created.ServiceProvider()?;
        let service = provider.Service()?;

        let inbound_parameters = GattLocalCharacteristicParameters::new()?;
        inbound_parameters.SetCharacteristicProperties(
            GattCharacteristicProperties::WriteWithoutResponse | GattCharacteristicProperties::Write,
        )?;
        inbound_parameters.SetWriteProtectionLevel(GattProtectionLevel::Plain)?;
        let inbound = service
            .CreateCharacteristicAsync(INBOUND, &inbound_parameters)?
            .get()?
            .Characteristic()?;
        let outbound_parameters = GattLocalCharacteristicParameters::new()?;
        outbound_parameters.SetCharacteristicProperties(GattCharacteristicProperties::Notify)?;
        outbound_parameters.SetReadProtectionLevel(GattProtectionLevel::Plain)?;
        let outbound = service
            .CreateCharacteristicAsync(OUTBOUND, &outbound_parameters)?
            .get()?
            .Characteristic()?;

        let state: Arc<Mutex<Accepting>> = Arc::default();
        let writes = state.clone();
        inbound.WriteRequested(&TypedEventHandler::new(
            move |_, args: Ref<GattWriteRequestedEventArgs>| {
                let Some(args) = args.as_ref() else { return Ok(()) };
                let deferral = args.GetDeferral()?;
                let id = args.Session()?.DeviceId()?.Id()?.to_string();
                let request = args.GetRequestAsync()?.get()?;
                let bytes = bytes_of(&request.Value()?)?;
                if request.Option()? == GattWriteOption::WriteWithResponse {
                    request.Respond()?;
                }
                let mut state = writes.lock().unwrap();
                let buffer = peer(&mut state, &id);
                buffer.lock().unwrap().receive(&bytes);
                drop(state);
                deferral.Complete()
            },
        ))?;
        let subscriptions = state.clone();
        outbound.SubscribedClientsChanged(&TypedEventHandler::new(
            move |sender: Ref<GattLocalCharacteristic>, _| {
                let Some(sender) = sender.as_ref() else { return Ok(()) };
                let mut subscribed = Vec::new();
                for client in sender.SubscribedClients()? {
                    subscribed.push((client.Session()?.DeviceId()?.Id()?.to_string(), client));
                }
                let mut state = subscriptions.lock().unwrap();
                // A central that unsubscribed has disconnected: its stream is over.
                for (id, peer) in state.peers.iter_mut() {
                    if peer.client.is_some() && !subscribed.iter().any(|(s, _)| s == id) {
                        peer.buffer.lock().unwrap().closed = true;
                        peer.client = None;
                    }
                }
                for (id, client) in subscribed {
                    peer(&mut state, &id);
                    state.peers.get_mut(&id).unwrap().client = Some(client);
                }
                Ok(())
            },
        ))?;

        let parameters = GattServiceProviderAdvertisingParameters::new()?;
        parameters.SetIsConnectable(true)?;
        parameters.SetIsDiscoverable(true)?;
        provider.StartAdvertisingWithParameters(&parameters)?;
        Ok(Self {
            kind: Kind::Server(Server { provider, outbound, state }),
            buffer: Shared::default(),
        })
    }
    pub fn connect(id: &str, cancel: &AtomicBool) -> Result<Self> {
        initialize();
        canceled(cancel)?;
        let device = BluetoothLEDevice::FromBluetoothAddressAsync(parse_address(id)?)?
            .get()
            .map_err(|_| anyhow::anyhow!("找不到这台接收电脑，请重新查找"))?;
        let services = device
            .GetGattServicesForUuidWithCacheModeAsync(SERVICE, BluetoothCacheMode::Uncached)?
            .get()?;
        anyhow::ensure!(
            services.Status()? == GattCommunicationStatus::Success && services.Services()?.Size()? > 0,
            "对方没有运行 KVJ 接收"
        );
        let service = services.Services()?.GetAt(0)?;
        let session = service.Session()?;
        session.SetMaintainConnection(true)?;
        canceled(cancel)?;
        let characteristic = |uuid| -> Result<GattCharacteristic> {
            let found = service
                .GetCharacteristicsForUuidWithCacheModeAsync(uuid, BluetoothCacheMode::Uncached)?
                .get()?;
            anyhow::ensure!(
                found.Status()? == GattCommunicationStatus::Success && found.Characteristics()?.Size()? > 0,
                "KVJ 蓝牙服务不完整，请更新两端"
            );
            Ok(found.Characteristics()?.GetAt(0)?)
        };
        let inbound = characteristic(INBOUND)?;
        let outbound = characteristic(OUTBOUND)?;

        let buffer = Shared::default();
        let incoming = buffer.clone();
        outbound.ValueChanged(&TypedEventHandler::new(
            move |_, args: Ref<GattValueChangedEventArgs>| {
                if let Some(args) = args.as_ref() {
                    let bytes = bytes_of(&args.CharacteristicValue()?)?;
                    incoming.lock().unwrap().receive(&bytes);
                }
                Ok(())
            },
        ))?;
        let lost = buffer.clone();
        device.ConnectionStatusChanged(&TypedEventHandler::new(
            move |sender: Ref<BluetoothLEDevice>, _| {
                if let Some(sender) = sender.as_ref() {
                    if sender.ConnectionStatus()? == BluetoothConnectionStatus::Disconnected {
                        lost.lock().unwrap().closed = true;
                    }
                }
                Ok(())
            },
        ))?;
        let subscribed = outbound
            .WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue::Notify,
            )?
            .get()?;
        anyhow::ensure!(subscribed == GattCommunicationStatus::Success, "无法接收对方消息");
        Ok(Self {
            kind: Kind::Central(Central { device, session, inbound, _outbound: outbound }),
            buffer,
        })
    }
    pub fn accept(&mut self) -> Result<Option<(Self, String)>> {
        let Kind::Server(server) = &self.kind else { return Ok(None) };
        let status = server.provider.AdvertisementStatus()?;
        anyhow::ensure!(
            status != GattServiceProviderAdvertisementStatus::Aborted,
            "蓝牙广播已中止，请检查蓝牙是否开启"
        );
        let next = server.state.lock().unwrap().pending.pop_front();
        Ok(next.map(|(id, buffer)| {
            (
                Self {
                    kind: Kind::Accepted {
                        server: (server.outbound.clone(), server.state.clone()),
                        id: id.clone(),
                    },
                    buffer,
                },
                id,
            )
        }))
    }
    /// Why advertising has not started yet, if it has not.
    pub fn waiting(&mut self) -> Option<String> {
        let Kind::Server(server) = &self.kind else { return None };
        match server.provider.AdvertisementStatus() {
            Ok(GattServiceProviderAdvertisementStatus::Started)
            | Ok(GattServiceProviderAdvertisementStatus::StartedWithoutAllAdvertisementData) => None,
            Ok(status) => Some(format!("蓝牙广播尚未开始（{status:?}）")),
            Err(error) => Some(format!("蓝牙广播状态未知：{error}")),
        }
    }
    pub fn read(&mut self, bytes: &mut [u8]) -> Result<usize> {
        let mut buffer = self.buffer.lock().unwrap();
        let count = buffer.inbox.len().min(bytes.len());
        anyhow::ensure!(count > 0 || !buffer.closed, "蓝牙连接已断开");
        bytes[..count].copy_from_slice(&buffer.inbox[..count]);
        buffer.inbox.drain(..count);
        Ok(count)
    }
    /// Sends a whole message, split to the link's packet size.
    pub fn write(&mut self, bytes: &[u8], cancel: &AtomicBool) -> Result<()> {
        anyhow::ensure!(!self.buffer.lock().unwrap().closed, "蓝牙连接已断开");
        match &self.kind {
            Kind::Server(_) => bail!("监听端不能发送"),
            Kind::Accepted { server, id } => {
                // Wait briefly for the central to finish subscribing.
                let started = Instant::now();
                let client = loop {
                    canceled(cancel)?;
                    if let Some(client) = server.1.lock().unwrap().peers.get(id).and_then(|p| p.client.clone()) {
                        break client;
                    }
                    anyhow::ensure!(started.elapsed() < Duration::from_millis(750), "对方尚未订阅 KVJ 消息");
                    std::thread::sleep(Duration::from_millis(5));
                };
                let size = (client.MaxNotificationSize()? as usize).max(20);
                for chunk in bytes.chunks(size) {
                    let sent = server.0.NotifyValueForSubscribedClientAsync(&buffer_of(chunk)?, &client)?.get()?;
                    anyhow::ensure!(sent.Status()? == GattCommunicationStatus::Success, "蓝牙发送失败或连接已断开");
                }
            }
            Kind::Central(central) => {
                let size = (central.session.MaxPduSize()? as usize).saturating_sub(3).max(20);
                for chunk in bytes.chunks(size) {
                    canceled(cancel)?;
                    let status = central
                        .inbound
                        .WriteValueWithOptionAsync(&buffer_of(chunk)?, GattWriteOption::WriteWithoutResponse)?
                        .get()?;
                    anyhow::ensure!(status == GattCommunicationStatus::Success, "蓝牙发送失败或连接已断开");
                }
            }
        }
        Ok(())
    }
}
/// The buffer for a central, created (and offered for accepting) on first sight.
fn peer(state: &mut Accepting, id: &str) -> Shared {
    if let Some(peer) = state.peers.get(id).filter(|p| !p.buffer.lock().unwrap().closed) {
        return peer.buffer.clone();
    }
    let peer = Peer::default();
    let buffer = peer.buffer.clone();
    state.peers.insert(id.to_owned(), peer);
    state.pending.push_back((id.to_owned(), buffer.clone()));
    buffer
}
