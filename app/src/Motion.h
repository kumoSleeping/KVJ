#pragma once

// Whether a sticker's image plays as an animation (AnimatedImage) or shows as
// a still picture (Image). Decided by the file's content, not its name: QQ and
// WeChat save GIFs as .png or .jpg. A moving one is decoded frame by frame on
// the GUI thread, once for the projection and once for each preview, so only
// files within the limits below play; larger, longer or unreadable ones show
// their first frame (or "无法读取"), decoded off the GUI thread as before.
//
// The file is read on a thread of its own, never on the GUI thread: opening
// one can wait (a network disk, a disk asleep, macOS asking for access to
// another app's files). Until it is read the picture shows still; `revision`
// then changes and bindings that called plays() ask again.

#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QtQml/qqmlregistration.h>
#include <memory>

class Motion : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int revision READ revision NOTIFY changed)

public:
    // At most this many pixels a frame (the image's full size), this many
    // frames and this large a file. A 1280×720 GIF frame takes ~5 ms to decode
    // on an M1, a 1920×1080 one 11–21 ms, three times over.
    static constexpr qint64 maxPixels = 1280 * 720;
    static constexpr int maxSide = 4096;
    static constexpr int maxFrames = 3000;
    static constexpr qint64 maxBytes = 48LL * 1024 * 1024;

    explicit Motion(QObject *parent = nullptr);
    ~Motion() override;

    // A local GIF or animated WebP within the limits, with more than one frame,
    // as far as known now (false until the file is read; read again when asked
    // after a while, in case it changed).
    Q_INVOKABLE bool plays(const QUrl &url);
    // Reads the file at `path` (any thread); `why` gets the reason a moving
    // picture is held still (empty when it is simply a still one).
    static bool probe(const QString &path, QString *why = nullptr);
    int revision() const { return m_revision; }

signals:
    void changed();

private:
    struct Known
    {
        bool known = false;
        bool plays = false;
        bool asked = false;
        qint64 at = 0;
    };
    // Shared with the reading threads: they post back only while this lives.
    struct Link;
    void next();
    void probed(const QString &path, bool plays, const QString &why);

    QHash<QString, Known> m_known;
    QStringList m_queue;
    int m_reading = 0;
    int m_revision = 0;
    QElapsedTimer m_clock;
    std::shared_ptr<Link> m_link;
};
