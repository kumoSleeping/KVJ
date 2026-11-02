#pragma once

// A Korg nanoKONTROL (the nanoKONTROL2 in its CC mode) as the effects' faders,
// knobs and keys. Only devices of that name are opened: a DJ controller on the
// same computer sends control changes too, and must never move the picture.
//
// Nothing here can hold the picture up. The system delivers MIDI on a thread
// of its own; that thread only stores each control's latest value in a table
// of atomics (no lock, no allocation, no Qt). The GUI thread looks at the
// table sixty times a second and passes on what changed, the latest value of
// each control only, however many messages came. Devices are looked for,
// opened and closed on one more thread of their own, every second or when the
// system says something changed, never on the GUI thread: the system's MIDI
// service can be slow to answer. A device taken away leaves every effect as it
// was.

#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QtQml/qqmlregistration.h>

#include <atomic>
#include <cstdint>
#include <mutex>

// Written by the system's MIDI thread, read by the GUI thread. Never freed:
// a message may still arrive while the app quits.
struct MidiTable
{
    // A control change's value plus one (0: never heard), and how often it
    // went on (from 0 to above) and off, by channel and number.
    std::atomic<uint8_t> value[16][128] = {};
    std::atomic<uint8_t> ons[16][128] = {};
    std::atomic<uint8_t> offs[16][128] = {};
    // Counts every message, so the GUI thread skips the table when nothing came.
    std::atomic<uint32_t> messages{0};
    // A pitch bend or a note came: the device is in one of its DAW modes.
    std::atomic<bool> daw{false};

    // The devices open now, set by the device thread.
    std::mutex devicesMutex;
    QStringList devices;
    std::atomic<uint32_t> devicesRevision{0};

    // One MIDI 1.0 message (any thread).
    void feed(uint8_t status, uint8_t data1, uint8_t data2)
    {
        const int kind = status & 0xF0;
        if (kind == 0xB0) {
            const int channel = status & 0x0F, number = data1 & 0x7F, v = data2 & 0x7F;
            const int before = int(value[channel][number].exchange(uint8_t(v + 1))) - 1;
            if (before <= 0 && v > 0)
                ons[channel][number].fetch_add(1);
            else if (before > 0 && v == 0)
                offs[channel][number].fetch_add(1);
        } else if (kind == 0xE0 || kind == 0x90) {
            daw = true;
        } else {
            return;
        }
        messages.fetch_add(1);
    }
    static bool wanted(const QString &name) { return name.contains(QLatin1String("nanokontrol"), Qt::CaseInsensitive); }
    void setDevices(const QStringList &names)
    {
        {
            std::lock_guard<std::mutex> lock(devicesMutex);
            if (devices == names)
                return;
            devices = names;
        }
        devicesRevision.fetch_add(1);
    }
};

// The system's side (platform/mac/MidiPort.mm, platform/win/MidiPort.cpp): a
// thread of its own that opens wanted devices while enabled and closes them
// when not.
class MidiPort
{
public:
    virtual ~MidiPort() = default;
    virtual void setEnabled(bool on) = 0;
    // Stops the thread, waiting a second at most; a thread stuck in the
    // system is left behind (the port is then never freed).
    virtual void stop() = 0;
};
MidiPort *openMidiPort(MidiTable *table);

class Midi : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    // Off: no device is opened. The app keeps the choice (Live.qml).
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    // The names of the devices open now.
    Q_PROPERTY(QStringList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY devicesChanged)
    // The device sent a pitch bend or a note: it is in a DAW mode, not CC mode.
    Q_PROPERTY(bool dawMode READ dawMode NOTIFY dawModeChanged)

public:
    explicit Midi(QObject *parent = nullptr);
    ~Midi() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool on);
    QStringList devices() const { return m_devices; }
    bool connected() const { return !m_devices.isEmpty(); }
    bool dawMode() const { return m_dawMode; }

signals:
    void enabledChanged();
    void devicesChanged();
    void dawModeChanged();
    // A control change, its latest value and how often it went on and off
    // since the last one passed on (a key pressed and let go between two looks
    // has value 0, ons 1 and offs 1).
    void control(int channel, int number, int value, int ons, int offs);

private:
    void poll();

    MidiTable *m_table = nullptr;
    MidiPort *m_port = nullptr;
    QTimer m_timer;
    bool m_enabled = false;
    QStringList m_devices;
    bool m_dawMode = false;
    uint32_t m_messages = 0;
    uint32_t m_devicesRevision = 0;
    uint8_t m_value[16][128] = {};
    uint8_t m_ons[16][128] = {};
    uint8_t m_offs[16][128] = {};
};
