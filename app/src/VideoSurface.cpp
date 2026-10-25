#include "VideoSurface.h"

#include "FrameNode.h"
#include "PreviewSurface.h"
#include "VideoPlayer.h"
#include "kvj.h"

#include <QQuickWindow>
#include <QSGSimpleTextureNode>

#include <algorithm>
#include <cmath>
#include <utility>

namespace {
// The time due moved this much further than the clock took it: a jump, not a
// fine correction of the follow.
constexpr double kJump = 0.75;
// The old picture plays on at most this long waiting for the new one's frame.
constexpr double kHoldMs = 3000;
} // namespace

VideoSurface::VideoSurface(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
    m_timer.setSingleShot(true);
    m_timer.setTimerType(Qt::PreciseTimer);
    connect(&m_timer, &QTimer::timeout, this, &VideoSurface::tick);
    // A new match (a jump or a rate change) is followed at once, not at the next wake.
    connect(this, &VideoSurface::timingChanged, this, [this] {
        if (m_player)
            m_timer.start(0);
    });
}

VideoSurface::~VideoSurface()
{
    const QList<PreviewSurface *> previews = std::exchange(m_previews, {});
    for (PreviewSurface *preview : previews)
        preview->setSource(nullptr);
}

void VideoSurface::attachPreview(PreviewSurface *preview)
{
    if (!m_previews.contains(preview))
        m_previews.append(preview);
}

void VideoSurface::detachPreview(PreviewSurface *preview)
{
    m_previews.removeAll(preview);
}

// A reduced copy for each preview that is due one. Sampled down to twice the
// size and halved smoothly: a soft picture for a fraction of a millisecond. The
// first frame after a jump goes to every preview, so each dissolves with it,
// and the old picture's frames keep the dissolving one moving there too.
void VideoSurface::feedPreviews(const QImage &image, Layer layer)
{
    if (m_previews.isEmpty() || image.isNull())
        return;
    const double now = kvj_clock_ms();
    const bool jump = layer == Layer::Jump;
    QImage small;
    for (PreviewSurface *preview : std::as_const(m_previews)) {
        if (layer == Layer::Previous ? !preview->wantsPrevious(now) : !preview->wantsFrame(now, jump))
            continue;
        const int height = preview->frameHeight();
        if (small.isNull() || small.height() != height) {
            const QImage sampled = image.height() > height * 2
                ? image.scaledToHeight(height * 2, Qt::FastTransformation)
                : image;
            small = sampled.scaledToHeight(height, Qt::SmoothTransformation);
        }
        if (layer == Layer::Previous)
            preview->setPreviousFrame(small, now);
        else
            preview->setFrame(small, now, jump ? m_fadeMs : 0);
    }
}

bool VideoSurface::fadeable() const
{
    return m_fadeMs > 0 && m_hasFrame && m_player && m_lastTickAt >= 0;
}

// A jump that dissolves: the player that drew the picture so far plays on
// from where it was. False while the one before is still the picture (the new
// player has shown nothing yet): that one goes on, and the new player only
// has to look elsewhere.
bool VideoSurface::keepPlaying(double nowMs)
{
    if (m_outgoing && m_outHolding)
        return false;
    m_outgoing = std::move(m_player);
    m_outBase = m_lastTarget + (nowMs - m_lastTickAt) / 1000.0 * m_lastRate;
    m_outAt = nowMs;
    m_outRate = m_lastRate;
    m_outLastPts = std::exchange(m_lastPts, -1);
    m_outHolding = true;
    return true;
}

void VideoSurface::dropOutgoing()
{
    m_outgoing.reset();
    m_outHolding = false;
    m_outPending = QImage();
    m_outNew = false;
}

void VideoSurface::tickOutgoing(double nowMs, int *wait)
{
    if (m_outHolding ? nowMs - m_outAt > kHoldMs : nowMs - m_fadeFrom >= m_fadeMs) {
        dropOutgoing();
        return;
    }
    const double target = m_outBase + (nowMs - m_outAt) / 1000.0 * m_outRate;
    VideoFrame frame;
    if (m_outgoing->frameFor(target, &frame, m_outRate)) {
        const double minimum = m_maxFps > 0 ? 0.9 / m_maxFps : 0;
        const double since = frame.pts - m_outLastPts;
        if (m_outLastPts < 0 || since < 0 || since >= minimum || since > 0.5) {
            m_outLastPts = frame.pts;
            m_outPending = std::move(frame.image);
            m_outNew = true;
            // Still the picture until the new player has its first frame.
            m_outShown = m_outHolding;
            feedPreviews(m_outPending, m_outHolding ? Layer::Shown : Layer::Previous);
            update();
        }
    }
    const double ahead = m_outgoing->untilNext(target);
    const double rate = std::max(0.1, m_outRate);
    *wait = std::min(*wait, ahead > 0 ? int(std::clamp(ahead / rate * 1000.0 - 1.0, 1.0, 50.0)) : 8);
}

void VideoSurface::setSource(const QString &source)
{
    if (m_source == source)
        return;
    m_source = source;
    restart();
    emit sourceChanged();
}

void VideoSurface::setMaxHeight(int height)
{
    if (m_options.maxHeight == height)
        return;
    m_options.maxHeight = height;
    restart();
    emit qualityChanged();
}

void VideoSurface::restart()
{
    m_timer.stop();
    // The old picture stays up until the new player has a frame for the target;
    // with a dissolve it plays on meanwhile.
    if (!m_source.isEmpty() && fadeable())
        keepPlaying(kvj_clock_ms());
    else
        dropOutgoing();
    m_player = m_source.isEmpty() ? nullptr : std::make_unique<VideoPlayer>(m_source, m_options);
    m_lastPts = -1;
    m_lastTickAt = -1;
    // Another file is a jump too: its first frame dissolves from the old one.
    m_jumped = m_hasFrame;
    if (m_source.isEmpty()) {
        m_clear = true;
        m_newFrame = false;
        m_pending = QImage();
        if (m_hasFrame) {
            m_hasFrame = false;
            emit hasFrameChanged();
        }
        for (PreviewSurface *preview : std::as_const(m_previews))
            preview->clearFrame();
        update();
    } else {
        m_timer.start(0);
    }
    if (!m_error.isEmpty()) {
        m_error.clear();
        emit errorChanged();
    }
}

void VideoSurface::tick()
{
    if (!m_player)
        return;
    const double now = kvj_clock_ms();
    const double target = m_position + (now - m_clockAtMs + m_offsetMs) / 1000.0 * m_rate;
    if (m_lastTickAt >= 0 && std::abs(target - (m_lastTarget + (now - m_lastTickAt) / 1000.0 * m_rate)) > kJump) {
        m_jumped = true;
        if (fadeable() && keepPlaying(now))
            m_player = std::make_unique<VideoPlayer>(m_source, m_options);
    }
    m_lastTarget = target;
    m_lastTickAt = now;
    m_lastRate = m_rate;
    VideoFrame frame;
    if (m_player->frameFor(target, &frame, m_rate)) {
        // A frame-rate cap skips frames that follow the shown one too closely,
        // but never holds back a frame after a jump.
        const double minimum = m_maxFps > 0 ? 0.9 / m_maxFps : 0;
        const double since = frame.pts - m_lastPts;
        if (m_lastPts < 0 || since < 0 || since >= minimum || since > 0.5) {
            m_lastPts = frame.pts;
            m_pending = std::move(frame.image);
            m_newFrame = true;
            m_fadeNext = m_jumped && m_fadeMs > 0;
            m_jumped = false;
            // The new picture is here: the old one dissolves out from now on.
            if (m_fadeNext && m_outgoing && m_outHolding) {
                m_outHolding = false;
                m_fadeFrom = now;
            }
            feedPreviews(m_pending, m_fadeNext ? Layer::Jump : Layer::Shown);
            if (!m_hasFrame) {
                m_hasFrame = true;
                emit hasFrameChanged();
            }
            update();
        }
    }
    const QString error = m_player->error();
    if (error != m_error) {
        m_error = error;
        emit errorChanged();
    }
    // Sleep until the next decoded frame is due (in wall time), polling briefly
    // while the decoder catches up.
    const double ahead = m_player->untilNext(target);
    const double rate = std::max(0.1, m_rate);
    int wait = ahead > 0 ? int(std::clamp(ahead / rate * 1000.0 - 1.0, 1.0, 50.0)) : 8;
    if (m_outgoing)
        tickOutgoing(now, &wait);
    m_timer.start(wait);
}

QSGNode *VideoSurface::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    auto *node = static_cast<FrameNode *>(old);
    if (m_clear) {
        m_clear = false;
        delete node;
        return nullptr;
    }
    const double now = kvj_clock_ms();
    // The old picture's frame: still the picture (before the new one's first
    // frame dissolves over it), or the picture dissolving out.
    auto outTexture = [this] {
        m_outNew = false;
        QSGTexture *texture = window()->createTextureFromImage(m_outPending);
        m_outPending = QImage();
        return texture;
    };
    if (m_outNew && m_outShown && !m_outPending.isNull()) {
        if (!node)
            node = new FrameNode;
        node->show(outTexture(), 0, now);
    }
    if (m_newFrame && !m_pending.isNull()) {
        m_newFrame = false;
        QSGTexture *texture = window()->createTextureFromImage(m_pending);
        // Hand the buffer back to the player's pool as soon as it is uploaded.
        m_pending = QImage();
        if (!node)
            node = new FrameNode;
        node->show(texture, std::exchange(m_fadeNext, false) ? m_fadeMs : 0, now);
    }
    if (m_outNew && !m_outPending.isNull()) {
        QSGTexture *texture = outTexture();
        if (node)
            node->showPrevious(texture);
        else
            delete texture;
    }
    if (!node)
        return nullptr;
    // A dissolve draws every display frame until it is over, then rests again.
    if (node->layout(boundingRect(), now))
        QMetaObject::invokeMethod(this, [this] { update(); }, Qt::QueuedConnection);
    return node;
}
