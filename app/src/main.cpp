#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setOrganizationName(QStringLiteral("kumo"));
    QGuiApplication::setApplicationName(QStringLiteral("KVJ"));
    QGuiApplication::setApplicationDisplayName(QStringLiteral("KVJ"));
    QGuiApplication::setApplicationVersion(QStringLiteral("0.1.0"));
    QQuickStyle::setStyle(QStringLiteral("Basic"));

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
    return app.exec();
}
