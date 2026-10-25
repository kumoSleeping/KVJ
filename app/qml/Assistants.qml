import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The two helpers of smart following, at the panel's foot. One keeps the tempo
// with the music: its dot swings at the followed speed. The other watches
// whether the picture is still where the music is: its dot circles while all is
// well, it hops on a jump, and once the threshold is passed (the music went
// somewhere else, or went quiet) the ring ripples in amber until it is found.
// Each pauses on its own; the player then has that part of the picture, and
// the helper only listens: it stays lit and goes on judging, it just does not
// move the picture.
Rectangle {
    id: root
    implicitHeight: column.implicitHeight + 20
    radius: Theme.radiusLg
    color: Theme.inset

    // Smart following is on, and which helpers have handed their part back.
    property bool active: false
    property bool tempoPaused: false
    property bool jumpPaused: false
    // 跳转 paused and the music elsewhere than the picture: 对速 holds the speed.
    property bool musicAway: false
    // The speed the picture plays at, whoever sets it.
    property real tempo: match ? match.rate : 1
    property var view: ({})
    property var match: null

    signal tempoToggled()
    signal jumpToggled()
    // Double-click on the speed: back to the material's own.
    signal tempoReset()

    // The engine's rules (core/engine/src/runtime.rs): a new position this far
    // from the followed one is a jump; this long without a confirmation the
    // follow counts as lost and the whole Set is searched again.
    readonly property real jumpMs: 2500
    readonly property real lostMs: 2000

    // Listening: both helpers judge. Working: that judgement moves the picture.
    readonly property bool working: active
    readonly property bool tempoWorking: active && !tempoPaused
    readonly property bool shown: Window.window ? Window.window.visible : false
    readonly property var tracking: view.tracking || null
    readonly property string inputState: view.input ? view.input.state : ""
    readonly property bool quiet: working && ["quiet", "stalled", "waiting"].indexOf(inputState) >= 0
    readonly property bool lost: working && !!match && view.phase === "searching"
    property real now: 0
    readonly property real age: match ? Math.max(0, now - match.clock_at_ms) : 0
    readonly property real deviation: tracking && tracking.error_ms !== null && tracking.error_ms !== undefined
                                      ? Math.abs(tracking.error_ms) : 0
    // How near the watcher is to calling a jump: 1 is the threshold.
    readonly property real pressure: match ? Math.max(deviation / jumpMs, age / lostMs) : 0
    readonly property bool alert: working && (quiet || lost || (!!match && pressure >= 1))
    readonly property bool keeping: working && !!match && !quiet && !lost && !(tempoWorking && musicAway)
    readonly property real rate: tempo
    // The speed the music is heard at, for the swing.
    readonly property real heard: match ? match.rate : tempo
    readonly property int lock: match ? match.lock_revision : 0
    property bool jumped: false

    function percent(r) {
        const p = (r - 1) * 100
        return (p > 0.05 ? "+" : p < -0.05 ? "−" : "") + Math.abs(p).toFixed(1) + "%"
    }
    function clock(seconds) {
        const s = Math.max(0, seconds)
        const m = Math.floor(s / 60)
        const rest = Math.floor(s - m * 60)
        return m + ":" + (rest < 10 ? "0" : "") + rest
    }

    onLockChanged: {
        if (working && lock > 0) {
            jumped = true
            jumpNote.restart()
            hop.restart()
        }
    }
    Timer {
        interval: 125
        repeat: true
        triggeredOnStart: true
        running: root.working && root.shown
        onTriggered: root.now = Engine.clockMs()
    }
    Timer {
        id: jumpNote
        interval: 2500
        onTriggered: root.jumped = false
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: 10
        spacing: 6

        // —— Tempo ——
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Item {
                implicitWidth: 28
                implicitHeight: 28
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 2
                    width: 24
                    height: 2
                    radius: 1
                    color: Theme.line
                }
                Rectangle {
                    id: beat
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: root.keeping ? Theme.text : Theme.faint
                    // One swing per beat of a 120 BPM track at the followed speed.
                    SequentialAnimation on x {
                        running: root.keeping && root.shown
                        loops: Animation.Infinite
                        NumberAnimation { from: 2; to: 18; duration: 500 / root.heard; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 18; to: 2; duration: 500 / root.heard; easing.type: Easing.InOutSine }
                    }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: "对速"
                        font.pixelSize: Theme.sizeSm
                        font.weight: Font.DemiBold
                        color: root.working ? Theme.text : Theme.muted
                    }
                    Text {
                        visible: root.active && (!!root.match || root.tempoPaused)
                        text: root.percent(root.rate)
                        font.pixelSize: Theme.sizeSm
                        font.features: { "tnum": 1 }
                        color: Theme.text
                        MouseArea { anchors.fill: parent; onDoubleClicked: root.tempoReset() }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: {
                        if (!root.active)
                            return "未开启"
                        if (root.quiet)
                            return "等声音"
                        if (!root.match)
                            return "等找到位置"
                        if (root.tempoPaused)
                            return "只监听 · " + (root.lost ? "等重新对上" : root.match.rate_confidence < 0.3 ? "按音频估速中"
                                                  : "听到 " + root.percent(root.match.rate) + " · 把握 " + Math.round(root.match.rate_confidence * 100) + "%")
                        if (root.musicAway)
                            return "音乐不在画面这里，速度保持不动"
                        if (root.lost)
                            return "保持当前速度，等重新对上"
                        if (root.match.rate_confidence < 0.3)
                            return "按音频估速中"
                        return "跟着音乐调速 · 把握 " + Math.round(root.match.rate_confidence * 100) + "%"
                    }
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: Theme.muted
                    elide: Text.ElideRight
                }
            }
            IconButton {
                // Kept in its place while off, so nothing moves when it starts.
                opacity: root.active ? 1 : 0
                enabled: root.active
                iconName: root.tempoPaused ? "play" : "pause"
                tip: root.tempoPaused ? "继续对速" : "暂停对速（速度交给播放器）"
                onClicked: root.tempoToggled()
            }
        }

        // —— Jumps ——
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Item {
                id: watch
                implicitWidth: 28
                implicitHeight: 28
                readonly property color tone: root.alert ? Theme.warn : root.working ? Theme.text : Theme.faint

                SequentialAnimation {
                    id: hop
                    NumberAnimation { target: watch; property: "scale"; to: 1.35; duration: 120; easing.type: Easing.OutQuad }
                    NumberAnimation { target: watch; property: "scale"; to: 1; duration: 260; easing.type: Easing.OutBack }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    radius: 9
                    color: "transparent"
                    border.width: 1.5
                    border.color: root.alert ? Theme.warn : root.working ? Theme.muted : Theme.line
                }
                // Watching: a dot going round the ring.
                Item {
                    anchors.fill: parent
                    visible: root.working && !root.alert
                    Rectangle {
                        x: parent.width / 2 - 2.5
                        y: parent.height / 2 - 9 - 2.5
                        width: 5
                        height: 5
                        radius: 2.5
                        color: Theme.text
                    }
                    NumberAnimation on rotation {
                        running: root.working && !root.alert && root.shown
                        from: 0
                        to: 360
                        duration: 2400
                        loops: Animation.Infinite
                    }
                }
                // Past the threshold: rings spreading out.
                Rectangle {
                    id: ripple
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    radius: 9
                    color: "transparent"
                    border.width: 1.5
                    border.color: Theme.warn
                    visible: root.alert
                    ParallelAnimation {
                        running: root.alert && root.shown
                        loops: Animation.Infinite
                        NumberAnimation { target: ripple; property: "scale"; from: 1; to: 1.6; duration: 900; easing.type: Easing.OutCubic }
                        NumberAnimation { target: ripple; property: "opacity"; from: 0.9; to: 0; duration: 900 }
                    }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 6
                    height: 6
                    radius: 3
                    color: watch.tone
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: "跳转监测"
                        font.pixelSize: Theme.sizeSm
                        font.weight: Font.DemiBold
                        color: root.working ? Theme.text : Theme.muted
                    }
                    Text {
                        text: "阈值 " + (root.jumpMs / 1000).toFixed(1) + " s"
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: Theme.faint
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: {
                        if (!root.active)
                            return "未开启"
                        if (root.inputState === "stalled")
                            return "音频中断"
                        if (root.inputState === "quiet")
                            return "没有声音"
                        if (root.inputState === "waiting")
                            return "等待音频"
                        if (!root.match)
                            return "听音频，在 Set 里找位置"
                        const only = root.jumpPaused ? "只监听 · " : ""
                        if (root.lost || root.pressure >= 1)
                            return only + "超出阈值 · 正在重新找位置"
                        if (root.jumped)
                            return only + (root.jumpPaused ? "听到在 " : root.lock > 1 ? "已跳转到 " : "找到了 ")
                                   + root.match.entry.title + " " + root.clock(root.match.position)
                        return only + "偏差 " + root.deviation.toFixed(0) + " ms"
                    }
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: root.alert ? Theme.warn : Theme.muted
                    elide: Text.ElideRight
                }
                // How near to a jump: the right end is the threshold.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    implicitHeight: 3
                    radius: 1.5
                    color: Theme.line
                    opacity: root.working && !!root.match ? 1 : 0.4
                    Rectangle {
                        width: parent.width * Math.min(1, root.working ? root.pressure : 0)
                        height: parent.height
                        radius: 1.5
                        color: root.alert ? Theme.warn : Theme.text
                        Behavior on width { NumberAnimation { duration: 120 } }
                    }
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2
                        height: 9
                        radius: 1
                        color: root.alert ? Theme.warn : Theme.muted
                    }
                }
            }
            IconButton {
                // Kept in its place while off, so nothing moves when it starts.
                opacity: root.active ? 1 : 0
                enabled: root.active
                iconName: root.jumpPaused ? "play" : "pause"
                tip: root.jumpPaused ? "继续跳转" : "暂停跳转（只跟速度）"
                onClicked: root.jumpToggled()
            }
        }
    }
}
