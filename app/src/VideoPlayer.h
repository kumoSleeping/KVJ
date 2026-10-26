#pragma once

// Decodes one file ahead of a moving target time on its own thread. The picture
// asks for the frame due at a time; the player seeks when that time jumps away
// from what it has decoded and drops frames that are already late. Only a few
// frames are held, and their buffers are reused. Each player is a decoder of
// its own; the process keeps count of them, and dissolves (which want a second
// one) stay within `kBudget`.

#include "Decoder.h"

#include <condition_variable>
#include <deque>
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
    std::thread m_thread;
};
