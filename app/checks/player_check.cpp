// Headless check of the system decoder and VideoPlayer: follow a moving target at
// 60 Hz from several start points, including jumps back and ahead, and report the
// time to the first frame, frames shown per second and how late they were.
//   kvj-player-check <video> [start seconds]...
#include "VideoPlayer.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QTextStream>
#include <QThread>

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    const QStringList args = app.arguments().mid(1);
    if (args.isEmpty()) {
        out << "usage: kvj-player-check <video> [start seconds]...\n";
        return 2;
    }
    QList<double> starts;
    for (const QString &arg : args.mid(1))
        starts << arg.toDouble();
    if (starts.isEmpty())
        starts = {0, 30, 5, 60.5};

    DecodeOptions options;
    options.maxHeight = qEnvironmentVariableIntValue("KVJ_MAX_HEIGHT");
    VideoPlayer player(args.first(), options);
    int failures = 0;
    for (const double start : starts) {
        QElapsedTimer clock;
        clock.start();
        double first = -1, worstLate = 0;
        int shown = 0, ticks = 0;
        QSize size;
        while (clock.elapsed() < 1500) {
            ++ticks;
            const double target = start + clock.elapsed() / 1000.0;
            VideoFrame frame;
            if (player.frameFor(target, &frame)) {
                if (first < 0) {
                    first = clock.elapsed();
                    size = frame.image.size();
                } else {
                    ++shown;
                    worstLate = std::max(worstLate, target - frame.pts);
                }
            }
            QThread::usleep(4000);
        }
        if (!player.error().isEmpty())
            out << "error: " << player.error() << "\n";
        const bool ok = first >= 0 && shown > 10;
        failures += ok ? 0 : 1;
        out << QStringLiteral("start %1 s · first frame %2 ms · %3×%4 · %5 frames/s after · worst lag %6 ms · %7 polls/s · %8\n")
                   .arg(start, 0, 'f', 1).arg(first).arg(size.width()).arg(size.height())
                   .arg(shown / ((1500 - std::max(0.0, first)) / 1000.0), 0, 'f', 1)
                   .arg(worstLate * 1000, 0, 'f', 1).arg(ticks / 1.5, 0, 'f', 0).arg(ok ? "ok" : "FAIL");
        out.flush();
    }
    return failures ? 1 : 0;
}
