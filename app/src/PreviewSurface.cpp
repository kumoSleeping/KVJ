#include "PreviewSurface.h"

#include <QQuickWindow>
#include <QSGSimpleTextureNode>

#include <algorithm>

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

void PreviewSurface::setSource(VideoSurface *source)
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

bool PreviewSurface::wantsFrame(double nowMs) const
{
    if (!isVisible() || width() < 1 || height() < 1 || !window() || !window()->isVisible())
        return false;
    return m_fps > 0 && nowMs - m_lastAt >= 1000.0 / m_fps - 2.0;
}

// Tall enough for the item on this screen, never more than a small picture.
int PreviewSurface::frameHeight() const
{
    const qreal ratio = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    return std::clamp(int(height() * ratio), 72, 360);
}

void PreviewSurface::setFrame(const QImage &image, double nowMs)
{
    m_lastAt = nowMs;
    m_pending = image;
    m_newFrame = true;
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
    auto *node = static_cast<QSGSimpleTextureNode *>(old);
    if (m_clear) {
        m_clear = false;
        delete node;
        node = nullptr;
    }
    if (m_newFrame && !m_pending.isNull()) {
        m_newFrame = false;
        QSGTexture *texture = window()->createTextureFromImage(m_pending);
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
    const QSizeF size = node->texture()->textureSize();
    const QRectF bounds = boundingRect();
    const QSizeF fitted = size.scaled(bounds.size(), Qt::KeepAspectRatio);
    node->setRect(QRectF(bounds.center() - QPointF(fitted.width() / 2, fitted.height() / 2), fitted));
    return node;
}
