#pragma once

// QML face of the Rust engine (core/engine, C ABI in kvj.h). Commands that can
// block (importing files, listing devices, starting a session) run on the thread
// pool; their replies and the engine's events land back on the GUI thread.

#include <QJsonObject>
#include <QObject>
#include <QStringList>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <functional>
#include <memory>

class QLockFile;
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
    // This build's version (the release tag without its "v").
    Q_PROPERTY(QString version READ version CONSTANT)
    // The last update check: {current, latest, newer, url, name, published_at}.
    Q_PROPERTY(QVariantMap update READ update NOTIFY updateChanged)
    Q_PROPERTY(bool checkingUpdate READ checkingUpdate NOTIFY updateChanged)
    Q_PROPERTY(QString updateError READ updateError NOTIFY updateChanged)
    // The computer and its screens kept awake (Awake.h): set while projecting,
    // following or sending.
    Q_PROPERTY(bool keepAwake READ keepAwake WRITE setKeepAwake NOTIFY keepAwakeChanged)

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
    QString version() const { return m_version; }
    QVariantMap update() const { return m_update; }
    bool checkingUpdate() const { return m_checkingUpdate; }
    QString updateError() const { return m_updateError; }

    // The newest published release (GitHub). `quiet`: a failure is not shown.
    Q_INVOKABLE void checkUpdate(bool quiet);
    // A scrubbed report from the logs on disk, previewed in full
    // (reportReady), then sent exactly as shown (reportSent); reportFailed says why not.
    Q_INVOKABLE void prepareReport(const QString &note);
    Q_INVOKABLE void submitReport(const QString &id);
    bool keepAwake() const { return m_keepAwake; }
    void setKeepAwake(bool on);

    Q_INVOKABLE void refreshDevices();
    Q_INVOKABLE void createSet(const QString &name);
    Q_INVOKABLE void deleteSet(const QString &setId);
    Q_INVOKABLE void removeEntry(const QString &setId, const QString &entryId);
    // `track`: 0 the main track, 1..3 the aux ones (画面 2..4).
    Q_INVOKABLE void importUrls(const QString &setId, const QList<QUrl> &urls, int track = 0);
    // On or off for following; also while following, for the next round.
    Q_INVOKABLE void enableEntries(const QString &setId, const QStringList &entryIds, bool on);
    // Moves entries to a track (0..3); like other edits, only while not following.
    Q_INVOKABLE void setTrack(const QString &setId, const QStringList &entryIds, int track);
    // `room`: 现场模式, the input hears a reverberant room through a microphone.
    // `track`: only that track's entries are followed; `view.track` says which.
    Q_INVOKABLE void start(const QString &setId, const QString &device, int channelStart, bool room, int track = 0);
    Q_INVOKABLE void stop();
    // Bluetooth Low Energy: nearby KVJ receivers, advertising as one, standby
    // connections to receivers, the current DJ, and sender-only sessions.
    Q_INVOKABLE void scanBluetooth();
    // `receiving`: Bluetooth is the chosen input (a remembered DJ may be chosen).
    Q_INVOKABLE void listenBluetooth(bool on, bool receiving);
    // Allow (and remember) or refuse a DJ asking to pair; forget a paired computer.
    Q_INVOKABLE void pairBluetooth(const QString &id, bool allow);
    Q_INVOKABLE void forgetBluetooth(const QString &token);
    Q_INVOKABLE void connectBluetooth(const QVariantMap &device);
    Q_INVOKABLE void disconnectBluetooth(const QString &id);
    Q_INVOKABLE void selectBluetooth(const QString &id);
    Q_INVOKABLE void startSending(const QString &peer, const QString &device, int channelStart);
    Q_INVOKABLE void clearError();
    Q_INVOKABLE static QUrl fileUrl(const QString &path) { return QUrl::fromLocalFile(path); }
    // The engine's monotonic clock; matched.clock_at_ms is on it.
    Q_INVOKABLE static double clockMs();
    // Where the Set document and caches live: $KVJ_DATA_DIR, else the app's data folder.
    static QString defaultDataDir();

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
    void keepAwakeChanged();
    void updateChanged();
    void reportReady(const QVariantMap &preview);
    void reportSent(const QString &id);
    void reportFailed(const QString &error);

private:
    using Done = std::function<void(const QJsonValue &ok)>;
    // `finally` runs after the reply, whether it succeeded or not. Background
    // commands run on `pool` (the global thread pool when none).
    void call(const QJsonObject &request, Done done, bool background, std::function<void()> finally = {},
              QThreadPool *pool = nullptr);
    // A background command whose reply ({"ok"} or {"error"}) goes to `done`
    // as is: its failure is the caller's to show, not the window's error line.
    void ask(const QJsonObject &request, std::function<void(const QJsonObject &reply)> done);
    void edit(const QJsonObject &edit);
    void setError(const QString &error);
    void applyPresented(const QJsonObject &view);
    void poll();
    // The session's log lines also go to <dataDir>/logs, a file a day, so a
    // show can be looked into afterwards.
    void writeLog(const QStringList &lines);
    static void onEvent(void *user, const char *json);

    KvjEngine *m_engine = nullptr;
    QString m_dataDir;
    QString m_version;
    QVariantMap m_update;
    bool m_checkingUpdate = false;
    QString m_updateError;
    QVariantMap m_document;
    QVariantMap m_view;
    QVariantMap m_matched;
    QVariantList m_devices;
    QVariantList m_bluetoothDevices;
    QStringList m_logs;
    QString m_error;
    int m_busy = 0;
    bool m_importing = false;
    bool m_keepAwake = false;
    qint64 m_logCursor = 0;
    QString m_session;
    QTimer m_poll;
    // Entries turned on or off, one after another in the order asked: the
    // engine writes the document to disk (synced) and may wait for an import,
    // which the GUI thread drawing the projection must never do.
    QThreadPool m_edits;
    // Held while this KVJ uses the data folder: a second one is told.
    std::unique_ptr<QLockFile> m_lock;
};
