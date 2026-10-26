#pragma once

// Something that makes a picture for the projection: a video following the
// music (VideoSurface) or a live camera (CameraSurface). Each draws its own
// picture and hands reduced copies of the frames it shows to the previews in
// the operator's window (PreviewSurface), each at the preview's own rate and
// only while that preview is on screen. The first frame after a jump goes to
// every preview at once so they dissolve with the source; during a dissolve the
// picture going out keeps moving there too.

#include <QImage>
#include <QList>
#include <QQuickItem>
#include <QSize>
#include <QString>

class PreviewSurface;

class PictureSource : public QQuickItem
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("A picture source is a VideoSurface or a CameraSurface.")
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    // The picture as it arrives (the video's stored frame size, the camera's).
    Q_PROPERTY(QSize sourceSize READ sourceSize NOTIFY sourceInfoChanged)

public:
    explicit PictureSource(QQuickItem *parent = nullptr);
    ~PictureSource() override;

    bool hasFrame() const { return m_hasFrame; }
    QString error() const { return m_error; }
    QSize sourceSize() const { return m_sourceSize; }
    void attachPreview(PreviewSurface *preview);
    void detachPreview(PreviewSurface *preview);

signals:
    void hasFrameChanged();
    void errorChanged();
    void sourceInfoChanged();

protected:
    enum class Layer { Shown, Jump, Previous };
    // `image` is the frame now shown (Shown), the first one after a jump that
    // dissolves in over `fadeMs` (Jump), or the picture dissolving out
    // (Previous). `mirror` flips the copies left to right.
    void feedPreviews(const QImage &image, Layer layer, int fadeMs = 0, bool mirror = false);
    void clearPreviews();
    // Some preview is on screen and would take frames.
    bool previewsWatching() const;
    virtual void previewsChanged() {}

    void setHasFrame(bool hasFrame);
    void setError(const QString &error);
    QSize m_sourceSize;

private:
    QList<PreviewSurface *> m_previews;
    // A small copy of the picture last shown, for a preview attached while
    // the source shows a still picture (paused) and sends no new frame.
    QImage m_last;
    double m_lastAt = -1e9;
    bool m_hasFrame = false;
    QString m_error;
};
