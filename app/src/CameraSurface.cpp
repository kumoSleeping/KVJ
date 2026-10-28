#include "CameraSurface.h"

#include "Engine.h"
#include "FrameNode.h"
#include "kvj.h"

#include <QCamera>
#include <QCoreApplication>
#include <QMediaCaptureSession>
#include <QMediaDevices>
#include <QQuickWindow>
#include <QThread>
#include <QVideoFrame>
#include <QVideoSink>
#if QT_CONFIG(permissions)
#include <QPermissions>
#endif
#ifdef Q_OS_WIN
#include <windows.h>
#include <mfapi.h>
#include <objbase.h>
#endif

#include <algorithm>
#include <mutex>
#include <tuple>
#include <utility>

namespace {
// A frame not drawn this long after it came (the window went away meanwhile)
// no longer holds back the next one.
constexpr double kDrawWaitMs = 500;
// A camera that failed is tried again, and one sending nothing is started
// again, this long after; each further time in a row twice as long, up to the most.
constexpr double kRetryMs = 3000;
constexpr double kRetryMostMs = 30000;
// A start or a stop that has not come back in this long has hung in the
// system's camera stack; it is given up. Starting a camera takes well under
// a second, even a slow USB one.
constexpr double kHangMs = 5000;
// Cameras given up so in this run: past this many no camera is started
// again (each leaves a thread stuck in the system for good).
constexpr int kMostHung = 3;
int g_hung = 0;

// Whether a camera gets a thread of its own: on Windows (see the header),
// elsewhere only when KVJ_CAMERA_THREAD=1 asks for it.
bool ownThread()
{
#ifdef Q_OS_WIN
    return qEnvironmentVariable("KVJ_CAMERA_THREAD") != QLatin1String("0");
#else
    return qEnvironmentVariable("KVJ_CAMERA_THREAD") == QLatin1String("1");
#endif
}

// The camera's own format closest to a projected picture: at most 1080 lines,
// a fluent rate, at least 720 lines, not compressed (decoding JPEG costs more
// than converting, but a USB 2 webcam gives 1080 lines at 30 only as JPEG),
// then the largest. Then 30 a second, or the rate nearest above it (the extra
// frames would only be dropped), else the fastest under it.
QCameraFormat pickFormat(const QCameraDevice &device)
{
    const auto key = [](const QCameraFormat &format) {
        const QSize size = format.resolution();
        const float fps = format.maxFrameRate();
        const bool full = fps >= 29.5f;
        return std::make_tuple(size.height() <= 1080, fps >= 24, size.height() >= 720,
                               format.pixelFormat() != QVideoFrameFormat::Format_Jpeg, size.width() * size.height(),
                               full, full ? -fps : fps);
    };
    QCameraFormat best;
    for (const QCameraFormat &format : device.videoFormats()) {
        if (best.isNull() || key(format) > key(best))
            best = format;
    }
    return best;
}
} // namespace

// What a camera's own side shares with its item, which may go first.
struct CameraLink
{
    std::mutex mutex;
    // Null once the item is gone (or has given this camera up).
    CameraSurface *surface = nullptr;
    // When the worker went into the camera stack (a start or a stop), 0 while
    // it is out of it.
    std::atomic<double> busySince{0};
    double busyMs() const
    {
        const double at = busySince;
        return at > 0 ? kvj_clock_ms() - at : 0;
    }
};

// A camera's capture objects, used only on the worker's thread (or this
// item's, without a thread of its own). Frames go straight to the item's
// offer(); what it has to say goes to the item as a queued call.
class CameraWorker : public QObject
{
public:
    explicit CameraWorker(std::shared_ptr<CameraLink> link)
        : m_link(std::move(link))
    {
    }
    ~CameraWorker() override
    {
        stop();
        m_session.reset();
        m_sink.reset();
#ifdef Q_OS_WIN
        if (m_mf)
            MFShutdown();
        if (m_com)
            CoUninitialize();
#endif
    }

    // First thing on its own thread: Media Foundation is used from it.
    void setUp()
    {
#ifdef Q_OS_WIN
        m_com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
        m_mf = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
#endif
    }

    void start(const QCameraDevice &device, const QCameraFormat &format, int generation)
    {
        stop();
        Busy busy(*m_link);
        if (!m_session) {
            m_sink = std::make_unique<QVideoSink>();
            // Frames may come on the camera's own thread: taken there,
            // converted on the item's conversion thread, shown on its thread.
            connect(m_sink.get(), &QVideoSink::videoFrameChanged, this, [link = m_link](const QVideoFrame &frame) {
                std::lock_guard lock(link->mutex);
                if (link->surface)
                    link->surface->offer(frame);
            }, Qt::DirectConnection);
            m_session = std::make_unique<QMediaCaptureSession>();
            m_session->setVideoSink(m_sink.get());
        }
        m_camera = std::make_unique<QCamera>(device);
        if (!format.isNull())
            m_camera->setCameraFormat(format);
        // Queued: the camera may report while it starts.
        connect(m_camera.get(), &QCamera::errorOccurred, this, [this, generation](QCamera::Error error, const QString &text) {
            if (error != QCamera::NoError)
                report(generation, text);
        }, Qt::QueuedConnection);
        m_session->setCamera(m_camera.get());
        m_camera->start();
#ifdef Q_OS_WIN
        // Qt's Windows camera is active at once or not at all, and one the
        // system would not hand over says nothing else: it would only send
        // no frames, and be started again and again.
        if (!m_camera->isActive())
            report(generation, QStringLiteral("系统没有交出这台相机（可能在系统设置里关掉了相机，或被别的程序占用）"));
#endif
    }

    void stop()
    {
        if (!m_camera)
            return;
        Busy busy(*m_link);
        m_camera->stop();
        m_session->setCamera(nullptr);
        m_camera.reset();
    }

private:
    struct Busy
    {
        explicit Busy(CameraLink &link)
            : link(link)
        {
            link.busySince = kvj_clock_ms();
        }
        ~Busy() { link.busySince = 0; }
        CameraLink &link;
    };

    void report(int generation, const QString &text)
    {
        std::lock_guard lock(m_link->mutex);
        if (CameraSurface *surface = m_link->surface)
            QMetaObject::invokeMethod(surface, [surface, generation, text] { surface->failed(generation, text); },
                                      Qt::QueuedConnection);
    }

    std::shared_ptr<CameraLink> m_link;
    std::unique_ptr<QVideoSink> m_sink;
    std::unique_ptr<QMediaCaptureSession> m_session;
    std::unique_ptr<QCamera> m_camera;
    bool m_com = false;
    bool m_mf = false;
};

CameraSurface::CameraSurface(QQuickItem *parent)
    : PictureSource(parent)
{
    setFlag(ItemHasContents, true);
    m_soon.setSingleShot(true);
    m_soon.setInterval(0);
    connect(&m_soon, &QTimer::timeout, this, &CameraSurface::evaluate);
    // Whether a preview is on screen is not signalled; it is looked at now and
    // then, and so is whether frames still come and a failed camera is due again.
    m_poll.setInterval(1000);
    connect(&m_poll, &QTimer::timeout, this, &CameraSurface::evaluate);
    m_convert.setMaxThreadCount(1);
    m_convert.setExpiryTimeout(-1);
}

CameraSurface::~CameraSurface()
{
    ++m_generation;
    giveUp();
    m_convert.waitForDone();
}

// The camera's side goes: told to stop and go when it can, never waited for.
// One stuck in the system is left where it is.
void CameraSurface::giveUp()
{
    if (!m_link)
        return;
    {
        std::lock_guard lock(m_link->mutex);
        m_link->surface = nullptr;
    }
    CameraWorker *worker = std::exchange(m_worker, nullptr);
    QThread *thread = worker->thread();
    const bool stuck = m_link->busyMs() > kHangMs;
    m_link.reset();
    m_running = false;
    if (thread == QThread::currentThread()) {
        delete worker;
    } else if (!stuck) {
        // Stops the camera (in its destructor) on its thread, then the thread ends.
        connect(worker, &QObject::destroyed, thread, &QThread::quit, Qt::DirectConnection);
        worker->deleteLater();
    }
}

void CameraSurface::setDeviceId(const QString &id)
{
    if (m_deviceId == id)
        return;
    m_deviceId = id;
    // Another camera: the running one makes way.
    stop();
    m_failed = false;
    m_lost = false;
    m_hung = false;
    m_retries = 0;
    setError(QString());
    schedule();
    emit deviceIdChanged();
}

void CameraSurface::setActive(bool active)
{
    if (m_active == active)
        return;
    m_active = active;
    m_failed = false;
    m_lost = false;
    m_hung = false;
    m_retries = 0;
    if (active) {
        m_poll.start();
    } else {
        m_poll.stop();
        setError(QString());
    }
    schedule();
    emit activeChanged();
}

void CameraSurface::setMirrored(bool mirrored)
{
    if (m_mirrored == mirrored)
        return;
    m_mirrored = mirrored;
    emit mirroredChanged();
}

void CameraSurface::itemChange(ItemChange change, const ItemChangeData &value)
{
    if (change == ItemSceneChange) {
        disconnect(m_windowShown);
        if (value.window)
            m_windowShown = connect(value.window, &QWindow::visibleChanged, this, &CameraSurface::schedule);
        schedule();
    } else if (change == ItemVisibleHasChanged) {
        schedule();
    }
    PictureSource::itemChange(change, value);
}

void CameraSurface::previewsChanged()
{
    schedule();
}

// Settled once the current event is done: properties set one after another
// (a new camera and `active`) start it once.
void CameraSurface::schedule()
{
    m_soon.start();
}

bool CameraSurface::shown() const
{
    // Exposed, not only visible: a minimized or covered window draws nothing,
    // so a frame waiting to be drawn would hold back the previews' frames.
    return isVisible() && window() && window()->isVisible() && window()->isExposed();
}

QCameraDevice CameraSurface::findDevice() const
{
    if (m_deviceId.isEmpty())
        return QMediaDevices::defaultVideoInput();
    const QByteArray id = m_deviceId.toUtf8();
    const QList<QCameraDevice> devices = QMediaDevices::videoInputs();
    const auto found = std::find_if(devices.begin(), devices.end(), [&id](const QCameraDevice &d) { return d.id() == id; });
    return found == devices.end() ? QCameraDevice() : *found;
}

double CameraSurface::retryMs() const
{
    return std::min(kRetryMs * double(1 << std::min(m_retries, 4)), kRetryMostMs);
}

void CameraSurface::evaluate()
{
    const double now = kvj_clock_ms();
    if (m_newFrame && now - m_takenAt > kDrawWaitMs) {
        m_newFrame = false;
        m_pending = QImage();
        m_busy = false;
    }
    // Nobody looking only stops the converting: the camera runs on.
    m_watched = shown() || previewsWatching();
    if (!m_active) {
        stop();
        return;
    }
    // The system's camera stack has not come back from a start or a stop:
    // the camera is given up rather than wait for it.
    if (m_link && m_link->busyMs() > kHangMs) {
        ++g_hung;
        Engine::note(QStringLiteral("camera: 系统的相机接口 %1 秒没有回应，放弃这台相机").arg(qRound(m_link->busyMs() / 1000)));
        ++m_generation;
        giveUp();
        m_hung = true;
        m_newFrame = false;
        m_pending = QImage();
        m_busy = false;
        m_clear = true;
        setHasFrame(false);
        clearPreviews();
        update();
        setError(QStringLiteral("相机没有回应（系统的相机接口卡住了）：先移除这台相机，或重启 KVJ"));
        return;
    }
    if (m_hung)
        return;
    if (m_running) {
        // Frames since it started: it works, whatever was wrong before.
        const double frameAt = m_frameAt;
        if (frameAt > m_startedAt) {
            m_retries = 0;
            setError(QString());
        }
        // Nothing for a while (the stream stalled, the iPhone locked, the
        // driver stuck, or it went away unannounced): started again.
        const double quiet = now - std::max(frameAt, m_startedAt);
        if (quiet < retryMs())
            return;
        Engine::note(QStringLiteral("camera: 重启（%1 秒无画面）").arg(qRound(quiet / 1000)));
        stop();
        ++m_retries;
        m_lost = true;
        setError(QStringLiteral("相机没有画面"));
    }
    if (m_asking)
        return;
    if (m_failed) {
        if (now - m_failedAt < retryMs())
            return;
        // Tried again, if it is still there.
        m_failed = false;
        ++m_retries;
    }
#if QT_CONFIG(permissions)
    const QCameraPermission permission;
    switch (qApp->checkPermission(permission)) {
    case Qt::PermissionStatus::Undetermined:
        m_asking = true;
        qApp->requestPermission(permission, this, [this](const QPermission &) {
            m_asking = false;
            evaluate();
        });
        return;
    case Qt::PermissionStatus::Denied:
        setError(QStringLiteral("没有相机权限"));
        return;
    case Qt::PermissionStatus::Granted:
        break;
    }
#endif
    if (!m_devices) {
        m_devices = new QMediaDevices(this);
        connect(m_devices, &QMediaDevices::videoInputsChanged, this, &CameraSurface::devicesChanged);
    }
    if (g_hung >= kMostHung) {
        setError(QStringLiteral("系统的相机接口多次卡住：重启 KVJ 后再用相机"));
        return;
    }
    const QCameraDevice device = findDevice();
    if (device.isNull()) {
        setError(m_lost ? QStringLiteral("相机已断开")
                 : m_deviceId.isEmpty() ? QStringLiteral("没有相机")
                                        : QStringLiteral("找不到这台相机"));
        return;
    }
    start(device);
}

void CameraSurface::start(const QCameraDevice &device)
{
    if (!m_worker) {
        m_link = std::make_shared<CameraLink>();
        m_link->surface = this;
        m_worker = new CameraWorker(m_link);
        if (ownThread()) {
            auto *thread = new QThread;
            thread->setObjectName(QStringLiteral("kvj-camera"));
            m_worker->moveToThread(thread);
            connect(thread, &QThread::finished, thread, &QObject::deleteLater);
            thread->start();
            QMetaObject::invokeMethod(m_worker, [worker = m_worker] { worker->setUp(); });
        }
    }
    const int generation = ++m_generation;
    const QCameraFormat format = pickFormat(device);
    m_running = true;
    m_startedId = device.id();
    m_first = true;
    m_lost = false;
    // What was wrong is said until the first frame (evaluate). The start is
    // counted from now: one that does not come back is caught by evaluate.
    QMetaObject::invokeMethod(m_worker, [worker = m_worker, device, format, generation] {
        worker->start(device, format, generation);
    });
    m_startedAt = kvj_clock_ms();
    Engine::note(QStringLiteral("camera: %1 · %2×%3 at %4 fps")
             .arg(device.description())
             .arg(format.resolution().width())
             .arg(format.resolution().height())
             .arg(double(format.maxFrameRate())));
}

// What the camera said went wrong, from its side. A report from a camera
// already let go changes nothing.
void CameraSurface::failed(int generation, const QString &text)
{
    if (!m_running || generation != m_generation)
        return;
    Engine::note(QStringLiteral("camera: %1").arg(text));
    stop();
    m_failed = true;
    m_failedAt = kvj_clock_ms();
#ifdef Q_OS_WIN
    // Media Foundation's own words (with its HRESULT) say more than ours.
    setError(text.isEmpty() ? QStringLiteral("相机打不开") : QStringLiteral("相机打不开：%1").arg(text));
#else
    setError(QStringLiteral("相机打不开"));
#endif
}

void CameraSurface::stop()
{
    if (!m_running)
        return;
    ++m_generation;
    m_running = false;
    QMetaObject::invokeMethod(m_worker, [worker = m_worker] { worker->stop(); });
    // A conversion under way lets go when it lands; a frame waiting to be
    // drawn is dropped here.
    if (m_newFrame)
        m_busy = false;
    m_pending = QImage();
    m_newFrame = false;
    m_clear = true;
    setHasFrame(false);
    clearPreviews();
    update();
}

// The camera in use (or the one that just failed, often for this) is gone:
// said so until it, or another, can start.
void CameraSurface::devicesChanged()
{
    if (m_running || m_failed) {
        const QList<QCameraDevice> devices = QMediaDevices::videoInputs();
        const bool present = std::any_of(devices.begin(), devices.end(),
                                         [this](const QCameraDevice &d) { return d.id() == m_startedId; });
        if (!present) {
            Engine::note(QStringLiteral("camera: disconnected"));
            stop();
            m_lost = true;
            setError(QStringLiteral("相机已断开"));
        }
    }
    m_failed = false;
    // Plugged in again or another one: a camera given up is tried again.
    m_hung = false;
    schedule();
}

// On whichever thread the camera delivers. RGB32 is what the picture and the
// previews take as they are; a premultiplied ARGB frame from an opaque camera
// is the same bytes.
void CameraSurface::offer(const QVideoFrame &frame)
{
    if (!frame.isValid())
        return;
    m_frameAt = kvj_clock_ms();
    if (!m_watched || m_busy.exchange(true))
        return;
    const int generation = m_generation;
    const bool mirror = m_mirrored;
    m_convert.start([this, frame, generation, mirror] {
        QImage image = frame.toImage();
        if (image.format() == QImage::Format_ARGB32_Premultiplied || image.format() == QImage::Format_ARGB32)
            image.reinterpretAsFormat(QImage::Format_RGB32);
        else if (!image.isNull() && image.format() != QImage::Format_RGB32)
            image.convertTo(QImage::Format_RGB32);
        if (mirror && !image.isNull())
            image = std::move(image).mirrored(true, false);
        QMetaObject::invokeMethod(this, [this, image = std::move(image), generation] { take(image, generation); },
                                  Qt::QueuedConnection);
    });
}

void CameraSurface::take(const QImage &image, int generation)
{
    if (generation != m_generation || image.isNull()) {
        m_busy = false;
        return;
    }
    if (image.size() != m_sourceSize) {
        m_sourceSize = image.size();
        emit sourceInfoChanged();
    }
    // The first frame is taken by every preview at once.
    feedPreviews(image, std::exchange(m_first, false) ? Layer::Jump : Layer::Shown);
    setHasFrame(true);
    if (!shown()) {
        m_busy = false;
        return;
    }
    m_pending = image;
    m_newFrame = true;
    m_takenAt = kvj_clock_ms();
    update();
}

QSGNode *CameraSurface::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    auto *node = static_cast<FrameNode *>(old);
    if (m_clear) {
        m_clear = false;
        delete node;
        node = nullptr;
    }
    const double now = kvj_clock_ms();
    if (m_newFrame && !m_pending.isNull()) {
        m_newFrame = false;
        QSGTexture *texture = window()->createTextureFromImage(m_pending);
        m_pending = QImage();
        if (!node)
            node = new FrameNode;
        node->show(texture, 0, now);
        m_busy = false;
    }
    if (!node)
        return nullptr;
    node->layout(boundingRect(), now);
    return node;
}
