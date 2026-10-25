import QtQuick
import QtQuick.Window
import KVJ

// The projected output: the followed video, the title of an audio-only entry,
// the effects, stickers and live overlay (Stage). It carries no controls or
// status. The operator's preview copies its picture from `surface`.
Window {
    id: root
    title: "KVJ 投放"
    color: "black"
    width: 960
    height: 540

    property real offsetMs: 0
    property int maxHeight: 720
    property int maxFps: 30
    // The operator's preview is up: keep decoding even while this is put away.
    property bool previewing: false
    readonly property alias surface: surface
    readonly property var match: Engine.matched && Engine.matched.entry ? Engine.matched : null
    readonly property var entry: match ? match.entry : null

    function openOn(screenIndex, fullscreen) {
        const screens = Qt.application.screens
        const target = screens[Math.max(0, Math.min(screenIndex, screens.length - 1))]
        if (visibility === Window.FullScreen)
            showNormal()
        screen = target
        width = Math.min(960, target.width)
        height = Math.round(width * 9 / 16)
        x = target.virtualX + Math.round((target.width - width) / 2)
        y = target.virtualY + Math.round((target.height - height) / 2)
        if (fullscreen)
            showFullScreen()
        else
            show()
        raise()
    }
    function closeOutput() {
        if (visibility === Window.FullScreen)
            showNormal()
        hide()
    }

    Stage {
        anchors.fill: parent
        entry: root.entry
        VideoSurface {
            id: surface
            anchors.fill: parent
            // Nothing is decoded while neither the output nor the preview is up.
            source: (root.visible || root.previewing) && root.entry && root.entry.video ? root.entry.path : ""
            maxHeight: root.maxHeight
            maxFps: root.maxFps
            position: root.match ? root.match.position : 0
            rate: root.match ? root.match.rate : 1
            clockAtMs: root.match ? root.match.clock_at_ms : 0
            offsetMs: root.offsetMs
        }
    }
    Shortcut {
        sequence: "Esc"
        enabled: root.visibility === Window.FullScreen
        onActivated: root.showNormal()
    }
}
