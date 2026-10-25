#include "VideoPlayer.h"

#include <algorithm>
#include <chrono>

namespace {
// Seek instead of decoding through when the target leaves what is decoded.
constexpr double kBackTolerance = 0.25;
constexpr double kAheadLimit = 2.0;
// Frames decoded ahead of the target: enough to absorb decoder jitter, few
// enough to keep memory small next to the DJ software.
constexpr int kAhead = 3;
constexpr size_t kSpare = 3;
} // namespace

VideoPlayer::VideoPlayer(const QString &path, const DecodeOptions &options)
    : m_path(path)
    , m_options(options)
{
    m_thread = std::thread([this] { run(); });
}

VideoPlayer::~VideoPlayer()
{
    {
        std::lock_guard lock(m_mutex);
        m_stop = true;
    }
    m_wake.notify_all();
    m_thread.join();
}

QString VideoPlayer::error() const
{
    std::lock_guard lock(m_mutex);
    return m_error;
}

// Called with the mutex held.
void VideoPlayer::recycle(VideoFrame &&frame)
{
    if (m_spare.size() < kSpare && !frame.image.isNull())
        m_spare.push_back(std::move(frame.image));
}

bool VideoPlayer::frameFor(double target, VideoFrame *frame, double rate)
{
    bool fresh = false;
    {
        std::lock_guard lock(m_mutex);
        m_target = target;
        m_rate = rate;
        m_targetSet = true;
        // Keep the newest frame that is due; later ones wait their turn.
        while (m_queue.size() >= 2 && m_queue[1].pts <= target) {
            recycle(std::move(m_queue.front()));
            m_queue.pop_front();
        }
        // After a jump the queue still holds the old position: keep the current
        // picture rather than flash a stale frame while the decoder seeks.
        const bool stale = !m_queue.empty()
            && (target - m_queue.front().pts > kAheadLimit || m_queue.front().pts - target > kBackTolerance);
        if (!stale && !m_queue.empty() && m_queue.front().pts <= target && m_queue.front().pts != m_shownPts) {
            *frame = m_queue.front();
            m_shownPts = frame->pts;
            fresh = true;
        }
    }
    m_wake.notify_one();
    return fresh;
}

double VideoPlayer::untilNext(double target) const
{
    std::lock_guard lock(m_mutex);
    for (const VideoFrame &f : m_queue) {
        if (f.pts > target)
            return f.pts - target;
    }
    return -1;
}

void VideoPlayer::run()
{
    std::unique_ptr<Decoder> decoder = createDecoder();
    QString openError;
    if (!decoder || !decoder->open(m_path, m_options, &openError)) {
        std::lock_guard lock(m_mutex);
        m_error = openError.isEmpty() ? QStringLiteral("无法打开视频") : openError;
        return;
    }
    const double duration = decoder->duration();
    double cursor = 0; // where the decoder is: the last seek or the last decoded frame
    double last = -1; // the previous decoded frame, for the frame interval
    double step = 1.0 / 30;
    bool positioned = false;
    bool ended = false;
    // How long a seek takes to deliver its first frame, learned per file. Seeks
    // aim that far ahead so the picture lands on time instead of chasing it.
    double lead = 0.15;
    std::chrono::steady_clock::time_point seekedAt;
    bool measuring = false;

    std::unique_lock lock(m_mutex);
    while (!m_stop) {
        if (!m_targetSet) {
            m_wake.wait(lock);
            continue;
        }
        const double target = m_target;
        const double rate = std::clamp(m_rate, 0.0, 2.0);
        // A paused target never catches up with frames ahead of it: any step
        // back is a seek.
        const double back = rate < 0.05 ? 0.0 : kBackTolerance;
        const double oldest = m_queue.empty() ? cursor : m_queue.front().pts;
        if (!positioned || target < oldest - back || target > cursor + kAheadLimit) {
            // A seek superseded after its lead ran out took at least this long;
            // one superseded sooner (scrubbing) tells nothing.
            if (measuring) {
                const double spent = std::chrono::duration<double>(std::chrono::steady_clock::now() - seekedAt).count();
                if (spent >= lead)
                    lead = std::clamp(std::max(lead * 1.5, spent), 0.0, 1.5);
            }
            // Paused, start a little early so the frame showing at the target
            // itself is decoded; earlier ones are dropped below.
            double to = std::max(0.0, rate < 0.05 ? target - 0.05 : target + lead * rate);
            if (duration > 0)
                to = std::min(to, std::max(0.0, duration - 0.05));
            while (!m_queue.empty()) {
                recycle(std::move(m_queue.front()));
                m_queue.pop_front();
            }
            lock.unlock();
            decoder->seek(to);
            lock.lock();
            cursor = to;
            last = -1;
            positioned = true;
            ended = false;
            seekedAt = std::chrono::steady_clock::now();
            measuring = true;
            continue;
        }
        const auto ahead = std::count_if(m_queue.begin(), m_queue.end(),
                                         [target](const VideoFrame &f) { return f.pts > target; });
        if (ended || ahead >= kAhead) {
            m_wake.wait_for(lock, std::chrono::milliseconds(20));
            continue;
        }
        // Decode into a spare buffer the picture no longer holds.
        VideoFrame frame;
        for (auto it = m_spare.begin(); it != m_spare.end(); ++it) {
            if (it->isDetached()) {
                frame.image = std::move(*it);
                m_spare.erase(it);
                break;
            }
        }
        // Frames already past their display interval are never converted.
        const double discardBefore = m_target - step;
        lock.unlock();
        const bool ok = decoder->next(&frame, discardBefore);
        lock.lock();
        if (!ok) {
            ended = true;
            if (!decoder->error().isEmpty())
                m_error = decoder->error();
            recycle(std::move(frame));
            continue;
        }
        if (frame.pts > last && frame.pts - last < 0.2)
            step = std::clamp(frame.pts - last, 1.0 / 240, 0.1);
        last = frame.pts;
        // A seek may restart at an earlier keyframe; the cursor never moves back
        // behind the seek point, or the ahead check would seek again forever.
        cursor = std::max(cursor, frame.pts);
        // Already past its display interval (catching up after a seek): drop it.
        if (frame.pts + step <= m_target) {
            recycle(std::move(frame));
            continue;
        }
        if (measuring) {
            measuring = false;
            const double took = std::chrono::duration<double>(std::chrono::steady_clock::now() - seekedAt).count();
            lead = std::clamp(0.7 * lead + 0.3 * took, 0.0, 1.5);
        }
        m_queue.push_back(std::move(frame));
    }
}
