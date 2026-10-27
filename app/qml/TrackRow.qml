import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// One row of the timeline, as an editor's track on a clock of its own: its
// keys on top (the track's name first, which a press chooses on the board,
// then what drives this track's player: play and pause, where it is, its
// cursor and the key that plays from it, the speed with − / + and 复原, what
// happens after its last entry, and 投放 画面 N, the quick cut), under them
// the whole row at a glance, then the row's ruler and its lane. Its keys rest while following leads that
// player.
//
// Each row has its own view of its own length: pinch (or ⌘/Ctrl/Alt +
// scroll) over it zooms it about the pointer, a sideways swipe or a wheel
// moves it, − 全览 + at the ruler's right end (or a double-click on the
// ruler) zoom and fit it; zoomed in, the overview on the bar frames what the
// lane shows, and the lane follows its own playhead unless it was touched a
// moment ago. A press anywhere on a track's row makes it the active row, the
// one Enter, 跳至光标处 and the zoom keys act on (its name is inked);
// a press or drag on its timeline (the overview, the ruler, the lane) only
// places this row's cursor: nothing a click does moves a picture. A
// right click on an entry offers 移出轨道, elsewhere on the lane or on the
// name the track's menu (清空轨道). An empty track's lane is left blank. While entries or files dragged here would
// land on this track (the Timeline judges where a drag drops), the row lights
// up and its lane is veiled with what replaces its entries.
//
//   view      the Timeline (the main player's state, the active row, the drop)
//   spec      { key, kind, track, cameraId, name, entries, player }
//   layout    { clips, total }: the row's entries end to end, from the view
//   rowIndex  the row's place in the view's rows
//   zoomAt(x, factor), zoomStep(factor), fit(), setMark(x), jump(),
//   markClip, canJump: for the Timeline's keys
Item {
    id: row

    property var view: null
    property var spec: ({})
    property var layout: ({ clips: [], total: 0 })
    property int rowIndex: -1

    readonly property string key: spec.key || ""
    readonly property bool camera: spec.kind === "camera"
    readonly property int track: spec.track || 0
    // The first track plays on the window's own player (`view.player`); in
    // everything shown it is a track like the others.
    readonly property bool main: !camera && track === 0
    readonly property var player: main ? view.player : spec.player || null
    readonly property string name: spec.name || (camera ? "相机" : "画面 " + (track + 1))
    readonly property var clips: layout.clips || []
    readonly property real total: layout.total || 0
    readonly property var entries: spec.entries || []
    // The row Enter, 跳至光标处 and the zoom keys act on: the one pressed last.
    readonly property bool active: !camera && view.activeItem === row
    // A drag over the row would put what it carries on this track.
    readonly property bool dropOnto: view.dropZone.kind === "onto" && view.dropZone.index === rowIndex

    // What the row's player shows, where, how fast. The main row's comes from
    // the view, which knows who leads.
    readonly property string playingId: main ? view.playingId : player && player.entry ? player.entry.id : ""
    readonly property real position: main ? view.position : player ? player.playhead : 0
    readonly property var playClip: clips.find(c => c.entry.id === playingId) || null
    readonly property real playT: playClip ? playClip.start + Math.min(position, playClip.length) : -1
    readonly property var shown: main ? view.shown : player ? player.entry : null
    // The keys a hand may use: none of them while following leads the player.
    readonly property bool canSeek: main ? view.manualSeek : !!player && !player.lead
    // 同步变速: this aux track plays at the main one's speed, and its
    // speed keys change the main one's (so both).
    readonly property bool linked: !main && view.tempoLinked
    readonly property bool canTempo: main || linked ? view.manualTempo : !!player && !player.lead
    readonly property bool playing: main ? !!view.match || (!!view.transport && view.transport.playing) : !!player && player.playing
    readonly property bool canPlay: main ? view.manualSeek && !!view.transport && !!view.transport.entry : canSeek && clips.length > 0
    // The speed played (the main one bent while a nudge key is held), and the setting it comes back to.
    readonly property real speed: main ? view.speed : player ? player.effectiveSpeed : 1
    readonly property real setting: main || linked ? view.tempo : player ? player.speed : 1
    readonly property real minSpeed: main || linked ? (view.transport ? view.transport.minTempo : 0.5) : player ? player.minSpeed : 0.5
    readonly property real maxSpeed: main || linked ? (view.transport ? view.transport.maxTempo : 1.5) : player ? player.maxSpeed : 1.5
    readonly property bool bending: main && view.bending !== 0
    readonly property bool loop: main ? !!view.player && view.player.loopOn : !!player && player.loop
    readonly property bool followed: !camera && view.followTrack === track
    readonly property bool onAir: view.onAir.indexOf(key) >= 0
    readonly property bool inPreview: view.inPreview.indexOf(key) >= 0

    // The keys' line, the whole row at a glance under it, the ruler.
    readonly property int barHeight: 32
    readonly property int overviewHeight: 20
    readonly property int rulerHeight: 16
    // The audience sees this track and nothing else.
    // Its layer is the top one the audience sees (what its 投放 does).
    readonly property bool onTop: view.onTop === key

    // —— The row's view: pixels a second (0 = all of it fits) and the second at the left edge ——
    property real zoom: 0
    property real viewStart: 0
    // When the row was last touched; until a while after, it does not follow its playhead.
    property real touchedAt: 0
    property int swipeAxis: 0
    readonly property real laneWidth: Math.max(1, lane.width)
    // A minute while the row is empty, so its ruler still has ticks.
    readonly property real extent: total > 0 ? total : 60
    readonly property real maxScale: 400
    readonly property real fitScale: laneWidth / Math.max(1, extent)
    readonly property real pps: zoom > 0 ? Math.max(fitScale, Math.min(maxScale, zoom)) : fitScale
    readonly property real span: laneWidth / Math.max(1e-6, pps)
    readonly property real viewLeft: Math.max(0, Math.min(viewStart, extent - span))
    readonly property bool zoomed: pps > fitScale + 1e-6
    readonly property real notchZoom: 1.15
    // For TrackPiece, which takes the row as its view.
    readonly property var emptyClip: ({ entry: { id: "", path: "", title: "", duration: 0, video: false }, n: 0, start: 0, length: 0 })
    function tempoColor(bpm) {
        return view.tempoColor(bpm)
    }

    // —— The row's cursor: an entry and a second in it ——
    property string markId: ""
    property real markAt: 0
    readonly property var markClip: clips.find(c => c.entry.id === markId) || null
    readonly property real markT: markClip ? markClip.start + Math.min(markAt, markClip.length) : -1
    readonly property bool canJump: canSeek && !!markClip

    // Each row's view and cursor are kept (by the view, per Set and row) and
    // come back with the row.
    function keep() {
        view.keep(key, { zoom: zoom, viewStart: viewStart, markId: markId, markAt: markAt })
    }
    function restore() {
        const s = key ? view.kept(key) : null
        zoom = s ? s.zoom : 0
        viewStart = s ? s.viewStart : 0
        markId = s ? s.markId : ""
        markAt = s ? s.markAt : 0
        touchedAt = 0
    }
    onKeyChanged: Qt.callLater(row.restore)
    Connections {
        target: row.view
        function onSetIdChanged() {
            Qt.callLater(row.restore)
        }
    }
    Component.onCompleted: restore()

    function touch() {
        touchedAt = Date.now()
        keep()
        view.mirror(row)
    }
    // Zoom by `factor` keeping the second under `x` (lane pixels) where it is.
    function zoomAt(x, factor) {
        const t = viewLeft + x / pps
        const next = Math.max(fitScale, Math.min(maxScale, pps * factor))
        zoom = next
        viewStart = Math.max(0, Math.min(t - x / next, extent - laneWidth / next))
        touch()
    }
    // The lane shows seconds `left` on, or `a` to `b` (the overview's frame
    // dragged, or its ends).
    function moveView(left) {
        viewStart = Math.max(0, Math.min(left, extent - span))
        touch()
    }
    function setView(a, b) {
        a = Math.max(0, a)
        zoom = laneWidth / Math.max(laneWidth / maxScale, Math.min(extent, b) - a)
        viewStart = a
        touch()
    }
    function pan(pixels) {
        viewStart = Math.max(0, Math.min(viewLeft + pixels / pps, extent - span))
        touch()
    }
    function fit() {
        zoom = 0
        viewStart = 0
        keep()
        view.mirror(row)
    }
    // The − / + keys: a step about the playhead, or the cursor, if the lane
    // shows it, as an editor's zoom keys do; else about the middle.
    function zoomStep(factor) {
        const shows = t => t >= viewLeft && t <= viewLeft + span
        const t = shows(playT) ? playT : shows(markT) ? markT : viewLeft + span / 2
        zoomAt((t - viewLeft) * pps, factor)
    }
    // Scrolling over the row. A trackpad (a gesture with phases, as macOS
    // sends) moves the lane with the fingers, one for one, along the axis the
    // gesture started on, its momentum included: a swipe across that drifts up
    // or down does not jitter; once the rows are more than fit, a swipe up or
    // down scrolls them instead. A wheel (any mouse; Windows sends touchpads as
    // fine wheel steps too) moves a tenth of the view a notch, tilted or with
    // Shift across as well; upright it scrolls the rows once they are more
    // than fit. ⌘/Ctrl, or Alt as in After Effects and Premiere, zooms about
    // the pointer, as a pinch does (Windows sends a touchpad's pinch as Ctrl +
    // wheel): a wheel's notch is one fine step (macOS hands every notch over
    // on its own, however fast the wheel turns), a fraction of one on a fine
    // wheel; a trackpad follows the fingers and stops when they lift, its
    // glide left out.
    function scroll(wheel, x) {
        const p = wheel.pixelDelta
        const a = wheel.angleDelta
        if (wheel.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier)) {
            if (wheel.phase === Qt.ScrollMomentum)
                return
            if (p.x !== 0 || p.y !== 0) {
                zoomAt(x, Math.pow(1.005, Math.max(-60, Math.min(60, p.y !== 0 ? p.y : p.x))))
            } else {
                const notches = (a.y !== 0 ? a.y : a.x) / 120
                zoomAt(x, Math.pow(notchZoom, Math.max(-2, Math.min(2, notches))))
            }
            return
        }
        if (wheel.phase !== Qt.NoScrollPhase) {
            // macOS begins a gesture as the fingers land, before they move,
            // so the begin carries no delta: each gesture picks its axis anew.
            if (wheel.phase === Qt.ScrollBegin || wheel.phase === Qt.ScrollEnd)
                swipeAxis = 0
            if (p.x === 0 && p.y === 0)
                return
            if (swipeAxis === 0)
                swipeAxis = Math.abs(p.x) >= Math.abs(p.y) ? 1 : 2
            pan(-(swipeAxis === 1 ? p.x : p.y))
            return
        }
        const notches = (Math.abs(a.x) > Math.abs(a.y) ? a.x : a.y) / 120
        pan(-notches * span * 0.1 * pps)
    }

    // The cursor to `seconds` along the row (or lane pixel `x`); this row becomes the active one.
    function markTime(seconds) {
        if (!clips.length)
            return
        const t = Math.max(0, Math.min(total - 0.001, seconds))
        for (const c of clips) {
            if (t < c.start + c.length) {
                markId = c.entry.id
                markAt = Math.max(0, Math.min(c.entry.duration, t - c.start))
                break
            }
        }
        view.activate(key)
        touch()
    }
    function setMark(x) {
        markTime(viewLeft + Math.max(0, Math.min(laneWidth, x)) / pps)
    }
    // From the cursor: the main track as its jumps go (app.play), an aux
    // track the same way (TrackPlayer.play): within the entry shown it keeps
    // playing or paused, another entry starts playing.
    function jump() {
        if (!canJump)
            return
        if (main)
            view.player.play(markClip.entry, markAt)
        else
            player.play(markClip.entry, markAt)
    }
    // Played from second `t` of the track (its own time), the cursor left
    // where it is.
    function playAtTime(t) {
        const c = clips.find(c => t >= c.start && t < c.start + c.length) || clips[clips.length - 1]
        if (!c)
            return
        const at = Math.max(0, Math.min(c.entry.duration, t - c.start))
        if (main)
            view.player.play(c.entry, at)
        else if (player)
            player.play(c.entry, at)
    }
    // The other track row, the one this one syncs to.
    readonly property var other: view.rowItems.find(r => !!r && r !== row && !r.camera) || null
    // This row's own player, whichever row is active (the window's toggle
    // acts on the active row).
    function togglePlay() {
        if (main) {
            if (view.manualSeek && view.transport) {
                view.transport.toggle()
                view.player.tick()
            }
        } else if (player) {
            player.toggle()
        }
    }
    // Where its playhead is this instant, in the track's own seconds (not as
    // of the last tick): what another row lines up with.
    function liveT() {
        if (!playClip)
            return -1
        const at = main ? (view.player && view.player.aiMain ? position : view.transport.now()) : player.now()
        return playClip.start + Math.min(at, playClip.length)
    }
    function nudgeSpeed(step) {
        if (!canTempo)
            return
        if (main)
            view.player.nudgeTempo(step)
        else if (linked)
            view.transport.setTempo(view.transport.tempo + step)
        else
            player.setSpeed(player.speed + step)
    }
    function setSpeedTo(value) {
        if (!canTempo)
            return
        if (main || linked)
            view.transport.setTempo(value)
        else
            player.setSpeed(value)
    }
    function resetSpeed() {
        if (!canTempo)
            return
        if (main || linked)
            view.player.resetTempo()
        else
            player.setSpeed(1)
    }
    function flipLoop() {
        if (main)
            view.player.loopOn = !view.player.loopOn
        else if (player)
            player.loop = !player.loop
    }

    // Tick marks in each entry's own time (plain seconds while the row is
    // empty), at least 70 px apart. A label that would run into the one before
    // (many short entries, each starting at 0:00) is left off; its mark stays.
    readonly property var ticks: {
        const out = []
        if (camera || pps <= 0)
            return out
        const along = clips.length ? clips : [{ start: 0, length: extent }]
        const steps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        const step = steps.find(s => s * pps >= 70) || 7200
        let labelled = -1e9
        for (const c of along) {
            const a = Math.max(c.start, viewLeft)
            const b = Math.min(c.start + c.length, viewLeft + span)
            // None so near an entry's end that its label runs into the next entry's 0:00.
            for (let k = Math.ceil((a - c.start) / step - 1e-6); b > a && c.start + k * step <= b && out.length < 300; ++k) {
                if (k !== 0 && (c.length - k * step) * pps < 48)
                    continue
                const x = (c.start + k * step - viewLeft) * pps
                const fits = x - labelled >= 48
                if (fits)
                    labelled = x
                out.push({ x: x, label: fits ? view.clock(k * step, step < 1) : "" })
            }
        }
        return out
    }

    // While playing, a playhead that leaves the view brings it along, unless
    // the row was touched a moment ago.
    Timer {
        interval: 200
        repeat: true
        running: row.visible && row.zoomed && row.playT >= 0 && row.playing
        onTriggered: {
            // Synced, the rows' one view follows them all (Timeline.followTogether).
            if (Date.now() - row.touchedAt < 4000 || row.view.viewsLocked)
                return
            if (row.playT < row.viewLeft || row.playT > row.viewLeft + row.span * 0.97) {
                row.viewStart = Math.max(0, row.playT - row.span * 0.1)
                row.view.mirror(row)
            }
        }
    }

    // The track's menu: a right click on an empty part of its lane. Clearing
    // a track puts what is on it back in the library.
    Item {
        id: header
        PopMenu {
            id: trackMenu
            PopAction {
                enabled: !!row.player && !row.main && !row.view.tempoLinked
                text: row.player && row.player.followMain ? "不再跟随画面 1 的速度" : "跟随画面 1 的速度"
                onTriggered: row.player.followMain = !row.player.followMain
            }
            MenuSeparator {}
            PopAction {
                enabled: !row.view.running && row.clips.length > 0
                text: row.view.running ? "清空轨道（先停止监听）" : "清空轨道（素材回到素材库）"
                risky: true
                onTriggered: row.view.clearTrack(row.track)
            }
        }
        function openMenu(item, x, y) {
            trackMenu.popup(item, x, y)
        }
    }

    // —— The play bar, the ruler and the lane ——
    Item {
        id: body
        width: row.width
        height: row.height

        RowLayout {
            id: bar
            visible: !row.camera
            width: parent.width
            height: row.barHeight
            spacing: 2

            // The track's name: inked while it is the active row, PGM's dot
            // while the audience sees it. A press chooses its layer on the
            // board; a right click opens its menu.
            Rectangle {
                implicitWidth: nameText.implicitWidth + (row.onAir ? 22 : 14)
                implicitHeight: 20
                radius: 10
                color: row.active && row.view.rows.length > 1 ? Theme.text : nameArea.containsMouse ? Theme.hover : Theme.inset
                Rectangle {
                    visible: row.onAir
                    x: 7
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6
                    height: 6
                    radius: 3
                    color: Theme.danger
                }
                Text {
                    id: nameText
                    x: row.onAir ? 16 : 7
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.name
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    color: row.active && row.view.rows.length > 1 ? Theme.bg : Theme.body
                }
                MouseArea {
                    id: nameArea
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => {
                        row.view.activate(row.key)
                        if (mouse.button === Qt.RightButton)
                            header.openMenu(nameArea, mouse.x, mouse.y)
                        else
                            row.view.pickSource(row.key)
                    }
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 700
                    ToolTip.text: row.name + (row.onAir ? "（观众正看到）" : "") + " · 点一下在画板上选中 · 右键：清空轨道"
                }
            }
            Item { Layout.preferredWidth: 6 }
            Text {
                id: timeText
                Layout.preferredWidth: 104
                text: row.playClip ? (row.clips.length > 1 ? row.playClip.n + " · " : "")
                                     + row.view.clock(row.position, true) + " / " + row.view.clock(row.playClip.entry.duration, false)
                      : row.clips.length ? "—" : ""
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: row.canSeek ? Theme.body : Theme.muted
                elide: Text.ElideRight
            }
            Item { Layout.fillWidth: true }
            // The speed: a percent a key, the bar, 复原 (or a double-click on the readout).
            IconButton {
                id: speedDown
                implicitWidth: 22
                implicitHeight: 22
                iconSize: 12
                iconName: "minus"
                tip: "慢 1%"
                autoRepeat: true
                enabled: row.canTempo && row.setting > row.minSpeed + 1e-6
                onClicked: row.nudgeSpeed(-0.01)
            }
            Seek {
                Layout.preferredWidth: 64
                Layout.minimumWidth: 40
                implicitHeight: 22
                from: (row.minSpeed - 1) * 100
                to: (row.maxSpeed - 1) * 100
                value: (row.setting - 1) * 100
                enabled: row.canTempo
                onMoved: row.setSpeedTo(1 + value / 100)
                TapHandler {
                    enabled: row.canTempo
                    onDoubleTapped: row.resetSpeed()
                }
            }
            IconButton {
                implicitWidth: 22
                implicitHeight: 22
                iconSize: 12
                iconName: "plus"
                tip: "快 1%"
                autoRepeat: true
                enabled: row.canTempo && row.setting < row.maxSpeed - 1e-6
                onClicked: row.nudgeSpeed(0.01)
            }
            Text {
                Layout.preferredWidth: 50
                horizontalAlignment: Text.AlignRight
                text: "×" + row.speed.toFixed(3)
                font.pixelSize: Theme.sizeSm
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: row.bending ? Theme.warn : row.shown ? Theme.text : Theme.faint
                MouseArea { anchors.fill: parent; enabled: row.canTempo; onDoubleClicked: row.resetSpeed() }
            }
            Text {
                Layout.preferredWidth: 46
                text: row.view.signed(row.speed)
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: row.bending ? Theme.warn : Theme.body
                MouseArea { anchors.fill: parent; enabled: row.canTempo; onDoubleClicked: row.resetSpeed() }
            }
            TextButton {
                flat: true
                implicitHeight: 22
                leftPadding: 6
                rightPadding: 6
                font.pixelSize: Theme.sizeXs
                text: "复原"
                enabled: row.canTempo && Math.abs(row.setting - 1) > 1e-6
                onClicked: row.resetSpeed()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "回到素材原速（也可双击速度）"
            }
            // Who sets the speed: following, a held key, the hand; for an aux track, the main one's pace.
            Text {
                Layout.maximumWidth: 96
                text: row.main ? (row.view.match ? (row.view.match.rate_confidence >= 0.7 ? "智能 · 已稳定" : "智能 · 校准中")
                                  : row.view.player && row.view.player.aiLeads ? (row.view.player.tempoPaused ? "智能跳转 · 手动速度" : "智能调速 · 不跳转")
                                  : row.bending ? (row.view.speed > row.view.tempo ? "按住加速" : "按住减速")
                                  : row.view.manual ? "手动" : "智能跟随")
                      : row.player && row.player.lead ? "智能跟随"
                      : row.linked ? "同步变速"
                      : row.player && row.player.followMain ? "跟画面 1 速度" : "手动"
                font.pixelSize: 11
                color: Theme.faint
                elide: Text.ElideRight
            }
            Item { Layout.preferredWidth: 4 }
            // What happens after the row's last entry.
            TextButton {
                flat: true
                implicitHeight: 22
                leftPadding: 6
                rightPadding: 8
                font.pixelSize: Theme.sizeXs
                iconName: row.loop ? "refresh" : ""
                text: row.loop ? "循环" : "播完即停"
                enabled: row.main ? !!row.view.player : !!row.player
                onClicked: row.flipLoop()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: row.loop ? "循环播放：放完这条轨道的最后一个素材后从第一个重来；点一下改为播完即停"
                                       : "播完即停：放完这条轨道的最后一个素材后停在最后一帧；点一下改为循环播放"
            }
            Item { Layout.preferredWidth: 4 }
            // 快切: this track's layer floated to the top, to the audience with
            // the board's dissolve, as it is sized; the others stay under it.
            TextButton {
                implicitHeight: 22
                leftPadding: 8
                rightPadding: 10
                outlined: !row.onTop
                primary: row.onTop
                font.pixelSize: Theme.sizeXs
                iconName: "cast"
                text: "投放" + row.name
                onClicked: row.view.takeLive(row.key)
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "快切（" + (row.track === 0 ? "[" : "]") + "）：" + row.name + " 浮到最上层投给观众，保留它在画板上的大小和位置（在画外时铺满画面）；其它画面留在下面。用画板的渐变设置"
            }
        }
        // In the middle of the keys line: play, the cursor and the keys that
        // play from it. Centred on the row, kept clear of the keys at either side.
        Row {
            id: middle
            visible: !row.camera
            readonly property real leftEnd: timeText.x + timeText.width + 12
            readonly property real rightStart: speedDown.x - 12
            x: Math.max(leftEnd, Math.min((bar.width - width) / 2, rightStart - width))
            height: row.barHeight
            spacing: 6
            // Play / pause: a round key, ink while it plays.
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                id: playKey
                implicitWidth: 28
                implicitHeight: 28
                iconSize: 15
                iconName: row.playing ? "pause" : "play"
                enabled: row.canPlay
                icon.color: !enabled ? Theme.faint : row.playing ? Theme.bg : Theme.text
                background: Rectangle {
                    radius: 14
                    color: row.playing ? (playKey.hovered ? Theme.body : Theme.text)
                         : playKey.down ? Theme.selected : playKey.hovered && playKey.enabled ? Theme.hover : Theme.inset
                    Behavior on color { ColorAnimation { duration: 90 } }
                }
                tip: (row.playing ? "暂停" : "播放") + row.name
                onClicked: row.togglePlay()
            }
            // To the other track's time, both playing: the same videos line
            // up, the timeline as one.
            TextButton {
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: 20
                leftPadding: 6
                rightPadding: 6
                outlined: true
                font.pixelSize: 11
                text: "同步播放"
                enabled: row.canSeek && row.clips.length > 0 && !!row.other && row.other.playT >= 0
                onClicked: row.view.syncPlay(row)
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: row.other ? row.name + " 跳到" + row.other.name + "正在播放的时间，两条一起播放" : ""
            }
            TextButton {
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: 20
                leftPadding: 6
                rightPadding: 6
                outlined: true
                font.pixelSize: 11
                text: "跳至"
                enabled: row.canJump
                onClicked: row.view.jumpRow(row)
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "从光标处播放" + row.name + "（选中的轨道也可按回车）"
            }
        }


        // The row's whole length at a glance: where its picture is, a
        // notch where one entry meets the next, its cursor as a hollow
        // ball and, zoomed in, a frame round what the lane shows. A press
        // or drag places the cursor, never the picture.
        Item {
            id: seek
            visible: !row.camera
            y: row.barHeight
            width: parent.width
            height: row.overviewHeight
            readonly property real share: row.total > 0 && row.playT >= 0 ? Math.max(0, Math.min(1, row.playT / row.total)) : 0
            function timeAt(x) {
                return Math.max(0, Math.min(1, x / width)) * row.total
            }
            // The frame round what the lane shows, in the bar's pixels, never
            // too thin to take hold of.
            readonly property bool framed: row.zoomed && row.total > 0
            readonly property real frameW: Math.min(width, Math.max(12, width * row.span / row.extent))
            readonly property real frameX: Math.max(0, Math.min(width - frameW, width * (row.viewLeft + row.span / 2) / row.extent - frameW / 2))
            // What a press at `x` takes hold of: the frame ("move"), one of its
            // ends ("left", "right"), nothing ("near", a band round it) or the
            // cursor ("mark"). A press on the frame never goes through to the bar.
            function zoneAt(x) {
                if (!framed)
                    return "mark"
                const a = frameX, b = frameX + frameW
                const grip = Math.min(6, frameW / 4)
                if (x >= a + grip && x <= b - grip)
                    return "move"
                if (x >= a - 8 && x < a + grip)
                    return "left"
                if (x > b - grip && x <= b + 8)
                    return "right"
                if (x >= a - 28 && x <= b + 28)
                    return "near"
                return "mark"
            }
            // The whole track: each entry a soft segment, what has played of
            // it a shade deeper (not ink), a gap where one meets the next.
            Item {
                id: groove
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 8
                Repeater {
                    model: row.clips.length ? row.clips : [{ start: 0, length: row.extent }]
                    Rectangle {
                        required property var modelData
                        readonly property real from: groove.width * modelData.start / Math.max(1e-6, row.extent)
                        readonly property real to: groove.width * (modelData.start + modelData.length) / Math.max(1e-6, row.extent)
                        x: from + (modelData.start > 0 ? 1.5 : 0)
                        width: Math.max(2, to - x)
                        height: groove.height
                        radius: 4
                        color: Theme.dark ? "#2a303a" : "#e9e9ee"
                        clip: true
                        Rectangle {
                            width: Math.max(0, Math.min(parent.width, groove.width * seek.share - parent.x))
                            height: parent.height
                            color: row.canSeek ? (Theme.dark ? "#6b7380" : "#9a9aa2") : (Theme.dark ? "#3a404a" : "#cfcfd5")
                        }
                    }
                }
            }
            // The part the lane shows, while zoomed in: a clear window over it
            // that drags along, its ends (grips) wider or narrower.
            Rectangle {
                id: frame
                readonly property string held: seekArea.zone
                visible: seek.framed
                x: seek.frameX
                width: seek.frameW
                height: parent.height
                radius: 5
                color: Theme.dark ? (held === "move" ? "#38ffffff" : "#22ffffff") : (held === "move" ? "#24000000" : "#14000000")
                border.width: held === "move" || held === "left" || held === "right" ? 2 : 1.5
                border.color: held ? Theme.text : (Theme.dark ? "#c3c8d0" : "#55555c")
                Repeater {
                    model: ["left", "right"]
                    Rectangle {
                        required property string modelData
                        visible: frame.width >= 24
                        x: modelData === "left" ? 4 : frame.width - 4 - width
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2
                        height: 10
                        radius: 1
                        color: frame.held === modelData ? Theme.text : Theme.muted
                    }
                }
            }
            // The playhead: an upright capsule.
            Rectangle {
                visible: row.playT >= 0
                x: seek.width * seek.share - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 4
                height: 16
                radius: 2
                color: row.canSeek ? Theme.text : Theme.muted
            }
            Rectangle {
                visible: row.markT >= 0 && row.total > 0
                x: seek.width * row.markT / row.total - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 11
                height: 11
                radius: 5.5
                color: Theme.raised
                border.width: 2
                border.color: row.active ? Theme.text : Theme.muted
                scale: seekArea.pressed && seekArea.held === "mark" ? 1.2 : 1
            }
            // Where a press would put the cursor.
            Rectangle {
                visible: seekArea.hoverZone === "mark" && !seekArea.pressed && seekArea.enabled
                x: seekArea.mouseX - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 11
                height: 11
                radius: 5.5
                color: "transparent"
                border.width: 1.5
                border.color: Theme.faint
            }
            MouseArea {
                id: seekArea
                anchors.fill: parent
                enabled: row.clips.length > 0
                hoverEnabled: true
                preventStealing: true
                // What the press took hold of, and where the frame was then.
                property string held: ""
                property real grabX: 0
                property real grabLeft: 0
                property real grabRight: 0
                readonly property string hoverZone: containsMouse ? seek.zoneAt(mouseX) : ""
                readonly property string zone: pressed ? held : hoverZone
                cursorShape: zone === "move" ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                             : zone === "left" || zone === "right" ? Qt.SizeHorCursor
                             : zone === "mark" ? Qt.PointingHandCursor : Qt.ArrowCursor
                onPressed: mouse => {
                    held = seek.zoneAt(mouse.x)
                    grabX = mouse.x
                    grabLeft = row.viewLeft
                    grabRight = row.viewLeft + row.span
                    if (held === "mark")
                        row.markTime(seek.timeAt(mouse.x))
                }
                onPositionChanged: mouse => {
                    if (!pressed)
                        return
                    const d = (mouse.x - grabX) / width * row.extent
                    const least = row.laneWidth / row.maxScale
                    if (held === "mark")
                        row.markTime(seek.timeAt(mouse.x))
                    else if (held === "move")
                        row.moveView(grabLeft + d)
                    else if (held === "left")
                        row.setView(Math.min(grabLeft + d, grabRight - least), grabRight)
                    else if (held === "right")
                        row.setView(grabLeft, Math.max(grabRight + d, grabLeft + least))
                }
                onReleased: held = ""
                onCanceled: held = ""
                onWheel: wheel => row.scroll(wheel, row.laneWidth / 2)
                ToolTip.visible: containsMouse && !pressed && hoverZone === "mark"
                ToolTip.delay: 900
                ToolTip.text: "按下或拖动放光标；回车或「跳至」从光标处播放 · 放大后：拖方框移动显示的区间，拖两端改宽窄"
            }
        }



        // The row's ruler, in each entry's own time: its playhead's flag and
        // its cursor's diamond. A press or drag places the cursor, a
        // double-click shows the whole row; − 全览 + at its right end.
        Item {
            id: ruler
            visible: !row.camera
            y: row.barHeight + row.overviewHeight
            width: parent.width
            height: row.rulerHeight
            clip: true
            // By place: panning makes the ticks afresh every frame.
            Repeater {
                model: row.ticks.length
                Item {
                    required property int index
                    readonly property var modelData: row.ticks[index] || { x: 0, label: "" }
                    x: modelData.x
                    height: ruler.height
                    Rectangle {
                        y: ruler.height - height
                        width: 1
                        height: 4
                        color: Theme.faint
                    }
                    Text {
                        x: 3
                        y: 0
                        text: parent.modelData.label
                        font.pixelSize: 9
                        font.features: { "tnum": 1 }
                        color: Theme.faint
                    }
                }
            }
            Rectangle {
                visible: rulerArea.containsMouse && !rulerArea.pressed && row.clips.length > 0
                x: rulerArea.mouseX
                width: 1
                height: ruler.height
                color: Theme.faint
            }
            Rectangle {
                visible: row.playT >= row.viewLeft && row.playT <= row.viewLeft + row.span
                x: (row.playT - row.viewLeft) * row.pps - 5
                y: 2
                width: 10
                height: ruler.height - 2
                radius: 3
                color: row.canSeek ? Theme.text : Theme.muted
            }
            Rectangle {
                visible: row.markT >= row.viewLeft && row.markT <= row.viewLeft + row.span
                x: (row.markT - row.viewLeft) * row.pps - 4.5
                y: ruler.height - 8
                width: 9
                height: 9
                rotation: 45
                color: row.active ? Theme.text : Theme.muted
            }
            MouseArea {
                id: rulerArea
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: row.clips.length ? Qt.PointingHandCursor : Qt.ArrowCursor
                onPressed: mouse => row.setMark(mouse.x)
                onPositionChanged: mouse => {
                    if (pressed)
                        row.setMark(mouse.x)
                }
                onDoubleClicked: row.fit()
                onWheel: wheel => row.scroll(wheel, wheel.x)
            }
            PinchHandler {
                target: null
                onScaleChanged: delta => row.zoomAt(centroid.position.x, delta)
            }
            // The row's zoom keys, on a plate over the ruler's right end.
            Rectangle {
                anchors.right: parent.right
                width: zoomKeys.implicitWidth + 4
                height: parent.height
                radius: 3
                color: Theme.raised
                Row {
                    id: zoomKeys
                    anchors.centerIn: parent
                    spacing: 0
                    Repeater {
                        model: [{ label: "−", tip: "缩小这条轨道" }, { label: "全览", tip: "整条轨道（也可双击标尺）" }, { label: "+", tip: "放大这条轨道" }]
                        AbstractButton {
                            id: zoomKey
                            required property var modelData
                            required property int index
                            implicitWidth: label.implicitWidth + 10
                            implicitHeight: row.rulerHeight
                            autoRepeat: index !== 1
                            hoverEnabled: true
                            enabled: index === 0 || index === 1 ? row.zoomed : row.total > 0 && row.pps < row.maxScale - 1e-6
                            onClicked: index === 1 ? row.fit() : row.zoomStep(index === 0 ? 1 / 1.3 : 1.3)
                            background: Rectangle {
                                radius: 3
                                color: zoomKey.down ? Theme.selected : zoomKey.hovered && zoomKey.enabled ? Theme.hover : "transparent"
                            }
                            contentItem: Text {
                                id: label
                                text: zoomKey.modelData.label
                                font.pixelSize: 10
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                color: zoomKey.enabled ? (zoomKey.hovered ? Theme.text : Theme.muted) : Theme.faint
                            }
                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: modelData.tip + "（这条轨道选中时也可按快捷键 − / = / \\）"
                        }
                    }
                }
            }
        }

        // The entries end to end, the row's playhead and its cursor.
        Item {
            id: lane
            visible: !row.camera
            y: row.barHeight + row.overviewHeight + row.rulerHeight
            width: parent.width
            height: parent.height - y
            clip: true
            readonly property int tempoHeight: 14
            readonly property int waveHeight: Math.round((height - tempoHeight - 1) * 0.36)
            readonly property int filmHeight: height - tempoHeight - 1 - waveHeight

            // Nothing on the track: a faint outline where its entries would lie.
            Rectangle {
                anchors.fill: parent
                visible: !row.clips.length
                radius: Theme.radius
                color: "transparent"
                border.width: 1
                border.color: Theme.line
            }
            // By place, not by clip: the clips are made afresh whenever the
            // Set or the entry on the screen changes (every cut), and a model
            // of them would build every strip anew each time.
            Repeater {
                model: row.clips.length
                TrackPiece {
                    required property int index
                    view: row
                    clip: row.clips[index]
                    stripWidth: lane.width
                    tempoHeight: lane.tempoHeight
                    filmHeight: lane.filmHeight
                    waveHeight: lane.waveHeight
                    playingId: row.playingId
                    position: row.position
                    dimOff: row.main ? !row.view.manual : true
                    dimSilent: row.main ? !row.view.manual : false
                    numbered: row.clips.length > 1
                    small: true
                }
            }
            Rectangle {
                visible: laneArea.containsMouse && !laneArea.pressed && row.clips.length > 0
                x: laneArea.mouseX
                width: 1
                height: lane.height
                color: "#80ffffff"
            }
            // The cursor.
            Rectangle {
                visible: row.markT >= row.viewLeft && row.markT <= row.viewLeft + row.span
                x: (row.markT - row.viewLeft) * row.pps - 1.5
                width: 3
                height: lane.height
                color: "#99000000"
                Rectangle {
                    x: 1
                    width: 1
                    height: parent.height
                    color: "white"
                }
            }
            Item {
                visible: row.playT >= row.viewLeft && row.playT <= row.viewLeft + row.span
                x: (row.playT - row.viewLeft) * row.pps
                height: lane.height
                Rectangle {
                    x: -2
                    width: 4
                    height: lane.height
                    radius: 1
                    color: "#99000000"
                    Rectangle {
                        x: 1
                        width: 2
                        height: parent.height
                        color: row.canSeek ? Theme.text : Theme.muted
                    }
                }
            }
            // What is dragged here takes the track's place, as a record put
            // on a deck: the whole lane, veiled, says so.
            Rectangle {
                visible: row.dropOnto
                width: lane.width
                height: lane.height
                radius: Theme.radius
                color: Qt.rgba(Theme.selected.r, Theme.selected.g, Theme.selected.b, 0.88)
                border.width: 2
                border.color: Theme.text
                Text {
                    x: 10
                    y: 8
                    width: parent.width - 20
                    text: (row.clips.length ? "替换为：" : "放上：") + row.view.dropTitle
                    font.pixelSize: Theme.sizeXs
                    font.weight: Font.DemiBold
                    color: Theme.text
                    elide: Text.ElideRight
                }
            }
            // A press or drag places the cursor, never the picture (Enter or
            // 跳至 plays from it); a right click on an entry offers 移出轨道,
            // elsewhere the track's menu.
            // The wheel and a pinch move and zoom this row.
            MouseArea {
                id: laneArea
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: row.clips.length ? Qt.PointingHandCursor : Qt.ArrowCursor
                function clipAt(x) {
                    const t = row.viewLeft + x / row.pps
                    return row.clips.find(c => t >= c.start && t < c.start + c.length) || null
                }
                onPressed: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        const c = clipAt(mouse.x)
                        if (c) {
                            pieceMenu.entryId = c.entry.id
                            pieceMenu.popup()
                        } else {
                            header.openMenu(laneArea, mouse.x, mouse.y)
                        }
                        return
                    }
                    row.setMark(mouse.x)
                }
                onPositionChanged: mouse => {
                    if (pressed && (pressedButtons & Qt.LeftButton))
                        row.setMark(mouse.x)
                }
                onWheel: wheel => row.scroll(wheel, wheel.x)
            }
            PopMenu {
                id: pieceMenu
                property string entryId: ""
                PopAction {
                    text: "移出轨道"
                    onTriggered: row.view.removeEntry(pieceMenu.entryId)
                }
            }
            PinchHandler {
                target: null
                onScaleChanged: delta => row.zoomAt(centroid.position.x, delta)
            }
        }
    }

    // A press anywhere on a track's row makes it the active one; the
    // handler only watches, the press goes on to what is under it.
    Item {
        anchors.fill: parent
        z: 10
        PointHandler {
            enabled: !row.camera
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onActiveChanged: if (active) row.view.activate(row.key)
        }
    }

    // Lit while a drag would land on this track.
    Rectangle {
        visible: row.dropOnto
        anchors.fill: parent
        anchors.margins: -2
        radius: Theme.radius + 2
        color: Theme.selected
        opacity: 0.4
    }
    Rectangle {
        visible: row.dropOnto
        anchors.fill: parent
        anchors.margins: -2
        radius: Theme.radius + 2
        color: "transparent"
        border.width: 2
        border.color: Theme.text
    }
}
