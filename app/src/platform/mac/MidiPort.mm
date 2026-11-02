// Core MIDI. The client is made on the port's own thread, which then runs its
// run loop for good: Core MIDI tells of devices coming and going on the run
// loop of the thread that made the client, and keeps its list of devices up
// to date only through it. Messages arrive on Core MIDI's own thread, as
// MIDI 1.0 in universal packets, and only go into the table.

#include "Midi.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>

#include <chrono>
#include <future>
#include <map>
#include <thread>

namespace {

QString nameOf(MIDIObjectRef object)
{
    CFStringRef name = nullptr;
    if (MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name) != noErr || !name)
        return {};
    const QString out = QString::fromCFString(name);
    CFRelease(name);
    return out;
}

class MacMidiPort final : public MidiPort
{
public:
    explicit MacMidiPort(MidiTable *table)
        : m_table(table)
    {
        m_thread = std::thread([this] {
            run();
            m_exited.set_value();
        });
    }
    void setEnabled(bool on) override
    {
        m_enabled = on;
        m_changed = true;
    }
    void stop() override
    {
        m_stop = true;
        if (m_exited.get_future().wait_for(std::chrono::seconds(1)) == std::future_status::ready) {
            m_thread.join();
            delete this;
        } else {
            // Stuck in Core MIDI: left to the end of the process.
            m_thread.detach();
        }
    }

private:
    static void notified(const MIDINotification *message, void *self)
    {
        switch (message->messageID) {
        case kMIDIMsgSetupChanged:
        case kMIDIMsgObjectAdded:
        case kMIDIMsgObjectRemoved:
        case kMIDIMsgPropertyChanged:
            static_cast<MacMidiPort *>(self)->m_changed = true;
            break;
        default:
            break;
        }
    }

    void run()
    {
        if (MIDIClientCreate(CFSTR("KVJ"), &MacMidiPort::notified, this, &m_client) != noErr)
            return;
        MidiTable *table = m_table;
        const OSStatus made = MIDIInputPortCreateWithProtocol(
            m_client, CFSTR("KVJ in"), kMIDIProtocol_1_0, &m_port, ^(const MIDIEventList *list, void *) {
                const MIDIEventPacket *packet = &list->packet[0];
                for (UInt32 p = 0; p < list->numPackets; ++p) {
                    for (UInt32 w = 0; w < packet->wordCount;) {
                        const UInt32 word = packet->words[w];
                        const UInt32 type = word >> 28;
                        // MIDI 1.0 channel voice: 0x2g ss dd dd.
                        if (type == 0x2)
                            table->feed(uint8_t(word >> 16), uint8_t(word >> 8), uint8_t(word));
                        // Universal packet sizes in words, by message type.
                        static const UInt32 words[16] = {1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4};
                        w += words[type];
                    }
                    packet = MIDIEventPacketNext(packet);
                }
            });
        if (made != noErr)
            return;
        auto lastScan = std::chrono::steady_clock::now() - std::chrono::hours(1);
        while (!m_stop) {
            // Notifications come in here; with nothing to wait for, sleep.
            if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false) == kCFRunLoopRunFinished)
                std::this_thread::sleep_for(std::chrono::milliseconds(250));
            const auto now = std::chrono::steady_clock::now();
            if (m_changed.exchange(false) || now - lastScan > std::chrono::seconds(3)) {
                lastScan = now;
                scan();
            }
        }
        for (const auto &[id, source] : m_open)
            MIDIPortDisconnectSource(m_port, source);
        m_open.clear();
        // The client stays: Core MIDI ends it with the process.
    }

    // Opens the wanted sources there are, closes those gone (all of them while off).
    void scan()
    {
        std::map<SInt32, MIDIEndpointRef> present;
        std::map<SInt32, QString> names;
        if (m_enabled) {
            const ItemCount count = MIDIGetNumberOfSources();
            for (ItemCount i = 0; i < count; ++i) {
                const MIDIEndpointRef source = MIDIGetSource(i);
                SInt32 id = 0;
                if (!source || MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id) != noErr)
                    continue;
                SInt32 offline = 0;
                MIDIObjectGetIntegerProperty(source, kMIDIPropertyOffline, &offline);
                const QString name = nameOf(source);
                if (offline || !MidiTable::wanted(name))
                    continue;
                present[id] = source;
                names[id] = name;
            }
        }
        for (auto it = m_open.begin(); it != m_open.end();) {
            if (present.count(it->first)) {
                ++it;
            } else {
                MIDIPortDisconnectSource(m_port, it->second);
                it = m_open.erase(it);
            }
        }
        for (const auto &[id, source] : present) {
            if (!m_open.count(id) && MIDIPortConnectSource(m_port, source, nullptr) == noErr)
                m_open[id] = source;
        }
        QStringList open;
        for (const auto &[id, source] : m_open)
            open.append(names[id]);
        m_table->setDevices(open);
    }

    MidiTable *m_table;
    std::thread m_thread;
    std::promise<void> m_exited;
    std::atomic_bool m_stop{false};
    std::atomic_bool m_enabled{false};
    std::atomic_bool m_changed{true};
    MIDIClientRef m_client = 0;
    MIDIPortRef m_port = 0;
    std::map<SInt32, MIDIEndpointRef> m_open;
};

} // namespace

MidiPort *openMidiPort(MidiTable *table)
{
    return new MacMidiPort(table);
}
