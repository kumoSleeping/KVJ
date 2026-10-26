#pragma once

// A small, cheap copy of a picture source's picture (a VideoSurface, a
// CameraSurface) for the operator's window. It decodes nothing: the source
// hands it a reduced copy of a frame it already has, at most `fps` times a
// second and only while the preview is on screen, so the preview costs a few
// small uploads a second.

#include "PictureSource.h"

#include <QImage>
#include <QPointer>
#include <QQuickItem>

class PreviewSurface : public QQuickItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(PictureSource *source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(int fps MEMBER m_fps NOTIFY fpsChanged)
    // Frames at least this tall whatever the item's own size (0 = as tall as
    // it is drawn): a small tile whose picture is also shown larger elsewhere
    // in the window, through a ShaderEffectSource.
    Q_PROPERTY(int rows MEMBER m_rows NOTIFY fpsChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)

public:
    explicit PreviewSurface(QQuickItem *parent = nullptr);
    ~PreviewSurface() override;

    PictureSource *source() const { return m_source; }
    void setSource(PictureSource *source);
    bool hasFrame() const { return m_hasFrame; }
    int fps() const { return m_fps; }
    bool onScreen() const;

    // Called by the source on the GUI thread. The first frame after a jump is
    // `urgent`: it is taken whenever the preview is up, and dissolves in over
    // `fadeMs` like the source's own picture.
    bool wantsFrame(double nowMs, bool urgent = false) const;
    int frameHeight() const;
    void setFrame(const QImage &image, double nowMs, int fadeMs = 0);
    // The picture dissolving out after a jump goes on playing too.
    bool wantsPrevious(double nowMs) const;
    void setPreviousFrame(const QImage &image, double nowMs);
    void clearFrame();

signals:
    void sourceChanged();
    void fpsChanged();
    void hasFrameChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
    QPointer<PictureSource> m_source;
    int m_fps = 12;
    int m_rows = 0;
    double m_lastAt = -1e9;
    QImage m_pending;
    bool m_newFrame = false;
    QImage m_previous;
    bool m_newPrevious = false;
    double m_previousAt = -1e9;
    int m_fadeMs = 0;
    bool m_clear = false;
    bool m_hasFrame = false;
};
