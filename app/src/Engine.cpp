#include "Engine.h"

#include "kvj.h"

#include <QDir>
#include <QJsonArray>
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
    m_dataDir = qEnvironmentVariable("KVJ_DATA_DIR");
    if (m_dataDir.isEmpty())
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(m_dataDir);
    m_engine = kvj_engine_new(QDir::toNativeSeparators(m_dataDir).toUtf8().constData(), &Engine::onEvent, this);

    call({{"cmd", "document"}}, [this](const QJsonValue &ok) {
        m_document = ok.toObject().toVariantMap();
        emit documentChanged();
    }, false);
    refreshDevices();

    m_poll.setInterval(250);
    connect(&m_poll, &QTimer::timeout, this, &Engine::poll);
    m_poll.start();
}

Engine::~Engine()
{
    m_poll.stop();
    // Background commands hold the raw engine pointer; let them finish first.
    QThreadPool::globalInstance()->waitForDone();
    // Joins the worker: no event can reach this object afterwards.
    kvj_engine_free(m_engine);
    m_engine = nullptr;
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

void Engine::call(const QJsonObject &request, Done done, bool background, std::function<void()> finally)
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
    QThreadPool::globalInstance()->start([guard, engine, request, done, finally] {
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

void Engine::setError(const QString &error)
{
    if (m_error == error)
        return;
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

void Engine::removeEntry(const QString &setId, const QString &entryId)
{
    edit({{"kind", "remove"}, {"set_id", setId}, {"entry_id", entryId}});
}

void Engine::importUrls(const QString &setId, const QList<QUrl> &urls)
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

void Engine::start(const QString &setId, const QString &device, int channelStart)
{
    clearError();
    const QJsonObject request{
        {"cmd", "start"},
        {"set_id", setId},
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

void Engine::stop()
{
    call({{"cmd", "stop"}}, [this](const QJsonValue &ok) {
        m_view = ok.toObject().toVariantMap();
        emit viewChanged();
    }, false);
}

void Engine::scanBluetooth()
{
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

void Engine::listenBluetooth(bool on)
{
    call({{"cmd", "bluetooth_listen"}, {"on", on}}, nullptr, true);
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
            for (const QJsonValue &entry : logs) {
                const QJsonObject log = entry.toObject();
                m_logs.append(log.value("message").toString());
                m_logCursor = log.value("id").toInteger();
            }
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
