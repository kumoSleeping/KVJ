#pragma once

// QML face of the Rust engine (core/engine, C ABI in kvj.h). Commands that can
// block (importing files, listing devices, starting a session) run on the thread
// pool; their replies and the engine's events land back on the GUI thread.

#include <QJsonObject>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <functional>

struct KvjEngine;

class Engine : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantMap document READ document NOTIFY documentChanged)
    Q_PROPERTY(QVariantMap view READ view NOTIFY viewChanged)
    Q_PROPERTY(QVariantMap matched READ matched NOTIFY matchedChanged)
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(QVariantList bluetoothDevices READ bluetoothDevices NOTIFY bluetoothDevicesChanged)
    Q_PROPERTY(QStringList logs READ logs NOTIFY logsChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    // Files being probed into a Set; only this holds back further adding.
    Q_PROPERTY(bool importing READ importing NOTIFY importingChanged)
    Q_PROPERTY(QString dataDir READ dataDir CONSTANT)

public:
    explicit Engine(QObject *parent = nullptr);
    ~Engine() override;

    QVariantMap document() const { return m_document; }
    QVariantMap view() const { return m_view; }
    QVariantMap matched() const { return m_matched; }
    QVariantList devices() const { return m_devices; }
    QVariantList bluetoothDevices() const { return m_bluetoothDevices; }
    QStringList logs() const { return m_logs; }
    QString error() const { return m_error; }
    bool busy() const { return m_busy > 0; }
    bool importing() const { return m_importing; }
    QString dataDir() const { return m_dataDir; }

    Q_INVOKABLE void refreshDevices();
    Q_INVOKABLE void createSet(const QString &name);
    Q_INVOKABLE void deleteSet(const QString &setId);
    Q_INVOKABLE void removeEntry(const QString &setId, const QString &entryId);
    Q_INVOKABLE void importUrls(const QString &setId, const QList<QUrl> &urls);
    Q_INVOKABLE void start(const QString &setId, const QString &device, int channelStart);
    Q_INVOKABLE void stop();
    // Bluetooth: paired devices (or a fresh search), standby connections to
    // receivers, the current DJ on the receiving side, and sender-only sessions.
    Q_INVOKABLE void scanBluetooth(bool inquiry);
    Q_INVOKABLE void connectBluetooth(const QVariantMap &device);
    Q_INVOKABLE void disconnectBluetooth(const QString &id);
    Q_INVOKABLE void selectBluetooth(const QString &id);
    Q_INVOKABLE void pairBluetooth();
    Q_INVOKABLE void startSending(const QString &peer, const QString &device, int channelStart);
    Q_INVOKABLE void clearError();
    Q_INVOKABLE static QUrl fileUrl(const QString &path) { return QUrl::fromLocalFile(path); }
    // The engine's monotonic clock; matched.clock_at_ms is on it.
    Q_INVOKABLE static double clockMs();

signals:
    void documentChanged();
    void viewChanged();
    void matchedChanged();
    void devicesChanged();
    void bluetoothDevicesChanged();
    void logsChanged();
    void errorChanged();
    void busyChanged();
    void importingChanged();

private:
    using Done = std::function<void(const QJsonValue &ok)>;
    // `finally` runs after the reply, whether it succeeded or not.
    void call(const QJsonObject &request, Done done, bool background, std::function<void()> finally = {});
    void edit(const QJsonObject &edit);
    void setError(const QString &error);
    void applyPresented(const QJsonObject &view);
    void poll();
    static void onEvent(void *user, const char *json);

    KvjEngine *m_engine = nullptr;
    QString m_dataDir;
    QVariantMap m_document;
    QVariantMap m_view;
    QVariantMap m_matched;
    QVariantList m_devices;
    QVariantList m_bluetoothDevices;
    QStringList m_logs;
    QString m_error;
    int m_busy = 0;
    bool m_importing = false;
    qint64 m_logCursor = 0;
    QString m_session;
    QTimer m_poll;
};
