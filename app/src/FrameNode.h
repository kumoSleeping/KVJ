#pragma once

// The picture in the scene graph, able to dissolve from the frame it showed into
// the next one: the new frame is drawn whole and the old one over it, fading
// out. A jump with no fade simply replaces the picture.

#include <QSGOpacityNode>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

class FrameNode : public QSGNode
{
public:
    bool hasFrame() const { return m_current; }

    // Shows `texture`, which the node takes over. With `fadeMs` > 0 the picture
    // shown so far stays on top and dissolves over that long from `nowMs`.
    void show(QSGTexture *texture, double fadeMs, double nowMs)
    {
        if (fadeMs > 0 && m_current) {
            dropPrevious();
            removeChildNode(m_current);
            m_fade = new QSGOpacityNode;
            m_fade->appendChildNode(m_current);
            appendChildNode(m_fade);
            m_previous = m_current;
            m_current = nullptr;
            m_fadeFrom = nowMs;
            m_fadeMs = fadeMs;
        }
        if (!m_current) {
            m_current = new QSGSimpleTextureNode;
            m_current->setOwnsTexture(true);
            m_current->setFiltering(QSGTexture::Linear);
            // With its texture before it joins the tree: the software
            // renderer draws a node as soon as it is added.
            m_current->setTexture(texture);
            // Under the picture that is fading out.
            prependChildNode(m_current);
            return;
        }
        m_current->setTexture(texture);
    }

    // Fits the pictures into `bounds`, keeping their aspect ratios. True while
    // a dissolve is still running and wants another frame.
    bool layout(const QRectF &bounds, double nowMs)
    {
        if (m_current)
            fit(m_current, bounds);
        if (!m_fade)
            return false;
        const double t = (nowMs - m_fadeFrom) / m_fadeMs;
        if (t >= 1) {
            dropPrevious();
            return false;
        }
        const double eased = t <= 0 ? 0 : t * t * (3 - 2 * t);
        m_fade->setOpacity(1 - eased);
        fit(m_previous, bounds);
        return true;
    }

private:
    static void fit(QSGSimpleTextureNode *node, const QRectF &bounds)
    {
        const QSizeF fitted = node->texture()->textureSize().toSizeF().scaled(bounds.size(), Qt::KeepAspectRatio);
        node->setRect(QRectF(bounds.center() - QPointF(fitted.width() / 2, fitted.height() / 2), fitted));
    }
    void dropPrevious()
    {
        if (!m_fade)
            return;
        removeChildNode(m_fade);
        delete m_fade; // and the old picture with its texture
        m_fade = nullptr;
        m_previous = nullptr;
    }

    QSGSimpleTextureNode *m_current = nullptr;
    QSGOpacityNode *m_fade = nullptr;
    QSGSimpleTextureNode *m_previous = nullptr;
    double m_fadeFrom = 0;
    double m_fadeMs = 0;
};
