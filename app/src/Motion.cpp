#include "Motion.h"

#include "Engine.h"

#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QMutex>
#include <QMutexLocker>
#include <exception>
#include <thread>

struct Motion::Link
{
    QMutex mutex;
    Motion *owner = nullptr;
};

// Files read at once, at most; the rest wait their turn.
static constexpr int readers = 2;
// A file known this long is read again when asked.
static constexpr qint64 freshMs = 10000;

Motion::Motion(QObject *parent)
    : QObject(parent)
    , m_link(std::make_shared<Link>())
{
    m_link->owner = this;
    m_clock.start();
}

Motion::~Motion()
{
    QMutexLocker lock(&m_link->mutex);
    m_link->owner = nullptr;
}

bool Motion::probe(const QString &path, QString *why)
{
    // `why` stays empty for a picture that simply is still.
    const auto no = [why](const QString &reason = {}) {
        if (why)
            *why = reason;
        return false;
    };
    const QFileInfo file(path);
    if (!file.isFile())
        return no();
    if (file.size() > maxBytes)
        return no(QStringLiteral("文件 %1 MB，超过 %2 MB").arg(file.size() >> 20).arg(maxBytes >> 20));
    QImageReader reader(path);
    reader.setDecideFormatFromContent(true);
    if (!reader.canRead())
        return no(QStringLiteral("读不出图片"));
    if (!reader.supportsAnimation())
        return no();
    QSize size = reader.size();
    // A GIF's frames are drawn on its canvas, whose size Qt does not report:
    // read it from the header (a broken one may claim 60000×60000).
    if (reader.format() == "gif") {
        QFile in(path);
        const QByteArray head = in.open(QIODevice::ReadOnly) ? in.read(10) : QByteArray();
        if (head.size() < 10)
            return no(QStringLiteral("读不出尺寸"));
        const auto le16 = [&head](int at) { return int(uchar(head[at])) | int(uchar(head[at + 1])) << 8; };
        size = size.expandedTo(QSize(le16(6), le16(8)));
    }
    if (!size.isValid() || size.isEmpty())
        return no(QStringLiteral("读不出尺寸"));
    if (size.width() > maxSide || size.height() > maxSide || qint64(size.width()) * size.height() > maxPixels)
        return no(QStringLiteral("%1×%2，超过 1280×720 的像素数").arg(size.width()).arg(size.height()));
    const int frames = reader.imageCount();
    if (frames <= 1)
        return no(frames == 1 ? QString() : QStringLiteral("读不出帧数"));
    if (frames > maxFrames)
        return no(QStringLiteral("%1 帧，超过 %2 帧").arg(frames).arg(maxFrames));
    return true;
}

bool Motion::plays(const QUrl &url)
{
    if (!url.isLocalFile())
        return false;
    const QString path = url.toLocalFile();
    Known &known = m_known[path];
    if (!known.asked && (!known.known || m_clock.elapsed() - known.at > freshMs)) {
        known.asked = true;
        m_queue.append(path);
        next();
    }
    return known.plays;
}

void Motion::next()
{
    while (m_reading < readers && !m_queue.isEmpty()) {
        const QString path = m_queue.takeFirst();
        ++m_reading;
        // A thread of its own, let go: one stuck opening a file never holds up
        // quitting (a thread pool is waited for when the app ends).
        try {
            std::thread([link = m_link, path] {
                QString why;
                const bool plays = probe(path, &why);
                QMutexLocker lock(&link->mutex);
                if (Motion *owner = link->owner)
                    QMetaObject::invokeMethod(owner, [owner, path, plays, why] { owner->probed(path, plays, why); },
                                              Qt::QueuedConnection);
            }).detach();
        } catch (const std::exception &) {
            // No thread to be had: it stays still.
            --m_reading;
            m_known[path].asked = false;
            return;
        }
    }
}

void Motion::probed(const QString &path, bool plays, const QString &why)
{
    --m_reading;
    Known &known = m_known[path];
    const bool turned = known.plays != plays;
    const bool first = !known.known;
    known = Known{true, plays, false, m_clock.elapsed()};
    // A GIF or WebP held still is said once, in the log: otherwise it looks broken.
    const QString suffix = QFileInfo(path).suffix().toLower();
    if ((first || turned) && !plays && !why.isEmpty()
        && (suffix == QLatin1String("gif") || suffix == QLatin1String("webp")))
        Engine::note(QStringLiteral("贴图：%1 不播放动画（%2）").arg(QFileInfo(path).fileName(), why));
    if (turned) {
        ++m_revision;
        emit changed();
    }
    next();
}
