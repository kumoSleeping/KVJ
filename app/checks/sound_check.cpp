// Headless check of the picture's sound (AudioFollower): play a file at volume
// 0 on the default output while the picture's timing changes as the player
// changes it (speed steps, a nudge, back to 1), with KVJ_SOUND_LOG on, so its
// log shows how far the sound stays from the picture and that no change of
// speed seeks or starves the output.
//   kvj-sound-check <media> [start seconds]
#include "AudioFollower.h"
#include "kvj.h"

#include <QGuiApplication>
#include <QTextStream>
#include <QTimer>

int main(int argc, char *argv[])
{
    qputenv("KVJ_SOUND_LOG", "1");
    QGuiApplication app(argc, argv);
    QTextStream out(stdout);
    const QStringList args = app.arguments().mid(1);
    if (args.isEmpty()) {
        out << "usage: kvj-sound-check <media> [start seconds]\n";
        return 2;
    }
    const double start = args.size() > 1 ? args[1].toDouble() : 60;

    AudioFollower sound;
    sound.setVolume(0);
    double position = start;
    double clockAt = kvj_clock_ms();
    double rate = 1;
    auto timing = [&] {
        sound.setProperty("position", position);
        sound.setProperty("clockAtMs", clockAt);
        sound.setProperty("rate", rate);
    };
    // As Transport does: re-anchored where it is, then the new rate.
    auto setRate = [&](double next) {
        const double now = kvj_clock_ms();
        position += (now - clockAt) / 1000 * rate;
        clockAt = now;
        rate = next;
        timing();
        out << "— rate " << next << Qt::endl;
    };
    timing();
    sound.setSource(args.first());
    sound.setEnabled(true);

    const QList<QPair<int, double>> steps = {
        {3000, 1.2}, {6000, 0.9}, {9000, 1.01}, {10000, 1.02}, {11000, 1.03},
        // A nudge: half again as fast for two seconds.
        {13000, 1.5}, {15000, 1.0}, {18000, 0.5}, {20000, 1.0},
    };
    for (const auto &step : steps)
        QTimer::singleShot(step.first, &app, [&, step] { setRate(step.second); });
    QTimer::singleShot(24000, &app, [&] {
        out << "error: " << (sound.error().isEmpty() ? QStringLiteral("none") : sound.error()) << Qt::endl;
        app.quit();
    });
    return app.exec();
}
