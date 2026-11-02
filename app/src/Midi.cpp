#include "Midi.h"

#if !defined(Q_OS_MACOS) && !defined(Q_OS_WIN)
// No MIDI elsewhere.
MidiPort *openMidiPort(MidiTable *)
{
    return nullptr;
}
#endif

Midi::Midi(QObject *parent)
    : QObject(parent)
    , m_table(new MidiTable())
{
    m_timer.setInterval(16);
    m_timer.setTimerType(Qt::PreciseTimer);
    connect(&m_timer, &QTimer::timeout, this, &Midi::poll);
}

Midi::~Midi()
{
    m_timer.stop();
    if (m_port) {
        m_port->stop();
        // The table stays: the system may still deliver a message.
    }
}

void Midi::setEnabled(bool on)
{
    if (m_enabled == on)
        return;
    m_enabled = on;
    if (on && !m_port) {
        // A thread that cannot be made leaves only the controller unused.
        try {
            m_port = openMidiPort(m_table);
        } catch (...) {
            m_port = nullptr;
        }
    }
    if (m_port)
        m_port->setEnabled(on);
    if (on) {
        m_timer.start();
    } else {
        m_timer.stop();
        if (!m_devices.isEmpty()) {
            m_devices.clear();
            emit devicesChanged();
        }
        if (m_dawMode) {
            m_dawMode = false;
            emit dawModeChanged();
        }
    }
    emit enabledChanged();
}

void Midi::poll()
{
    const uint32_t revision = m_table->devicesRevision.load();
    if (revision != m_devicesRevision) {
        m_devicesRevision = revision;
        QStringList names;
        {
            std::lock_guard<std::mutex> lock(m_table->devicesMutex);
            names = m_table->devices;
        }
        // Plugged in again, perhaps after switching it to CC mode.
        m_table->daw = false;
        if (m_dawMode) {
            m_dawMode = false;
            emit dawModeChanged();
        }
        if (names != m_devices) {
            m_devices = names;
            emit devicesChanged();
        }
    }
    const uint32_t messages = m_table->messages.load();
    if (messages == m_messages)
        return;
    m_messages = messages;
    if (m_table->daw.load() != m_dawMode) {
        m_dawMode = !m_dawMode;
        emit dawModeChanged();
    }
    for (int channel = 0; channel < 16; ++channel) {
        for (int number = 0; number < 128; ++number) {
            const uint8_t value = m_table->value[channel][number].load(std::memory_order_relaxed);
            const uint8_t ons = m_table->ons[channel][number].load(std::memory_order_relaxed);
            const uint8_t offs = m_table->offs[channel][number].load(std::memory_order_relaxed);
            if (value == m_value[channel][number] && ons == m_ons[channel][number] && offs == m_offs[channel][number])
                continue;
            const int newOns = uint8_t(ons - m_ons[channel][number]);
            const int newOffs = uint8_t(offs - m_offs[channel][number]);
            m_value[channel][number] = value;
            m_ons[channel][number] = ons;
            m_offs[channel][number] = offs;
            if (value > 0)
                emit control(channel, number, value - 1, newOns, newOffs);
        }
    }
}
