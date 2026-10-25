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
    // Closed by the system (its key, Alt+F4): it stays up and asks (Main.qml);
    // closeOutput() puts it away.
    signal closeAsked()
    property bool guarded: true
    onClosing: close => {
        if (root.guarded && root.visible) {
            close.accepted = false
            root.closeAsked()
        }
    }

    // The screen it was opened on, by name. That screen gone (a cable pulled, a
    // projector off), the system would move the picture onto the operator's
    // screen over the desk: it is put away instead and waits, and comes back
    // on that screen the way it was once it is there again.
    property string screenName: ""
    property bool wantsFullScreen: false
    property bool waiting: false
    Connections {
        target: Qt.application
        function onScreensChanged() { Qt.callLater(root.followScreens) }
    }
    function followScreens() {
        const screens = Qt.application.screens
        const at = screens.findIndex(s => s.name === root.screenName)
        if (root.visible && at < 0 && root.screenName !== "") {
            root.waiting = true
            if (visibility === Window.FullScreen)
                showNormal()
            hide()
        } else if (root.waiting && at >= 0) {
            openOn(at, root.wantsFullScreen)
        }
    }

    function openOn(screenIndex, fullscreen) {
        const screens = Qt.application.screens
        if (!screens.length)
            return
        const target = screens[Math.max(0, Math.min(screenIndex, screens.length - 1))]
        screenName = target.name
        wantsFullScreen = fullscreen
        waiting = false
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
        waiting = false
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
