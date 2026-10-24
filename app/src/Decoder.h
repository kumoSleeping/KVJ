#pragma once

// Platform video decoding through the system: AVFoundation on macOS, Media
// Foundation on Windows. A decoder lives on one thread and is used only there.

#include <QImage>
#include <QSize>
#include <QString>
#include <memory>

struct VideoFrame
{
    QImage image; // Format_RGB32
    double pts = -1; // presentation time in seconds
};

struct DecodeOptions
{
    // Scale on the system side so that frames are at most this tall (0 = source).
    int maxHeight = 720;
};

class Decoder
{
public:
    virtual ~Decoder() = default;
    virtual bool open(const QString &path, const DecodeOptions &options, QString *error) = 0;
    // Position the stream so the following next() calls continue at (or just
    // before) `seconds`; frames before it may still be returned and are dropped
    // by the caller.
    virtual bool seek(double seconds) = 0;
    // The next frame in presentation order at or after `discardBefore` seconds;
    // earlier frames are decoded (they are references) but never converted or
    // copied. False at the end or on an error. `frame->image` may hold an
    // unshared image of the right size to reuse.
    virtual bool next(VideoFrame *frame, double discardBefore) = 0;
    virtual double duration() const = 0;
    virtual QString error() const = 0;
};

std::unique_ptr<Decoder> createDecoder();

// The size to decode a `width`×`height` source at, keeping the aspect ratio and
// even dimensions; never upscales.
inline QSize scaledSize(double width, double height, int maxHeight)
{
    if (width <= 0 || height <= 0)
        return {};
    if (maxHeight > 0 && height > maxHeight) {
        width = width * maxHeight / height;
        height = maxHeight;
    }
    return QSize(int(width / 2 + 0.5) * 2, int(height / 2 + 0.5) * 2);
}

// Reuse `image` when it is unshared and already the right size.
inline void prepareImage(QImage &image, QSize size)
{
    if (image.size() != size || image.format() != QImage::Format_RGB32 || !image.isDetached())
        image = QImage(size, QImage::Format_RGB32);
}
