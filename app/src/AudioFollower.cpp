#include "AudioFollower.h"

#include "kvj.h"

#include <rubberband/RubberBandStretcher.h>

#include <QAudioFormat>
#include <QDebug>
#include <QAudioSink>
#include <QCoreApplication>
#include <QDir>
#include <QIODevice>
#include <QPointer>
#include <QTimer>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <mutex>
#include <vector>

namespace {
// The sound seeks only when the picture jumps: its time moves further than
// its own speed explains. Otherwise it is steered, faster or slower with the
// pitch kept, however far off it is (after a nudge at four times the speed
// the stretcher's delay leaves it half a second behind): gently while close,
// up to half as fast again to catch up; and only when it is lost altogether.
constexpr double kJumpBeyond = 0.25;
constexpr double kLostBeyond = 2.0;
// For a moment after the picture's speed changes the stretcher's delay makes
// the sound look further off than it is: it is not steered then.
constexpr double kChangingMs = 500;
constexpr double kSteerBelow = 0.008;
double pullFor(double drift)
{
    if (std::abs(drift) < kSteerBelow)
        return 0;
    // Within a tenth of a second: a few percent, unheard. Beyond: quicker.
    const double most = std::abs(drift) < 0.1 ? 0.04 : 0.5;
    return std::clamp(-drift * (std::abs(drift) < 0.1 ? 0.8 : 1.5), -most, most);
}
// Frames fed to the stretcher at a time, as KDJ feeds it: a new speed is heard
// within about 10 ms.
constexpr int kBlock = 512;
// How much the output holds: enough that a busy moment never starves it.
constexpr double kQueueSeconds = 0.12;
// After a seek the sound comes in over this long instead of with a click.
constexpr double kFadeSeconds = 0.008;
constexpr int kTickMs = 10;

// Rubber Band R3, real time, as KDJ runs it: short windows for quick response,
// both channels together, no threads of its own, a steady pitch while the
// ratio moves.
constexpr RubberBand::RubberBandStretcher::Options kOptions =
    RubberBand::RubberBandStretcher::OptionProcessRealTime | RubberBand::RubberBandStretcher::OptionEngineFiner
    | RubberBand::RubberBandStretcher::OptionWindowShort | RubberBand::RubberBandStretcher::OptionChannelsTogether
    | RubberBand::RubberBandStretcher::OptionThreadingNever
    | RubberBand::RubberBandStretcher::OptionPitchHighConsistency;

struct Timing
{
    double position = 0;
    double rate = 0;
    double clockAtMs = 0;
    double offsetMs = 0;
};
} // namespace

// The playing itself, on the follower's thread; only setTiming is called from
// elsewhere. It knows the media time of the next frame it writes to the
// output (each written frame stands for 1 / outRate seconds at the speed it
// was stretched to), so the media time heard now is that less what the output
// still holds, each part at the speed it was made at. That is kept on the
// picture's.
class SoundPlayer
{
public:
    ~SoundPlayer() { close(); }

    void setTiming(const Timing &timing)
    {
        std::lock_guard lock(m_mutex);
        m_timing = timing;
    }

    // An empty path closes. Returns what went wrong, if anything.
    QString open(const QString &path, const QAudioDevice &device, double volume)
    {
        close();
        m_volume = volume;
        if (path.isEmpty())
            return {};
        if (!m_timer) {
            m_timer = std::make_unique<QTimer>();
            m_timer->setTimerType(Qt::PreciseTimer);
            m_timer->setInterval(kTickMs);
            QObject::connect(m_timer.get(), &QTimer::timeout, m_timer.get(), [this] { tick(); });
        }
        uint32_t rate = 0;
        m_sound = kvj_sound_open(QDir::toNativeSeparators(path).toUtf8().constData(), &rate, &m_duration);
        if (!m_sound)
            return QStringLiteral("这个素材没有可播放的声音");
        m_srcRate = int(rate);

        QAudioFormat format;
        format.setChannelCount(2);
        format.setSampleFormat(QAudioFormat::Float);
        format.setSampleRate(m_srcRate);
        if (!device.isFormatSupported(format))
            format.setSampleRate(device.preferredFormat().sampleRate());
        if (!device.isFormatSupported(format))
            format.setSampleFormat(QAudioFormat::Int16);
        m_float = format.sampleFormat() == QAudioFormat::Float;
        m_outRate = format.sampleRate() > 0 ? format.sampleRate() : m_srcRate;
        m_sink = std::make_unique<QAudioSink>(device, format);
        m_sink->setBufferSize(frameBytes() * int(m_outRate * kQueueSeconds));
        m_sink->setVolume(float(m_volume));

        // Played at another rate than its own, the stretcher's pitch makes up for it.
        m_speed = 1;
        m_ratio = double(m_outRate) / m_srcRate;
        m_stretcher = std::make_unique<RubberBand::RubberBandStretcher>(
            size_t(m_srcRate), 2, kOptions, m_ratio, double(m_srcRate) / m_outRate);
        m_stretcher->setMaxProcessSize(kBlock);
        m_inLeft.assign(kBlock, 0);
        m_inRight.assign(kBlock, 0);
        m_outLeft.assign(kBlock * 2, 0);
        m_outRight.assign(kBlock * 2, 0);
        m_frames.assign(kBlock * 2 * 2, 0);
        m_bytes.resize(kBlock * 2 * 8);
        m_needSync = true;
        m_timer->start();
        return {};
    }

    void setVolume(double volume)
    {
        m_volume = volume;
        if (m_sink)
            m_sink->setVolume(float(volume));
    }

    void close()
    {
        if (m_timer)
            m_timer->stop();
        if (m_sink)
            m_sink->stop();
        m_io = nullptr;
        m_sink.reset();
        m_stretcher.reset();
        if (m_sound)
            kvj_sound_free(m_sound);
        m_sound = nullptr;
    }

    void shutDown()
    {
        close();
        m_timer.reset();
    }

private:
    int frameBytes() const { return m_float ? 8 : 4; }

    void tick()
    {
        if (!m_sound || !m_sink)
            return;
        Timing timing;
        {
            std::lock_guard lock(m_mutex);
            timing = m_timing;
        }
        const double now = kvj_clock_ms();
        const double target = timing.position + (now - timing.clockAtMs + timing.offsetMs) / 1000.0 * timing.rate;
        const bool outside = target < 0 || (m_duration > 0 && target >= m_duration - 0.05);

        // Held or past either end: silent at once, and from the picture's
        // place again once it moves.
        if (timing.rate <= 0 || outside) {
            if (m_io) {
                m_sink->stop();
                m_io = nullptr;
            }
            m_needSync = true;
            return;
        }

        // A jump: the picture's time is not where its speed since the last
        // look would have taken it.
        const bool jumped = m_lastLookAt > 0
                            && std::abs(target - (m_lastTarget + (now - m_lastLookAt) / 1000.0 * m_lastRate)) > kJumpBeyond;
        m_lastTarget = target;
        m_lastLookAt = now;
        if (timing.rate != m_lastRate) {
            m_lastRate = timing.rate;
            m_rateAt = now;
        }
        const bool changing = now - m_rateAt < kChangingMs;
        const int queuedFrames = m_io ? (m_sink->bufferSize() - m_sink->bytesFree()) / frameBytes() : 0;
        const double queued = queuedMedia(queuedFrames);
        const double gap = m_mediaOut - queued - target;
        if (m_log)
            report(now, gap, double(queuedFrames) / m_outRate);
        if (m_needSync || !m_io || jumped || std::abs(gap) > kLostBeyond) {
            m_speed = timing.rate;
            applyRatio();
            seek(target);
            ++m_seeks;
            m_needSync = false;
        } else {
            // The reported queue moves in steps; steer on a smoothed gap.
            m_drift = changing ? 0 : 0.8 * m_drift + 0.2 * gap;
            m_speed = timing.rate * (1.0 + pullFor(m_drift));
            applyRatio();
        }
        fill();
    }

    // KVJ_SOUND_LOG=1: once a second, how far the sound is from the picture,
    // at what speed, what the output holds, and the seeks and starved moments
    // so far.
    void report(double now, double gap, double queued)
    {
        if (m_io && m_sink->state() == QAudio::IdleState && m_sink->error() == QAudio::UnderrunError)
            ++m_starved;
        if (now - m_reportedAt < 1000)
            return;
        m_reportedAt = now;
        qInfo().noquote() << QStringLiteral("sound: gap %1 ms · speed %2 · queued %3 ms · seeks %4 · starved %5")
                                 .arg(gap * 1000, 0, 'f', 1).arg(m_speed, 0, 'f', 4).arg(queued * 1000, 0, 'f', 0)
                                 .arg(m_seeks).arg(m_starved);
    }

    // Media seconds in the output's last `frames` frames, from what was written.
    double queuedMedia(int frames)
    {
        while (!m_written.empty() && m_writtenFrames - m_written.front().frames >= frames) {
            m_writtenFrames -= m_written.front().frames;
            m_written.pop_front();
        }
        double media = 0;
        for (const Written &part : m_written)
            media += part.frames * part.mediaPerFrame;
        if (!m_written.empty())
            media -= (m_writtenFrames - frames) * m_written.front().mediaPerFrame;
        return std::max(0.0, media);
    }

    void applyRatio()
    {
        const double ratio = double(m_outRate) / (m_srcRate * std::max(0.05, m_speed));
        if (std::abs(ratio - m_ratio) > 1e-9) {
            m_ratio = ratio;
            m_stretcher->setTimeRatio(ratio);
        }
    }

    // From `at` on: the output emptied, the file and the stretcher started
    // there afresh, its start padded and its delay dropped so the first frame
    // out is the one at `at`.
    void seek(double at)
    {
        m_sink->stop();
        m_io = m_sink->start();
        kvj_sound_seek(m_sound, at);
        m_stretcher->reset();
        std::fill(m_inLeft.begin(), m_inLeft.end(), 0.0f);
        std::fill(m_inRight.begin(), m_inRight.end(), 0.0f);
        for (size_t pad = m_stretcher->getPreferredStartPad(); pad > 0;) {
            const size_t n = std::min<size_t>(pad, kBlock);
            const float *planes[2] = {m_inLeft.data(), m_inRight.data()};
            m_stretcher->process(planes, n, false);
            pad -= n;
        }
        m_discard = int(m_stretcher->getStartDelay());
        m_written.clear();
        m_writtenFrames = 0;
        m_mediaOut = at;
        m_drift = 0;
        m_faded = 0;
    }

    // The stretcher's next block from the file; past its end, silence.
    void feed()
    {
        const size_t required = m_stretcher->getSamplesRequired();
        const size_t n = required > 0 ? std::min<size_t>(required, kBlock) : kBlock;
        const size_t got = kvj_sound_read(m_sound, m_frames.data(), n);
        for (size_t i = 0; i < n; ++i) {
            m_inLeft[i] = i < got ? m_frames[i * 2] : 0.0f;
            m_inRight[i] = i < got ? m_frames[i * 2 + 1] : 0.0f;
        }
        const float *planes[2] = {m_inLeft.data(), m_inRight.data()};
        m_stretcher->process(planes, n, false);
    }

    // The output topped up.
    void fill()
    {
        if (!m_io)
            return;
        int room = m_sink->bytesFree() / frameBytes();
        const int fadeFrames = std::max(1, int(m_outRate * kFadeSeconds));
        for (int feeds = 0; room > 0 && feeds < 64;) {
            int available = m_stretcher->available();
            if (available <= 0) {
                feed();
                ++feeds;
                continue;
            }
            const int n = std::min({available, room, kBlock * 2});
            float *planes[2] = {m_outLeft.data(), m_outRight.data()};
            const int got = int(m_stretcher->retrieve(planes, size_t(n)));
            const int skip = std::min(got, m_discard);
            m_discard -= skip;
            const int count = got - skip;
            if (count <= 0)
                continue;
            for (int i = 0; i < count; ++i) {
                float gain = 1.0f;
                if (m_faded < fadeFrames)
                    gain = float(m_faded++) / fadeFrames;
                m_frames[i * 2] = m_outLeft[skip + i] * gain;
                m_frames[i * 2 + 1] = m_outRight[skip + i] * gain;
            }
            qint64 bytes = 0;
            if (m_float) {
                bytes = qint64(count) * 8;
                std::memcpy(m_bytes.data(), m_frames.data(), size_t(bytes));
            } else {
                auto *out = reinterpret_cast<qint16 *>(m_bytes.data());
                for (int i = 0; i < count * 2; ++i)
                    out[i] = qint16(std::clamp(m_frames[i], -1.0f, 1.0f) * 32767.0f);
                bytes = qint64(count) * 4;
            }
            m_io->write(m_bytes.data(), bytes);
            room -= count;
            m_mediaOut += count / double(m_outRate) * m_speed;
            m_written.push_back({count, m_speed / m_outRate});
            m_writtenFrames += count;
        }
    }

    std::mutex m_mutex;
    Timing m_timing;

    std::unique_ptr<QTimer> m_timer;
    KvjSound *m_sound = nullptr;
    double m_duration = 0;
    int m_srcRate = 48000;
    int m_outRate = 48000;
    bool m_float = true;
    double m_volume = 1;
    std::unique_ptr<QAudioSink> m_sink;
    QIODevice *m_io = nullptr;
    std::unique_ptr<RubberBand::RubberBandStretcher> m_stretcher;
    double m_ratio = 1;
    double m_speed = 1;
    // Media seconds of the next frame written to the output.
    double m_mediaOut = 0;
    double m_drift = 0;
    // What is in the output, oldest first: frames and the media each stands for.
    struct Written
    {
        int frames;
        double mediaPerFrame;
    };
    std::deque<Written> m_written;
    qint64 m_writtenFrames = 0;
    double m_lastRate = 0;
    double m_rateAt = 0;
    double m_lastTarget = 0;
    double m_lastLookAt = 0;
    int m_discard = 0;
    int m_faded = 0;
    bool m_needSync = true;
    const bool m_log = qEnvironmentVariableIntValue("KVJ_SOUND_LOG") > 0;
    double m_reportedAt = 0;
    int m_seeks = 0;
    int m_starved = 0;
    std::vector<float> m_inLeft, m_inRight, m_outLeft, m_outRight, m_frames;
    QByteArray m_bytes;
};

AudioFollower::AudioFollower(QObject *parent)
    : QObject(parent)
    , m_player(std::make_shared<SoundPlayer>())
{
    m_thread.setObjectName(QStringLiteral("kvj-sound"));
    m_context = new QObject;
    m_context->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_context, &QObject::deleteLater);
    m_thread.start(QThread::TimeCriticalPriority);
    connect(this, &AudioFollower::timingChanged, this, &AudioFollower::push);
    connect(&m_outputs, &QMediaDevices::audioOutputsChanged, this, [this] {
        emit devicesChanged();
        // An output that went away (headphones unplugged) falls back to the default.
        if (m_enabled && chosenDevice().id() != m_openDevice)
            reopen();
    });
}

AudioFollower::~AudioFollower()
{
    const std::shared_ptr<SoundPlayer> player = m_player;
    QMetaObject::invokeMethod(m_context, [player] { player->shutDown(); }, Qt::BlockingQueuedConnection);
    m_thread.quit();
    m_thread.wait();
}

void AudioFollower::setEnabled(bool enabled)
{
    if (m_enabled == enabled)
        return;
    m_enabled = enabled;
    reopen();
    emit enabledChanged();
}

void AudioFollower::setSource(const QString &source)
{
    if (m_source == source)
        return;
    m_source = source;
    reopen();
    emit sourceChanged();
}

void AudioFollower::setDevice(const QString &device)
{
    if (m_device == device)
        return;
    m_device = device;
    if (m_enabled && chosenDevice().id() != m_openDevice)
        reopen();
    emit deviceChanged();
}

void AudioFollower::setVolume(double volume)
{
    volume = std::clamp(volume, 0.0, 1.0);
    if (m_volume == volume)
        return;
    m_volume = volume;
    const std::shared_ptr<SoundPlayer> player = m_player;
    QMetaObject::invokeMethod(m_context, [player, volume] { player->setVolume(volume); });
    emit volumeChanged();
}

QVariantList AudioFollower::devices() const
{
    QVariantList list;
    for (const QAudioDevice &device : QMediaDevices::audioOutputs()) {
        list.append(QVariantMap{
            {"id", QString::fromUtf8(device.id())},
            {"name", device.description()},
            {"isDefault", device.isDefault()},
        });
    }
    return list;
}

QAudioDevice AudioFollower::chosenDevice() const
{
    for (const QAudioDevice &device : QMediaDevices::audioOutputs()) {
        if (QString::fromUtf8(device.id()) == m_device)
            return device;
    }
    return QMediaDevices::defaultAudioOutput();
}

void AudioFollower::push()
{
    m_player->setTiming({m_position, m_rate, m_clockAtMs, m_offsetMs});
}

void AudioFollower::reopen()
{
    push();
    const QString path = m_enabled ? m_source : QString();
    const QAudioDevice device = chosenDevice();
    m_openDevice = path.isEmpty() ? QByteArray() : device.id();
    if (path.isEmpty())
        setError({});
    const std::shared_ptr<SoundPlayer> player = m_player;
    const double volume = m_volume;
    QPointer<AudioFollower> self(this);
    QMetaObject::invokeMethod(m_context, [player, path, device, volume, self] {
        const QString error = player->open(path, device, volume);
        QMetaObject::invokeMethod(qApp, [self, error, path] {
            // Only what the latest request found counts.
            if (self && (self->m_enabled ? self->m_source : QString()) == path)
                self->setError(error);
        });
    });
}

void AudioFollower::setError(const QString &error)
{
    if (m_error == error)
        return;
    m_error = error;
    emit errorChanged();
}
