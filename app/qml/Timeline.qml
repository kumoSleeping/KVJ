import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// Where following is: one lane per entry that is on, the one on the screen with
// a moving playhead, the others holding where they were last seen. At a handover
// both DJs' entries are on and both lanes show. Above the lanes, the speed the
// music runs at against the recording; below them, that speed over the last minute.
Rectangle {
    id: line
    radius: 8
    color: Theme.raised

    property var entries: []
    property bool running: false
    property string phase: ""
    readonly property var match: Engine.matched && Engine.matched.entry ? Engine.matched : null
    readonly property string playingId: match ? match.entry.id : ""
    readonly property var lanes: entries.filter(e => e.enabled !== false || e.id === playingId)

    // The playhead, carried forward on the engine's clock between matches.
    property real position: 0
    // Where each entry was when it was last on the screen: { id: seconds }.
    property var seen: ({})
    // Rate every quarter second over the last minute; NaN while nothing is followed.
    readonly property int span: 240
    property var rates: []
    property int jumps: 0

    function clock(seconds, tenths) {
        const s = Math.max(0, seconds)
        const m = Math.floor(s / 60)
        const rest = s - m * 60
        const text = tenths ? rest.toFixed(1) : Math.floor(rest).toString()
        return m + ":" + (rest < 10 ? "0" : "") + text
    }
    function now() {
        if (!match)
            return 0
        const p = match.position + (Engine.clockMs() - match.clock_at_ms) / 1000 * match.rate
        return Math.max(0, Math.min(match.entry.duration, p))
    }
    function signed(rate) {
        const pct = (rate - 1) * 100
        return (pct >= 0 ? "+" : "−") + Math.abs(pct).toFixed(1) + "%"
    }

    property string lastId: ""
    property int lastLock: -1
    onMatchChanged: {
        if (lastId.length && lastId !== playingId) {
            const next = Object.assign({}, seen)
            next[lastId] = position
            seen = next
        }
        if (match) {
            if (lastLock >= 0 && match.lock_revision !== lastLock)
                jumps += 1
            lastLock = match.lock_revision
            lastId = playingId
            position = now()
            const i = (lanes || []).findIndex(e => e.id === playingId)
            if (i >= 0)
                laneList.positionViewAtIndex(i, ListView.Contain)
        } else {
            lastId = ""
        }
    }
    onRunningChanged: {
        if (running) {
            seen = {}
            rates = []
            jumps = 0
            lastLock = -1
            lastId = ""
        }
    }

    Timer {
        interval: 50
        repeat: true
        running: !!line.match && line.visible
        onTriggered: line.position = line.now()
    }
    Timer {
        interval: 250
        repeat: true
        running: line.running && line.visible
        onTriggered: {
            const next = line.rates.concat([line.match ? line.match.rate : NaN])
            line.rates = next.length > line.span ? next.slice(next.length - line.span) : next
            trace.requestPaint()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 6

        // What is on the screen, where in it, and how fast.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Caption { text: "时间线" }
            Text {
                Layout.fillWidth: true
                text: line.match ? line.match.entry.title
                    : line.running ? (line.phase === "searching" ? "重新搜索" : "等待识别") : ""
                font.pixelSize: Theme.sizeSm
                font.weight: line.match ? Font.DemiBold : Font.Normal
                color: line.match ? Theme.text : Theme.muted
                elide: Text.ElideRight
            }
            Text {
                visible: !!line.match
                text: line.match ? line.clock(line.position, true) + " / " + line.clock(line.match.entry.duration, false)
                                   + "   剩余 " + line.clock(line.match.entry.duration - line.position, false) : ""
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
                text: line.match ? "×" + line.match.rate.toFixed(3) : "×—"
                font.pixelSize: 20
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: line.match ? Theme.text : Theme.faint
            }
            ColumnLayout {
                spacing: 0
                Text {
                    text: line.match ? line.signed(line.match.rate) : "实时速度"
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: line.match ? Theme.body : Theme.faint
                }
                Text {
                    text: !line.match ? "" : line.match.rate_confidence >= 0.7 ? "速度已稳定" : "速度校准中"
                    font.pixelSize: 11
                    color: Theme.faint
                }
            }
        }

        ListView {
            id: laneList
            Layout.fillWidth: true
            Layout.fillHeight: true
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
                    // A tick every minute.
                    Repeater {
                        model: Math.floor(lane.duration / 60)
                        Rectangle {
                            required property int index
                            x: track.width * (index + 1) * 60 / lane.duration
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
                text: line.entries.length ? "没有启用的素材，在左侧打开要跟随的" : "Set 里还没有素材"
                font.pixelSize: Theme.sizeSm
                color: Theme.faint
            }
        }

        // The last minute of speed, around ×1.000.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.line
        }
        Canvas {
            id: trace
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const w = width, h = height
                const values = line.rates
                let reach = 0.02
                for (const r of values)
                    if (!isNaN(r))
                        reach = Math.max(reach, Math.abs(r - 1) * 1.2)
                const y = r => h / 2 - (r - 1) / reach * (h / 2 - 2)
                ctx.strokeStyle = Theme.line
                ctx.lineWidth = 1
                ctx.setLineDash([3, 3])
                ctx.beginPath()
                ctx.moveTo(0, h / 2)
                ctx.lineTo(w, h / 2)
                ctx.stroke()
                ctx.setLineDash([])
                ctx.strokeStyle = Theme.text
                ctx.lineWidth = 1.5
                ctx.beginPath()
                let open = false
                for (let i = 0; i < values.length; ++i) {
                    const r = values[i]
                    const x = w - (values.length - 1 - i) / (line.span - 1) * w
                    if (isNaN(r)) {
                        open = false
                        continue
                    }
                    if (open)
                        ctx.lineTo(x, y(r))
                    else
                        ctx.moveTo(x, y(r))
                    open = true
                }
                ctx.stroke()
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Text { text: "速度 · 1 分钟前"; font.pixelSize: 10; color: Theme.faint; Layout.fillWidth: true }
            Text {
                visible: line.running && line.jumps > 0
                text: "跳转 " + line.jumps + " 次"
                font.pixelSize: 10
                font.features: { "tnum": 1 }
                color: Theme.faint
            }
            Text { text: "现在"; font.pixelSize: 10; color: Theme.faint; Layout.leftMargin: 8 }
        }
    }
}
