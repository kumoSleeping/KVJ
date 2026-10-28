#pragma once

// Decodes one file ahead of a moving target time on its own thread. The picture
// asks for the frame due at a time; the player seeks when that time jumps away
// from what it has decoded and drops frames that are already late. Only a few
// frames are held, and their buffers are reused. Each player is a decoder of
// its own; the process keeps count of them, and dissolves (which want a second
// one) stay within `kBudget`.

#include "Decoder.h"

#include <chrono>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

class VideoPlayer
{
public:
    VideoPlayer(const QString &path, const DecodeOptions &options);
    ~VideoPlayer();
    VideoPlayer(const VideoPlayer &) = delete;
    VideoPlayer &operator=(const VideoPlayer &) = delete;

    static constexpr int kBudget = 6;
    // Players in the process, counting ones still stopping.
    static int live();
    // Lets go of a player whose decoder call never came back: it is told to
    // stop and left to do so whenever the call returns, if ever, and is not
    // waited for (joining a hung thread would hang whoever waits, the app's
    // exit too). It is never freed, as its thread may still use it.
    static void abandon(std::unique_ptr<VideoPlayer> player);

    // The frame due at `target` seconds, if it differs from the one returned
    // last. `rate` is how fast the target moves (0 while paused): seeks aim
    // ahead by what passes while they decode, and a paused picture lands on the
    // exact frame.
    bool frameFor(double target, VideoFrame *frame, double rate = 1);
    // Media seconds from `target` until the next decoded frame is due, or a
    // negative value when none is decoded yet.
    double untilNext(double target) const;
    QString error() const;
    // The video as stored, once the decoder has opened it (empty and 0 before).
    QSize sourceSize() const;
    double sourceFps() const;
    // Seconds the decoder has been inside one call to the system (opening,
    // seeking, decoding), 0 between calls. A decoder that never comes back
    // (a hardware decoder hung by the driver) holds the picture still, and
    // only a new player gets it moving again.
    double busySeconds() const;

private:
    void run();
    void recycle(VideoFrame &&frame);

    const QString m_path;
    const DecodeOptions m_options;
    mutable std::mutex m_mutex;
    std::condition_variable m_wake;
    std::deque<VideoFrame> m_queue;
    std::vector<QImage> m_spare;
    double m_target = 0;
    double m_rate = 1;
    bool m_targetSet = false;
    double m_shownPts = -1;
    bool m_stop = false;
    QString m_error;
    QSize m_sourceSize;
    double m_sourceFps = 0;
    bool m_busy = false;
    std::chrono::steady_clock::time_point m_busyAt;
    std::thread m_thread;
};
