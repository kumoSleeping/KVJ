import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// What smart following itself has decided, in the panel: a small picture and
// its progress through the entry, from the engine's match. While following
// draws the picture it is the same picture, copied from the projected one;
// while a helper is paused (the player draws the picture) it plays where the
// music is on a small decoder of its own, so the desk shows what is really
// playing and this what following hears. Empty while following is off or has
// not found the music yet.
ColumnLayout {
    id: root
    spacing: 4

    property bool active: false
    // Following draws the picture: copy it instead of decoding it again.
    property bool mirror: false
    property var match: null
    property real offsetMs: 0
    property VideoSurface source

    readonly property var entry: active && match ? match.entry : null
    readonly property bool shown: Window.window ? Window.window.visible : false
    property real now: 0
    readonly property real at: match ? match.position + (now - match.clock_at_ms + offsetMs) / 1000 * match.rate : 0
    readonly property real duration: entry ? entry.duration : 0

    Timer {
        interval: 100
        repeat: true
        triggeredOnStart: true
        running: !!root.entry && root.shown
        onTriggered: root.now = Engine.clockMs()
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: width * 9 / 16
        radius: Theme.radius
        color: "black"
        clip: true

        // Under the picture of its own as well, until that has its first frame.
        PreviewSurface {
            anchors.fill: parent
            source: root.entry && root.entry.video && (root.mirror || !own.hasFrame) ? root.source : null
            fps: 12
            visible: !!source
        }
        VideoSurface {
            id: own
            anchors.fill: parent
            visible: !root.mirror
            source: !root.mirror && root.shown && root.entry && root.entry.video ? root.entry.path : ""
            maxHeight: 240
            maxFps: 24
            position: root.match ? root.match.position : 0
            rate: root.match ? root.match.rate : 0
            clockAtMs: root.match ? root.match.clock_at_ms : 0
            offsetMs: root.offsetMs
        }
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: !!root.entry && !root.entry.video
            text: root.entry ? root.entry.title : ""
            color: "white"
            font.pixelSize: Theme.sizeSm
            font.weight: Font.DemiBold
        }
    }

    // Where in the entry following puts the music.
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 3
        radius: 1.5
        color: Theme.line
        Rectangle {
            width: root.duration > 0 ? parent.width * Math.max(0, Math.min(1, root.at / root.duration)) : 0
            height: parent.height
            radius: 1.5
            color: Theme.text
        }
    }
}
