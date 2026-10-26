#include "PictureSource.h"

#include "PreviewSurface.h"
#include "kvj.h"

#include <utility>

PictureSource::PictureSource(QQuickItem *parent)
    : QQuickItem(parent)
{
}

PictureSource::~PictureSource()
{
    const QList<PreviewSurface *> previews = std::exchange(m_previews, {});
    for (PreviewSurface *preview : previews)
        preview->setSource(nullptr);
}

void PictureSource::attachPreview(PreviewSurface *preview)
{
    if (m_previews.contains(preview))
        return;
    m_previews.append(preview);
    // It shows the picture at once, moving or not.
    if (!m_last.isNull() && hasFrame()) {
        const int height = preview->frameHeight();
        preview->setFrame(m_last.height() > height ? m_last.scaledToHeight(height, Qt::SmoothTransformation) : m_last,
                          kvj_clock_ms());
    }
    previewsChanged();
}

void PictureSource::detachPreview(PreviewSurface *preview)
{
    if (m_previews.removeAll(preview))
        previewsChanged();
}

bool PictureSource::previewsWatching() const
{
    for (PreviewSurface *preview : m_previews) {
        if (preview->onScreen() && preview->fps() > 0)
            return true;
    }
    return false;
}

// A reduced copy for each preview that is due one. Sampled down to twice the
// size and halved smoothly: a soft picture for a fraction of a millisecond.
void PictureSource::feedPreviews(const QImage &image, Layer layer, int fadeMs, bool mirror)
{
    if (image.isNull())
        return;
    const double now = kvj_clock_ms();
    // The picture shown, kept small (at most twice a second) for previews to come.
    if (layer != Layer::Previous && now - m_lastAt >= 500) {
        const int keep = 540;
        QImage last = image.height() > keep ? image.scaledToHeight(keep, Qt::SmoothTransformation) : image.copy();
        m_last = mirror ? std::move(last).mirrored(true, false) : std::move(last);
        m_lastAt = now;
    }
    if (m_previews.isEmpty())
        return;
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
            if (mirror)
                small = std::move(small).mirrored(true, false);
        }
        if (layer == Layer::Previous)
            preview->setPreviousFrame(small, now);
        else
            preview->setFrame(small, now, jump ? fadeMs : 0);
    }
}

void PictureSource::clearPreviews()
{
    m_last = QImage();
    m_lastAt = -1e9;
    for (PreviewSurface *preview : std::as_const(m_previews))
        preview->clearFrame();
}

void PictureSource::setHasFrame(bool hasFrame)
{
    if (m_hasFrame == hasFrame)
        return;
    m_hasFrame = hasFrame;
    emit hasFrameChanged();
}

void PictureSource::setError(const QString &error)
{
    if (m_error == error)
        return;
    m_error = error;
    emit errorChanged();
}
