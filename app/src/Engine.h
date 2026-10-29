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
    // The in-app update under way: {phase, version, received, total, error};
    // phase "" (none), downloading, verifying, unpacking, ready, installing, failed.
    Q_PROPERTY(QVariantMap updateJob READ updateJob NOTIFY updateJobChanged)
    // What the last update did, said once after the restart ("" when nothing).
    Q_PROPERTY(QString updateNotice READ updateNotice NOTIFY updateJobChanged)
    // The computer and its screens kept awake (Awake.h): set while projecting
    // or following.
    Q_PROPERTY(bool keepAwake READ keepAwake WRITE setKeepAwake NOTIFY keepAwakeChanged)
    // 详细日志: every recognition round and the pictures' timing go to
    // <dataDir>/logs/detail-<date>.log, with the usual lines between them.
    // Off until set (About keeps the user's choice across starts).
    Q_PROPERTY(bool detailLog READ detailLog WRITE setDetailLog NOTIFY detailLogChanged)
    // Entries sharing their sound with another on the same track: entry id
    // to what it shares, said in a sentence (empty: none known).
    Q_PROPERTY(QVariantMap alike READ alike NOTIFY alikeChanged)

public:
    explicit Engine(QObject *parent = nullptr);
    ~Engine() override;

    QVariantMap document() const { return m_document; }
    QVariantMap view() const { return m_view; }
    QVariantMap matched() const { return m_matched; }
    QVariantList devices() const { return m_devices; }
    QStringList logs() const { return m_logs; }
    QString error() const { return m_error; }
    bool busy() const { return m_busy > 0; }
    bool importing() const { return m_importing; }
    QString dataDir() const { return m_dataDir; }
    QString version() const { return m_version; }
    QVariantMap update() const { return m_update; }
    bool checkingUpdate() const { return m_checkingUpdate; }
    QString updateError() const { return m_updateError; }
    QVariantMap updateJob() const { return m_updateJob; }
    QString updateNotice() const { return m_updateNotice; }

    // The newest published release (GitHub). `quiet`: a failure is not shown.
    Q_INVOKABLE void checkUpdate(bool quiet);
    // Fetches, checks and unpacks the release the last check found
    // (update.installable); updateJob follows it. Cancel stops it or drops
    // what is ready.
    Q_INVOKABLE void downloadUpdate();
    Q_INVOKABLE void cancelUpdate();
    // Once ready: starts the updater, which swaps the new version in after
    // KVJ quits and starts it, and quits. Whoever calls it has made sure no
    // show is interrupted unasked.
    Q_INVOKABLE void installUpdate();
    Q_INVOKABLE void dismissUpdateNotice();
    // Called once the window is up: an updater waiting for this version to
    // start is told it did, and updateNotice says what the last update did.
    void settleUpdate();
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
    // Before another entry of the Set, or to its end (empty `beforeId`).
    Q_INVOKABLE void moveEntry(const QString &setId, const QString &entryId, const QString &beforeId = {});
    // `track`: 0 the main track, 1..3 the aux ones (画面 2..4).
    // `placed`: onto the timeline (on), or only into the Set's library.
    Q_INVOKABLE void importUrls(const QString &setId, const QList<QUrl> &urls, int track = 0, bool placed = true);
    // On or off for following; also while following, for the next round.
    Q_INVOKABLE void enableEntries(const QString &setId, const QStringList &entryIds, bool on);
    // Moves entries to a track (0..3); like other edits, only while not following.
    // Every Set into the first: KVJ keeps one library of videos.
    Q_INVOKABLE void mergeSets();
    Q_INVOKABLE void setTrack(const QString &setId, const QStringList &entryIds, int track);
    // Onto `track`, after what is on it, in this order; one placed on another
    // track gets a copy there (the same video on both).
    Q_INVOKABLE void placeEntries(const QString &setId, const QStringList &entryIds, int track);
    // `room`: 现场模式, the input hears a reverberant room through a microphone.
    // `track`: only that track's entries are followed; `view.track` says which.
    Q_INVOKABLE void start(const QString &setId, const QString &device, int channelStart, bool room, int track = 0);
    Q_INVOKABLE void stop();
    // While following: listen to another track; what the other one found is
    // let go first (its picture back to its own player), then view.track says it.
    Q_INVOKABLE void followTrack(int track);
    Q_INVOKABLE void clearError();
    Q_INVOKABLE static QUrl fileUrl(const QString &path) { return QUrl::fromLocalFile(path); }
    // The engine's monotonic clock; matched.clock_at_ms is on it.
    Q_INVOKABLE static double clockMs();
    // Where the Set document and caches live: $KVJ_DATA_DIR, else the app's data folder.
    static QString defaultDataDir();
    // A line for the session's log on disk (writeLog's file, which a Windows
    // build, having no console, also needs) and the console, from the app's
    // own parts (the pictures, the cameras) on the GUI thread.
    static void note(const QString &line);
    bool detailLog() const { return s_detail; }
    QVariantMap alike() const { return m_alike; }
    void setDetailLog(bool on);
    // Whether 详细日志 is on, and a line for its file only (GUI thread).
    static bool detailing() { return s_detail; }
    static void detail(const QString &line);

signals:
    void documentChanged();
    void viewChanged();
    void matchedChanged();
    void devicesChanged();
    void logsChanged();
    void errorChanged();
    void busyChanged();
    void importingChanged();
    void keepAwakeChanged();
    void detailLogChanged();
    void alikeChanged();
    void updateChanged();
    void updateJobChanged();
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
    void pollUpdate();
    // The session's log lines also go to <dataDir>/logs, a file a day, so a
    // show can be looked into afterwards.
    void writeLog(const QStringList &lines);
    void fetchAlike();
    // Appends timed lines to <dataDir>/logs/<kind>-<date>.log.
    static void append(const QString &kind, const QStringList &lines);
    static inline bool s_detail = false;
    static void onEvent(void *user, const char *json);

    KvjEngine *m_engine = nullptr;
    QString m_dataDir;
    QString m_version;
    QVariantMap m_update;
    bool m_checkingUpdate = false;
    QString m_updateError;
    QVariantMap m_updateJob;
    QString m_updateNotice;
    QTimer m_updatePoll;
    QVariantMap m_document;
    QVariantMap m_alike;
    qint64 m_alikeRevision = -1;
    QVariantMap m_view;
    QVariantMap m_matched;
    QVariantList m_devices;
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
