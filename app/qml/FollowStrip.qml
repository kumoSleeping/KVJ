import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// 音频对位, pressed into a strip as tall as the main track's row and about
// half the old card's width, for the right end of the track area. On it: what
// following does (未监听 / 监听中 / 跟随中 and the title), the input's level,
// 开始监听 (the ear), 开始跟随, 跳至此处 (the crosshair), the input, which
// track is followed, and the two helpers as small keys (对速's dot swings,
// 跳转's ring watches; a press pauses or resumes one, the pointer tells how it
// is doing). ⋯ opens the rest: the channels, 现场模式, 画面偏移, the helpers in
// full with the jump threshold, the Bluetooth DJs and the last error; a dot
// on it says a DJ asks to pair. While following runs, its small picture
// (FollowMonitor) stands at the strip's left, the panel's tone until it has
// found the music; stopped, it is gone and takes no room.
//
// API
//   app            the window (Main.qml's `app`): read following, match,
//                  followPaused, aiLeads, aiPicture, manualSeek, tempoPaused,
//                  jumpPaused, musicAway, shownTempo, view, phase, running,
//                  devices, receiving, incoming, awayDjs, discoverable,
//                  entries, phaseText(), clock(); called listen(), follow(),
//                  jumpToMatch(), resetTempo(); tempoPaused / jumpPaused /
//                  discoverable set as the card did. Engine: stop(),
//                  refreshDevices(), clearError(), the Bluetooth calls.
//   surface        the projection's VideoSurface, for the monitor's mirror
//   entries        the Set's entries (default app.entries): which tracks have
//                  sound to follow
//   rowHeight      the strip's height (the timeline's mainRowHeight)
//   stripWidth     the strip's width without the monitor
//   followTrack    0..3, the track followed (kept under "follow/track"); only
//                  tracks with an entry that has sound are offered, never
//                  while running
//   device         the chosen input (devices[deviceIndex]), deviceIndex
//   channel        the first channel of the chosen pair (0, 2, …)
//   roomMode       现场模式: on for a microphone, either way by hand
//   offsetMs       画面偏移 (kept under "output/offset", as the card's)
//   canStart       the followed track has an entry that is on and has sound
//   monitorVisible the monitor is shown (while following runs)
// The host's listen() / follow() start the engine with device, channel,
// roomMode and followTrack from here, and offsets the picture by offsetMs.
Item {
    id: root

    property var app: null
    property var surface: null
    property var entries: app ? app.entries : []
    property real rowHeight: 143
    property real stripWidth: 184
    property int followTrack: 0
    property alias deviceIndex: deviceBox.currentIndex
    readonly property var devices: app ? app.devices : []
    readonly property var device: devices.length ? devices[Math.max(0, Math.min(deviceBox.currentIndex, devices.length - 1))] : null
    readonly property int channel: channelBox.currentIndex * 2
    readonly property bool microphone: !!device && device.kind === "input"
    property bool roomMode: microphone
    onMicrophoneChanged: roomMode = microphone
    property real offsetMs: 0

    readonly property bool running: !!app && app.running
    readonly property bool following: !!app && app.following
    readonly property var match: app ? app.match : null
    // Tracks with something to hear: 0 the main one, 1..3 画面 2..4.
    readonly property var audioTracks: [0, 1, 2, 3].filter(t => t === 0 || (entries || []).some(e => (e.track || 0) === t && !e.silent))
    readonly property bool canStart: !running && !Engine.importing
                                     && (entries || []).some(e => (e.track || 0) === followTrack && e.enabled !== false && !e.silent)
    readonly property bool monitorVisible: following
    readonly property real monitorWidth: Math.round((rowHeight - 7) * 16 / 9)
    readonly property bool asking: !!app && (app.incoming || []).some(p => p.link.state === "asking")

    function trackName(t) {
        return t === 0 ? "主轨" : "画面 " + (t + 1)
    }
    // A track that no longer has sound gives way to the main one.
    onAudioTracksChanged: {
        if (!running && (entries || []).length > 0 && audioTracks.indexOf(followTrack) < 0)
            followTrack = 0
    }

    implicitWidth: (monitorVisible ? monitorWidth + 8 : 0) + stripWidth
    implicitHeight: rowHeight

    Settings {
        category: "follow"
        property alias track: root.followTrack
    }
    Settings {
        category: "output"
        property alias offset: root.offsetMs
    }

    // —— The helpers' state, as Assistants judges it ——
    readonly property bool tempoPaused: !!app && app.tempoPaused
    readonly property bool jumpPaused: !!app && app.jumpPaused
    readonly property var view: app ? app.view : ({})
    readonly property var tracking: view.tracking || null
    readonly property string inputState: view.input ? view.input.state : ""
    readonly property bool quiet: following && ["quiet", "stalled", "waiting"].indexOf(inputState) >= 0
    readonly property bool lost: following && !!match && view.phase === "searching"
    property real now: 0
    readonly property real age: match ? Math.max(0, now - match.clock_at_ms) : 0
    readonly property real deviation: tracking && tracking.error_ms !== null && tracking.error_ms !== undefined
                                      ? Math.abs(tracking.error_ms) : 0
    // The engine's rules (core/engine/src/runtime.rs), as in Assistants.
    readonly property real jumpMs: 2500
    readonly property real lostMs: 2000
    readonly property real pressure: match ? Math.max(deviation / jumpMs, age / lostMs) : 0
    readonly property bool alert: following && (quiet || lost || (!!match && pressure >= 1))
    readonly property bool keeping: following && !!match && !quiet && !lost && !(!tempoPaused && !!app && app.musicAway)
    readonly property real heard: match ? match.rate : 1
    readonly property bool shown: visible && !!Window.window && Window.window.visible

    function percent(r) {
        const p = (r - 1) * 100
        return (p > 0.05 ? "+" : p < -0.05 ? "−" : "") + Math.abs(p).toFixed(1) + "%"
    }
    function tempoText() {
        if (!following)
            return "对速：未开启"
        if (quiet)
            return "对速：等声音"
        if (!match)
            return "对速：等找到位置"
        if (tempoPaused)
            return "对速已暂停（只监听）· " + (lost ? "等重新对上" : match.rate_confidence < 0.3 ? "按音频估速中"
                                             : "听到 " + percent(match.rate) + " · 把握 " + Math.round(match.rate_confidence * 100) + "%")
        if (app.musicAway)
            return "对速：音乐不在画面这里，速度保持不动"
        if (lost)
            return "对速：保持当前速度，等重新对上"
        if (match.rate_confidence < 0.3)
            return "对速：按音频估速中"
        return "对速：跟着音乐调速 " + percent(app.shownTempo) + " · 把握 " + Math.round(match.rate_confidence * 100) + "%"
    }
    function jumpText() {
        const head = "跳转监测（阈值 " + (jumpMs / 1000).toFixed(1) + " s）："
        if (!following)
            return head + "未开启"
        if (inputState === "stalled")
            return head + "音频中断"
        if (inputState === "quiet")
            return head + "没有声音"
        if (inputState === "waiting")
            return head + "等待音频"
        if (!match)
            return head + "听音频，在 Set 里找位置"
        const only = jumpPaused ? "已暂停（只监听）· " : ""
        if (lost || pressure >= 1)
            return head + only + "超出阈值 · 正在重新找位置"
        return head + only + "偏差 " + deviation.toFixed(0) + " ms"
    }

    Timer {
        interval: 125
        repeat: true
        triggeredOnStart: true
        running: root.following && root.shown
        onTriggered: root.now = Engine.clockMs()
    }

    // —— Following's own picture, only while it runs ——
    Item {
        id: monitorBox
        visible: root.monitorVisible
        width: root.monitorWidth
        height: root.height
        FollowMonitor {
            id: monitor
            width: parent.width
            active: root.following
            mirror: !!root.app && root.app.aiPicture
            match: root.match
            offsetMs: root.offsetMs
            source: root.surface
        }
        // Nothing found yet: the panel's tone and a word, never a black box.
        Rectangle {
            visible: !root.match
            width: parent.width
            height: width * 9 / 16
            radius: Theme.radius
            color: Theme.inset
            Text {
                anchors.centerIn: parent
                width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.quiet ? "等声音…" : "听音频，找位置…"
                font.pixelSize: Theme.sizeXs
                color: Theme.faint
            }
        }
    }

    // —— The strip ——
    Rectangle {
        id: panel
        x: root.monitorVisible ? root.monitorWidth + 8 : 0
        width: root.stripWidth
        height: root.height
        radius: Theme.radius
        color: Theme.inset

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 0

            // What following does, and how fast the music is heard.
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                Text {
                    id: status
                    Layout.fillWidth: true
                    readonly property bool warn: Engine.error.length > 0 || root.asking
                    text: Engine.error.length > 0 ? Engine.error
                          : root.asking ? "有 DJ 请求连接 · 点 ⋯"
                          : root.match ? (root.app.followPaused ? "监听中" : "跟随中") + " · " + root.match.entry.title
                          : root.following ? root.app.phaseText(root.app.phase) : "未监听"
                    font.pixelSize: Theme.sizeXs
                    font.weight: Font.DemiBold
                    color: warn ? Theme.warn : root.match && !root.app.followPaused ? Theme.text : Theme.muted
                    elide: Text.ElideRight
                    MouseArea {
                        id: statusArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: if (Engine.error.length > 0) Engine.clearError()
                    }
                    ToolTip.visible: statusArea.containsMouse && status.truncated
                    ToolTip.delay: 400
                    ToolTip.text: status.text + (Engine.error.length > 0 ? "\n（点一下清除）" : "")
                }
                Text {
                    visible: !!root.match
                    text: root.match ? "×" + root.match.rate.toFixed(3) : ""
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: Theme.muted
                }
            }
            // The input's level, of the chosen channels.
            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 4
                Layout.preferredHeight: 3
                radius: 1.5
                color: Theme.line
                Rectangle {
                    readonly property real db: root.following && root.view.input && root.view.input.rms_dbfs !== null ? root.view.input.rms_dbfs : -70
                    width: parent.width * Math.max(0, Math.min(1, (db + 70) / 70))
                    height: parent.height
                    radius: 1.5
                    color: Theme.text
                    Behavior on width { NumberAnimation { duration: 120 } }
                }
            }
            Item { Layout.fillHeight: true }

            // Listen, follow, go there once, and the rest.
            RowLayout {
                Layout.fillWidth: true
                spacing: 2
                IconButton {
                    implicitWidth: 28
                    implicitHeight: 28
                    iconName: root.following ? "square" : "ear"
                    active: root.following
                    tip: root.following ? "停止监听" : "开始监听：听音乐、判断位置，画面仍归播放器"
                    enabled: root.following || root.canStart
                    onClicked: root.following ? Engine.stop() : root.app.listen()
                }
                TextButton {
                    Layout.fillWidth: true
                    implicitHeight: 28
                    leftPadding: 8
                    rightPadding: 8
                    primary: true
                    iconName: root.app && root.app.aiLeads ? "pause" : "play"
                    text: root.app && root.app.aiLeads ? "暂停" : "跟随"
                    enabled: root.following || root.canStart
                    onClicked: {
                        if (root.app.aiLeads)
                            root.app.tempoPaused = root.app.jumpPaused = true
                        else
                            root.app.follow()
                    }
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: root.app && root.app.aiLeads ? "停止跟随：继续监听，画面交回播放器"
                                                              : "开始跟随：画面跟着音乐走（没在监听时先开始监听）"
                }
                IconButton {
                    implicitWidth: 28
                    implicitHeight: 28
                    iconName: "crosshair"
                    tip: "跳至此处：播放器跳到智能跟随判断的位置"
                    enabled: !!root.match && !!root.app && root.app.manualSeek
                    onClicked: root.app.jumpToMatch()
                }
                IconButton {
                    id: moreKey
                    implicitWidth: 28
                    implicitHeight: 28
                    iconName: "ellipsis"
                    tip: "声道、现场模式、画面偏移、跳转阈值、蓝牙 DJ"
                    active: more.visible
                    onClicked: more.visible ? more.close() : more.open()
                    Rectangle {
                        visible: root.asking || Engine.error.length > 0
                        x: parent.width - 9
                        y: 3
                        width: 6
                        height: 6
                        radius: 3
                        color: Theme.warn
                    }
                }
            }
            Item { Layout.preferredHeight: 4 }

            Select {
                id: deviceBox
                Layout.fillWidth: true
                implicitHeight: 26
                font.pixelSize: Theme.sizeXs
                enabled: !root.running
                model: root.devices.map(d => d.label + (d.error ? "（不可用）" : ""))
                ToolTip.visible: hovered && !down
                ToolTip.delay: 600
                ToolTip.text: "声音输入"
            }
            Item { Layout.preferredHeight: 4 }

            // Which track is followed, and the helpers.
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                Select {
                    id: trackBox
                    Layout.preferredWidth: 70
                    implicitHeight: 26
                    leftPadding: 8
                    rightPadding: 22
                    font.pixelSize: Theme.sizeXs
                    enabled: !root.running && root.audioTracks.length > 1
                    model: root.audioTracks.map(t => root.trackName(t))
                    currentIndex: root.audioTracks.indexOf(root.followTrack)
                    displayText: root.trackName(root.followTrack)
                    onActivated: index => root.followTrack = root.audioTracks[index]
                    ToolTip.visible: hovered && !down
                    ToolTip.delay: 600
                    ToolTip.text: "跟随哪条轨道（" + root.trackName(root.followTrack) + "）：只有含声音的轨道可选；相机、流媒体和无声的轨道不支持"
                }
                Helper {
                    Layout.fillWidth: true
                    label: "对速"
                    live: root.following
                    paused: root.tempoPaused
                    tip: root.tempoText()
                    onFlip: root.app.tempoPaused = !root.app.tempoPaused
                    // One swing per beat of a 120 BPM track at the followed speed.
                    Item {
                        anchors.fill: parent
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            x: 1
                            width: 16
                            height: 2
                            radius: 1
                            color: Theme.line
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6
                            height: 6
                            radius: 3
                            color: root.keeping && !root.tempoPaused ? Theme.text : Theme.faint
                            SequentialAnimation on x {
                                running: root.keeping && root.shown
                                loops: Animation.Infinite
                                NumberAnimation { from: 1; to: 11; duration: 500 / root.heard; easing.type: Easing.InOutSine }
                                NumberAnimation { from: 11; to: 1; duration: 500 / root.heard; easing.type: Easing.InOutSine }
                            }
                        }
                    }
                }
                Helper {
                    Layout.fillWidth: true
                    label: "跳转"
                    live: root.following
                    paused: root.jumpPaused
                    warn: root.alert
                    level: root.following && !!root.match ? Math.min(1, root.pressure) : -1
                    tip: root.jumpText()
                    onFlip: root.app.jumpPaused = !root.app.jumpPaused
                    Item {
                        anchors.fill: parent
                        Rectangle {
                            anchors.centerIn: parent
                            width: 14
                            height: 14
                            radius: 7
                            color: "transparent"
                            border.width: 1.5
                            border.color: root.alert ? Theme.warn : root.following ? Theme.muted : Theme.line
                        }
                        Item {
                            anchors.fill: parent
                            visible: root.following && !root.alert
                            Rectangle {
                                x: parent.width / 2 - 2
                                y: parent.height / 2 - 7 - 2
                                width: 4
                                height: 4
                                radius: 2
                                color: root.jumpPaused ? Theme.faint : Theme.text
                            }
                            NumberAnimation on rotation {
                                running: root.following && !root.alert && root.shown
                                from: 0
                                to: 360
                                duration: 2400
                                loops: Animation.Infinite
                            }
                        }
                        Rectangle {
                            id: ripple
                            anchors.centerIn: parent
                            width: 14
                            height: 14
                            radius: 7
                            color: "transparent"
                            border.width: 1.5
                            border.color: Theme.warn
                            visible: root.alert
                            ParallelAnimation {
                                running: root.alert && root.shown
                                loops: Animation.Infinite
                                NumberAnimation { target: ripple; property: "scale"; from: 1; to: 1.5; duration: 900; easing.type: Easing.OutCubic }
                                NumberAnimation { target: ripple; property: "opacity"; from: 0.9; to: 0; duration: 900 }
                            }
                        }
                    }
                }
            }
        }
    }

    // A helper as a small key: its sign, its name; pressed, it pauses or
    // resumes. `level` (0..1, or −1 for none) runs along its foot to the
    // threshold.
    component Helper: AbstractButton {
        id: helper
        property string label
        property string tip
        property bool paused: false
        property bool warn: false
        property real level: -1
        // Following runs: the key works and its name is inked.
        property bool live: false
        signal flip()
        default property alias sign: signBox.data
        implicitHeight: 26
        enabled: helper.live
        onClicked: helper.flip()
        hoverEnabled: true
        background: Rectangle {
            radius: Theme.radius
            color: helper.down ? Theme.selected : helper.hovered ? Theme.hover : "transparent"
            Rectangle {
                visible: helper.level >= 0
                x: 4
                y: parent.height - 3
                width: parent.width - 8
                height: 2
                radius: 1
                color: Theme.line
                Rectangle {
                    width: parent.width * Math.max(0, helper.level)
                    height: parent.height
                    radius: 1
                    color: helper.warn ? Theme.warn : Theme.text
                    Behavior on width { NumberAnimation { duration: 120 } }
                }
            }
        }
        contentItem: Item {
            implicitWidth: 18 + 3 + name.implicitWidth
            Item {
                id: signBox
                x: 1
                anchors.verticalCenter: parent.verticalCenter
                width: 18
                height: 18
                opacity: helper.paused ? 0.45 : 1
            }
            Text {
                id: name
                x: 21
                anchors.verticalCenter: parent.verticalCenter
                text: helper.label
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.strikeout: helper.paused && helper.live
                color: helper.warn ? Theme.warn : !helper.live || helper.paused ? Theme.faint : Theme.text
            }
        }
        leftPadding: 2
        rightPadding: 2
        ToolTip.visible: hovered
        ToolTip.delay: 400
        ToolTip.text: helper.tip + (helper.live ? "\n点一下" + (helper.paused ? "继续" : "暂停") : "")
    }

    // —— The rest, behind ⋯ ——
    Popup {
        id: more
        parent: moreKey
        x: moreKey.width - width
        y: -height - 6
        width: 300
        padding: 14
        margins: 8
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.raised
            border.width: 1
            border.color: Theme.line
        }
        contentItem: ColumnLayout {
            spacing: 8

            Heading {
                Layout.fillWidth: true
                text: "音频对位"
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: root.match ? root.match.entry.title : root.following ? root.app.phaseText(root.app.phase) : "未监听"
                    font.pixelSize: Theme.sizeLg
                    font.weight: Font.DemiBold
                    color: root.match && !root.app.followPaused ? Theme.text : Theme.muted
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: root.match ? (root.app.followPaused ? "只监听" : root.app.phaseText(root.app.phase)) + " · " + root.app.clock(root.match.position, true)
                                       + " · ×" + root.match.rate.toFixed(3) + " · " + root.trackName(root.followTrack) : root.trackName(root.followTrack)
                    font.pixelSize: Theme.sizeSm
                    font.features: { "tnum": 1 }
                    color: Theme.muted
                    elide: Text.ElideRight
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                Caption { text: "声音输入 · " + (root.device ? root.device.label : "自动") }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Select {
                        id: channelBox
                        Layout.preferredWidth: 104
                        enabled: !root.running
                        model: {
                            const channels = root.device ? Math.max(1, root.device.channels) : 2
                            const pairs = []
                            for (let i = 0; i < channels; i += 2)
                                pairs.push(i + 1 < channels ? "CH " + (i + 1) + "/" + (i + 2) : "CH " + (i + 1))
                            return pairs
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Toggle {
                        text: "现场模式"
                        checked: root.roomMode
                        enabled: !root.running
                        onToggled: root.roomMode = checked
                        ToolTip.visible: hovered
                        ToolTip.delay: 600
                        ToolTip.text: "麦克风听现场：在混响里也能跟上。选麦克风时自动打开；电脑内录或蓝牙接收时关闭"
                    }
                    IconButton {
                        iconName: "refresh"
                        tip: "刷新设备"
                        enabled: !root.running && !Engine.busy
                        onClicked: Engine.refreshDevices()
                    }
                }
            }

            // Calibration of the followed picture against the music.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text { text: "画面偏移"; font.pixelSize: Theme.sizeSm; color: Theme.muted }
                Seek {
                    Layout.fillWidth: true
                    from: -400
                    to: 400
                    stepSize: 10
                    value: root.offsetMs
                    onMoved: root.offsetMs = value
                }
                Text {
                    Layout.preferredWidth: 58
                    horizontalAlignment: Text.AlignRight
                    text: (root.offsetMs > 0 ? "+" : "") + root.offsetMs.toFixed(0) + " ms"
                    font.pixelSize: Theme.sizeSm
                    font.features: { "tnum": 1 }
                    color: root.offsetMs === 0 ? Theme.muted : Theme.text
                    MouseArea { anchors.fill: parent; onDoubleClicked: root.offsetMs = 0 }
                }
            }

            // The two helpers in full: the speed, and the jump threshold.
            Assistants {
                Layout.fillWidth: true
                active: root.following
                tempoPaused: root.tempoPaused
                jumpPaused: root.jumpPaused
                musicAway: !!root.app && root.app.musicAway
                tempo: root.app ? root.app.shownTempo : 1
                onTempoToggled: root.app.tempoPaused = !root.app.tempoPaused
                onJumpToggled: root.app.jumpPaused = !root.app.jumpPaused
                onTempoReset: root.app.resetTempo()
                view: root.view
                match: root.match
            }

            // Bluetooth DJs: the operator picks the current DJ, allows a new
            // one asking to pair, and forgets paired ones.
            ColumnLayout {
                id: djList
                Layout.fillWidth: true
                spacing: 4
                visible: !!root.app && (root.app.receiving || root.asking)
                RowLayout {
                    Layout.fillWidth: true
                    Caption { text: "DJ"; Layout.fillWidth: true }
                    Toggle {
                        text: "可被发现"
                        checked: !!root.app && root.app.discoverable
                        onToggled: root.app.discoverable = checked
                        ToolTip.visible: hovered
                        ToolTip.delay: 500
                        ToolTip.text: "开着时 DJ 电脑随时能找到这台并请求连接；记住的 DJ 回来会自动连上"
                    }
                }
                // The chosen DJ is let go only on a second press (within 4 s):
                // one stray click must not cut the music off.
                property string letGoId: ""
                Timer {
                    id: letGoTimer
                    interval: 4000
                    onTriggered: djList.letGoId = ""
                }
                Repeater {
                    model: root.app ? (root.app.incoming || []).filter(p => p.link.state !== "disconnected" || p.selected || p.known) : []
                    ItemDelegate {
                        id: dj
                        required property var modelData
                        readonly property bool asking: modelData.link.state === "asking"
                        readonly property bool lettingGo: modelData.selected && djList.letGoId === modelData.link.peer
                        Layout.fillWidth: true
                        implicitHeight: 32
                        topPadding: 0
                        bottomPadding: 0
                        leftPadding: 8
                        rightPadding: 2
                        onClicked: {
                            if (asking || modelData.link.state === "disconnected") {
                                return
                            } else if (!modelData.selected) {
                                djList.letGoId = ""
                                Engine.selectBluetooth(modelData.link.peer)
                            } else if (lettingGo) {
                                djList.letGoId = ""
                                Engine.selectBluetooth("")
                            } else {
                                djList.letGoId = modelData.link.peer
                                letGoTimer.restart()
                            }
                        }
                        ToolTip.visible: hovered && !!modelData.link.error
                        ToolTip.delay: 400
                        ToolTip.text: modelData.link.error || ""
                        contentItem: RowLayout {
                            spacing: 6
                            Text {
                                Layout.fillWidth: true
                                text: dj.modelData.device.name
                                font.pixelSize: Theme.size
                                font.weight: dj.modelData.selected || dj.asking ? Font.DemiBold : Font.Normal
                                color: dj.modelData.selected || dj.asking ? Theme.text : Theme.muted
                                elide: Text.ElideRight
                            }
                            Text {
                                visible: !dj.asking
                                text: dj.lettingGo ? "再点一下取消"
                                    : dj.modelData.link.state === "receiving" ? "发送中"
                                    : dj.modelData.link.state === "connected" ? (dj.modelData.selected ? "当前 DJ" : "待命")
                                    : dj.modelData.selected ? "已断开 · 回来后自动恢复" : "已断开"
                                font.pixelSize: Theme.sizeXs
                                color: Theme.muted
                            }
                            TextButton {
                                visible: dj.asking
                                primary: true
                                text: "允许"
                                onClicked: Engine.pairBluetooth(dj.modelData.link.peer, true)
                            }
                            TextButton {
                                visible: dj.asking
                                text: "拒绝"
                                onClicked: Engine.pairBluetooth(dj.modelData.link.peer, false)
                            }
                            IconButton {
                                visible: !dj.asking && dj.modelData.known && dj.hovered
                                iconName: "x"
                                tip: "忘记这台 DJ 电脑（下次需重新允许）"
                                onClicked: Engine.forgetBluetooth(dj.modelData.token)
                            }
                        }
                        background: Rectangle {
                            radius: Theme.radius
                            color: dj.asking ? Theme.inset : dj.hovered ? Theme.hover : "transparent"
                        }
                    }
                }
                // Remembered DJs that are not here now.
                Repeater {
                    model: root.app && root.app.receiving ? root.app.awayDjs : []
                    ItemDelegate {
                        id: away
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 28
                        topPadding: 0
                        bottomPadding: 0
                        leftPadding: 8
                        rightPadding: 2
                        contentItem: RowLayout {
                            spacing: 6
                            Text {
                                Layout.fillWidth: true
                                text: away.modelData.name
                                font.pixelSize: Theme.sizeSm
                                color: Theme.faint
                                elide: Text.ElideRight
                            }
                            Text {
                                text: "已记住 · 不在附近"
                                font.pixelSize: Theme.sizeXs
                                color: Theme.faint
                            }
                            IconButton {
                                visible: away.hovered
                                iconName: "x"
                                tip: "忘记这台 DJ 电脑"
                                onClicked: Engine.forgetBluetooth(away.modelData.token)
                            }
                        }
                        background: Rectangle {
                            radius: Theme.radius
                            color: away.hovered ? Theme.hover : "transparent"
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: Engine.error.length > 0
                text: Engine.error
                font.pixelSize: Theme.sizeSm
                color: Theme.warn
                wrapMode: Text.Wrap
                MouseArea { anchors.fill: parent; onClicked: Engine.clearError() }
            }
        }
    }
}
