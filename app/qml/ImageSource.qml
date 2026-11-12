import QtQuick
import KVJ

// A picture from 预备 as a picture source (a layer, `image:<file URL>`): drawn
// fitted inside this item's box, as VideoSurface and CameraSurface draw
// theirs, for SourceTextures to take (its `sourceSize` gives the shape). Each
// window that shows it holds its own: the projection, decoded at most `rows`
// tall (a photo from a camera is not held at its full size), and the
// operator's window, smaller. A GIF or WebP that moves (Motion.plays) plays
// on and on, each frame decoded when due.
Item {
    id: root

    required property string key
    property int rows: 1440
    readonly property url url: key.startsWith("image:") ? key.substring(6) : ""
    readonly property bool moving: Motion.revision >= 0 && Motion.plays(url)
    readonly property Item shown: moving ? motion : still
    readonly property size sourceSize: shown.implicitWidth > 0 && shown.implicitHeight > 0
                                       ? Qt.size(shown.implicitWidth, shown.implicitHeight) : Qt.size(0, 0)
    readonly property bool hasFrame: shown.status === Image.Ready
    readonly property string error: shown.status === Image.Error ? "无法读取" : ""

    Image {
        id: still
        anchors.fill: parent
        visible: !root.moving
        source: visible ? root.url : ""
        sourceSize.height: root.rows
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
    }
    AnimatedImage {
        id: motion
        anchors.fill: parent
        visible: root.moving
        cache: false
        source: visible ? root.url : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
        // Round and round, as a sticker does (Sticker.qml).
        onPlayingChanged: if (!playing) again.restart()
        onStatusChanged: if (status === AnimatedImage.Ready) again.restart()
        Timer {
            id: again
            interval: 50
            onTriggered: if (!motion.playing && motion.visible && motion.status === AnimatedImage.Ready && motion.frameCount > 1) motion.playing = true
        }
    }
}
