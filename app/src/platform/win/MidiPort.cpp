// WinMM. It tells of no device coming or going, so the port's thread looks at
// the list of inputs every two seconds and, when it changed, closes every
// device it had open and opens the wanted ones there are now (their numbers
// move when one is plugged in or out). Messages arrive on WinMM's own thread
// and only go into the table: nothing else may be called from there.

#include "Midi.h"

#include <windows.h>
#include <mmsystem.h>

#include <chrono>
#include <condition_variable>
#include <future>
#include <thread>
#include <vector>

namespace {

void CALLBACK received(HMIDIIN, UINT message, DWORD_PTR user, DWORD_PTR param1, DWORD_PTR)
{
    if (message != MIM_DATA)
        return;
    const DWORD data = DWORD(param1);
    reinterpret_cast<MidiTable *>(user)->feed(uint8_t(data), uint8_t(data >> 8), uint8_t(data >> 16));
}

class WinMidiPort final : public MidiPort
{
public:
    explicit WinMidiPort(MidiTable *table)
        : m_table(table)
    {
        m_thread = std::thread([this] {
            run();
            m_exited.set_value();
        });
    }
    void setEnabled(bool on) override
    {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_enabled = on;
            m_changed = true;
        }
        m_wake.notify_all();
    }
    void stop() override
    {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_stop = true;
        }
        m_wake.notify_all();
        if (m_exited.get_future().wait_for(std::chrono::seconds(1)) == std::future_status::ready) {
            m_thread.join();
            delete this;
        } else {
            m_thread.detach();
        }
    }

private:
    void run()
    {
        // The inputs as last seen; empty, they are looked at afresh.
        std::vector<std::wstring> seen;
        bool looked = false;
        for (;;) {
            bool enabled;
            {
                std::unique_lock<std::mutex> lock(m_mutex);
                m_wake.wait_for(lock, std::chrono::seconds(2), [this] { return m_stop || m_changed; });
                if (m_stop)
                    break;
                enabled = m_enabled;
                if (m_changed)
                    looked = false;
                m_changed = false;
            }
            if (!enabled) {
                closeAll();
                looked = false;
                continue;
            }
            std::vector<std::wstring> names;
            const UINT count = midiInGetNumDevs();
            for (UINT i = 0; i < count; ++i) {
                MIDIINCAPSW caps = {};
                names.push_back(midiInGetDevCapsW(i, &caps, sizeof caps) == MMSYSERR_NOERROR ? std::wstring(caps.szPname) : std::wstring());
            }
            if (looked && names == seen)
                continue;
            seen = names;
            looked = true;
            closeAll();
            QStringList open;
            for (UINT i = 0; i < UINT(names.size()); ++i) {
                const QString name = QString::fromStdWString(names[i]);
                if (!MidiTable::wanted(name))
                    continue;
                HMIDIIN handle = nullptr;
                if (midiInOpen(&handle, i, DWORD_PTR(&received), DWORD_PTR(m_table), CALLBACK_FUNCTION) != MMSYSERR_NOERROR)
                    continue;
                if (midiInStart(handle) != MMSYSERR_NOERROR) {
                    midiInClose(handle);
                    continue;
                }
                m_open.push_back(handle);
                open.append(name);
            }
            m_table->setDevices(open);
        }
        closeAll();
    }
    void closeAll()
    {
        for (HMIDIIN handle : m_open) {
            midiInStop(handle);
            midiInReset(handle);
            midiInClose(handle);
        }
        m_open.clear();
        m_table->setDevices({});
    }

    MidiTable *m_table;
    std::thread m_thread;
    std::promise<void> m_exited;
    std::mutex m_mutex;
    std::condition_variable m_wake;
    bool m_stop = false;
    bool m_enabled = false;
    bool m_changed = true;
    std::vector<HMIDIIN> m_open;
};

} // namespace

MidiPort *openMidiPort(MidiTable *table)
{
    return new WinMidiPort(table);
}
