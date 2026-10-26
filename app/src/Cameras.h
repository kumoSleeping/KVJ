#pragma once

// The cameras on this computer, for choosing one as a picture source:
// `list` is [{id, name}], the id being what CameraSurface.deviceId takes. The
// camera stack is asked only when `list` is first read, so a start that never
// looks at cameras never loads it; from then on the list follows cameras
// plugged in and out.

#include <QObject>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

class QMediaDevices;

class Cameras : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantList list READ list NOTIFY changed)

public:
    explicit Cameras(QObject *parent = nullptr);

    QVariantList list() const;

signals:
    void changed();

private:
    mutable QMediaDevices *m_devices = nullptr;
};
