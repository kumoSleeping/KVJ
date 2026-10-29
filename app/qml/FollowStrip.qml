import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// 声学追踪, as a narrow column under the PGM monitor, at the window's right. Top to bottom: its name and a light with its word
// (未监听 red; 监听中 / 跟随中 green); following's own small picture
// (FollowMonitor, its 16:9 room always kept, black until it finds); what
// it found (the title, or the phase) and how fast it hears the music; the
// input's level; 监听, 跟随 / 暂停, 跳至此处 (the
// crosshair) and 画面偏移 (dragged or wheeled); with two tracks, which one
// it listens to (监听 画面 1 | 画面 2, not while it runs); the input with its
// channels (a device with more than two lists each pair), 现场模式 and 刷新,
// these two shown folded or not; at the foot the two helpers in full
// (Assistants): the speed and the jump threshold, each paused or resumed on
// its own.
//
// API
//   app            the window (Main.qml's `app`): read following, match,
//                  followPaused, aiLeads, aiMain, manualSeek, tempoPaused,
//                  jumpPaused, musicAway, shownTempo, view, phase, running,
//                  devices, entries, phaseText(), clock(); called listen(),
//                  follow(), jumpToMatch(), resetTempo(); tempoPaused /
//                  jumpPaused set as the card did. Engine: stop(),
//                  refreshDevices(), clearError().
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
    readonly property var audioTracks: (tracks || [0]).filter(t => t === (tracks || [0])[0] || (entries || []).some(e => (e.track || 0) === t && !e.silent))
    readonly property bool canStart: !running && !Engine.importing
                                     && (entries || []).some(e => (e.track || 0) === followTrack && e.enabled !== false && !e.silent)
    readonly property bool monitorVisible: following
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
    // A track that no longer has sound, or is not shown, gives way to the
    // first one shown.
    onAudioTracksChanged: {
        if (!running && (entries || []).length > 0 && audioTracks.indexOf(followTrack) < 0)
            followTrack = audioTracks.length ? audioTracks[0] : (tracks || [0])[0]
    }

    implicitWidth: 228
    // One block, as tall as what it holds; `compact` (set by the host when
    // the column is short of room) folds what is under the keys into ⋯.
    implicitHeight: column.implicitHeight
    property bool compact: false
    // How tall it is unfolded, folded or not (from its parts, so that
    // folding does not change it).
    readonly property real fullHeight: headRow.implicitHeight + monitorBox.full + keysRow.implicitHeight
                                       + choice.implicitHeight + details.implicitHeight + 4 * column.spacing

    Settings {
        category: "follow"
        property alias track: root.followTrack
    }
    Settings {
        category: "output"
        property alias offset: root.offsetMs
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: 5

        // Its name; listening or not, at the corner: green while it listens,
        // red while not.
        RowLayout {
            id: headRow
            Layout.fillWidth: true
            spacing: 6
            Heading {
                Layout.fillWidth: true
                text: "声学追踪"
            }
            // The light, with its word: green while listening, red while not.
            StatusLight {
                word: !root.following ? "未监听" : root.app && root.app.aiLeads ? "跟随中" : "监听中"
                on: root.following
            }
        }

        // Following's own picture, where it puts the music: 16:9 at the
        // card's width, black until following has found the music; its
        // room always kept.
        Item {
            id: monitorBox
            readonly property real full: width * 9 / 16 + 3
            Layout.fillWidth: true
            Layout.preferredHeight: full
            Layout.minimumHeight: full
            Rectangle {
                width: parent.width
                height: parent.height - 3
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
                        readonly property bool warn: Engine.error.length > 0
                        text: Engine.error.length > 0 ? Engine.error
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
                            onClicked: if (Engine.error.length > 0) Engine.clearError()
                        }
                        ToolTip.visible: statusArea.containsMouse
                        ToolTip.delay: 600
                        ToolTip.text: Engine.error.length > 0 ? Engine.error + "\n（点一下清除）"
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
            id: keysRow
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
            // Follow, or pause following: a key like 监听.
            TextButton {
                implicitHeight: 28
                leftPadding: 8
                rightPadding: 10
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
                tip: "跳至此处：播放器跳到声学追踪判断的位置"
                enabled: !!root.match && !!root.app && root.app.manualSeek
                onClicked: root.app.jumpToMatch()
            }
            Item { Layout.fillWidth: true }
            // Folded (the column short of room): the rest in a popover.
            IconButton {
                id: moreKey
                visible: root.compact
                implicitWidth: 28
                implicitHeight: 28
                iconName: "ellipsis"
                active: more.visible
                tip: "画面偏移、对速和跳转"
                onClicked: more.visible ? more.close() : more.open()
            }
            OffsetKey {
                owner: root
                visible: !root.compact
            }
        }


        // Which track it listens to and the input: right under the keys,
        // folded or not, so both are chosen without ⋯.
        ColumnLayout {
            id: choice
            Layout.fillWidth: true
            spacing: 5
            // Which track it listens to, while there are two: a segmented
            // plate, the one chosen raised.
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
                                              : "声学追踪听" + root.trackName(modelData) + "的声音"
                            }
                        }
                    }
                }
            }

            // The input, its channels with it; 现场模式; 刷新.
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
                    tip: "现场模式：麦克风听现场，在混响里也能跟上。选麦克风时自动打开；电脑内录时关闭"
                    onClicked: root.roomMode = !root.roomMode
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
        }

        // Under it, the rest (details), unless folded into the popover.
        Item {
            id: detailsHome
            visible: !root.compact
            Layout.fillWidth: true
            implicitHeight: root.compact ? 0 : details.implicitHeight
        }
    }

    // The two helpers (and, folded, 画面偏移): under the choice of track
    // and input, or in a popover from ⋯ when the column is short of room.
    ColumnLayout {
        id: details
        parent: root.compact ? moreBody : detailsHome
        width: parent ? parent.width : 0
        spacing: 5

        // Folded, 画面偏移 is here instead of beside the keys.
        RowLayout {
            visible: root.compact
            Layout.fillWidth: true
            Caption {
                Layout.fillWidth: true
                text: "画面偏移"
            }
            OffsetKey { owner: root }
        }
        // The two helpers in full: the speed, and the jump
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
    Popup {
        id: more
        parent: moreKey
        x: moreKey.width - width
        // Under the choice of track and input, which stays in sight.
        y: moreKey.height + column.spacing + choice.height + 6
        width: root.width + 24
        padding: 12
        margins: 8
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.raised
            border.width: 1
            border.color: Theme.line
        }
        contentItem: Item {
            id: moreBody
            implicitWidth: root.width
            implicitHeight: details.implicitHeight
        }
    }
    onCompactChanged: if (!compact) more.close()

    // 画面偏移: dragged sideways or wheeled in 10 ms steps,
    // double-clicked back to 0.
    component OffsetKey: Item {
        id: offsetKey
        // (An inline component does not see this file's ids.)
        property var owner
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
                text: (offsetKey.owner.offsetMs > 0 ? "+" : offsetKey.owner.offsetMs < 0 ? "−" : "±") + Math.abs(offsetKey.owner.offsetMs).toFixed(0) + "ms"
                font.pixelSize: 11
                font.features: { "tnum": 1 }
                color: offsetKey.owner.offsetMs === 0 ? Theme.muted : Theme.text
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
                pressValue = offsetKey.owner.offsetMs
            }
            onPositionChanged: mouse => {
                if (pressed)
                    offsetKey.owner.setOffset(pressValue + Math.round((mouse.x - pressX) / 3) * 10)
            }
            onDoubleClicked: offsetKey.owner.offsetMs = 0
            onWheel: wheel => {
                spun += wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
                const steps = spun > 0 ? Math.floor(spun / 120) : Math.ceil(spun / 120)
                if (steps !== 0) {
                    spun -= steps * 120
                    offsetKey.owner.setOffset(offsetKey.owner.offsetMs + steps * 10)
                }
            }
            ToolTip.visible: containsMouse && !pressed
            ToolTip.delay: 600
            ToolTip.text: "画面偏移：跟随的画面比音乐早（−）或晚（+）多少\n左右拖动或滚轮调，每格 10 ms；双击归零"
        }
    }

    // A small text key: ink while `on`, an outline while not.
    component Chip: AbstractButton {
        id: chip
        property bool on: false
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
}
