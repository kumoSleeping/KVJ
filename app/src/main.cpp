#include "Engine.h"
#include "TitleBar.h"
#include "kvj.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QThread>
#include <QQmlApplicationEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSaveFile>
#include <QTimer>

namespace {

bool isTextBox(const QQuickItem *item)
{
    return item && (item->inherits("QQuickTextInput") || item->inherits("QQuickTextEdit"));
}

// The window on screen: the player's, or the sender's while it stands in.
QQuickWindow *shownWindow()
{
    for (QWindow *window : QGuiApplication::topLevelWindows()) {
        auto *quick = qobject_cast<QQuickWindow *>(window);
        if (quick && quick->isVisible() && quick->title().startsWith(QLatin1String("KVJ"))
            && quick->title() != QLatin1String("KVJ 投放"))
            return quick;
    }
    return nullptr;
}

// A press anywhere but in the text box being typed in leaves it: the box
// keeps no focus that would hold the player's keys off (they rest while words
// are typed). Pressing another box gives it the focus as usual; Esc leaves the
// box too. The box lets go of the focus itself: the window's root item takes
// none when forced.
class LeaveTyping : public QObject
{
public:
    using QObject::QObject;

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() == QEvent::MouseButtonPress) {
            auto *window = qobject_cast<QQuickWindow *>(watched);
            QQuickItem *typing = window ? window->activeFocusItem() : nullptr;
            if (isTextBox(typing)) {
                const QPointF at = typing->mapFromScene(static_cast<QMouseEvent *>(event)->scenePosition());
                if (!typing->contains(at))
                    typing->setFocus(false, Qt::MouseFocusReason);
            }
        }
        // Esc reaches the box as a shortcut override first, before any Esc
        // shortcut takes it; as a press when no shortcut looked.
        if ((event->type() == QEvent::ShortcutOverride || event->type() == QEvent::KeyPress)
            && static_cast<QKeyEvent *>(event)->key() == Qt::Key_Escape) {
            auto *item = qobject_cast<QQuickItem *>(watched);
            if (isTextBox(item) && item->hasActiveFocus())
                item->setFocus(false, Qt::OtherFocusReason);
        }
        return false;
    }
};

// Space only types a space. Elsewhere it is dropped: a key, check or list
// keeps the focus once pressed, and Space would press it again (open the
// last file dialog, toggle play) — one touch of it during a show is too easy.
class QuietSpace : public QObject
{
public:
    using QObject::QObject;

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() == QEvent::KeyPress || event->type() == QEvent::KeyRelease) {
            auto *window = qobject_cast<QQuickWindow *>(watched);
            if (window && static_cast<QKeyEvent *>(event)->key() == Qt::Key_Space)
                return !isTextBox(window->activeFocusItem());
        }
        return false;
    }
};

// A nudge lasts while its key is held (Main.qml), and a Shortcut hears only
// the press: the release of ←/→, A/D or 4/6 on the number pad goes to the
// window's letGo, -1 for back and 1 for ahead.
class NudgeRelease : public QObject
{
public:
    NudgeRelease(QObject *window, QObject *parent) : QObject(parent), m_window(window) {}

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() == QEvent::KeyRelease && qobject_cast<QQuickWindow *>(watched)) {
            auto *key = static_cast<QKeyEvent *>(event);
            const bool pad = key->modifiers() & Qt::KeypadModifier;
            int direction = 0;
            if (key->key() == Qt::Key_Left || key->key() == Qt::Key_A || (pad && key->key() == Qt::Key_4))
                direction = -1;
            else if (key->key() == Qt::Key_Right || key->key() == Qt::Key_D || (pad && key->key() == Qt::Key_6))
                direction = 1;
            if (direction && !key->isAutoRepeat())
                QMetaObject::invokeMethod(m_window, "letGo", Q_ARG(QVariant, direction));
        }
        return false;
    }

private:
    QObject *m_window;
};

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
    // The picture's sound plays through the system's own media stack, like the
    // video; Qt's FFmpeg backend is not shipped.
    if (!qEnvironmentVariableIsSet("QT_MEDIA_BACKEND")) {
#if defined(Q_OS_MACOS)
        qputenv("QT_MEDIA_BACKEND", "darwin");
#elif defined(Q_OS_WIN)
        qputenv("QT_MEDIA_BACKEND", "windows");
#endif
    }
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
    // The player's own top bar in the title bar's row, where the system allows it.
    if (auto *window = engine.rootObjects().isEmpty() ? nullptr : qobject_cast<QWindow *>(engine.rootObjects().first())) {
        const TitleBarInset inset = unifyTitleBar(window);
        window->setProperty("titleInset", inset.left);
        window->setProperty("titleHeight", inset.height);
        window->setProperty("titleReachesContent", inset.reachesContent);
    }
    app.installEventFilter(new LeaveTyping(&app));
    app.installEventFilter(new QuietSpace(&app));
    if (!engine.rootObjects().isEmpty())
        app.installEventFilter(new NudgeRelease(engine.rootObjects().first(), &app));

    // Development aid: KVJ_SNAPSHOT=<file.png> saves the window on screen (the
    // player's, or the sender's with --send) and quits.
    const QString snapshot = qEnvironmentVariable("KVJ_SNAPSHOT");
    if (!snapshot.isEmpty() && !engine.rootObjects().isEmpty()) {
        QTimer::singleShot(2500, &app, [snapshot] {
            if (QQuickWindow *window = shownWindow())
                window->grabWindow().save(snapshot);
            QCoreApplication::quit();
        });
    }
    // Development aid: KVJ_DEV_DIR=<dir> lets a shell on this computer see the
    // running app without screen access. Every second <dir>/status.json gets the
    // engine's view, the presented match, the player, the timeline's playhead and
    // the latest log lines; creating <dir>/snap saves the window on screen to
    // <dir>/window.png, and a line written to <dir>/cmd goes to the window's
    // devCommand (Main.qml), its answer to <dir>/cmd.out.
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
            if (window) {
                const QVariant shown = window->property("shownEntry");
                status.insert("player", QJsonObject{
                    {"entry", shown.toMap().value("title").toString()},
                    {"playhead", window->property("playhead").toDouble()},
                    {"tempo", window->property("shownTempo").toDouble()},
                    {"following", window->property("following").toBool()},
                    {"paused_follow", window->property("followPaused").toBool()},
                    {"ai_picture", window->property("aiPicture").toBool()},
                    {"fade_ms", window->property("fadeOn").toBool() ? window->property("fadeMs").toInt() : 0},
                    {"visible", window->isVisible()},
                });
                status.insert("title_bar", QJsonObject{
                    {"height", window->property("titleHeight").toDouble()},
                    {"reaches_content", window->property("titleReachesContent").toBool()},
                });
            }
            if (QObject *timeline = window ? window->findChild<QObject *>("timeline") : nullptr) {
                status.insert("timeline", QJsonObject{
                    {"position", timeline->property("position").toDouble()},
                    {"playing", timeline->property("playingId").toString()},
                    {"lanes", timeline->property("lanes").toList().size()},
                    {"running", timeline->property("running").toBool()},
                    {"parked", timeline->property("parked").toBool()},
                });
            }
            QSaveFile out(dir.filePath("status.json"));
            if (out.open(QIODevice::WriteOnly)) {
                out.write(QJsonDocument(status).toJson());
                out.commit();
            }
            QFile cmd(dir.filePath("cmd"));
            if (window && cmd.open(QIODevice::ReadOnly)) {
                const QString line = QString::fromUtf8(cmd.readAll()).trimmed();
                cmd.remove();
                QVariant answer;
                QMetaObject::invokeMethod(window, "devCommand", Q_RETURN_ARG(QVariant, answer), Q_ARG(QVariant, line));
                QSaveFile reply(dir.filePath("cmd.out"));
                if (reply.open(QIODevice::WriteOnly)) {
                    reply.write((line + QStringLiteral(" -> ") + answer.toString() + QLatin1Char('\n')).toUtf8());
                    reply.commit();
                }
            }
            if (QFile::exists(dir.filePath("snap"))) {
                QFile::remove(dir.filePath("snap"));
                if (QQuickWindow *shown = shownWindow())
                    shown->grabWindow().save(dir.filePath("window.png"));
            }
        });
        tick->start(1000);
    }
    return app.exec();
}
