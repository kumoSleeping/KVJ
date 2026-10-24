#pragma once

// Decodes one file ahead of a moving target time on its own thread. The picture
// asks for the frame due at a time; the player seeks when that time jumps away
// from what it has decoded and drops frames that are already late. Only a few
// frames are held, and their buffers are reused.

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

    // The frame due at `target` seconds, if it differs from the one returned last.
    bool frameFor(double target, VideoFrame *frame);
    // Media seconds from `target` until the next decoded frame is due, or a
    // negative value when none is decoded yet.
    double untilNext(double target) const;
    QString error() const;

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
    bool m_targetSet = false;
    double m_shownPts = -1;
    bool m_stop = false;
    QString m_error;
    std::thread m_thread;
};
