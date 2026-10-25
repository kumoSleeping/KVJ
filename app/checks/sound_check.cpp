// Headless check of the picture's sound (AudioFollower): play a file at volume
// 0 on the default output while the picture's timing changes as the player
// changes it (speed steps, nudges, back to 1), with KVJ_SOUND_LOG on, so its
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
        // Nudges: four times as fast for a third of a second (twice in a
        // row), a tenth of the speed for a little over a second.
        {13000, 4.0}, {13333, 1.0}, {14000, 4.0}, {14666, 1.0}, {16000, 0.1}, {17111, 1.0},
        {19000, 1.5}, {21000, 1.0},
    };
    // A jump, as a seek on the timeline: thirty seconds on.
    QTimer::singleShot(22500, &app, [&] {
        const double now = kvj_clock_ms();
        position += (now - clockAt) / 1000 * rate + 30;
        clockAt = now;
        timing();
        out << "— jump +30 s" << Qt::endl;
    });
    for (const auto &step : steps)
        QTimer::singleShot(step.first, &app, [&, step] { setRate(step.second); });
    QTimer::singleShot(26000, &app, [&] {
        out << "error: " << (sound.error().isEmpty() ? QStringLiteral("none") : sound.error()) << Qt::endl;
        app.quit();
    });
    return app.exec();
}
