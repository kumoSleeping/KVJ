#include "VideoSurface.h"

#include "PreviewSurface.h"
#include "VideoPlayer.h"
#include "kvj.h"

#include <QQuickWindow>
#include <QSGSimpleTextureNode>

#include <algorithm>
#include <cmath>
#include <utility>

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
// size and halved smoothly: a soft picture for a fraction of a millisecond.
void VideoSurface::feedPreviews()
{
    if (m_previews.isEmpty() || m_pending.isNull())
        return;
    const double now = kvj_clock_ms();
    QImage small;
    for (PreviewSurface *preview : std::as_const(m_previews)) {
        if (!preview->wantsFrame(now))
            continue;
        const int height = preview->frameHeight();
        if (small.isNull() || small.height() != height) {
            const QImage sampled = m_pending.height() > height * 2
                ? m_pending.scaledToHeight(height * 2, Qt::FastTransformation)
                : m_pending;
            small = sampled.scaledToHeight(height, Qt::SmoothTransformation);
        }
        preview->setFrame(small, now);
    }
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
    // The old picture stays up until the new player has a frame for the target.
    m_player = m_source.isEmpty() ? nullptr : std::make_unique<VideoPlayer>(m_source, m_options);
    m_lastPts = -1;
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
    VideoFrame frame;
    if (m_player->frameFor(target, &frame)) {
        // A frame-rate cap skips frames that follow the shown one too closely,
        // but never holds back a frame after a jump.
        const double minimum = m_maxFps > 0 ? 0.9 / m_maxFps : 0;
        const double since = frame.pts - m_lastPts;
        if (m_lastPts < 0 || since < 0 || since >= minimum || since > 0.5) {
            m_lastPts = frame.pts;
            m_pending = std::move(frame.image);
            m_newFrame = true;
            feedPreviews();
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
    const int wait = ahead > 0 ? int(std::clamp(ahead / rate * 1000.0 - 1.0, 1.0, 50.0)) : 8;
    m_timer.start(wait);
}

QSGNode *VideoSurface::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    auto *node = static_cast<QSGSimpleTextureNode *>(old);
    if (m_clear) {
        m_clear = false;
        delete node;
        return nullptr;
    }
    if (m_newFrame && !m_pending.isNull()) {
        m_newFrame = false;
        QSGTexture *texture = window()->createTextureFromImage(m_pending);
        // Hand the buffer back to the player's pool as soon as it is uploaded.
        m_pending = QImage();
        if (!node) {
            node = new QSGSimpleTextureNode;
            node->setOwnsTexture(true);
            node->setFiltering(QSGTexture::Linear);
        }
        node->setTexture(texture);
    }
    if (!node)
        return nullptr;
    // Fit inside the item, keeping the video's aspect ratio.
    const QSizeF size = node->texture()->textureSize();
    const QRectF bounds = boundingRect();
    const QSizeF fitted = size.scaled(bounds.size(), Qt::KeepAspectRatio);
    node->setRect(QRectF(bounds.center() - QPointF(fitted.width() / 2, fitted.height() / 2), fitted));
    return node;
}
