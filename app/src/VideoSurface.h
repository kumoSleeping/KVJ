#pragma once

// The projected picture. It extrapolates the engine's match to the media time
// due now (position + elapsed engine clock × rate + offset) and shows the frame
// for that time. It wakes only when the next frame is due and redraws only when
// the frame changes, so a 30 fps video costs 30 redraws a second, not the
// display's refresh rate. Without a new frame it keeps the last one. A jump (a
// new file, or a time the clock alone would not have reached) can dissolve from
// the old picture over `fadeMs`. Previews (PreviewSurface) get reduced copies of
// the frames it shows.

#include "Decoder.h"

#include <QImage>
#include <QQuickItem>
#include <QList>
#include <QTimer>
#include <memory>

class PreviewSurface;
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
    // Dissolve this long into the picture after a jump (0 = cut).
    Q_PROPERTY(int fadeMs MEMBER m_fadeMs NOTIFY fadeChanged)
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
    int fadeMs() const { return m_fadeMs; }
    void attachPreview(PreviewSurface *preview);
    void detachPreview(PreviewSurface *preview);

signals:
    void sourceChanged();
    void timingChanged();
    void qualityChanged();
    void fadeChanged();
    void hasFrameChanged();
    void errorChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
    void restart();
    void tick();
    void feedPreviews(bool jump);

    QString m_source;
    DecodeOptions m_options;
    double m_position = 0;
    double m_rate = 1;
    double m_clockAtMs = 0;
    double m_offsetMs = 0;
    int m_maxFps = 30;
    int m_fadeMs = 0;
    double m_lastPts = -1;
    // Where the last tick aimed and when, to tell a jump from time passing.
    double m_lastTarget = 0;
    double m_lastTickAt = -1;
    // A jump happened; the first frame after it dissolves in.
    bool m_jumped = false;
    bool m_fadeNext = false;
    std::unique_ptr<VideoPlayer> m_player;
    QTimer m_timer;
    QImage m_pending;
    bool m_newFrame = false;
    bool m_clear = false;
    bool m_hasFrame = false;
    QString m_error;
    QList<PreviewSurface *> m_previews;
};
