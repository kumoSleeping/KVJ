#include "Engine.h"

#include "Awake.h"
#include "kvj.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QLockFile>
#include <QJsonDocument>
#include <QPointer>
#include <QStandardPaths>
#include <QThreadPool>

namespace {

// One JSON round trip through the C ABI: {"ok": …} or {"error": "…"}.
QJsonObject roundTrip(KvjEngine *engine, const QJsonObject &request)
{
    const QByteArray text = QJsonDocument(request).toJson(QJsonDocument::Compact);
    char *reply = kvj_call(engine, text.constData());
    if (!reply)
        return {{"error", QStringLiteral("引擎没有回应")}};
    const QJsonObject result = QJsonDocument::fromJson(QByteArray(reply)).object();
    kvj_string_free(reply);
    return result;
}

} // namespace

Engine::Engine(QObject *parent)
    : QObject(parent)
{
    m_edits.setMaxThreadCount(1);
    m_dataDir = defaultDataDir();
    QDir().mkpath(m_dataDir);
    m_lock = std::make_unique<QLockFile>(QDir(m_dataDir).filePath(QStringLiteral("kvj.lock")));
    const bool alone = m_lock->tryLock(0);
    // Logs older than two weeks go.
    const QDir logs(QDir(m_dataDir).filePath(QStringLiteral("logs")));
    const QStringList old = logs.entryList({QStringLiteral("kvj-*.log")}, QDir::Files, QDir::Name | QDir::Reversed);
    for (int i = 14; i < old.size(); ++i)
        QFile::remove(logs.filePath(old.at(i)));
    m_engine = kvj_engine_new(QDir::toNativeSeparators(m_dataDir).toUtf8().constData(), &Engine::onEvent, this);
    if (m_engine)
        m_version = roundTrip(m_engine, {{"cmd", "version"}}).value("ok").toString();
    QCoreApplication::setApplicationVersion(m_version);

    call({{"cmd", "document"}}, [this](const QJsonValue &ok) {
        m_document = ok.toObject().toVariantMap();
        emit documentChanged();
    }, false);
    refreshDevices();

    m_poll.setInterval(250);
    connect(&m_poll, &QTimer::timeout, this, &Engine::poll);
    m_poll.start();
    if (!alone)
        setError(QStringLiteral("另一个 KVJ 正在使用同一份 Set 数据：请只开一个，两个会互相干扰蓝牙和改动"));
}

void Engine::writeLog(const QStringList &lines)
{
    const QDir dir(QDir(m_dataDir).filePath(QStringLiteral("logs")));
    if (!dir.exists() && !QDir().mkpath(dir.path()))
        return;
    const QDateTime now = QDateTime::currentDateTime();
    QFile file(dir.filePath(QStringLiteral("kvj-%1.log").arg(now.toString(QStringLiteral("yyyy-MM-dd")))));
    if (!file.open(QIODevice::Append | QIODevice::Text))
        return;
    const QString at = now.toString(QStringLiteral("HH:mm:ss.zzz "));
    for (const QString &line : lines)
        file.write((at + line + QLatin1Char('\n')).toUtf8());
}

Engine::~Engine()
{
    m_poll.stop();
    // Background commands hold the raw engine pointer; let them finish first.
    QThreadPool::globalInstance()->waitForDone();
    m_edits.waitForDone();
    // Joins the worker: no event can reach this object afterwards.
    kvj_engine_free(m_engine);
    m_engine = nullptr;
}

QString Engine::defaultDataDir()
{
    const QString dir = qEnvironmentVariable("KVJ_DATA_DIR");
    return dir.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) : dir;
}

double Engine::clockMs()
{
    return kvj_clock_ms();
}

void Engine::onEvent(void *user, const char *json)
{
    auto *self = static_cast<Engine *>(user);
    const QByteArray data(json);
    QMetaObject::invokeMethod(self, [self, data] {
        self->applyPresented(QJsonDocument::fromJson(data).object());
    }, Qt::QueuedConnection);
}

void Engine::call(const QJsonObject &request, Done done, bool background, std::function<void()> finally,
                  QThreadPool *pool)
{
    if (!m_engine)
        return;
    if (!background) {
        const QJsonObject reply = roundTrip(m_engine, request);
        if (reply.contains("error"))
            setError(reply.value("error").toString());
        else if (done)
            done(reply.value("ok"));
        if (finally)
            finally();
        return;
    }
    ++m_busy;
    emit busyChanged();
    QPointer<Engine> guard(this);
    KvjEngine *engine = m_engine;
    (pool ? pool : QThreadPool::globalInstance())->start([guard, engine, request, done, finally] {
        const QJsonObject reply = roundTrip(engine, request);
        QMetaObject::invokeMethod(guard, [guard, reply, done, finally] {
            if (!guard)
                return;
            --guard->m_busy;
            emit guard->busyChanged();
            if (reply.contains("error"))
                guard->setError(reply.value("error").toString());
            else if (done)
                done(reply.value("ok"));
            if (finally)
                finally();
        }, Qt::QueuedConnection);
    });
}

void Engine::ask(const QJsonObject &request, std::function<void(const QJsonObject &reply)> done)
{
    if (!m_engine)
        return;
    QPointer<Engine> guard(this);
    KvjEngine *engine = m_engine;
    QThreadPool::globalInstance()->start([guard, engine, request, done] {
        const QJsonObject reply = roundTrip(engine, request);
        QMetaObject::invokeMethod(guard, [guard, reply, done] {
            if (guard)
                done(reply);
        }, Qt::QueuedConnection);
    });
}

void Engine::checkUpdate(bool quiet)
{
    if (m_checkingUpdate)
        return;
    m_checkingUpdate = true;
    if (!quiet)
        m_updateError.clear();
    emit updateChanged();
    ask({{"cmd", "update_check"}}, [this, quiet](const QJsonObject &reply) {
        m_checkingUpdate = false;
        if (reply.contains("error")) {
            if (!quiet)
                m_updateError = reply.value("error").toString();
        } else {
            m_update = reply.value("ok").toObject().toVariantMap();
            m_updateError.clear();
        }
        emit updateChanged();
    });
}

void Engine::prepareReport(const QString &note)
{
    ask({{"cmd", "report_prepare"}, {"note", note}}, [this](const QJsonObject &reply) {
        if (reply.contains("error"))
            emit reportFailed(reply.value("error").toString());
        else
            emit reportReady(reply.value("ok").toObject().toVariantMap());
    });
}

void Engine::submitReport(const QString &id)
{
    ask({{"cmd", "report_submit"}, {"id", id}}, [this](const QJsonObject &reply) {
        if (reply.contains("error"))
            emit reportFailed(reply.value("error").toString());
        else
            emit reportSent(reply.value("ok").toObject().value("id").toString());
    });
}

void Engine::setKeepAwake(bool on)
{
    if (m_keepAwake == on)
        return;
    m_keepAwake = on;
    stayAwake(on);
    emit keepAwakeChanged();
}

void Engine::setError(const QString &error)
{
    if (m_error == error)
        return;
    if (!error.isEmpty())
        writeLog({QStringLiteral("[error] ") + error});
    m_error = error;
    emit errorChanged();
}

void Engine::clearError()
{
    setError({});
}

void Engine::refreshDevices()
{
    call({{"cmd", "devices"}}, [this](const QJsonValue &ok) {
        m_devices = ok.toArray().toVariantList();
        emit devicesChanged();
    }, true);
}

void Engine::edit(const QJsonObject &edit)
{
    const QJsonObject request{
        {"cmd", "edit"},
        {"revision", m_document.value("revision").toLongLong()},
        {"edit", edit},
    };
    call(request, [this](const QJsonValue &ok) {
        m_document = ok.toObject().toVariantMap();
        emit documentChanged();
    }, false);
}

void Engine::createSet(const QString &name)
{
    edit({{"kind", "create"}, {"name", name}});
}

void Engine::deleteSet(const QString &setId)
{
    edit({{"kind", "delete"}, {"set_id", setId}});
}

void Engine::moveEntry(const QString &setId, const QString &entryId, const QString &beforeId)
{
    edit({{"kind", "move"}, {"set_id", setId}, {"entry_id", entryId},
          {"before_id", beforeId.isEmpty() ? QJsonValue() : QJsonValue(beforeId)}});
}

void Engine::removeEntry(const QString &setId, const QString &entryId)
{
    edit({{"kind", "remove"}, {"set_id", setId}, {"entry_id", entryId}});
}

void Engine::enableEntries(const QString &setId, const QStringList &entryIds, bool on)
{
    if (entryIds.isEmpty())
        return;
    const QJsonObject request{
        {"cmd", "enable"},
        {"set_id", setId},
        {"entry_ids", QJsonArray::fromStringList(entryIds)},
        {"on", on},
    };
    call(request, [this](const QJsonValue &ok) {
        // An edit made meanwhile (on the GUI thread) is never undone by an
        // older document.
        const QVariantMap document = ok.toObject().toVariantMap();
        if (document.value("revision").toLongLong() < m_document.value("revision").toLongLong())
            return;
        m_document = document;
        emit documentChanged();
    }, true, {}, &m_edits);
}

void Engine::mergeSets()
{
    edit({{"kind", "merge"}});
}

void Engine::setTrack(const QString &setId, const QStringList &entryIds, int track)
{
    if (entryIds.isEmpty())
        return;
    edit({{"kind", "track"}, {"set_id", setId}, {"entry_ids", QJsonArray::fromStringList(entryIds)}, {"track", track}});
}

void Engine::importUrls(const QString &setId, const QList<QUrl> &urls, int track, bool placed)
{
    QJsonArray paths;
    for (const QUrl &url : urls) {
        if (url.isLocalFile())
            paths.append(QDir::toNativeSeparators(url.toLocalFile()));
    }
    if (paths.isEmpty())
        return;
    const QJsonObject request{
        {"cmd", "import"},
        {"set_id", setId},
        {"revision", m_document.value("revision").toLongLong()},
        {"paths", paths},
        {"track", track},
        {"placed", placed},
    };
    clearError();
    m_importing = true;
    emit importingChanged();
    call(request, [this](const QJsonValue &ok) {
        m_document = ok.toObject().toVariantMap();
        emit documentChanged();
    }, true, [this] {
        m_importing = false;
        emit importingChanged();
    });
}

void Engine::start(const QString &setId, const QString &device, int channelStart, bool room, int track)
{
    clearError();
    const QJsonObject request{
        {"cmd", "start"},
        {"set_id", setId},
        {"device", device.isEmpty() ? QStringLiteral("auto") : device},
        {"channel_start", channelStart},
        {"room", room},
        {"track", track},
    };
    call(request, [this](const QJsonValue &ok) {
        m_view = ok.toObject().toVariantMap();
        m_session = m_view.value("session").toString();
        m_logs.clear();
        m_logCursor = 0;
        emit viewChanged();
        emit logsChanged();
    }, true);
}

void Engine::stop()
{
    call({{"cmd", "stop"}}, [this](const QJsonValue &ok) {
        m_view = ok.toObject().toVariantMap();
        emit viewChanged();
    }, false);
}

void Engine::scanBluetooth()
{
    // Development aid: KVJ_FAKE_RECEIVERS='[{"id":"…","name":"…"}]' lists made-up
    // receivers without the radio, for checking the layout.
    const QByteArray fake = qgetenv("KVJ_FAKE_RECEIVERS");
    if (!fake.isEmpty()) {
        m_bluetoothDevices = QJsonDocument::fromJson(fake).array().toVariantList();
        emit bluetoothDevicesChanged();
        return;
    }
    call({{"cmd", "bluetooth_scan"}}, [this](const QJsonValue &ok) {
        m_bluetoothDevices = ok.toArray().toVariantList();
        emit bluetoothDevicesChanged();
    }, true);
}

void Engine::connectBluetooth(const QVariantMap &device)
{
    call({{"cmd", "bluetooth_connect"}, {"device", QJsonObject::fromVariantMap(device)}}, nullptr, true);
}

void Engine::disconnectBluetooth(const QString &id)
{
    call({{"cmd", "bluetooth_disconnect"}, {"id", id}}, nullptr, true);
}

void Engine::selectBluetooth(const QString &id)
{
    call({{"cmd", "bluetooth_select"}, {"id", id.isEmpty() ? QJsonValue() : QJsonValue(id)}}, nullptr, false);
}

void Engine::listenBluetooth(bool on, bool receiving)
{
    // In the order asked: a quick off and on again must end listening.
    call({{"cmd", "bluetooth_listen"}, {"on", on}, {"receiving", receiving}}, nullptr, true, {}, &m_edits);
}

void Engine::pairBluetooth(const QString &id, bool allow)
{
    call({{"cmd", "bluetooth_pair"}, {"id", id}, {"allow", allow}}, nullptr, false);
}

void Engine::forgetBluetooth(const QString &token)
{
    call({{"cmd", "bluetooth_forget"}, {"token", token}}, nullptr, true);
}

void Engine::startSending(const QString &peer, const QString &device, int channelStart)
{
    clearError();
    const QJsonObject request{
        {"cmd", "send_start"},
        {"peer", peer},
        {"device", device.isEmpty() ? QStringLiteral("auto") : device},
        {"channel_start", channelStart},
    };
    call(request, [this](const QJsonValue &ok) {
        m_view = ok.toObject().toVariantMap();
        m_session = m_view.value("session").toString();
        m_logs.clear();
        m_logCursor = 0;
        emit viewChanged();
        emit logsChanged();
    }, true);
}

void Engine::applyPresented(const QJsonObject &view)
{
    const QVariantMap matched = view.value("matched").toObject().toVariantMap();
    if (matched != m_matched) {
        m_matched = matched;
        emit matchedChanged();
    }
}

void Engine::poll()
{
    const QJsonObject request{{"cmd", "status"}, {"after_log_id", m_logCursor}};
    call(request, [this](const QJsonValue &ok) {
        const QJsonObject status = ok.toObject();
        const QJsonArray logs = status.value("logs").toArray();
        if (!logs.isEmpty()) {
            QStringList lines;
            for (const QJsonValue &entry : logs) {
                const QJsonObject log = entry.toObject();
                const QString message = log.value("message").toString();
                m_logs.append(message);
                lines.append(QStringLiteral("[%1] %2").arg(log.value("level").toString(), message));
                m_logCursor = log.value("id").toInteger();
            }
            writeLog(lines);
            while (m_logs.size() > 200)
                m_logs.removeFirst();
            emit logsChanged();
        }
        QVariantMap view = status.toVariantMap();
        view.remove("logs");
        // The clock always moves; nothing else changed means nothing to redraw.
        view.remove("clock_ms");
        if (view != m_view) {
            m_view = view;
            emit viewChanged();
        }
        // Stopped or failed: nothing is presented any more.
        const QString phase = view.value("phase").toString();
        if ((phase == "stopped" || phase == "failed") && !m_matched.isEmpty()) {
            m_matched.clear();
            emit matchedChanged();
        }
        if (phase == "failed")
            setError(view.value("error").toString());
    }, false);
}
