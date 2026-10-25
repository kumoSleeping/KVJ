// macOS Bluetooth Low Energy transport. The receiving KVJ is a peripheral that
// advertises the KVJ service; a sending KVJ is a central that looks for exactly
// that service, so nothing else nearby is ever listed and no pairing is needed.
// Each connection is a byte stream: the central writes (without response) to
// the inbound characteristic, the peripheral notifies on the outbound one.
// CoreBluetooth calls back on one private serial queue; the Rust workers touch
// the shared buffers only through dispatch_sync on that queue.
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#include <string.h>

static NSString *const kService = @"D148EF97-F0EA-4E9E-AA99-959B9856283E";
static NSString *const kInbound = @"D148EF97-F0EA-4E9E-AA99-959B98562801";
static NSString *const kOutbound = @"D148EF97-F0EA-4E9E-AA99-959B98562802";
// A peer that stops reading is dropped rather than buffered without bound.
static const NSUInteger kBufferLimit = 64 * 1024;

static dispatch_queue_t queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("ltd.kumo.kvj.ble", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static void failure(char *out, size_t cap, NSString *message) {
    if (cap) snprintf(out, cap, "%s", message.UTF8String ?: "蓝牙操作失败");
}
static NSString *stateError(CBManagerState state) {
    switch (state) {
        case CBManagerStatePoweredOff: return @"蓝牙未开启";
        case CBManagerStateUnauthorized: return @"KVJ 没有蓝牙权限，请在系统设置的“隐私与安全性 → 蓝牙”中允许";
        case CBManagerStateUnsupported: return @"这台电脑不支持低功耗蓝牙";
        default: return nil;
    }
}
// A manager that never reaches "powered on" (for example a process macOS has
// not granted Bluetooth) must say so instead of finding nothing.
static NSString *notReady(CBManagerState state) {
    return stateError(state) ?: [NSString stringWithFormat:@"蓝牙尚未就绪（状态 %ld），请确认已允许 KVJ 使用蓝牙", (long)state];
}
static char *json(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String ?: "[]");
}

// One connection in either role.
@interface KVJLink : NSObject
@property(nonatomic, strong) NSMutableData *inbox;
@property(nonatomic, strong) NSMutableData *outbox;
@property(nonatomic) BOOL closed;
// Peripheral role: the subscribed central and our notifying characteristic.
@property(nonatomic, weak) CBPeripheralManager *manager;
@property(nonatomic, strong) CBCentral *central;
@property(nonatomic, strong) CBMutableCharacteristic *outbound;
// Central role: the remote peripheral, its inbound characteristic, and the
// client object (central manager + delegate) kept alive by this link.
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, strong) CBCharacteristic *inbound;
@property(nonatomic, strong) id owner;
- (void)pump;
@end
@implementation KVJLink
- (instancetype)init {
    if ((self = [super init])) { _inbox = [NSMutableData data]; _outbox = [NSMutableData data]; }
    return self;
}
- (void)receive:(NSData *)data {
    if (self.closed) return;
    if (self.inbox.length + data.length > kBufferLimit) { self.closed = YES; return; }
    [self.inbox appendData:data];
}
// Send as much of the outbox as the link accepts now; the ready callbacks resume it.
- (void)pump {
    while (self.outbox.length && !self.closed) {
        NSUInteger size;
        if (self.central) {
            size = MIN(self.outbox.length, self.central.maximumUpdateValueLength);
            NSData *chunk = [self.outbox subdataWithRange:NSMakeRange(0, size)];
            if (![self.manager updateValue:chunk forCharacteristic:self.outbound onSubscribedCentrals:@[self.central]]) return;
        } else if (self.peripheral && self.inbound) {
            if (!self.peripheral.canSendWriteWithoutResponse) return;
            size = MIN(self.outbox.length, [self.peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse]);
            NSData *chunk = [self.outbox subdataWithRange:NSMakeRange(0, size)];
            [self.peripheral writeValue:chunk forCharacteristic:self.inbound type:CBCharacteristicWriteWithoutResponse];
        } else {
            return;
        }
        [self.outbox replaceBytesInRange:NSMakeRange(0, size) withBytes:NULL length:0];
    }
}
@end

// The receiving side: advertise, accept centrals, keep one link per central.
@interface KVJServer : NSObject <CBPeripheralManagerDelegate>
@property(nonatomic, strong) CBPeripheralManager *manager;
@property(nonatomic, strong) CBMutableCharacteristic *inbound;
@property(nonatomic, strong) CBMutableCharacteristic *outbound;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, KVJLink *> *links;
@property(nonatomic, strong) NSMutableArray<KVJLink *> *pending;
@property(nonatomic, strong) NSMutableArray<NSString *> *pendingIds;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *error;
@property(nonatomic) int state; // 0 starting, 1 advertising, -1 failed
@property(nonatomic) BOOL added;
@end
@implementation KVJServer
- (KVJLink *)linkFor:(CBCentral *)central {
    KVJLink *link = self.links[central.identifier];
    if (!link || link.closed) {
        link = [KVJLink new];
        link.manager = self.manager;
        link.outbound = self.outbound;
        self.links[central.identifier] = link;
        [self.pending addObject:link];
        [self.pendingIds addObject:central.identifier.UUIDString];
    }
    return link;
}
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)manager {
    NSString *problem = stateError(manager.state);
    if (problem) { self.error = problem; self.state = -1; return; }
    if (manager.state != CBManagerStatePoweredOn || self.added) return;
    self.added = YES;
    self.inbound = [[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:kInbound]
        properties:CBCharacteristicPropertyWriteWithoutResponse value:nil permissions:CBAttributePermissionsWriteable];
    self.outbound = [[CBMutableCharacteristic alloc] initWithType:[CBUUID UUIDWithString:kOutbound]
        properties:CBCharacteristicPropertyNotify value:nil permissions:CBAttributePermissionsReadable];
    CBMutableService *service = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:kService] primary:YES];
    service.characteristics = @[self.inbound, self.outbound];
    [manager addService:service];
}
- (void)peripheralManager:(CBPeripheralManager *)manager didAddService:(CBService *)service error:(NSError *)error {
    if (error) { self.error = error.localizedDescription; self.state = -1; return; }
    [manager startAdvertising:@{
        CBAdvertisementDataServiceUUIDsKey: @[[CBUUID UUIDWithString:kService]],
        CBAdvertisementDataLocalNameKey: self.name ?: @"KVJ",
    }];
}
- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)manager error:(NSError *)error {
    if (error) { self.error = error.localizedDescription; self.state = -1; return; }
    self.state = 1;
}
- (void)peripheralManager:(CBPeripheralManager *)manager didReceiveWriteRequests:(NSArray<CBATTRequest *> *)requests {
    for (CBATTRequest *request in requests) {
        if (![request.characteristic.UUID isEqual:self.inbound.UUID] || !request.value) continue;
        [[self linkFor:request.central] receive:request.value];
    }
}
- (void)peripheralManager:(CBPeripheralManager *)manager central:(CBCentral *)central didSubscribeToCharacteristic:(CBCharacteristic *)characteristic {
    KVJLink *link = [self linkFor:central];
    link.central = central;
    [link pump];
}
- (void)peripheralManager:(CBPeripheralManager *)manager central:(CBCentral *)central didUnsubscribeFromCharacteristic:(CBCharacteristic *)characteristic {
    // The central disconnected or stopped listening: the stream is over.
    self.links[central.identifier].closed = YES;
    [self.links removeObjectForKey:central.identifier];
}
- (void)peripheralManagerIsReadyToUpdateSubscribers:(CBPeripheralManager *)manager {
    for (KVJLink *link in self.links.allValues) [link pump];
}
- (void)shutdown {
    [self.manager stopAdvertising];
    [self.manager removeAllServices];
    for (KVJLink *link in self.links.allValues) link.closed = YES;
    [self.links removeAllObjects];
    self.manager.delegate = nil;
}
@end

// The sending side: scan for KVJ receivers, or connect one link to a receiver.
@interface KVJClient : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *found;
@property(nonatomic) BOOL scanning;
@property(nonatomic, strong) NSUUID *target;
@property(nonatomic, weak) KVJLink *link;
@property(nonatomic) int state; // 0 pending, 1 ready, -1 failed
@property(nonatomic, copy) NSString *error;
@end
@implementation KVJClient
- (void)fail:(NSString *)message {
    if (self.state == 0) { self.error = message; self.state = -1; }
    self.link.closed = YES;
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSString *problem = stateError(central.state);
    if (problem) { [self fail:problem]; return; }
    if (central.state != CBManagerStatePoweredOn) return;
    CBUUID *service = [CBUUID UUIDWithString:kService];
    if (self.scanning) {
        [central scanForPeripheralsWithServices:@[service] options:nil];
    } else if (self.target && !self.link.peripheral) {
        CBPeripheral *peripheral = [central retrievePeripheralsWithIdentifiers:@[self.target]].firstObject;
        if (!peripheral) { [self fail:@"找不到这台接收电脑，请重新查找"]; return; }
        self.link.peripheral = peripheral;
        peripheral.delegate = self;
        [central connectPeripheral:peripheral options:nil];
    }
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisement RSSI:(NSNumber *)RSSI {
    NSString *id = peripheral.identifier.UUIDString;
    NSString *name = peripheral.name ?: advertisement[CBAdvertisementDataLocalNameKey] ?: id;
    self.found[id] = @{@"id": id, @"name": name, @"paired": @YES, @"computer": @YES};
}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    [peripheral discoverServices:@[[CBUUID UUIDWithString:kService]]];
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [self fail:error.localizedDescription ?: @"蓝牙连接失败"];
}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [self fail:@"蓝牙连接已断开"];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    CBService *service = nil;
    for (CBService *candidate in peripheral.services)
        if ([candidate.UUID isEqual:[CBUUID UUIDWithString:kService]]) service = candidate;
    if (error || !service) { [self fail:@"对方没有运行 KVJ 接收"]; return; }
    [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:kInbound], [CBUUID UUIDWithString:kOutbound]] forService:service];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    CBCharacteristic *outbound = nil;
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID isEqual:[CBUUID UUIDWithString:kInbound]]) self.link.inbound = c;
        if ([c.UUID isEqual:[CBUUID UUIDWithString:kOutbound]]) outbound = c;
    }
    if (error || !self.link.inbound || !outbound) { [self fail:@"KVJ 蓝牙服务不完整，请更新两端"]; return; }
    [peripheral setNotifyValue:YES forCharacteristic:outbound];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error || !characteristic.isNotifying) { [self fail:error.localizedDescription ?: @"无法接收对方消息"]; return; }
    self.state = 1;
    [self.link pump];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (!error && characteristic.value) [self.link receive:characteristic.value];
}
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    [self.link pump];
}
@end

// —— C interface (handles are retained Objective-C objects) ——

char *kvj_ble_scan(int milliseconds, char *error, size_t capacity) {
    KVJClient *client = [KVJClient new];
    client.found = [NSMutableDictionary dictionary];
    client.scanning = YES;
    dispatch_sync(queue(), ^{ client.central = [[CBCentralManager alloc] initWithDelegate:client queue:queue()]; });
    [NSThread sleepForTimeInterval:milliseconds / 1000.0];
    __block NSArray *devices = nil;
    __block NSString *problem = nil;
    dispatch_sync(queue(), ^{
        if (client.central.state != CBManagerStatePoweredOn) problem = notReady(client.central.state);
        [client.central stopScan];
        client.central.delegate = nil;
        if (client.state < 0) problem = client.error;
        devices = client.found.allValues;
    });
    if (problem) { failure(error, capacity, problem); return NULL; }
    return json(devices);
}
void kvj_ble_free_string(char *text) { free(text); }

char *kvj_ble_host_name(void) {
    return strdup([NSHost currentHost].localizedName.UTF8String ?: "KVJ");
}

void *kvj_ble_listen(const char *name, char *error, size_t capacity) {
    (void)error; (void)capacity; // start-up problems arrive through kvj_ble_listening
    KVJServer *server = [KVJServer new];
    server.links = [NSMutableDictionary dictionary];
    server.pending = [NSMutableArray array];
    server.pendingIds = [NSMutableArray array];
    server.name = [NSString stringWithUTF8String:name] ?: @"KVJ";
    dispatch_sync(queue(), ^{ server.manager = [[CBPeripheralManager alloc] initWithDelegate:server queue:queue()]; });
    return (__bridge_retained void *)server;
}
// 1 advertising, 0 still starting (`error` says why), -1 failed.
int kvj_ble_listening(void *handle, char *error, size_t capacity) {
    KVJServer *server = (__bridge KVJServer *)handle;
    __block int state = 0;
    __block NSString *problem = nil;
    dispatch_sync(queue(), ^{
        state = server.state;
        problem = state < 0 ? server.error : state == 0 ? notReady(server.manager.state) : nil;
    });
    if (problem) failure(error, capacity, problem);
    return state;
}
void *kvj_ble_accept(void *handle, char *peer, size_t capacity) {
    KVJServer *server = (__bridge KVJServer *)handle;
    __block KVJLink *link = nil;
    __block NSString *id = nil;
    dispatch_sync(queue(), ^{
        if (!server.pending.count) return;
        link = server.pending.firstObject;
        id = server.pendingIds.firstObject;
        [server.pending removeObjectAtIndex:0];
        [server.pendingIds removeObjectAtIndex:0];
    });
    if (!link) return NULL;
    if (capacity) snprintf(peer, capacity, "%s", id.UTF8String);
    return (__bridge_retained void *)link;
}

void *kvj_ble_connect(const char *identifier, char *error, size_t capacity) {
    NSUUID *target = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:identifier]];
    if (!target) { failure(error, capacity, @"蓝牙设备无效"); return NULL; }
    KVJClient *client = [KVJClient new];
    KVJLink *link = [KVJLink new];
    link.owner = client;
    client.link = link;
    client.target = target;
    dispatch_sync(queue(), ^{ client.central = [[CBCentralManager alloc] initWithDelegate:client queue:queue()]; });
    return (__bridge_retained void *)link;
}
// 1 ready, 0 still connecting, -1 failed.
int kvj_ble_connect_poll(void *handle, char *error, size_t capacity) {
    KVJLink *link = (__bridge KVJLink *)handle;
    __block int state = 0;
    __block NSString *problem = nil;
    dispatch_sync(queue(), ^{
        KVJClient *client = link.owner;
        state = client.state;
        problem = client.error;
    });
    if (state < 0) failure(error, capacity, problem ?: @"蓝牙连接失败");
    return state;
}

// Bytes copied into `bytes` (0 when none have arrived), or -1 once closed and drained.
int kvj_ble_read(void *handle, uint8_t *bytes, size_t capacity) {
    KVJLink *link = (__bridge KVJLink *)handle;
    __block int count = 0;
    dispatch_sync(queue(), ^{
        NSUInteger n = MIN(link.inbox.length, capacity);
        if (n) {
            memcpy(bytes, link.inbox.bytes, n);
            [link.inbox replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
            count = (int)n;
        } else if (link.closed) {
            count = -1;
        }
    });
    return count;
}
// Bytes accepted for sending (all or none), or -1 when closed.
int kvj_ble_write(void *handle, const uint8_t *bytes, size_t length) {
    KVJLink *link = (__bridge KVJLink *)handle;
    __block int accepted = 0;
    dispatch_sync(queue(), ^{
        if (link.closed) { accepted = -1; return; }
        if (link.outbox.length + length > kBufferLimit) return;
        [link.outbox appendBytes:bytes length:length];
        [link pump];
        accepted = (int)length;
    });
    return accepted;
}
void kvj_ble_close(void *handle) {
    id object = CFBridgingRelease(handle);
    dispatch_sync(queue(), ^{
        if ([object isKindOfClass:[KVJServer class]]) {
            [(KVJServer *)object shutdown];
        } else if ([object isKindOfClass:[KVJLink class]]) {
            KVJLink *link = object;
            link.closed = YES;
            KVJClient *client = link.owner;
            if (client) {
                if (link.peripheral) [client.central cancelPeripheralConnection:link.peripheral];
                client.central.delegate = nil;
                link.peripheral.delegate = nil;
                link.owner = nil;
            }
        }
    });
}
