#pragma once

// The sound of the entry on the screen, played in step with its picture on an
// output the operator picks (headphones, speakers, an interface). It takes the
// same timing as VideoSurface: media seconds at an engine-clock moment, a rate
// and a calibration offset. It plays on a thread of its own: the engine
// decodes the file (kvj_sound_*), Rubber Band stretches it to the picture's
// speed keeping its pitch, as KDJ does, and a QAudioSink plays it. A change of
// speed is only a new ratio for the stretcher, so the sound never breaks; a
// small drift from the picture is steered away the same way, a little faster
// or slower, and only a jump seeks. Nothing is opened while it is off, so it
// costs nothing until the operator wants sound; the output and the volume can
// be chosen before.

#include <QAudioDevice>
#include <QByteArray>
#include <QMediaDevices>
#include <QObject>
#include <QString>
#include <QThread>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>
#include <memory>

class SoundPlayer;

class AudioFollower : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(double position MEMBER m_position NOTIFY timingChanged)
    Q_PROPERTY(double rate MEMBER m_rate NOTIFY timingChanged)
    Q_PROPERTY(double clockAtMs MEMBER m_clockAtMs NOTIFY timingChanged)
    Q_PROPERTY(double offsetMs MEMBER m_offsetMs NOTIFY timingChanged)
    // An id from `devices`; empty for the system's default output.
    Q_PROPERTY(QString device READ device WRITE setDevice NOTIFY deviceChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    // [{ id, name, isDefault }] of the outputs there are now.
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
    explicit AudioFollower(QObject *parent = nullptr);
    ~AudioFollower() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool enabled);
    QString source() const { return m_source; }
    void setSource(const QString &source);
    QString device() const { return m_device; }
    void setDevice(const QString &device);
    double volume() const { return m_volume; }
    void setVolume(double volume);
    QVariantList devices() const;
    QString error() const { return m_error; }

signals:
    void enabledChanged();
    void sourceChanged();
    void timingChanged();
    void deviceChanged();
    void volumeChanged();
    void devicesChanged();
    void errorChanged();

private:
    // The file and the output to the player, anew.
    void reopen();
    // The timing to the player.
    void push();
    QAudioDevice chosenDevice() const;
    void setError(const QString &error);

    bool m_enabled = false;
    QString m_source;
    QString m_device;
    double m_volume = 1.0;
    double m_position = 0;
    double m_rate = 1;
    double m_clockAtMs = 0;
    double m_offsetMs = 0;
    QString m_error;
    // The output the player has open, to reopen only when another is chosen.
    QByteArray m_openDevice;

    QMediaDevices m_outputs;
    QThread m_thread;
    // Lives on m_thread: what the player's work is queued on.
    QObject *m_context = nullptr;
    std::shared_ptr<SoundPlayer> m_player;
};
