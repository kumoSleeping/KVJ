#include "PreviewSurface.h"

#include "FrameNode.h"
#include "kvj.h"

#include <QQuickWindow>
#include <QSGSimpleTextureNode>

#include <algorithm>
#include <utility>

PreviewSurface::PreviewSurface(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
}

PreviewSurface::~PreviewSurface()
{
    if (m_source)
        m_source->detachPreview(this);
}

void PreviewSurface::setSource(PictureSource *source)
{
    if (m_source == source)
        return;
    if (m_source)
        m_source->detachPreview(this);
    m_source = source;
    if (m_source)
        m_source->attachPreview(this);
    clearFrame();
    emit sourceChanged();
}

bool PreviewSurface::onScreen() const
{
    return isVisible() && width() >= 1 && height() >= 1 && window() && window()->isVisible();
}

bool PreviewSurface::wantsFrame(double nowMs, bool urgent) const
{
    return onScreen() && m_fps > 0 && (urgent || nowMs - m_lastAt >= 1000.0 / m_fps - 2.0);
}

bool PreviewSurface::wantsPrevious(double nowMs) const
{
    return onScreen() && m_hasFrame && m_fps > 0 && nowMs - m_previousAt >= 1000.0 / m_fps - 2.0;
}

void PreviewSurface::setPreviousFrame(const QImage &image, double nowMs)
{
    m_previousAt = nowMs;
    m_previous = image;
    m_newPrevious = true;
    update();
}

// Tall enough for the item on this screen, never more than a small picture.
int PreviewSurface::frameHeight() const
{
    const qreal ratio = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    return std::max(std::clamp(int(height() * ratio), 72, 360), std::min(m_rows, 720));
}

void PreviewSurface::setFrame(const QImage &image, double nowMs, int fadeMs)
{
    m_lastAt = nowMs;
    m_pending = image;
    m_newFrame = true;
    // Kept until drawn: two frames in one render still dissolve once.
    if (fadeMs > 0)
        m_fadeMs = fadeMs;
    if (!m_hasFrame) {
        m_hasFrame = true;
        emit hasFrameChanged();
    }
    update();
}

void PreviewSurface::clearFrame()
{
    m_pending = QImage();
    m_newFrame = false;
    m_previous = QImage();
    m_newPrevious = false;
    m_clear = true;
    m_lastAt = -1e9;
    if (m_hasFrame) {
        m_hasFrame = false;
        emit hasFrameChanged();
    }
    update();
}

QSGNode *PreviewSurface::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    auto *node = static_cast<FrameNode *>(old);
    if (m_clear) {
        m_clear = false;
        delete node;
        node = nullptr;
    }
    const double now = kvj_clock_ms();
    if (m_newFrame && !m_pending.isNull()) {
        m_newFrame = false;
        QSGTexture *texture = window()->createTextureFromImage(m_pending);
        m_pending = QImage();
        if (!node)
            node = new FrameNode;
        node->show(texture, std::exchange(m_fadeMs, 0), now);
    }
    if (m_newPrevious && !m_previous.isNull()) {
        m_newPrevious = false;
        QSGTexture *texture = window()->createTextureFromImage(m_previous);
        m_previous = QImage();
        if (node)
            node->showPrevious(texture);
        else
            delete texture;
    }
    if (!node)
        return nullptr;
    if (node->layout(boundingRect(), now))
        QMetaObject::invokeMethod(this, [this] { update(); }, Qt::QueuedConnection);
    return node;
}
