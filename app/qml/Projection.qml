import QtQuick
import QtQuick.Window
import KVJ

// The projected output: the followed video, the title of an audio-only entry,
// and the live overlay. It carries no controls or status.
Window {
    id: root
    title: "KVJ 投放"
    color: "black"
    width: 960
    height: 540

    property real offsetMs: 0
    property int maxHeight: 720
    property int maxFps: 30
    property alias overlay: overlay
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

    VideoSurface {
        id: surface
        anchors.fill: parent
        // Nothing is decoded while the output is put away.
        source: root.visible && root.entry && root.entry.video ? root.entry.path : ""
        maxHeight: root.maxHeight
        maxFps: root.maxFps
        position: root.match ? root.match.position : 0
        rate: root.match ? root.match.rate : 1
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
        font.pixelSize: Math.max(28, root.height / 12)
        font.weight: Font.DemiBold
    }
    Overlay {
        id: overlay
        anchors.fill: parent
    }
    Shortcut {
        sequence: "Esc"
        enabled: root.visibility === Window.FullScreen
        onActivated: root.showNormal()
    }
}
