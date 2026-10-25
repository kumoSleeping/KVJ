#include "FilmStrip.h"

#include "Decoder.h"

#include <QCoreApplication>
#include <QMutexLocker>
#include <QPainter>
#include <QThread>

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>

namespace {
// Room for about 450 frames of 213×120.
constexpr qint64 kBudget = 48ll << 20;
// A frame this little ahead of the last one decoded is reached by decoding on
// rather than by seeking.
constexpr qint64 kReachMs = 4000;

QString failKey(const QString &path, qint64 ms)
{
    return path + QLatin1Char('|') + QString::number(ms);
}
} // namespace

FrameCache *FrameCache::instance()
{
    static FrameCache *cache = new FrameCache(QCoreApplication::instance());
    return cache;
}

FrameCache::FrameCache(QObject *parent)
    : QObject(parent)
{
    m_thread = QThread::create([this] { run(); });
    // Thumbnails wait for everything else, the DJ software included.
    m_thread->start(QThread::LowPriority);
}

FrameCache::~FrameCache()
{
    {
        QMutexLocker lock(&m_mutex);
        m_stop = true;
    }
    m_wake.wakeAll();
    m_thread->wait();
    delete m_thread;
}

void FrameCache::want(const void *owner, const QString &path, const QList<qint64> &ms)
{
    {
        QMutexLocker lock(&m_mutex);
        if (path.isEmpty() || ms.isEmpty()) {
            m_wishes.remove(owner);
            return;
        }
        m_wishes.insert(owner, Wish{path, ms, ++m_serial});
    }
    m_wake.wakeOne();
}

void FrameCache::forget(const void *owner)
{
    QMutexLocker lock(&m_mutex);
    m_wishes.remove(owner);
}

QImage FrameCache::frame(const QString &path, qint64 ms, bool *exact)
{
    QMutexLocker lock(&m_mutex);
    *exact = false;
    auto file = m_thumbs.find(path);
    if (file == m_thumbs.end() || file->empty())
        return {};
    auto at = file->lower_bound(ms);
    if (at != file->end() && at->first == ms) {
        *exact = true;
        at->second.used = ++m_serial;
        return at->second.image;
    }
    if (at == file->end() || (at != file->begin() && ms - std::prev(at)->first < at->first - ms))
        --at;
    return at->second.image;
}

double FrameCache::aspect(const QString &path)
{
    QMutexLocker lock(&m_mutex);
    return m_aspect.value(path, 0);
}

// Called with the mutex held: drop the frames used longest ago until well
// under the budget.
void FrameCache::trim()
{
    if (m_bytes <= kBudget)
        return;
    struct Old
    {
        quint64 used;
        QString path;
        qint64 ms;
        qint64 bytes;
    };
    std::vector<Old> all;
    for (auto file = m_thumbs.begin(); file != m_thumbs.end(); ++file)
        for (const auto &[ms, thumb] : *file)
            all.push_back({thumb.used, file.key(), ms, thumb.image.sizeInBytes()});
    std::sort(all.begin(), all.end(), [](const Old &a, const Old &b) { return a.used < b.used; });
    for (const Old &old : all) {
        if (m_bytes <= kBudget * 3 / 4)
            break;
        m_thumbs[old.path].erase(old.ms);
        m_bytes -= old.bytes;
    }
}

void FrameCache::run()
{
    std::unique_ptr<Decoder> decoder;
    QString openPath;
    qint64 cursor = std::numeric_limits<qint64>::min() / 2; // ms of the last frame decoded

    QMutexLocker lock(&m_mutex);
    while (!m_stop) {
        // The next frame: one a little ahead in the open file first (no seek),
        // else the most wanted of the strip that asked last.
        QString path;
        qint64 ms = -1;
        const Wish *latest = nullptr;
        for (const Wish &wish : std::as_const(m_wishes)) {
            if (m_failed.contains(wish.path))
                continue;
            const auto &have = m_thumbs[wish.path];
            if (!latest || wish.at > latest->at) {
                for (qint64 t : wish.ms) {
                    if (!have.count(t) && !m_failed.contains(failKey(wish.path, t))) {
                        latest = &wish;
                        break;
                    }
                }
            }
            if (wish.path != openPath)
                continue;
            for (qint64 t : wish.ms) {
                if (t >= cursor && t - cursor < kReachMs && (ms < 0 || t < ms) && !have.count(t)
                    && !m_failed.contains(failKey(wish.path, t))) {
                    path = wish.path;
                    ms = t;
                }
            }
        }
        if (ms < 0 && latest) {
            const auto &have = m_thumbs[latest->path];
            for (qint64 t : latest->ms) {
                if (!have.count(t) && !m_failed.contains(failKey(latest->path, t))) {
                    path = latest->path;
                    ms = t;
                    break;
                }
            }
        }
        if (ms < 0) {
            m_wake.wait(&m_mutex);
            continue;
        }

        lock.unlock();
        bool opened = true;
        if (path != openPath) {
            decoder = createDecoder();
            DecodeOptions options;
            options.maxHeight = kHeight;
            QString error;
            opened = decoder && decoder->open(path, options, &error);
            openPath = opened ? path : QString();
            cursor = std::numeric_limits<qint64>::min() / 2;
        }
        VideoFrame frame;
        bool ok = false;
        if (opened) {
            if (!(ms >= cursor && ms - cursor < kReachMs))
                decoder->seek(ms / 1000.0);
            ok = decoder->next(&frame, ms / 1000.0 - 0.001);
            // Past the last frame: the last one there is.
            if (!ok && decoder->seek(std::max(0.0, ms / 1000.0 - 1.0)))
                while (decoder->next(&frame, -1))
                    ok = true;
            cursor = ok ? qint64(frame.pts * 1000) : std::numeric_limits<qint64>::min() / 2;
        }
        lock.relock();

        if (!opened) {
            m_failed.insert(path);
            continue;
        }
        if (!ok || frame.image.isNull()) {
            m_failed.insert(failKey(path, ms));
            continue;
        }
        m_aspect.insert(path, double(frame.image.width()) / std::max(1, frame.image.height()));
        auto &file = m_thumbs[path];
        if (file.count(ms))
            m_bytes -= file[ms].image.sizeInBytes();
        file[ms] = Thumb{frame.image, ++m_serial};
        m_bytes += frame.image.sizeInBytes();
        trim();
        emit ready(path);
    }
}

FilmStrip::FilmStrip(QQuickItem *parent)
    : QQuickPaintedItem(parent)
{
    setOpaquePainting(false);
    connect(FrameCache::instance(), &FrameCache::ready, this, [this](const QString &path) {
        if (path == m_source)
            update();
    });
}

FilmStrip::~FilmStrip()
{
    FrameCache::instance()->forget(this);
}

void FilmStrip::setSource(const QString &source)
{
    if (m_source == source)
        return;
    m_source = source;
    emit sourceChanged();
    refresh();
}

void FilmStrip::setDuration(double seconds)
{
    if (m_duration == seconds)
        return;
    m_duration = seconds;
    emit viewChanged();
    refresh();
}

void FilmStrip::setFrom(double seconds)
{
    if (m_from == seconds)
        return;
    m_from = seconds;
    emit viewChanged();
    refresh();
}

void FilmStrip::setPxPerSec(double px)
{
    px = std::max(1e-6, px);
    if (m_pxPerSec == px)
        return;
    m_pxPerSec = px;
    emit viewChanged();
    refresh();
}

void FilmStrip::geometryChange(const QRectF &next, const QRectF &old)
{
    QQuickPaintedItem::geometryChange(next, old);
    refresh();
}

void FilmStrip::itemChange(ItemChange change, const ItemChangeData &data)
{
    QQuickPaintedItem::itemChange(change, data);
    if (change == ItemVisibleHasChanged)
        refresh();
}

// Steps no more than one and a half times apart, so a frame is never cropped
// to less than two thirds of its width's worth of picture.
double FilmStrip::step() const
{
    static const double ladder[] = {0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 7.5, 10, 15, 20,
                                    30, 45, 60, 90, 120, 180, 240, 300, 450, 600, 900, 1200, 1800, 2700, 3600};
    double aspect = FrameCache::instance()->aspect(m_source);
    if (aspect <= 0)
        aspect = 16.0 / 9.0;
    const double raw = height() * aspect / m_pxPerSec;
    for (double s : ladder)
        if (s >= raw)
            return s;
    return 3600;
}

void FilmStrip::refresh()
{
    update();
    if (m_source.isEmpty() || m_duration <= 0 || width() < 1 || height() < 1 || !isVisible()) {
        FrameCache::instance()->want(this, QString(), {});
        return;
    }
    const double s = step();
    const qint64 first = std::max<qint64>(0, qint64(std::floor(m_from / s)));
    const qint64 last = qint64(std::floor(std::min(m_duration - 0.001, m_from + width() / m_pxPerSec) / s));
    // From the middle of the view outwards: what the eye is on comes first.
    QList<qint64> wanted;
    const qint64 mid = (first + last) / 2;
    for (qint64 d = 0; mid - d >= first || mid + d <= last; ++d) {
        if (mid + d <= last)
            wanted.append(qint64(std::llround(std::min((mid + d) * s, std::max(0.0, m_duration - 0.05)) * 1000)));
        if (d > 0 && mid - d >= first)
            wanted.append(qint64(std::llround((mid - d) * s * 1000)));
    }
    FrameCache::instance()->want(this, m_source, wanted);
}

void FilmStrip::paint(QPainter *painter)
{
    if (m_source.isEmpty() || m_duration <= 0)
        return;
    painter->setRenderHint(QPainter::SmoothPixmapTransform);
    const double s = step();
    const double h = height();
    const qint64 first = std::max<qint64>(0, qint64(std::floor(m_from / s)));
    const qint64 last = qint64(std::floor(std::min(m_duration - 0.001, m_from + width() / m_pxPerSec) / s));
    const double end = (m_duration - m_from) * m_pxPerSec;
    for (qint64 k = first; k <= last; ++k) {
        const double x = (k * s - m_from) * m_pxPerSec;
        const double w = std::min(s * m_pxPerSec, end - x);
        const qint64 ms = qint64(std::llround(std::min(k * s, std::max(0.0, m_duration - 0.05)) * 1000));
        bool exact = false;
        const QImage image = FrameCache::instance()->frame(m_source, ms, &exact);
        const QRectF target(x, 0, std::max(0.0, w - 1), h);
        if (image.isNull()) {
            painter->fillRect(target, m_gap);
            continue;
        }
        // Cover the cell, cropping evenly; a frame standing in is dimmed.
        const double scale = std::max(target.width() / image.width(), h / image.height());
        const QSizeF shown(target.width() / scale, h / scale);
        const QRectF source((image.width() - shown.width()) / 2, (image.height() - shown.height()) / 2,
                            shown.width(), shown.height());
        painter->setOpacity(exact ? 1.0 : 0.55);
        painter->drawImage(target, image, source);
    }
    painter->setOpacity(1);
}
