#include "Engine.h"
#include "kvj.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QThread>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSaveFile>
#include <QTimer>

namespace {

QJsonObject command(KvjEngine *engine, const QJsonObject &request)
{
    char *reply = kvj_call(engine, QJsonDocument(request).toJson(QJsonDocument::Compact).constData());
    const QJsonObject result = QJsonDocument::fromJson(QByteArray(reply)).object();
    kvj_string_free(reply);
    return result;
}

// Development aid, run from the app bundle because macOS gives Bluetooth only to
// processes that carry its usage description: `--ble-scan-test <file>` lists
// nearby KVJ receivers; `--ble-connect-test <file>` also connects to the first
// one and waits for the KVJ handshake; `--ble-send-test <file>` then waits to be
// chosen as the current DJ and streams a built-in test signal for ten seconds.
// Results are written to <file>.
int bluetoothTest(const QString &file, bool connect, bool send)
{
    QFile out(file);
    if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return 2;
    auto write = [&out](const QString &line) { out.write(line.toUtf8() + '\n'); out.flush(); };
    const QString data = QDir::temp().filePath(QStringLiteral("kvj-ble-test"));
    KvjEngine *engine = kvj_engine_new(data.toUtf8().constData(), nullptr, nullptr);
    const QJsonObject scan = command(engine, {{"cmd", "bluetooth_scan"}});
    write(QStringLiteral("scan ") + QJsonDocument(scan).toJson(QJsonDocument::Compact));
    int result = scan.contains("error") ? 1 : 0;
    const QJsonArray found = scan.value("ok").toArray();
    if (connect && !found.isEmpty()) {
        const QJsonObject device = found.first().toObject();
        write(QStringLiteral("connect ") + QJsonDocument(command(engine, {{"cmd", "bluetooth_connect"}, {"device", device}})).toJson(QJsonDocument::Compact));
        result = 1;
        for (int i = 0; i < 40 && result; ++i) {
            QThread::msleep(500);
            const QJsonObject status = command(engine, {{"cmd", "status"}}).value("ok").toObject();
            const QJsonObject peer = status.value("connections").toObject().value("outgoing").toArray().first().toObject();
            const QJsonObject link = peer.value("link").toObject();
            write(QStringLiteral("link %1 %2").arg(link.value("state").toString(), link.value("error").toString()));
            if (link.value("state").toString() == QLatin1String("connected") && !send)
                result = 0;
            // Sending needs the receiver to make this computer its current DJ.
            if (send && peer.value("selected").toBool()) {
                const QJsonObject started = command(engine, {{"cmd", "send_start"}, {"peer", device.value("id")}, {"device", "test-signal"}});
                write(QStringLiteral("send ") + QJsonDocument(started).toJson(QJsonDocument::Compact));
                for (int j = 0; j < 20; ++j) {
                    QThread::msleep(500);
                    const QJsonObject view = command(engine, {{"cmd", "status"}}).value("ok").toObject();
                    const QJsonObject sending = view.value("bluetooth").toObject();
                    write(QStringLiteral("sending %1 phase=%2 packets=%3 %4").arg(sending.value("state").toString(), view.value("phase").toString())
                              .arg(sending.value("packets").toInt()).arg(view.value("error").toString()));
                }
                command(engine, {{"cmd", "stop"}});
                result = 0;
                break;
            }
        }
    } else if (connect) {
        result = 1;
    }
    kvj_engine_free(engine);
    write(QStringLiteral("result %1").arg(result));
    return result;
}

} // namespace

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setOrganizationName(QStringLiteral("kumo"));
    QGuiApplication::setApplicationName(QStringLiteral("KVJ"));
    QGuiApplication::setApplicationDisplayName(QStringLiteral("KVJ"));
    QGuiApplication::setApplicationVersion(QStringLiteral("0.1.0"));
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    const QStringList args = app.arguments();
    for (const QString flag : {QStringLiteral("--ble-scan-test"), QStringLiteral("--ble-connect-test"), QStringLiteral("--ble-send-test")}) {
        const int at = args.indexOf(flag);
        if (at > 0 && at + 1 < args.size())
            return bluetoothTest(args.at(at + 1), flag != QLatin1String("--ble-scan-test"), flag == QLatin1String("--ble-send-test"));
    }

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("KVJ", "Main");

    // Development aid: KVJ_SNAPSHOT=<file.png> saves the control window and quits.
    const QString snapshot = qEnvironmentVariable("KVJ_SNAPSHOT");
    if (!snapshot.isEmpty() && !engine.rootObjects().isEmpty()) {
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        QTimer::singleShot(2500, &app, [window, snapshot] {
            if (window)
                window->grabWindow().save(snapshot);
            QCoreApplication::quit();
        });
    }
    // Development aid: KVJ_DEV_DIR=<dir> lets a shell on this computer see the
    // running app without screen access. Every second <dir>/status.json gets the
    // engine's view, the presented match, the timeline's playhead and the latest
    // log lines; creating <dir>/snap saves the control window to <dir>/window.png.
    const QString devDir = qEnvironmentVariable("KVJ_DEV_DIR");
    if (!devDir.isEmpty() && !engine.rootObjects().isEmpty()) {
        QDir().mkpath(devDir);
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        auto *kvj = engine.singletonInstance<Engine *>("KVJ", "Engine");
        auto *tick = new QTimer(&app);
        QObject::connect(tick, &QTimer::timeout, &app, [devDir, window, kvj] {
            const QDir dir(devDir);
            QJsonObject status{{"at", QDateTime::currentDateTime().toString(Qt::ISODateWithMs)},
                               {"clock_ms", Engine::clockMs()}};
            if (kvj) {
                const QStringList logs = kvj->logs();
                status.insert("view", QJsonObject::fromVariantMap(kvj->view()));
                status.insert("matched", QJsonObject::fromVariantMap(kvj->matched()));
                status.insert("error", kvj->error());
                status.insert("logs", QJsonArray::fromStringList(logs.mid(qMax(0, logs.size() - 30))));
            }
            if (QObject *timeline = window ? window->findChild<QObject *>("timeline") : nullptr) {
                status.insert("timeline", QJsonObject{
                    {"position", timeline->property("position").toDouble()},
                    {"playing", timeline->property("playingId").toString()},
                    {"lanes", timeline->property("lanes").toList().size()},
                    {"running", timeline->property("running").toBool()},
                });
            }
            QSaveFile out(dir.filePath("status.json"));
            if (out.open(QIODevice::WriteOnly)) {
                out.write(QJsonDocument(status).toJson());
                out.commit();
            }
            if (window && QFile::exists(dir.filePath("snap"))) {
                QFile::remove(dir.filePath("snap"));
                window->grabWindow().save(dir.filePath("window.png"));
            }
        });
        tick->start(1000);
    }
    return app.exec();
}
