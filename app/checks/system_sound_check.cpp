// Headless check of the system's decoders reading the sound symphonia cannot
// (SystemSound.h): each file is opened for playing through the engine, as the
// app does, and read to the end. It must last about `seconds` and be a sound,
// neither silence nor noise.
//   kvj-system-sound-check <cache dir> <seconds> <media>...
#include "SystemSound.h"
#include "kvj.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QTextStream>

#include <algorithm>
#include <cmath>
#include <vector>

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    const QStringList args = app.arguments().mid(1);
    if (args.size() < 3) {
        out << "usage: kvj-system-sound-check <cache dir> <seconds> <media>...\n";
        return 2;
    }
    useSystemSound(args[0]);
    const double expected = args[1].toDouble();
    int failed = 0;
    for (const QString &file : args.mid(2)) {
        const QString name = QFileInfo(file).fileName().leftJustified(24);
        const QByteArray path = QDir::toNativeSeparators(file).toUtf8();
        const double told = systemSound(path.constData(), nullptr);
        uint32_t rate = 0;
        double duration = 0;
        KvjSound *sound = kvj_sound_open(path.constData(), &rate, &duration);
        if (!sound) {
            out << name << " FAIL no sound (system: " << told << " s)" << Qt::endl;
            ++failed;
            continue;
        }
        std::vector<float> frames(2 * 4096);
        size_t total = 0;
        float peak = 0;
        double energy = 0;
        for (;;) {
            const size_t n = kvj_sound_read(sound, frames.data(), 4096);
            for (size_t i = 0; i < n * 2; ++i) {
                peak = std::max(peak, std::abs(frames[i]));
                energy += double(frames[i]) * frames[i];
            }
            total += n;
            if (n < 4096)
                break;
        }
        kvj_sound_free(sound);
        const double seconds = rate ? double(total) / rate : 0;
        const double rms = total ? std::sqrt(energy / (2.0 * total)) : 0;
        // The samples are a tone well below full scale: noise read as samples
        // (wrong byte order) is near or past it, silence is nothing.
        const bool ok = std::abs(seconds - expected) < 0.25 && peak > 0.01 && peak < 0.9 && rms > 0.003;
        out << name << (ok ? " OK   " : " FAIL ") << seconds << " s " << rate << " Hz peak " << peak << " rms " << rms
            << " (system: " << told << " s)" << Qt::endl;
        if (!ok)
            ++failed;
    }
    return failed ? 1 : 0;
}
