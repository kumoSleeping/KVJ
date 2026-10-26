#include "CameraSurface.h"

#include "FrameNode.h"
#include "kvj.h"

#include <QCamera>
#include <QCoreApplication>
#include <QDebug>
#include <QMediaCaptureSession>
#include <QMediaDevices>
#include <QQuickWindow>
#include <QVideoFrame>
#include <QVideoSink>
#if QT_CONFIG(permissions)
#include <QPermissions>
#endif

#include <algorithm>
#include <tuple>
#include <utility>

namespace {
// A frame not drawn this long after it came (the window went away meanwhile)
// no longer holds back the next one.
constexpr double kDrawWaitMs = 500;

// The camera's own format closest to a projected picture: at most 1080 lines,
// a fluent rate, not compressed (decoding JPEG costs more than converting),
// then the largest. Rates above 30 a second count the same: the extra frames
// would only be dropped.
QCameraFormat pickFormat(const QCameraDevice &device)
{
    const auto key = [](const QCameraFormat &format) {
        const QSize size = format.resolution();
        return std::make_tuple(size.height() <= 1080, format.maxFrameRate() >= 24,
                               format.pixelFormat() != QVideoFrameFormat::Format_Jpeg,
                               size.width() * size.height(), std::min(format.maxFrameRate(), 30.0f));
    };
    QCameraFormat best;
    for (const QCameraFormat &format : device.videoFormats()) {
        if (best.isNull() || key(format) > key(best))
            best = format;
    }
    return best;
}
} // namespace

CameraSurface::CameraSurface(QQuickItem *parent)
    : PictureSource(parent)
{
    setFlag(ItemHasContents, true);
    m_soon.setSingleShot(true);
    m_soon.setInterval(0);
    connect(&m_soon, &QTimer::timeout, this, &CameraSurface::evaluate);
    // Whether a preview is on screen is not signalled; it is looked at now and then.
    m_poll.setInterval(1000);
    connect(&m_poll, &QTimer::timeout, this, &CameraSurface::evaluate);
    m_convert.setMaxThreadCount(1);
    m_convert.setExpiryTimeout(-1);
}

CameraSurface::~CameraSurface()
{
    ++m_generation;
    m_camera.reset();
    m_session.reset();
    m_sink.reset();
    m_convert.waitForDone();
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

void CameraSurface::evaluate()
{
    if (m_newFrame && kvj_clock_ms() - m_takenAt > kDrawWaitMs) {
        m_newFrame = false;
        m_pending = QImage();
        m_busy = false;
    }
    if (!m_active || !(shown() || previewsWatching())) {
        stop();
        return;
    }
    if (m_camera || m_failed || m_asking)
        return;
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
    if (!m_session) {
        m_sink = std::make_unique<QVideoSink>();
        // Frames may come on the camera's own thread: taken there, converted
        // on the conversion thread, shown on this one.
        connect(m_sink.get(), &QVideoSink::videoFrameChanged, this, [this](const QVideoFrame &frame) { offer(frame); },
                Qt::DirectConnection);
        m_session = std::make_unique<QMediaCaptureSession>();
        m_session->setVideoSink(m_sink.get());
    }
    const int generation = ++m_generation;
    m_camera = std::make_unique<QCamera>(device);
    const QCameraFormat format = pickFormat(device);
    if (!format.isNull())
        m_camera->setCameraFormat(format);
    // Queued: the camera may report while it starts, and is dropped on error.
    // A report from a camera already let go changes nothing.
    connect(m_camera.get(), &QCamera::errorOccurred, this, [this, generation](QCamera::Error error, const QString &text) {
        if (error == QCamera::NoError || !m_camera || generation != m_generation)
            return;
        qInfo().noquote() << QStringLiteral("camera: %1").arg(text);
        stop();
        m_failed = true;
        setError(QStringLiteral("相机打不开"));
    }, Qt::QueuedConnection);
    m_session->setCamera(m_camera.get());
    m_startedId = device.id();
    m_first = true;
    m_lost = false;
    setError(QString());
    m_camera->start();
    qInfo().noquote() << QStringLiteral("camera: %1 · %2×%3 at %4 fps")
                             .arg(device.description())
                             .arg(format.resolution().width())
                             .arg(format.resolution().height())
                             .arg(double(format.maxFrameRate()));
}

void CameraSurface::stop()
{
    if (!m_camera)
        return;
    ++m_generation;
    m_camera->stop();
    m_session->setCamera(nullptr);
    m_camera.reset();
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
    if (m_camera || m_failed) {
        const QList<QCameraDevice> devices = QMediaDevices::videoInputs();
        const bool present = std::any_of(devices.begin(), devices.end(),
                                         [this](const QCameraDevice &d) { return d.id() == m_startedId; });
        if (!present) {
            qInfo().noquote() << QStringLiteral("camera: disconnected");
            stop();
            m_lost = true;
            setError(QStringLiteral("相机已断开"));
        }
    }
    m_failed = false;
    schedule();
}

// On whichever thread the camera delivers. RGB32 is what the picture and the
// previews take as they are; a premultiplied ARGB frame from an opaque camera
// is the same bytes.
void CameraSurface::offer(const QVideoFrame &frame)
{
    if (!frame.isValid() || m_busy.exchange(true))
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
