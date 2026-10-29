#include "Engine.h"
#include "TitleBar.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QQmlApplicationEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSaveFile>
#include <QTimer>
#include <QMutex>
#include <QMutexLocker>

#ifdef Q_OS_UNIX
#include <sys/resource.h>
#endif

namespace {

// Every thread, decoder, camera, open folder and socket is a file descriptor or
// two, and a thread that cannot make its pipe ends KVJ at once (it did, at the
// Mac's default ceiling of 256). Ask for the most the system allows, up to
// 10240 (macOS's OPEN_MAX).
void raiseFileLimit()
{
#ifdef Q_OS_UNIX
    rlimit limit{};
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0)
        return;
    rlim_t wanted = 10240;
    if (limit.rlim_max != RLIM_INFINITY && limit.rlim_max < wanted)
        wanted = limit.rlim_max;
    if (limit.rlim_cur != RLIM_INFINITY && limit.rlim_cur < wanted) {
        limit.rlim_cur = wanted;
        setrlimit(RLIMIT_NOFILE, &limit);
    }
#endif
}

// Qt's own messages (QML errors, the camera's and the sound's notes) go to the
// data folder's logs as well as to stderr: a Windows build has no console, and
// what the window said last night is otherwise gone. One file a day,
// `logs/qt-<date>.log`, the ones older than two weeks removed at start.
QtMessageHandler stderrHandler = nullptr;

void logToDisk(QtMsgType type, const QMessageLogContext &context, const QString &text)
{
    static QMutex mutex;
    static QFile file;
    static QString day;
    static thread_local bool inside = false;
    if (!inside) {
        inside = true;
        QMutexLocker lock(&mutex);
        const QDateTime now = QDateTime::currentDateTime();
        const QString today = now.toString(QStringLiteral("yyyy-MM-dd"));
        if (today != day) {
            file.close();
            const QDir dir(Engine::defaultDataDir() + QStringLiteral("/logs"));
            QDir().mkpath(dir.path());
            file.setFileName(dir.filePath(QStringLiteral("qt-%1.log").arg(today)));
            file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text);
            day = today;
        }
        if (file.isOpen()) {
            const char *level = type == QtDebugMsg ? "debug" : type == QtInfoMsg ? "info"
                : type == QtWarningMsg ? "warn" : type == QtCriticalMsg ? "error" : "fatal";
            file.write((now.toString(QStringLiteral("HH:mm:ss.zzz ")) + QLatin1String(level) + QLatin1Char(' ')
                        + text + QLatin1Char('\n')).toUtf8());
            file.flush();
        }
        inside = false;
    }
    if (stderrHandler)
        stderrHandler(type, context, text);
}

void keepQtLogs()
{
    const QDir dir(Engine::defaultDataDir() + QStringLiteral("/logs"));
    const QDateTime oldest = QDateTime::currentDateTime().addDays(-14);
    for (const QFileInfo &info : dir.entryInfoList({QStringLiteral("qt-*.log")}, QDir::Files)) {
        if (info.lastModified() < oldest)
            QFile::remove(info.filePath());
    }
    stderrHandler = qInstallMessageHandler(logToDisk);
}

bool isTextBox(const QQuickItem *item)
{
    return item && (item->inherits("QQuickTextInput") || item->inherits("QQuickTextEdit"));
}

// The window on screen: the player's.
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
// the press: the release of ←/→ or A/D goes to the window's letGo, -1 for
// back and 1 for ahead. (The number pad's digits switch effects.)
class NudgeRelease : public QObject
{
public:
    NudgeRelease(QObject *window, QObject *parent) : QObject(parent), m_window(window) {}

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() == QEvent::KeyRelease && qobject_cast<QQuickWindow *>(watched)) {
            auto *key = static_cast<QKeyEvent *>(event);
            int direction = 0;
            if (key->key() == Qt::Key_Left || key->key() == Qt::Key_A)
                direction = -1;
            else if (key->key() == Qt::Key_Right || key->key() == Qt::Key_D)
                direction = 1;
            if (direction && !key->isAutoRepeat())
                QMetaObject::invokeMethod(m_window, "letGo", Q_ARG(QVariant, direction));
        }
        return false;
    }

private:
    QObject *m_window;
};

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
    raiseFileLimit();
    QGuiApplication app(argc, argv);
    QGuiApplication::setOrganizationName(QStringLiteral("kumo"));
    QGuiApplication::setApplicationName(QStringLiteral("KVJ"));
    QGuiApplication::setApplicationDisplayName(QStringLiteral("KVJ"));
    QQuickStyle::setStyle(QStringLiteral("Basic"));
    keepQtLogs();

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
    // Up and running a little while: an updater waiting for this version to
    // start (it otherwise puts the old one back) is told so.
    if (!engine.rootObjects().isEmpty()) {
        if (auto *kvj = engine.singletonInstance<Engine *>("KVJ", "Engine"))
            QTimer::singleShot(3000, kvj, &Engine::settleUpdate);
    }

    // Development aid: KVJ_SNAPSHOT=<file.png> saves the window on screen and
    // quits.
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
                // Written whole: a reader polling for it never gets half a picture.
                if (QQuickWindow *shown = shownWindow()) {
                    QSaveFile png(dir.filePath("window.png"));
                    if (png.open(QIODevice::WriteOnly) && shown->grabWindow().save(&png, "PNG"))
                        png.commit();
                }
            }
        });
        tick->start(1000);
    }
    return app.exec();
}
