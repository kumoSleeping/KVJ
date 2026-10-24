#pragma once

// The projected picture. It extrapolates the engine's match to the media time
// due now (position + elapsed engine clock × rate + offset) and shows the frame
// for that time. It wakes only when the next frame is due and redraws only when
// the frame changes, so a 30 fps video costs 30 redraws a second, not the
// display's refresh rate. Without a new frame it keeps the last one.

#include "Decoder.h"

#include <QImage>
#include <QQuickItem>
#include <QTimer>
#include <memory>

class VideoPlayer;

class VideoSurface : public QQuickItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(double position MEMBER m_position NOTIFY timingChanged)
    Q_PROPERTY(double rate MEMBER m_rate NOTIFY timingChanged)
    Q_PROPERTY(double clockAtMs MEMBER m_clockAtMs NOTIFY timingChanged)
    // Manual calibration added to the extrapolated time, in milliseconds.
    Q_PROPERTY(double offsetMs MEMBER m_offsetMs NOTIFY timingChanged)
    // Decode at most this tall (0 = source size).
    Q_PROPERTY(int maxHeight READ maxHeight WRITE setMaxHeight NOTIFY qualityChanged)
    // Show at most this many frames a second (0 = every frame of the source).
    Q_PROPERTY(int maxFps MEMBER m_maxFps NOTIFY qualityChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
    explicit VideoSurface(QQuickItem *parent = nullptr);
    ~VideoSurface() override;

    QString source() const { return m_source; }
    void setSource(const QString &source);
    int maxHeight() const { return m_options.maxHeight; }
    void setMaxHeight(int height);
    bool hasFrame() const { return m_hasFrame; }
    QString error() const { return m_error; }

signals:
    void sourceChanged();
    void timingChanged();
    void qualityChanged();
    void hasFrameChanged();
    void errorChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
    void restart();
    void tick();

    QString m_source;
    DecodeOptions m_options;
    double m_position = 0;
    double m_rate = 1;
    double m_clockAtMs = 0;
    double m_offsetMs = 0;
    int m_maxFps = 30;
    double m_lastPts = -1;
    std::unique_ptr<VideoPlayer> m_player;
    QTimer m_timer;
    QImage m_pending;
    bool m_newFrame = false;
    bool m_clear = false;
    bool m_hasFrame = false;
    QString m_error;
};
