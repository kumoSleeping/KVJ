#pragma once

// A small, cheap copy of a VideoSurface's picture for the operator's window.
// It decodes nothing: the projected surface hands it a reduced copy of a frame
// it already has, at most `fps` times a second and only while the preview is on
// screen, so the preview costs a few small uploads a second.

#include "VideoSurface.h"

#include <QImage>
#include <QPointer>
#include <QQuickItem>

class PreviewSurface : public QQuickItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(VideoSurface *source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(int fps MEMBER m_fps NOTIFY fpsChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)

public:
    explicit PreviewSurface(QQuickItem *parent = nullptr);
    ~PreviewSurface() override;

    VideoSurface *source() const { return m_source; }
    void setSource(VideoSurface *source);
    bool hasFrame() const { return m_hasFrame; }

    // Called by the source on the GUI thread.
    bool wantsFrame(double nowMs) const;
    int frameHeight() const;
    void setFrame(const QImage &image, double nowMs);
    void clearFrame();

signals:
    void sourceChanged();
    void fpsChanged();
    void hasFrameChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
    QPointer<VideoSurface> m_source;
    int m_fps = 12;
    double m_lastAt = -1e9;
    QImage m_pending;
    bool m_newFrame = false;
    bool m_clear = false;
    bool m_hasFrame = false;
};
