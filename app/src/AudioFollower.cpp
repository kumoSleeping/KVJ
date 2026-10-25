#include "AudioFollower.h"

#include "kvj.h"

#include <QAudioDevice>
#include <QAudioOutput>
#include <QMediaPlayer>
#include <QUrl>

#include <algorithm>
#include <cmath>

namespace {
// Further off than this, seek; closer, steer the speed.
constexpr double kSeekBeyond = 0.15;
// Steering in a few steps, a few percent at most (heard as a slight drift in
// pitch while it lasts): every change of speed makes the system re-time its
// output for a moment, so the speed changes only when the step does.
double pullFor(double gap)
{
    const double size = std::abs(gap);
    const double step = size < 0.03 ? 0 : size < 0.08 ? 0.01 : size < 0.12 ? 0.02 : 0.04;
    return gap > 0 ? -step : step;
}
} // namespace

AudioFollower::AudioFollower(QObject *parent)
    : QObject(parent)
{
    m_timer.setInterval(50);
    connect(&m_timer, &QTimer::timeout, this, &AudioFollower::sync);
    // A jump or a new rate is followed at once, not at the next check, but
    // after the rest of the timing: position and clock change one at a time.
    m_soon.setSingleShot(true);
    connect(&m_soon, &QTimer::timeout, this, &AudioFollower::sync);
    connect(this, &AudioFollower::timingChanged, this, [this] {
        if (m_player)
            m_soon.start(0);
    });
    connect(&m_outputs, &QMediaDevices::audioOutputsChanged, this, [this] {
        emit devicesChanged();
        // An output that went away (headphones unplugged) falls back to the default.
        applyDevice();
    });
}

AudioFollower::~AudioFollower() = default;

void AudioFollower::setEnabled(bool enabled)
{
    if (m_enabled == enabled)
        return;
    m_enabled = enabled;
    restart();
    emit enabledChanged();
}

void AudioFollower::setSource(const QString &source)
{
    if (m_source == source)
        return;
    m_source = source;
    restart();
    emit sourceChanged();
}

void AudioFollower::setDevice(const QString &device)
{
    if (m_device == device)
        return;
    m_device = device;
    applyDevice();
    emit deviceChanged();
}

void AudioFollower::setVolume(double volume)
{
    volume = std::clamp(volume, 0.0, 1.0);
    if (m_volume == volume)
        return;
    m_volume = volume;
    if (m_output)
        m_output->setVolume(float(m_volume));
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

void AudioFollower::applyDevice()
{
    if (!m_output)
        return;
    QAudioDevice chosen = QMediaDevices::defaultAudioOutput();
    for (const QAudioDevice &device : QMediaDevices::audioOutputs()) {
        if (QString::fromUtf8(device.id()) == m_device) {
            chosen = device;
            break;
        }
    }
    if (m_output->device() != chosen)
        m_output->setDevice(chosen);
}

void AudioFollower::restart()
{
    m_timer.stop();
    m_player.reset();
    m_output = nullptr;
    setError({});
    if (!m_enabled || m_source.isEmpty())
        return;
    m_player = std::make_unique<QMediaPlayer>();
    m_output = new QAudioOutput(m_player.get());
    m_output->setVolume(float(m_volume));
    applyDevice();
    m_player->setAudioOutput(m_output);
    connect(m_player.get(), &QMediaPlayer::errorOccurred, this, [this](QMediaPlayer::Error, const QString &message) {
        setError(message.isEmpty() ? QStringLiteral("无法播放声音") : message);
    });
    connect(m_player.get(), &QMediaPlayer::mediaStatusChanged, this, [this](QMediaPlayer::MediaStatus status) {
        if (status == QMediaPlayer::LoadedMedia)
            sync();
    });
    m_playRate = 1;
    m_settleUntilMs = 0;
    m_measureLead = false;
    m_gap = 0;
    m_player->setSource(QUrl::fromLocalFile(m_source));
    m_timer.start();
}

void AudioFollower::sync()
{
    if (!m_player)
        return;
    const QMediaPlayer::MediaStatus status = m_player->mediaStatus();
    if (status == QMediaPlayer::NoMedia || status == QMediaPlayer::LoadingMedia || status == QMediaPlayer::InvalidMedia)
        return;
    const double now = kvj_clock_ms();
    const double target = m_position + (now - m_clockAtMs + m_offsetMs) / 1000.0 * m_rate;
    const double duration = m_player->duration() / 1000.0;
    const double heard = m_player->position() / 1000.0;
    const bool outside = target < 0 || (duration > 0 && target >= duration - 0.05);

    // Held or past either end: silent, but kept at the picture's place.
    if (m_rate <= 0 || outside) {
        if (m_player->playbackState() == QMediaPlayer::PlayingState)
            m_player->pause();
        if (!outside && std::abs(heard - target) > 0.05 && now >= m_settleUntilMs) {
            m_player->setPosition(qint64(target * 1000));
            m_settleUntilMs = now + 400;
        }
        return;
    }

    const double gap = heard - target;
    if (now < m_settleUntilMs) {
        if (m_player->playbackState() != QMediaPlayer::PlayingState)
            m_player->play();
        return;
    }
    // How far short the last seek landed: the next one aims that much ahead.
    if (m_measureLead) {
        m_measureLead = false;
        if (std::abs(gap) < 1.0)
            m_lead = std::clamp(m_lead - gap, 0.0, 0.6);
    }
    if (std::abs(gap) > kSeekBeyond) {
        m_player->setPosition(qint64((target + m_lead) * 1000));
        m_settleUntilMs = now + 400;
        m_measureLead = true;
        m_gap = 0;
        return;
    }
    // The reported position moves in steps; steer on a smoothed gap.
    m_gap = 0.7 * m_gap + 0.3 * gap;
    const double rate = m_rate * (1.0 + pullFor(m_gap));
    if (std::abs(rate - m_playRate) > 0.0005) {
        m_playRate = rate;
        m_player->setPlaybackRate(rate);
    }
    if (m_player->playbackState() != QMediaPlayer::PlayingState)
        m_player->play();
}

void AudioFollower::setError(const QString &error)
{
    if (m_error == error)
        return;
    m_error = error;
    emit errorChanged();
}
