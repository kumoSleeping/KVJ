import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// 音频对位, as a narrow column under the PGM monitor, at the window's right. Top to bottom: its name and a light with its word
// (未监听 red; 监听中 / 跟随中 green); following's own small picture
// (FollowMonitor, its 16:9 room always kept, black until it finds); what
// it found (the title, or the phase) and how fast it hears the music; the
// input's level; 监听, 跟随 / 暂停 (the ink key), 跳至此处 (the
// crosshair) and 画面偏移 (dragged or wheeled); the input with its channels (a
// device with more than two lists each pair), 现场模式, the Bluetooth DJs (a
// key that shows while receiving or while one asks to pair) and 刷新; at the
// foot the two helpers in full (Assistants): the speed and the jump threshold,
// each paused or resumed on its own. With two tracks, which one it listens
// to is chosen under its name (监听 画面 1 | 画面 2), not while it runs.
//
// API
//   app            the window (Main.qml's `app`): read following, match,
//                  followPaused, aiLeads, aiMain, manualSeek, tempoPaused,
//                  jumpPaused, musicAway, shownTempo, view, phase, running,
//                  devices, receiving, incoming, awayDjs, discoverable,
//                  entries, phaseText(), clock(); called listen(), follow(),
//                  jumpToMatch(), resetTempo(); tempoPaused / jumpPaused /
//                  discoverable set as the card did. Engine: stop(),
//                  refreshDevices(), clearError(), the Bluetooth calls.
//   surface        the projection's VideoSurface, for the monitor's mirror
//   entries        the Set's entries (default app.entries): which tracks have
//                  sound to follow
//   rowHeight      no longer used (the card fills the row it stands in);
//                  kept so a host that still sets it does not break
//   tracks         the tracks shown (0, or 0 and 1): the ones it may follow
//   followTrack    the track followed (kept under "follow/track"), chosen
//                  here; a track that loses its sound or is no longer shown
//                  gives way to the main one, never while running
//   device         the chosen input (devices[deviceIndex]), deviceIndex
//   channel        the first channel of the chosen pair (0, 2, …)
//   roomMode       现场模式: on for a microphone, either way by hand
//   offsetMs       画面偏移 (kept under "output/offset", as the card's)
//   canStart       the followed track has an entry that is on and has sound
//   monitorVisible following runs (the monitor shows its picture)
// The host's listen() / follow() start the engine with device, channel,
// roomMode and followTrack from here, and offsets the picture by offsetMs.
Card {
    id: root

    property var app: null
    property var surface: null
    property var entries: app ? app.entries : []
    property real rowHeight: 120
    property int followTrack: 0
    property var tracks: [0]
    readonly property var devices: app ? app.devices : []
    // What the input key offers: each device once, or, with more than two
    // channels, once for each pair of them: { device (its index), channel
    // (the pair's first), label }.
    readonly property var inputs: {
        const list = []
        devices.forEach((d, i) => {
            const n = Math.max(1, d.channels || 2)
            const away = d.error ? "（不可用）" : ""
            if (n <= 2) {
                list.push({ device: i, channel: 0, label: d.label + away })
                return
            }
            for (let c = 0; c < n; c += 2)
                list.push({ device: i, channel: c, label: d.label + " · CH " + (c + 1) + (c + 1 < n ? "/" + (c + 2) : "") + away })
        })
        return list
    }
    readonly property var input: inputs.length ? inputs[Math.max(0, Math.min(deviceBox.currentIndex, inputs.length - 1))] : null
    readonly property int deviceIndex: input ? input.device : 0
    readonly property var device: input ? devices[input.device] || null : null
    readonly property int channel: input ? input.channel : 0
    readonly property bool microphone: !!device && device.kind === "input"
    property bool roomMode: microphone
    onMicrophoneChanged: roomMode = microphone
    property real offsetMs: 0

    readonly property bool running: !!app && app.running
    readonly property bool following: !!app && app.following
    readonly property var match: app ? app.match : null
    // Tracks with something to hear: 0 the main one, 1..3 画面 2..4.
    readonly property var audioTracks: (tracks || [0]).filter(t => t === 0 || (entries || []).some(e => (e.track || 0) === t && !e.silent))
    readonly property bool canStart: !running && !Engine.importing
                                     && (entries || []).some(e => (e.track || 0) === followTrack && e.enabled !== false && !e.silent)
    readonly property bool monitorVisible: following
    readonly property bool asking: !!app && (app.incoming || []).some(p => p.link.state === "asking")
    // The DJs' key shows while receiving over Bluetooth or while one asks.
    readonly property bool djsOffered: !!app && (app.receiving || asking)
    onDjsOfferedChanged: if (!djsOffered) djs.close()
    // Following hears nothing yet: the monitor says so.
    readonly property var view: app ? app.view : ({})
    readonly property string inputState: view.input ? view.input.state : ""
    readonly property bool quiet: following && ["quiet", "stalled", "waiting"].indexOf(inputState) >= 0

    function trackName(t) {
        return "画面 " + (t + 1)
    }
    function setOffset(ms) {
        offsetMs = Math.max(-400, Math.min(400, Math.round(ms / 10) * 10))
    }
    // A track that no longer has sound gives way to the main one.
    onAudioTracksChanged: {
        if (!running && (entries || []).length > 0 && audioTracks.indexOf(followTrack) < 0)
            followTrack = 0
    }

    implicitWidth: 228

    Settings {
        category: "follow"
        property alias track: root.followTrack
    }
    Settings {
        category: "output"
        property alias offset: root.offsetMs
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 5

        // Its name; listening or not, at the corner: green while it listens,
        // red while not.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Heading {
                Layout.fillWidth: true
                text: "音频对位"
            }
            // The light, with its word: green while listening, red while not.
            Rectangle {
                id: light
                readonly property string word: !root.following ? "未监听"
                                               : root.app && root.app.aiLeads ? "跟随中" : "监听中"
                implicitWidth: lightRow.implicitWidth + 16
                implicitHeight: 22
                radius: 11
                color: Theme.inset
                Row {
                    id: lightRow
                    anchors.centerIn: parent
                    spacing: 6
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6
                        height: 6
                        radius: 3
                        color: root.following ? "#30a46c" : Theme.danger
                        Behavior on color { ColorAnimation { duration: Theme.quick } }
                    }
                    Text {
                        text: light.word
                        font.pixelSize: Theme.sizeXs
                        font.weight: Font.Medium
                        color: root.following ? Theme.text : Theme.muted
                    }
                }
            }
        }

        // Which track it listens to, while there are two.
        // Which track it listens to: a segmented plate, the one chosen raised.
        RowLayout {
            visible: (root.tracks || []).length > 1
            Layout.fillWidth: true
            spacing: 8
            Caption { text: "监听" }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 28
                radius: Theme.radius
                color: Theme.inset
                Row {
                    id: trackKeys
                    anchors.fill: parent
                    anchors.margins: 2
                    spacing: 2
                    Repeater {
                        model: root.tracks
                        TextButton {
                            required property int modelData
                            readonly property bool on: root.followTrack === modelData
                            readonly property bool heard: root.audioTracks.indexOf(modelData) >= 0
                            width: (trackKeys.width - trackKeys.spacing * ((root.tracks || []).length - 1)) / Math.max(1, (root.tracks || []).length)
                            height: 24
                            leftPadding: 6
                            rightPadding: 6
                            background: Rectangle {
                                radius: Theme.radius - 1
                                color: parent.on ? Theme.raised : parent.hovered && parent.enabled ? Theme.hover : "transparent"
                            }
                            font.weight: on ? Font.DemiBold : Font.Medium
                            text: root.trackName(modelData)
                            enabled: on || (!root.running && heard)
                            onClicked: root.followTrack = modelData
                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: root.running && !on ? "先停止监听再换"
                                          : !heard ? root.trackName(modelData) + " 上还没有带声音的素材"
                                          : "音频对位听" + root.trackName(modelData) + "的声音"
                        }
                    }
                }
            }
        }

        // Following's own picture, where it puts the music: 16:9 at the card's
        // width, smaller (centred) when the card is short.
        // Its room always kept, 16:9 at the card's width, black until
        // following has found the music: never squeezed.
        Item {
            id: monitorBox
            readonly property real full: width * 9 / 16 + 3
            Layout.fillWidth: true
            Layout.preferredHeight: full
            Layout.maximumHeight: full
            Layout.minimumHeight: full
            Rectangle {
                width: parent.width
                height: parent.height - 3
                radius: Theme.radius
                color: "black"
            }
            FollowMonitor {
                id: monitor
                width: Math.min(parent.width, (parent.height - 3) * 16 / 9)
                anchors.horizontalCenter: parent.horizontalCenter
                active: root.following
                mirror: !!root.app && root.app.aiMain
                match: root.match
                offsetMs: root.offsetMs
                source: root.surface
            }
            // What following found, how fast the music is heard, and the input's
            // level, along the foot of its picture (no room taken under it).
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 3
                height: foot.implicitHeight + 16
                radius: Theme.radius
                gradient: Gradient {
                    GradientStop { position: 0; color: "transparent" }
                    GradientStop { position: 1; color: "#99000000" }
                }
            }
            ColumnLayout {
                id: foot
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 8
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        id: status
                        Layout.fillWidth: true
                        readonly property bool warn: Engine.error.length > 0 || root.asking
                        text: Engine.error.length > 0 ? Engine.error
                              : root.asking ? "有 DJ 请求连接 · 点这里"
                              : root.match ? root.match.entry.title
                              : root.following && root.app.phase === "indexing" ? root.app.phaseText(root.app.phase) : ""
                        font.pixelSize: Theme.sizeXs
                        font.weight: Font.DemiBold
                        color: warn ? Theme.warn : root.match && !root.app.followPaused ? "#ffffff" : "#b3ffffff"
                        elide: Text.ElideRight
                        MouseArea {
                            id: statusArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: status.warn ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                                if (Engine.error.length > 0)
                                    Engine.clearError()
                                else if (root.asking)
                                    djs.open()
                            }
                        }
                        ToolTip.visible: statusArea.containsMouse
                        ToolTip.delay: 600
                        ToolTip.text: Engine.error.length > 0 ? Engine.error + "\n（点一下清除）"
                                      : root.asking ? "有 DJ 电脑请求连接，点一下允许或拒绝"
                                      : root.match ? (root.app.followPaused ? "只监听" : "跟随中") + " · " + root.match.entry.title + " · "
                                                     + root.app.clock(root.match.position, true) + " · " + root.trackName(root.followTrack)
                                      : (root.following ? root.app.phaseText(root.app.phase) + " · " : "") + "跟随" + root.trackName(root.followTrack)

                    }
                    Text {
                        visible: !!root.match
                        text: root.match ? "×" + root.match.rate.toFixed(3) : ""
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: "#b3ffffff"
                    }
                }
                // The input's level, of the chosen channels.
                // The input's level, while listening (its room kept, so nothing moves).
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 3
                    radius: 1.5
                    color: "#33ffffff"
                    opacity: root.following ? 1 : 0
                    Rectangle {
                        readonly property real db: root.following && root.view.input && root.view.input.rms_dbfs !== null ? root.view.input.rms_dbfs : -70
                        width: parent.width * Math.max(0, Math.min(1, (db + 70) / 70))
                        height: parent.height
                        radius: 1.5
                        color: "#ffffff"
                        Behavior on width { NumberAnimation { duration: 120 } }
                    }
                }
            }
        }


        // Listen, follow or pause, go there once; the picture's offset.
        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            TextButton {
                implicitHeight: 28
                leftPadding: 8
                rightPadding: 10
                text: root.following ? "停止" : "监听"
                widest: "监听"
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: root.following ? "停止监听" : "开始监听：听音乐、判断位置，画面仍归播放器"
                enabled: root.following || root.canStart
                onClicked: root.following ? Engine.stop() : root.app.listen()
            }
            // The one ink key: follow, or pause following.
            TextButton {
                implicitHeight: 28
                leftPadding: 8
                rightPadding: 10
                primary: true
                iconName: root.app && root.app.aiLeads ? "pause" : "play"
                text: root.app && root.app.aiLeads ? "暂停" : "跟随"
                widest: "跟随"
                enabled: root.following || root.canStart
                onClicked: {
                    if (root.app.aiLeads)
                        root.app.tempoPaused = root.app.jumpPaused = true
                    else
                        root.app.follow()
                }
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: root.app && root.app.aiLeads ? "暂停跟随：继续监听，画面交回播放器"
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
            Item { Layout.fillWidth: true }
            // 画面偏移: dragged sideways or wheeled in 10 ms steps,
            // double-clicked back to 0.
            Item {
                implicitWidth: offsetRow.implicitWidth + 8
                implicitHeight: 24
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radius - 2
                    color: offsetArea.pressed ? Theme.selected : offsetArea.containsMouse ? Theme.hover : "transparent"
                }
                Row {
                    id: offsetRow
                    anchors.centerIn: parent
                    spacing: 3
                    Text {
                        text: "偏移"
                        font.pixelSize: 11
                        color: Theme.faint
                    }
                    Text {
                        text: (root.offsetMs > 0 ? "+" : root.offsetMs < 0 ? "−" : "±") + Math.abs(root.offsetMs).toFixed(0) + "ms"
                        font.pixelSize: 11
                        font.features: { "tnum": 1 }
                        color: root.offsetMs === 0 ? Theme.muted : Theme.text
                    }
                }
                MouseArea {
                    id: offsetArea
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: Qt.SizeHorCursor
                    property real pressX: 0
                    property real pressValue: 0
                    property real spun: 0
                    onPressed: mouse => {
                        pressX = mouse.x
                        pressValue = root.offsetMs
                    }
                    onPositionChanged: mouse => {
                        if (pressed)
                            root.setOffset(pressValue + Math.round((mouse.x - pressX) / 3) * 10)
                    }
                    onDoubleClicked: root.offsetMs = 0
                    onWheel: wheel => {
                        spun += wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
                        const steps = spun > 0 ? Math.floor(spun / 120) : Math.ceil(spun / 120)
                        if (steps !== 0) {
                            spun -= steps * 120
                            root.setOffset(root.offsetMs + steps * 10)
                        }
                    }
                    ToolTip.visible: containsMouse && !pressed
                    ToolTip.delay: 600
                    ToolTip.text: "画面偏移：跟随的画面比音乐早（−）或晚（+）多少\n左右拖动或滚轮调，每格 10 ms；双击归零"
                }
            }
        }

        // The input, its channels with it; 现场模式; the DJs; 刷新.
        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            Select {
                id: deviceBox
                Layout.fillWidth: true
                Layout.rightMargin: 2
                implicitHeight: 26
                font.pixelSize: Theme.sizeXs
                enabled: !root.running
                model: root.inputs.map(o => o.label)
                ToolTip.visible: hovered && !down
                ToolTip.delay: 600
                ToolTip.text: "声音输入" + (root.input ? "：" + root.input.label : "") + "\n多于两个声道的设备，每对声道单列一项"
            }
            Chip {
                text: "现场"
                on: root.roomMode
                enabled: !root.running
                tip: "现场模式：麦克风听现场，在混响里也能跟上。选麦克风时自动打开；电脑内录或蓝牙接收时关闭"
                onClicked: root.roomMode = !root.roomMode
            }
            Chip {
                id: djKey
                visible: root.djsOffered
                text: "DJ"
                on: djs.visible
                warn: root.asking
                tip: root.asking ? "有 DJ 请求连接：允许或拒绝" : "蓝牙 DJ：当前 DJ、可被发现、忘记记住的 DJ"
                onClicked: djs.visible ? djs.close() : djs.open()
            }
            IconButton {
                implicitWidth: 26
                implicitHeight: 26
                iconName: "refresh"
                iconSize: 14
                tip: "刷新设备"
                enabled: !root.running && !Engine.busy
                onClicked: Engine.refreshDevices()
            }
        }

        Item {
            Layout.fillHeight: true
            Layout.preferredHeight: 0
        }

        // The two helpers in full, at the foot: the speed, and the jump
        // threshold; each paused or resumed by its key.
        Assistants {
            Layout.fillWidth: true
            active: root.following
            tempoPaused: !!root.app && root.app.tempoPaused
            jumpPaused: !!root.app && root.app.jumpPaused
            musicAway: !!root.app && root.app.musicAway
            tempo: root.app ? root.app.shownTempo : 1
            onTempoToggled: root.app.tempoPaused = !root.app.tempoPaused
            onJumpToggled: root.app.jumpPaused = !root.app.jumpPaused
            onTempoReset: root.app.resetTempo()
            view: root.view
            match: root.match
        }
    }

    // A small text key: ink while `on`, an outline while not; a
    // dot at its corner while `warn`.
    component Chip: AbstractButton {
        id: chip
        property bool on: false
        property bool warn: false
        property string tip
        implicitWidth: implicitContentWidth + leftPadding + rightPadding
        implicitHeight: 22
        leftPadding: 6
        rightPadding: 6
        hoverEnabled: true
        background: Rectangle {
            radius: Theme.radius - 2
            color: chip.on ? (chip.enabled ? Theme.text : Theme.faint)
                           : chip.down ? Theme.selected : chip.hovered && chip.enabled ? Theme.hover : Theme.inset
            Behavior on color { ColorAnimation { duration: 90 } }
            Rectangle {
                visible: chip.warn
                x: parent.width - 5
                y: -1
                width: 6
                height: 6
                radius: 3
                color: Theme.warn
            }
        }
        contentItem: Text {
            text: chip.text
            font.pixelSize: 11
            font.weight: Font.DemiBold
            color: chip.on ? Theme.raised : chip.enabled ? Theme.body : Theme.faint
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        ToolTip.visible: hovered && tip.length > 0
        ToolTip.delay: 600
        ToolTip.text: tip
    }

    // —— The Bluetooth DJs, under their key ——
    Popup {
        id: djs
        parent: djKey
        x: djKey.width - width
        y: djKey.height + 6
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
            id: djList
            Layout.fillWidth: true
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                Heading { text: "蓝牙 DJ"; Layout.fillWidth: true }
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
            Text {
                Layout.fillWidth: true
                visible: !!root.app && (root.app.incoming || []).length === 0 && (!root.app.receiving || root.app.awayDjs.length === 0)
                text: "还没有 DJ 电脑连上"
                font.pixelSize: Theme.sizeSm
                color: Theme.faint
            }
        }
    }
}
