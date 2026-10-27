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
    // The aux tracks' pictures (画面 2..4): what each shows and where, as
    // { entry, position, rate, clockAtMs, offsetMs } (Main.auxTiming).
    property var auxTimings: [null, null, null]
    // Cameras taken in as sources, by device id.
    property var cameraIds: []
    // What each camera says is wrong, by device id ("" while it shows).
    readonly property var cameraErrors: {
        root.sourceRevision
        const out = {}
        for (let i = 0; i < cameraBank.count; ++i) {
            const c = cameraBank.itemAt(i)
            if (c)
                out[c.deviceId] = c.error
        }
        return out
    }
    // Sources the operator's window shows besides those on the air: decoded
    // too while it is up.
    property var wantedIds: []
    // On the air now (slots left on the stage around the picture are not),
    // and the layout a dissolve leaves.
    readonly property var programIds: Switcher.shownSourcesOf(Switcher.program).concat(
                                          Switcher.transition ? Switcher.shownSourcesOf(Switcher.transition.from) : [])
    function wants(id) {
        return programIds.indexOf(id) >= 0 || (root.previewing && wantedIds.indexOf(id) >= 0)
    }
    // The item that shows a source here, or null; `sourceRevision` moves when
    // the answer may have changed.
    property int sourceRevision: 0
    function sourceItem(id) {
        if (id === "track:0")
            return surface
        if (id.startsWith("track:"))
            return auxBank.itemAt(Number(id.substring(6)) - 1)
        if (id.startsWith("camera:")) {
            const device = id.substring(7)
            for (let i = 0; i < cameraBank.count; ++i) {
                const c = cameraBank.itemAt(i)
                if (c && c.deviceId === device)
                    return c
            }
        }
        return null
    }
    SourceTextures {
        id: textures
        sourceItem: root.sourceItem
        ids: root.programIds
    }
    // The picture's shape as the audience sees it: the window's while it is
    // up, else the screen it would fill or the 16:9 window it would open as.
    // The operator's preview takes the same shape, so a sticker sits in the
    // same place on both.
    property bool fullscreenNext: false
    property var screenNext: null
    readonly property real aspect: visible && height > 0 ? width / height
                                   : fullscreenNext && screenNext && screenNext.height > 0 ? screenNext.width / screenNext.height
                                   : 16 / 9
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

    // The picture is the program (Switcher): the sources composed by its
    // layout. The sources themselves lie under a black cover, drawn only
    // through it; the effects work on the composed picture.
    Stage {
        id: stage
        anchors.fill: parent
        entry: root.entry
        // The main track: the player's or following's.
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
        // The aux tracks, decoded only while on the air or watched.
        Repeater {
            id: auxBank
            model: 3
            onItemAdded: root.sourceRevision += 1
            VideoSurface {
                required property int index
                readonly property var timing: root.auxTimings[index] || null
                readonly property var entry: timing ? timing.entry : null
                anchors.fill: parent
                source: (root.visible || root.previewing) && !!entry && entry.video && root.wants("track:" + (index + 1)) ? entry.path : ""
                maxHeight: root.maxHeight
                maxFps: root.maxFps
                position: timing ? timing.position : 0
                rate: timing ? timing.rate : 0
                clockAtMs: timing ? timing.clockAtMs : 0
                offsetMs: timing ? timing.offsetMs : 0
                fadeMs: timing && timing.cut ? 0 : root.fadeMs
            }
        }
        IdList {
            id: cameraList
            ids: root.cameraIds
        }
        Repeater {
            id: cameraBank
            model: cameraList.model
            onItemAdded: root.sourceRevision += 1
            onItemRemoved: root.sourceRevision += 1
            // A camera taken in runs until it is let go, here or not, on the
            // air or not: starting and stopping one holds up the picture.
            // It only converts its frames while something shows them.
            CameraSurface {
                required property string key
                anchors.fill: parent
                deviceId: key
                active: true
            }
        }
        Rectangle {
            anchors.fill: parent
            color: "black"
        }
        Program {
            anchors.fill: parent
            now: stage.now
            textures: textures
        }
    }
    onSourceRevisionChanged: textures.refresh()
    Shortcut {
        sequence: "Esc"
        enabled: root.visibility === Window.FullScreen
        onActivated: root.showNormal()
    }
}
