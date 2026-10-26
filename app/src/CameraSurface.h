#pragma once

// A live camera as a picture source. The camera runs only while `active` and
// someone looks: the item is up in a shown window, or a preview of it is on
// screen. It stops otherwise, and clears its picture. Each frame the camera
// delivers is turned into an RGB image on a thread of its own and shown as it
// comes; frames arriving while the last one is still being converted or has
// not reached the screen yet are dropped, so a slow conversion lowers the frame
// rate rather than piling up. Previews get reduced copies at their own rates.
//
// The camera stack is touched only when a CameraSurface first becomes active
// and looked at; that is also when macOS asks for camera permission, never at
// start. A camera that is unplugged stops with an error and starts again when
// it comes back.

#include "PictureSource.h"

#include <QCameraDevice>
#include <QImage>
#include <QThreadPool>
#include <QTimer>
#include <atomic>
#include <memory>

class QCamera;
class QMediaCaptureSession;
class QMediaDevices;
class QVideoFrame;
class QVideoSink;

class CameraSurface : public PictureSource
{
    Q_OBJECT
    QML_ELEMENT
    // The camera's id from Cameras.list; empty for the system's default one.
    Q_PROPERTY(QString deviceId READ deviceId WRITE setDeviceId NOTIFY deviceIdChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    // Left and right swapped, as in a mirror.
    Q_PROPERTY(bool mirrored READ mirrored WRITE setMirrored NOTIFY mirroredChanged)

public:
    explicit CameraSurface(QQuickItem *parent = nullptr);
    ~CameraSurface() override;

    QString deviceId() const { return m_deviceId; }
    void setDeviceId(const QString &id);
    bool active() const { return m_active; }
    void setActive(bool active);
    bool mirrored() const { return m_mirrored; }
    void setMirrored(bool mirrored);

signals:
    void deviceIdChanged();
    void activeChanged();
    void mirroredChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;
    void itemChange(ItemChange change, const ItemChangeData &value) override;
    void previewsChanged() override;

private:
    void schedule();
    void evaluate();
    bool shown() const;
    QCameraDevice findDevice() const;
    void start(const QCameraDevice &device);
    void stop();
    void devicesChanged();
    void offer(const QVideoFrame &frame);
    void take(const QImage &image, int generation);

    QString m_deviceId;
    bool m_active = false;
    std::atomic<bool> m_mirrored{false};
    QTimer m_soon;
    QTimer m_poll;
    QMetaObject::Connection m_windowShown;
    QMediaDevices *m_devices = nullptr;
    std::unique_ptr<QVideoSink> m_sink;
    std::unique_ptr<QMediaCaptureSession> m_session;
    std::unique_ptr<QCamera> m_camera;
    // The camera started last.
    QByteArray m_startedId;
    // Waiting for the permission prompt; the camera failed (tried again after
    // a change); the camera went away while running.
    bool m_asking = false;
    bool m_failed = false;
    bool m_lost = false;
    // One conversion at a time, on one thread that lives as long as the item.
    QThreadPool m_convert;
    // A frame is being converted, or waits to be drawn.
    std::atomic<bool> m_busy{false};
    // Counts camera starts and stops; a frame from an earlier run is dropped.
    std::atomic<int> m_generation{0};
    bool m_first = false;
    QImage m_pending;
    bool m_newFrame = false;
    double m_takenAt = 0;
    bool m_clear = false;
};
