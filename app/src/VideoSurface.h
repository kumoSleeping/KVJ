#pragma once

// The projected picture. It extrapolates the engine's match to the media time
// due now (position + elapsed engine clock × rate + offset) and shows the frame
// for that time. It wakes only when the next frame is due and redraws only when
// the frame changes, so a 30 fps video costs 30 redraws a second, not the
// display's refresh rate. Without a new frame it keeps the last one. A jump (a
// new file, or a time the clock alone would not have reached) can dissolve from
// the old picture over `fadeMs`: the old one does not stop but plays on, on a
// player of its own from where it was at its speed, until the new one has a
// frame and through the dissolve, so both move while they cross. That takes a
// second decoder; with the process's decoders at their budget a jump cuts
// instead. Previews (PreviewSurface) get reduced copies of the frames it shows.

#include "Decoder.h"
#include "PictureSource.h"

#include <QImage>
#include <QTimer>
#include <memory>

class VideoPlayer;

class VideoSurface : public PictureSource
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
    // The video as stored (sourceSize, and its frames a second), kept from the
    // last one opened; for recommending the output's quality.
    Q_PROPERTY(double sourceFps READ sourceFps NOTIFY sourceInfoChanged)
    // Nobody can see the picture for now (the operator's window minimized, no
    // output up): the open file stays open but nothing is decoded, and the
    // picture goes on from where it is due once this turns off again. Closing
    // the file instead and opening it anew on the way back left the picture
    // black for good when the system would not give a decoder back.
    Q_PROPERTY(bool idle READ idle WRITE setIdle NOTIFY idleChanged)

public:
    explicit VideoSurface(QQuickItem *parent = nullptr);
    ~VideoSurface() override;

    QString source() const { return m_source; }
    void setSource(const QString &source);
    int maxHeight() const { return m_options.maxHeight; }
    void setMaxHeight(int height);
    bool idle() const { return m_idle; }
    void setIdle(bool idle);
    double sourceFps() const { return m_sourceFps; }
    int fadeMs() const { return m_fadeMs; }

signals:
    void sourceChanged();
    void timingChanged();
    void qualityChanged();
    void fadeChanged();
    void idleChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
    void restart();
    void tick();
    bool fadeable() const;
    static bool withinBudget();
    bool keepPlaying(double nowMs);
    void dropOutgoing();
    void tickOutgoing(double nowMs, int *wait);
    void replaceStalled();
    void noteError(const QString &error);

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
    double m_lastRate = 1;
    // A jump happened; the first frame after it dissolves in.
    bool m_jumped = false;
    bool m_fadeNext = false;
    bool m_idle = false;
    // How long the player may stay inside one decoder call before it is
    // given up for a new one; longer after each one given up, until a frame comes.
    double m_stallSeconds = 6;
    std::unique_ptr<VideoPlayer> m_player;
    QTimer m_timer;
    QImage m_pending;
    bool m_newFrame = false;
    bool m_clear = false;
    double m_sourceFps = 0;
    // The picture before the last jump, playing on from `m_outBase` seconds at
    // `m_outAt` (engine clock) at `m_outRate`. Holding: the new player has no
    // frame yet, so this one is still the picture; then it dissolves out from
    // `m_fadeFrom`.
    std::unique_ptr<VideoPlayer> m_outgoing;
    double m_outBase = 0;
    double m_outAt = 0;
    double m_outRate = 0;
    double m_outLastPts = -1;
    bool m_outHolding = false;
    double m_fadeFrom = 0;
    QImage m_outPending;
    bool m_outNew = false;
    bool m_outShown = false;
};
