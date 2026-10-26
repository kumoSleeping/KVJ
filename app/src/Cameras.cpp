#include "Cameras.h"

#include <QCameraDevice>
#include <QMediaDevices>
#include <QVariantMap>

Cameras::Cameras(QObject *parent)
    : QObject(parent)
{
}

QVariantList Cameras::list() const
{
    if (!m_devices) {
        auto *self = const_cast<Cameras *>(this);
        m_devices = new QMediaDevices(self);
        connect(m_devices, &QMediaDevices::videoInputsChanged, self, &Cameras::changed);
    }
    QVariantList cameras;
    for (const QCameraDevice &device : QMediaDevices::videoInputs())
        cameras.append(QVariantMap{{QStringLiteral("id"), QString::fromUtf8(device.id())},
                                   {QStringLiteral("name"), device.description()}});
    return cameras;
}
