#pragma once

// The timeline's waveform: KDJ's whole-track preview (整曲预览) drawn along the
// timeline at its zoom. The engine analyses each file once (kvj_waveform, 100
// columns a second, cached on disk) on one low-priority thread shared by every
// strip; a pixel that covers many columns shows their energy, as KDJ's preview
// buckets do, and their height-weighted colour, as KDJ draws it. The same
// thread then finds where the file's tempo changes (kvj_tempo) for the lane
// above the frames, once every waveform asked for is drawn.

#include <QByteArray>
#include <QColor>
#include <QHash>
#include <QMutex>
#include <QObject>
#include <QQuickPaintedItem>
#include <QSet>
#include <QStringList>
#include <QVariantList>
#include <QWaitCondition>

#include <atomic>
#include <memory>

class QThread;

class WaveCache : public QObject
{
    Q_OBJECT
public:
    static constexpr double kRate = 100; // columns a second
    struct Wave
    {
        QByteArray bytes; // heights, then R, G and B: `columns` bytes each
        int columns = 0;
    };
    static WaveCache *instance();
    ~WaveCache() override;

    // The file's waveform once analysed; asks for it otherwise (null meanwhile,
    // and for good when the file has no audio).
    std::shared_ptr<const Wave> wave(const QString &path);
    bool failed(const QString &path);
    // The file's tempo sections, end to end over it: {start, end, bpm (null
    // where no beat holds), confidence}. Asks for them when not known yet.
    QVariantList tempo(const QString &path);
    // Being looked for: not known yet, and the file has not turned out to have no audio.
    bool findingTempo(const QString &path);

signals:
    void ready(const QString &path);

private:
    explicit WaveCache(QObject *parent);
    void run();

    QMutex m_mutex;
    QWaitCondition m_wake;
    std::atomic_bool m_stop{false};
    QStringList m_queue;
    QHash<QString, std::shared_ptr<const Wave>> m_waves;
    QSet<QString> m_failed;
    QStringList m_tempoQueue;
    QHash<QString, QVariantList> m_tempi;
    QSet<QString> m_tempoFailed;
    QString m_cacheDir;
    QThread *m_thread = nullptr;
};

class WaveStrip : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
    // Media seconds at the left edge, and how many pixels a second takes.
    Q_PROPERTY(double from READ from WRITE setFrom NOTIFY viewChanged)
    Q_PROPERTY(double pxPerSec READ pxPerSec WRITE setPxPerSec NOTIFY viewChanged)
    // What the strip lies on; the colours are pushed away from it a little, as in KDJ.
    Q_PROPERTY(QColor background READ background WRITE setBackground NOTIFY viewChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
    // Being analysed: no waveform yet, and the file has not turned out to have no audio.
    Q_PROPERTY(bool analysing READ analysing NOTIFY readyChanged)
    // Where the tempo changes along the file (WaveCache::tempo), and whether
    // that is still being looked for.
    Q_PROPERTY(QVariantList tempo READ tempo NOTIFY tempoChanged)
    Q_PROPERTY(bool findingTempo READ findingTempo NOTIFY tempoChanged)

public:
    explicit WaveStrip(QQuickItem *parent = nullptr);

    QString source() const { return m_source; }
    void setSource(const QString &source);
    double from() const { return m_from; }
    void setFrom(double seconds);
    double pxPerSec() const { return m_pxPerSec; }
    void setPxPerSec(double px);
    QColor background() const { return m_background; }
    void setBackground(const QColor &color);
    bool ready() const { return !!m_wave; }
    bool analysing() const { return m_analysing; }
    QVariantList tempo() const { return m_tempo; }
    bool findingTempo() const { return m_findingTempo; }

    void paint(QPainter *painter) override;

signals:
    void sourceChanged();
    void viewChanged();
    void readyChanged();
    void tempoChanged();

private:
    void fetch();

    QString m_source;
    double m_from = 0;
    double m_pxPerSec = 10;
    QColor m_background = Qt::white;
    std::shared_ptr<const WaveCache::Wave> m_wave;
    bool m_analysing = false;
    QVariantList m_tempo;
    bool m_findingTempo = false;
};
