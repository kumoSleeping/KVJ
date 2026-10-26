#include "WaveStrip.h"

#include "Engine.h"
#include "kvj.h"

#include <QCoreApplication>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutexLocker>
#include <QPainter>
#include <QQuickWindow>
#include <QThread>

#include <algorithm>
#include <array>
#include <cmath>

namespace {

double clamp255(double v)
{
    return std::clamp(v, 0.0, 255.0);
}

// KDJ src/lib/waveformPalette.ts: releaseOverviewWaveformDisplayRgb, then
// waveformSurfaceContrastRgb with RELEASE_OVERVIEW_CONTRAST against the background.
QColor display(double low, double mid, double high, const QColor &background)
{
    const double strongest = std::max(mid, high);
    if (low > strongest)
        low = strongest + (low - strongest) * 0.95;
    const double neutral = (low + mid + high) / 3;
    double rgb[3] = {neutral + (low - neutral) * 0.74, neutral + (mid - neutral) * 0.74,
                     neutral + (high - neutral) * 0.74};
    const double peak = std::max({rgb[0], rgb[1], rgb[2]});
    const double scale = peak > 238 ? 238 / peak : 1;
    const double bg[3] = {background.redF() * 255, background.greenF() * 255, background.blueF() * 255};
    for (int c = 0; c < 3; ++c)
        rgb[c] = clamp255(std::round(bg[c] + (std::round(rgb[c] * scale) - bg[c]) * 1.1));
    return QColor(int(rgb[0]), int(rgb[1]), int(rgb[2]));
}

} // namespace

WaveCache *WaveCache::instance()
{
    static WaveCache *cache = new WaveCache(QCoreApplication::instance());
    return cache;
}

WaveCache::WaveCache(QObject *parent)
    : QObject(parent)
    , m_cacheDir(QDir(Engine::defaultDataDir()).filePath(QStringLiteral("cache/wave")))
{
    m_thread = QThread::create([this] { run(); });
    // Waveforms wait for everything else, the DJ software included.
    m_thread->start(QThread::LowPriority);
}

WaveCache::~WaveCache()
{
    m_stop = true;
    {
        QMutexLocker lock(&m_mutex);
        m_wake.wakeAll();
    }
    m_thread->wait();
    delete m_thread;
}

std::shared_ptr<const WaveCache::Wave> WaveCache::wave(const QString &path)
{
    QMutexLocker lock(&m_mutex);
    if (const auto found = m_waves.constFind(path); found != m_waves.constEnd())
        return found.value();
    if (!path.isEmpty() && !m_failed.contains(path) && !m_queue.contains(path)) {
        m_queue.append(path);
        m_wake.wakeAll();
    }
    return {};
}

bool WaveCache::failed(const QString &path)
{
    QMutexLocker lock(&m_mutex);
    return m_failed.contains(path);
}

QVariantList WaveCache::tempo(const QString &path)
{
    QMutexLocker lock(&m_mutex);
    if (const auto found = m_tempi.constFind(path); found != m_tempi.constEnd())
        return found.value();
    if (!path.isEmpty() && !m_tempoFailed.contains(path) && !m_tempoQueue.contains(path)) {
        m_tempoQueue.append(path);
        m_wake.wakeAll();
    }
    return {};
}

bool WaveCache::findingTempo(const QString &path)
{
    QMutexLocker lock(&m_mutex);
    return !path.isEmpty() && !m_tempi.contains(path) && !m_tempoFailed.contains(path);
}

void WaveCache::run()
{
    const QByteArray cacheDir = QDir::toNativeSeparators(m_cacheDir).toUtf8();
    const KvjStopFn stop = [](void *user) { return static_cast<WaveCache *>(user)->m_stop.load(); };
    for (;;) {
        QString path;
        bool wave = true;
        {
            QMutexLocker lock(&m_mutex);
            while (m_queue.isEmpty() && m_tempoQueue.isEmpty() && !m_stop)
                m_wake.wait(&m_mutex);
            if (m_stop)
                return;
            // Waveforms first: the strip is blank without one, the tempo lane only bare.
            wave = !m_queue.isEmpty();
            path = wave ? m_queue.first() : m_tempoQueue.first();
        }
        const QByteArray file = QDir::toNativeSeparators(path).toUtf8();
        if (!wave) {
            char *json = kvj_tempo(file.constData(), cacheDir.constData(), stop, this);
            if (m_stop) {
                kvj_string_free(json);
                return;
            }
            const QVariantList sections =
                json ? QJsonDocument::fromJson(json).object().value(QStringLiteral("sections")).toArray().toVariantList()
                     : QVariantList();
            kvj_string_free(json);
            {
                QMutexLocker lock(&m_mutex);
                m_tempoQueue.removeAll(path);
                if (sections.isEmpty())
                    m_tempoFailed.insert(path);
                else
                    m_tempi.insert(path, sections);
            }
            emit ready(path);
            continue;
        }
        size_t columns = 0;
        unsigned char *bytes = kvj_waveform(file.constData(), cacheDir.constData(), stop, this, &columns);
        if (m_stop) {
            kvj_bytes_free(bytes, columns);
            return;
        }
        {
            QMutexLocker lock(&m_mutex);
            m_queue.removeAll(path);
            if (bytes && columns > 0) {
                auto wave = std::make_shared<Wave>();
                wave->bytes = QByteArray(reinterpret_cast<const char *>(bytes), qsizetype(columns * 4));
                wave->columns = int(columns);
                m_waves.insert(path, wave);
            } else {
                m_failed.insert(path);
            }
        }
        kvj_bytes_free(bytes, columns);
        emit ready(path);
    }
}

WaveStrip::WaveStrip(QQuickItem *parent)
    : QQuickPaintedItem(parent)
{
    setOpaquePainting(false);
    connect(WaveCache::instance(), &WaveCache::ready, this, [this](const QString &path) {
        if (path == m_source)
            fetch();
    });
}

void WaveStrip::setSource(const QString &source)
{
    if (m_source == source)
        return;
    m_source = source;
    emit sourceChanged();
    fetch();
}

void WaveStrip::setFrom(double seconds)
{
    if (m_from == seconds)
        return;
    m_from = seconds;
    emit viewChanged();
    update();
}

void WaveStrip::setPxPerSec(double px)
{
    px = std::max(1e-6, px);
    if (m_pxPerSec == px)
        return;
    m_pxPerSec = px;
    emit viewChanged();
    update();
}

void WaveStrip::setBackground(const QColor &color)
{
    if (m_background == color)
        return;
    m_background = color;
    emit viewChanged();
    update();
}

void WaveStrip::fetch()
{
    auto *cache = WaveCache::instance();
    const bool was = ready(), wasAnalysing = m_analysing;
    m_wave = cache->wave(m_source);
    m_analysing = !m_wave && !m_source.isEmpty() && !cache->failed(m_source);
    if (was != ready() || wasAnalysing != m_analysing)
        emit readyChanged();
    const QVariantList tempo = cache->tempo(m_source);
    const bool finding = cache->findingTempo(m_source);
    if (tempo != m_tempo || finding != m_findingTempo) {
        m_tempo = tempo;
        m_findingTempo = finding;
        emit tempoChanged();
    }
    update();
}

void WaveStrip::paint(QPainter *painter)
{
    if (!m_wave || m_wave->columns <= 0)
        return;
    const int n = m_wave->columns;
    const auto *amp = reinterpret_cast<const uchar *>(m_wave->bytes.constData());
    const uchar *band[3] = {amp + n, amp + 2 * n, amp + 3 * n};

    // In device pixels, one column of them at a time.
    const double dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    painter->save();
    painter->scale(1 / dpr, 1 / dpr);
    painter->setPen(Qt::NoPen);
    const int width = int(std::ceil(this->width() * dpr));
    const double height = this->height() * dpr;
    const double mid = height / 2;
    const double room = std::max(0.5 * dpr, mid - dpr);
    // Column i is centred on i / kRate seconds; a pixel spans [c0, c1) in columns.
    const double perPixel = WaveCache::kRate / (m_pxPerSec * dpr);
    // A height back to the energy it stands for (heights are amplitudes raised to 1.2).
    static const auto power = [] {
        std::array<double, 256> out{};
        for (int v = 0; v < 256; ++v)
            out[v] = std::pow(v / 255.0, 2 / 1.2);
        return out;
    }();
    for (int p = 0; p < width; ++p) {
        const double c0 = m_from * WaveCache::kRate + p * perPixel;
        const double c1 = c0 + perPixel;
        if (c1 < -0.5 || c0 > n - 0.5)
            continue;
        double level = 0;
        double rgb[3] = {0, 0, 0};
        if (perPixel < 1) {
            // Zoomed in past the columns: between the two nearest.
            const double c = std::clamp((c0 + c1) / 2, 0.0, double(n - 1));
            const int a = int(std::floor(c));
            const int b = std::min(n - 1, a + 1);
            const double f = c - a;
            level = amp[a] + (amp[b] - amp[a]) * f;
            for (int k = 0; k < 3; ++k)
                rgb[k] = band[k][a] + (band[k][b] - band[k][a]) * f;
        } else {
            // The energy of the columns, as KDJ's preview buckets have; the
            // colour weighted by height as KDJ draws it.
            const int a = std::clamp(int(std::floor(c0 + 0.5)), 0, n - 1);
            const int b = std::clamp(int(std::floor(c1 + 0.5)), a + 1, n);
            double energy = 0, total = 0;
            for (int i = a; i < b; ++i) {
                energy += power[amp[i]];
                const double w = amp[i] / 255.0 + 0.001;
                total += w;
                for (int k = 0; k < 3; ++k)
                    rgb[k] += band[k][i] * w;
            }
            level = std::pow(std::sqrt(energy / (b - a)), 1.2) * 255;
            for (double &v : rgb)
                v /= total;
        }
        const double half = std::max(0.5 * dpr, level / 255 * room);
        painter->setBrush(display(rgb[0], rgb[1], rgb[2], m_background));
        painter->drawRect(QRectF(p, mid - half, 1, half * 2));
    }
    painter->restore();
}
