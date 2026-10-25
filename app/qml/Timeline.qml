import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// The player's transport. One lane per entry: the one on the screen with a
// moving playhead, the others holding where they were last seen; pressing or
// dragging on a lane plays that entry from there. Above the lanes, play and
// pause, the speed (a bar, and keys a percent at a time) and how jumps look.
// While smart following leads, it shows where following is and the keys rest:
// only the entries that are on have lanes then, so at a handover between DJs
// both of theirs show. As tall as its lanes, up to four.
Rectangle {
    id: line
    radius: 8
    color: Theme.raised
    implicitHeight: 12 + header.implicitHeight + 8 + controls.implicitHeight + 6 + laneList.Layout.preferredHeight + 12

    property var entries: []
    property bool running: false
    property string phase: ""
    // The window's player: its clock (transport), who leads and what is shown.
    property var player: null

    readonly property bool manual: !!player && player.manual
    readonly property var transport: player ? player.transport : null
    readonly property var shown: player ? player.shownEntry : null
    readonly property string playingId: shown ? shown.id : ""
    readonly property real position: player ? player.playhead : 0
    readonly property real tempo: player ? player.shownTempo : 1
    readonly property var match: player && player.aiPicture ? player.match : null
    readonly property var lanes: manual ? entries : entries.filter(e => e.enabled !== false || e.id === playingId)

    // Where each entry was when it was last on the screen: { id: seconds }.
    property var seen: ({})

    function clock(seconds, tenths) {
        const s = Math.max(0, seconds)
        const m = Math.floor(s / 60)
        const rest = s - m * 60
        const text = tenths ? rest.toFixed(1) : Math.floor(rest).toString()
        return m + ":" + (rest < 10 ? "0" : "") + text
    }
    function signed(rate) {
        const pct = (rate - 1) * 100
        return (pct >= 0 ? "+" : "−") + Math.abs(pct).toFixed(1) + "%"
    }

    property string lastId: ""
    property real lastAt: 0
    onPositionChanged: lastAt = position
    onPlayingIdChanged: {
        if (lastId.length && lastId !== playingId) {
            const next = Object.assign({}, seen)
            next[lastId] = lastAt
            seen = next
        }
        lastId = playingId
        const i = (lanes || []).findIndex(e => e.id === playingId)
        if (i >= 0)
            laneList.positionViewAtIndex(i, ListView.Contain)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 0

        // What is on the screen, where in it, and how fast.
        RowLayout {
            id: header
            Layout.fillWidth: true
            spacing: 8
            IconButton {
                iconName: line.match || (line.transport && line.transport.playing) ? "pause" : "play"
                tip: "播放 / 暂停（空格）"
                enabled: line.manual && !!line.transport && !!line.transport.entry
                onClicked: line.player.toggle()
            }
            Text {
                Layout.fillWidth: true
                text: line.shown ? line.shown.title
                    : line.running ? (line.phase === "searching" ? "重新搜索" : "等待识别")
                    : line.entries.length ? "点下面的素材播放" : "Set 里还没有素材"
                font.pixelSize: Theme.sizeSm
                font.weight: line.shown ? Font.DemiBold : Font.Normal
                color: line.shown ? Theme.text : Theme.muted
                elide: Text.ElideRight
            }
            Text {
                visible: !!line.shown
                text: line.shown ? line.clock(line.position, true) + " / " + line.clock(line.shown.duration, false)
                                   + "   剩余 " + line.clock(line.shown.duration - line.position, false) : ""
                font.pixelSize: Theme.sizeSm
                font.features: { "tnum": 1 }
                color: Theme.body
            }
            Rectangle {
                Layout.preferredWidth: 1
                Layout.preferredHeight: 22
                Layout.leftMargin: 6
                Layout.rightMargin: 6
                color: Theme.line
            }
            Text {
                text: "×" + line.tempo.toFixed(3)
                font.pixelSize: 20
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: line.shown ? Theme.text : Theme.faint
            }
            ColumnLayout {
                spacing: 0
                Text {
                    text: line.signed(line.tempo)
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: Theme.body
                }
                Text {
                    text: line.match ? (line.match.rate_confidence >= 0.7 ? "智能 · 已稳定" : "智能 · 校准中")
                                     : line.manual ? "手动" : "智能跟随"
                    font.pixelSize: 11
                    color: Theme.faint
                }
            }
        }

        // Speed by hand (held, the keys repeat), and how every jump looks.
        RowLayout {
            id: controls
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 6
            Text {
                text: "速度"
                font.pixelSize: Theme.sizeSm
                color: line.manual ? Theme.muted : Theme.faint
            }
            IconButton {
                iconName: "minus"
                tip: "慢 1%"
                autoRepeat: true
                enabled: line.manual && line.transport.tempo > line.transport.minTempo
                onClicked: line.player.nudgeTempo(-0.01)
            }
            Seek {
                id: tempoBar
                Layout.fillWidth: true
                Layout.minimumWidth: 70
                from: line.transport ? (line.transport.minTempo - 1) * 100 : -50
                to: line.transport ? (line.transport.maxTempo - 1) * 100 : 50
                value: (line.tempo - 1) * 100
                enabled: line.manual
                onMoved: line.transport.setTempo(1 + value / 100)
                // Double-click: back to the material's own speed.
                TapHandler {
                    enabled: line.manual
                    onDoubleTapped: line.transport.setTempo(1)
                }
            }
            IconButton {
                iconName: "plus"
                tip: "快 1%"
                autoRepeat: true
                enabled: line.manual && line.transport.tempo < line.transport.maxTempo
                onClicked: line.player.nudgeTempo(0.01)
            }
            Rectangle {
                Layout.preferredWidth: 1
                Layout.preferredHeight: 18
                Layout.leftMargin: 4
                Layout.rightMargin: 4
                color: Theme.line
            }
            Toggle {
                text: "跳转渐变"
                checked: !!line.player && line.player.fadeOn
                onToggled: line.player.fadeOn = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "手动跳转和智能跟随的跳转都从上一个画面溶过去；关掉是直接切"
            }
            Seek {
                Layout.preferredWidth: 80
                Layout.minimumWidth: 50
                from: 100
                to: 2000
                stepSize: 50
                snapMode: Slider.SnapAlways
                value: line.player ? line.player.fadeMs : 400
                enabled: !!line.player && line.player.fadeOn
                onMoved: line.player.fadeMs = value
            }
            Text {
                Layout.preferredWidth: 40
                horizontalAlignment: Text.AlignRight
                text: ((line.player ? line.player.fadeMs : 400) / 1000).toFixed(2) + " s"
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: line.player && line.player.fadeOn ? Theme.body : Theme.faint
            }
        }

        ListView {
            id: laneList
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 6
            Layout.preferredHeight: Math.max(1, Math.min(4, count)) * 28 - 2
            clip: true
            spacing: 2
            model: line.lanes
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: Item {
                id: lane
                required property var modelData
                readonly property bool playing: line.playingId === modelData.id
                readonly property real duration: Math.max(1, modelData.duration)
                readonly property var last: line.seen[modelData.id]
                readonly property real at: playing ? line.position : (last !== undefined ? last : -1)
                width: ListView.view.width
                height: 26

                Text {
                    id: name
                    width: Math.min(170, lane.width * 0.24)
                    anchors.verticalCenter: parent.verticalCenter
                    text: lane.modelData.title
                    font.pixelSize: Theme.sizeXs
                    font.weight: lane.playing ? Font.DemiBold : Font.Normal
                    color: lane.playing ? Theme.text : lane.modelData.enabled === false ? Theme.faint : Theme.muted
                    elide: Text.ElideRight
                    // The name plays the entry from its start.
                    MouseArea {
                        anchors.fill: parent
                        enabled: line.manual
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: line.player.play(lane.modelData, 0)
                    }
                }
                Item {
                    id: track
                    anchors.left: name.right
                    anchors.leftMargin: 10
                    anchors.right: time.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    height: 14

                    Rectangle {
                        id: groove
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 6
                        radius: 3
                        color: Theme.line
                        Rectangle {
                            visible: lane.at >= 0
                            width: parent.width * Math.min(1, lane.at / lane.duration)
                            height: parent.height
                            radius: 3
                            color: lane.playing ? Theme.text : Theme.faint
                            opacity: lane.playing ? 0.9 : 0.6
                        }
                    }
                    // A tick every minute, every five on a long entry.
                    Repeater {
                        id: ticks
                        readonly property int step: lane.duration > 600 ? 300 : 60
                        model: Math.floor(lane.duration / step)
                        Rectangle {
                            required property int index
                            x: track.width * (index + 1) * ticks.step / lane.duration
                            anchors.verticalCenter: parent.verticalCenter
                            width: 1
                            height: 10
                            color: Theme.bg
                            opacity: 0.8
                        }
                    }
                    Rectangle {
                        visible: lane.playing
                        x: track.width * Math.min(1, lane.at / lane.duration) - 1
                        width: 2
                        height: track.height
                        radius: 1
                        color: Theme.text
                    }
                    // Press or drag anywhere on the lane: that entry, from there.
                    MouseArea {
                        anchors.fill: parent
                        anchors.topMargin: -6
                        anchors.bottomMargin: -6
                        enabled: line.manual
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        preventStealing: true
                        function seek(mouse) {
                            line.player.play(lane.modelData, Math.max(0, Math.min(1, mouse.x / width)) * lane.modelData.duration)
                        }
                        onPressed: mouse => {
                            line.player.scrubbing = true
                            seek(mouse)
                        }
                        onPositionChanged: mouse => seek(mouse)
                        onReleased: line.player.scrubbing = false
                        onCanceled: line.player.scrubbing = false
                    }
                }
                Text {
                    id: time
                    width: 72
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: lane.at >= 0 ? line.clock(lane.at, false) + " / " + line.clock(lane.duration, false)
                                       : line.clock(lane.duration, false)
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                    color: lane.playing ? Theme.body : Theme.faint
                }
            }
            Text {
                anchors.centerIn: parent
                visible: laneList.count === 0
                text: line.entries.length ? "没有启用的素材，在左侧打开要跟随的" : "把视频或文件夹拖到左侧"
                font.pixelSize: Theme.sizeSm
                color: Theme.faint
            }
        }
    }
}
