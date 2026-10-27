#pragma once

// Small frames from one video, side by side, for the timeline: the frames at
// even steps of media time, the step following the zoom so that they sit edge
// to edge. Frames are decoded small (kHeight px) on one low-priority thread
// shared by every strip and kept up to a fixed memory budget; until a frame is
// ready the nearest one already decoded from the same file stands in.

#include <QHash>
#include <QImage>
#include <QList>
#include <QMutex>
#include <QObject>
#include <QQuickPaintedItem>
#include <QSet>
#include <QWaitCondition>

#include <map>

class QThread;

class FrameCache : public QObject
{
    Q_OBJECT
public:
    static constexpr int kHeight = 120;
    static FrameCache *instance();
    ~FrameCache() override;

    // What `owner` shows now, most wanted first; replaces what it wanted before.
    void want(const void *owner, const QString &path, const QList<qint64> &ms);
    void forget(const void *owner);
    // The frame at `ms`, or else the nearest decoded one of the file (`exact`
    // false); null while the file has none yet.
    QImage frame(const QString &path, qint64 ms, bool *exact);
    // Width over height of the file's frames, 0 until one is decoded.
    double aspect(const QString &path);

signals:
    void ready(const QString &path);

private:
    explicit FrameCache(QObject *parent);
    void run();
    void trim();

    struct Thumb
    {
        QImage image;
        quint64 used = 0;
    };
    struct Wish
    {
        QString path;
        QList<qint64> ms;
        quint64 at = 0;
    };

    QMutex m_mutex;
    QWaitCondition m_wake;
    bool m_stop = false;
    QHash<const void *, Wish> m_wishes;
    QHash<QString, std::map<qint64, Thumb>> m_thumbs;
    QHash<QString, double> m_aspect;
    QSet<QString> m_failed; // "path|ms", or a path that cannot be opened
    qint64 m_bytes = 0;
    quint64 m_serial = 0;
    QThread *m_thread = nullptr;
};

class FilmStrip : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(double duration READ duration WRITE setDuration NOTIFY viewChanged)
    // Media seconds at the left edge, and how many pixels a second takes.
    Q_PROPERTY(double from READ from WRITE setFrom NOTIFY viewChanged)
    Q_PROPERTY(double pxPerSec READ pxPerSec WRITE setPxPerSec NOTIFY viewChanged)
    Q_PROPERTY(QColor gap MEMBER m_gap NOTIFY viewChanged)
    // Width over height of each frame's cell (0 = the frames' own): narrower
    // cells show the middle of each frame and fit more of them.
    Q_PROPERTY(double cellAspect READ cellAspect WRITE setCellAspect NOTIFY viewChanged)

public:
    explicit FilmStrip(QQuickItem *parent = nullptr);
    ~FilmStrip() override;

    QString source() const { return m_source; }
    void setSource(const QString &source);
    double duration() const { return m_duration; }
    void setDuration(double seconds);
    double from() const { return m_from; }
    void setFrom(double seconds);
    double pxPerSec() const { return m_pxPerSec; }
    void setPxPerSec(double px);
    double cellAspect() const { return m_cellAspect; }
    void setCellAspect(double aspect);

    void paint(QPainter *painter) override;

signals:
    void sourceChanged();
    void viewChanged();

protected:
    void geometryChange(const QRectF &next, const QRectF &old) override;
    void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
    // Seconds between frames for the current zoom, and the frames in view.
    double step() const;
    qint64 cellMs(qint64 k, double s) const;
    void refresh();

    QString m_source;
    double m_duration = 0;
    double m_from = 0;
    double m_pxPerSec = 10;
    QColor m_gap = Qt::black;
    double m_cellAspect = 0;
};
