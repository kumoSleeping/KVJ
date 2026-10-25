import QtQuick
import QtQuick.Window
import KVJ

// The projected output: the player's video (its own clock, or the engine's match
// while smart following leads), the title of an audio-only entry, the effects,
// stickers and live overlay (Stage). It carries no controls or status. The
// operator's monitor and preview copy their picture from `surface`.
Window {
    id: root
    title: "KVJ 投放"
    color: "black"
    width: 960
    height: 540

    // What to show and where it is: `position` seconds at `clockAtMs` on the
    // engine's clock, moving at `rate` (0 while paused).
    property var entry: null
    property real position: 0
    property real rate: 1
    property real clockAtMs: 0
    property real offsetMs: 0
    // Dissolve into the picture after a jump (0 = cut).
    property int fadeMs: 0
    property int maxHeight: 720
    property int maxFps: 30
    // The operator's preview is up: keep decoding even while this is put away.
    property bool previewing: false
    readonly property alias surface: surface

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
            position: root.position
            rate: root.rate
            clockAtMs: root.clockAtMs
            offsetMs: root.offsetMs
            fadeMs: root.fadeMs
        }
    }
    Shortcut {
        sequence: "Esc"
        enabled: root.visibility === Window.FullScreen
        onActivated: root.showNormal()
    }
}
