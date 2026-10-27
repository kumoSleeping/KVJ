import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// The track area across the foot of the window, laid out like a video
// editor's: a row a source, under one ruler and one view. On top a slim bar
// for what is not one track's: the Set and what the main track shows, where
// it is, the cursor with 跳至光标处, the zoom keys, 快捷键 and how jumps look.
// Under it the whole timeline's bar (a frame round the part the rows show,
// dragged along or wider and narrower by its ends; a press well away from it
// only sets the cursor) and the ruler, in each entry's own time along the
// longest row. Then the rows (TrackRow), two in view, more by scrolling:
// the main track (画面 1), the aux tracks (画面 2..4) and the cameras. Each has
// its header (its picture, which a press puts in the preview; its name; ⋯)
// and its own play bar over its lane, so every track plays, seeks, changes
// speed and loops on its own. On the main row a press only sets the cursor,
// 跳至光标处 (or Enter) plays from it; while smart following leads a player
// the keys its helpers at work own rest. Entries from the drawer (an internal
// drag whose source has `entryIds` and `title`), or files, dropped on the body
// of a track's row go on that track, which lights up with a block where they
// will land; dropped on the seam between two rows, or below the last, they go
// on a new track there, shown by an ink line (never above the main track,
// and only while a track can be added). Near the rows' top or bottom edge a
// drag scrolls them. Under the rows a slim + adds a track or a camera. Pinch on the trackpad (or ⌘/Ctrl/Alt +
// scroll, or − / +) zooms every lane about the pointer down to a few frames;
// a sideways swipe moves along, an upright one scrolls the rows once there
// are more than fit. Opening another Set than the one the picture plays parks
// the main row: that Set from its start, paused, while the picture plays on.
//
//   tracks    [{ key, kind: "track" | "camera", track, cameraId, name,
//             entries, player }] in row order. A track's entries are all of
//             them (those that are off are left out unless on the screen);
//             its player is `player` for track 0, a TrackPlayer for 1..3. A
//             camera has no entries or player. Empty: one main row from
//             `entries`.
//   textures  the window's SourceTextures, for the headers' pictures
//   followTrack  the track following listens to (an ear on its header)
//   canAddTrack  an aux track can be added (the + menu's 画面 N, drops that
//             insert a track)
//   player    the window's player (Main's `app`): the main track's clock,
//             who leads, the cursor's jump, the keys, the fade
//   trailing  an item placed right of the rows, top-aligned with the first
//   rowHeight / mainRowHeight  one row's height (the trailing item's too)
//   pickSource(key), addTrack(), addCamera(id), removeRow(key),
//   dropEntries(ids, track), dropFiles(urls, track): onto a track
//   insertEntries(ids, position), insertFiles(urls, position): onto a new
//             track that appears at `position` in `tracks` (1..tracks.length)
//   removeEntry(id): an entry's 移出轨道 (right click on it)
//   zoomAt(x, factor), zoomStep(factor), fit(), setMark(x), jump(): the keys
Rectangle {
    id: line
    color: Theme.raised
    implicitHeight: content.implicitHeight + 12

    property var entries: []
    property string setId: ""
    property string setName: ""
    property bool running: false
    property string phase: ""
    // The window's player: its clock (transport), who leads and what is shown.
    property var player: null
    property var tracks: []
    property SourceTextures textures: null
    property int followTrack: 0
    property bool canAddTrack: false
    property alias trailing: trailingSlot.data
    property int rowHeight: 120
    readonly property int mainRowHeight: rowHeight
    // Rows in view before the rest scroll.
    property int visibleRows: 2
    readonly property int headerWidth: 170
    readonly property int rowGap: 4
    // Room at the rows' right for their scroll bar, kept so the lanes stay under the ruler.
    readonly property int barRoom: 10

    signal pickSource(string key)
    signal addTrack()
    signal addCamera(string id)
    signal removeRow(string key)
    signal dropEntries(var entryIds, int track)
    signal dropFiles(var urls, int track)
    signal insertEntries(var entryIds, int position)
    signal insertFiles(var urls, int position)
    signal removeEntry(string entryId)

    readonly property var rows: tracks.length ? tracks
                                : [{ key: "track:0", kind: "track", track: 0, name: "画面 1 · 主轨", entries: entries, player: player }]
    readonly property var mainSpec: rows.find(r => r.kind !== "camera" && (r.track || 0) === 0) || null
    readonly property var mainEntries: mainSpec ? (mainSpec.entries || []).filter(e => (e.track || 0) === 0) : []
    readonly property var onAir: Switcher.sourcesOf(Switcher.program)
    readonly property var inPreview: Switcher.sourcesOf(Switcher.preview)
    // The first aux track not shown, 0 when all three are.
    readonly property int nextAux: [1, 2, 3].find(t => !rows.some(r => r.kind !== "camera" && (r.track || 0) === t)) || 0
    function hasCamera(id) {
        return rows.some(r => r.kind === "camera" && r.cameraId === id)
    }

    readonly property bool manual: !!player && player.manual
    // The speed is the player's (对速 paused), play and seeking are (跳转 paused).
    readonly property bool manualTempo: !!player && player.manualTempo
    readonly property bool manualSeek: !!player && player.manualSeek
    readonly property var transport: player ? player.transport : null
    // The picture comes from another Set than this one: this one is parked,
    // paused at its first entry's start, and the cursor waits there for Enter.
    // The speed, the nudge keys and the effects still work on the picture.
    readonly property bool parked: !!player && player.parked
    readonly property var live: player ? player.shownEntry : null
    readonly property var shown: parked ? (clips.length ? clips[0].entry : null) : live
    readonly property string playingId: shown ? shown.id : ""
    readonly property real position: parked ? 0 : player ? player.playhead : 0
    readonly property real tempo: player ? player.shownTempo : 1
    // The readout shows a held nudge key's bend; the bar stays on the tempo.
    readonly property real speed: player ? player.shownSpeed : 1
    readonly property int bending: speed > tempo + 1e-6 ? 1 : speed < tempo - 1e-6 ? -1 : 0
    readonly property var match: player && player.aiMain && !parked ? player.match : null
    // The entry on the screen stays until the picture has left it.
    readonly property var lanes: mainEntries.filter(e => e.enabled !== false || (!parked && !!live && e.id === live.id))

    // The main track's entries end to end: { entry, n (its number), start, length } in seconds.
    readonly property var clips: {
        let at = 0
        return lanes.map((e, i) => {
            const clip = { entry: e, n: i + 1, start: at, length: Math.max(1, e.duration) }
            at += clip.length
            return clip
        })
    }
    readonly property real mainTotal: clips.length ? clips[clips.length - 1].start + clips[clips.length - 1].length : 0
    // Every row's entries the same way, { clips, total }, the aux ones on
    // their own players' clocks; a camera has none.
    readonly property var layouts: rows.map(r => {
        if (r.kind === "camera")
            return { clips: [], total: 0 }
        if (r === mainSpec)
            return { clips: clips, total: mainTotal }
        const p = r.player || null
        const on = p ? p.entry : null
        let at = 0
        const list = (r.entries || []).filter(e => e.enabled !== false || (!!on && e.id === on.id)).map((e, i) => {
            const clip = { entry: e, n: i + 1, start: at, length: Math.max(1, e.duration) }
            at += clip.length
            return clip
        })
        return { clips: list, total: at }
    })
    // The longest row; the ruler is in its entries' time.
    readonly property int longest: {
        let best = -1
        for (let i = 0; i < layouts.length; ++i)
            if (layouts[i].total > 0 && (best < 0 || layouts[i].total > layouts[best].total))
                best = i
        return best
    }
    readonly property real total: longest >= 0 ? layouts[longest].total : 0
    // What the view spans: the longest row, or a minute while every row is empty.
    readonly property real extent: total > 0 ? total : 60

    // The view: pixels a second (0 = everything fits) and the second at the left edge.
    property real zoom: 0
    property real viewStart: 0
    readonly property real laneWidth: Math.max(1, ruler.width)
    readonly property real maxScale: 400
    readonly property real fitScale: laneWidth / Math.max(1, extent)
    readonly property real pps: zoom > 0 ? Math.max(fitScale, Math.min(maxScale, zoom)) : fitScale
    readonly property real span: laneWidth / Math.max(1e-6, pps)
    readonly property real viewLeft: Math.max(0, Math.min(viewStart, extent - span))
    // When the lanes were last touched; until a while after, they do not follow the playhead.
    property real touchedAt: 0
    // Each Set's view and cursor while another one is open: back on the Set
    // the picture plays, the timeline is as it was left. A parked Set opens
    // whole, from its start, with the cursor there.
    property var views: ({})
    property string viewedId: ""
    onSetIdChanged: {
        if (viewedId) {
            const next = Object.assign({}, views)
            next[viewedId] = { zoom: zoom, viewStart: viewStart, markId: markId, markAt: markAt }
            views = next
        }
        viewedId = setId
        // Once the Set's entries (and whether it is parked) have followed.
        Qt.callLater(arrive)
    }
    function arrive() {
        const kept = views[setId]
        touchedAt = 0
        if (kept && !parked) {
            zoom = kept.zoom
            viewStart = kept.viewStart
            markId = kept.markId
            markAt = kept.markAt
            return
        }
        fit()
        if (parked) {
            markId = clips.length ? clips[0].entry.id : ""
            markAt = 0
        }
    }

    // The mark (the cursor, the main track's): an entry and a second in it.
    property string markId: ""
    property real markAt: 0
    readonly property var markClip: clips.find(c => c.entry.id === markId) || null
    readonly property var playClip: clips.find(c => c.entry.id === playingId) || null
    readonly property real markT: markClip ? markClip.start + Math.min(markAt, markClip.length) : -1
    readonly property real playT: playClip ? playClip.start + Math.min(position, playClip.length) : -1

    function clock(seconds, tenths) {
        const s = Math.max(0, seconds)
        const m = Math.floor(s / 60)
        const rest = s - m * 60
        const text = tenths ? rest.toFixed(1) : Math.floor(rest).toString()
        return m + ":" + (rest < 10 ? "0" : "") + text
    }
    // A tempo's colour: neighbouring tempi apart, the same tempo alike in every entry.
    function tempoColor(bpm) {
        if (bpm === null || bpm === undefined)
            return Theme.inset
        const hue = (Math.log(bpm) / Math.LN2 * 2.5) % 1
        return Theme.dark ? Qt.hsla(hue, 0.42, 0.30, 1) : Qt.hsla(hue, 0.55, 0.84, 1)
    }
    function signed(rate) {
        const pct = (rate - 1) * 100
        return (pct >= 0 ? "+" : "−") + Math.abs(pct).toFixed(1) + "%"
    }
    function touch() {
        touchedAt = Date.now()
    }
    // Zoom by `factor` keeping the second under `x` (lane pixels) where it is.
    function zoomAt(x, factor) {
        const t = viewLeft + x / pps
        const next = Math.max(fitScale, Math.min(maxScale, pps * factor))
        zoom = next
        viewStart = Math.max(0, Math.min(t - x / next, extent - laneWidth / next))
        touch()
    }
    function pan(pixels) {
        viewStart = Math.max(0, Math.min(viewLeft + pixels / pps, extent - span))
        touch()
    }
    function fit() {
        zoom = 0
        viewStart = 0
    }
    // The − / + keys: a step about the playhead, or the cursor, if the lanes
    // show it, as an editor's zoom keys do; else about the middle.
    function zoomStep(factor) {
        const shows = t => t >= viewLeft && t <= viewLeft + span
        const t = shows(playT) ? playT : shows(markT) ? markT : viewLeft + span / 2
        zoomAt((t - viewLeft) * pps, factor)
    }
    // Show seconds `a` to `b` (the frame's ends dragged on the bar).
    function setView(a, b) {
        a = Math.max(0, a)
        zoom = laneWidth / Math.max(laneWidth / maxScale, Math.min(extent, b) - a)
        viewStart = a
        touch()
    }
    function moveView(a) {
        viewStart = Math.max(0, Math.min(a, extent - span))
        touch()
    }
    // The rows up or down by `pixels`, once there are more than fit.
    readonly property bool overflow: rowsView.contentHeight > rowsView.height + 0.5
    function scrollRows(pixels) {
        rowsView.contentY = Math.max(0, Math.min(rowsView.contentHeight - rowsView.height, rowsView.contentY + pixels))
    }
    // A row added with + comes into view (it is the last).
    property bool revealing: false
    readonly property int rowCount: rows.length
    onRowCountChanged: if (revealing) reveal.restart()
    Timer {
        id: reveal
        // Once the rows have been laid out anew.
        interval: 60
        onTriggered: rowsView.contentY = Math.max(0, rowsView.contentHeight - rowsView.height)
    }
    // —— Dropping on the rows ——
    readonly property int plusHeight: 24
    readonly property real pitch: rowHeight + rowGap
    // A drag over the rows: where it is (in the rows' view) and what it carries.
    property bool dragging: false
    property real dragY: 0
    property string dropTitle: ""
    // Where it would land: { kind: "onto", index, track } on a track's body,
    // { kind: "insert", position } on the seam above row `position` (or below
    // the last), or kind "" (a camera, or nowhere).
    readonly property var noZone: ({ kind: "", index: -1, track: -1, position: -1 })
    readonly property var dropZone: {
        if (!dragging)
            return noZone
        const y = dragY + rowsView.contentY
        const n = rows.length
        const seam = 10
        if (canAddTrack) {
            if (y >= n * pitch - rowGap - seam)
                return { kind: "insert", index: -1, track: -1, position: n }
            for (let k = 1; k < n; ++k)
                if (Math.abs(y - (k * pitch - rowGap / 2)) <= seam)
                    return { kind: "insert", index: -1, track: -1, position: k }
        }
        const i = Math.floor(y / pitch)
        if (i < 0 || i >= n || rows[i].kind === "camera")
            return noZone
        return { kind: "onto", index: i, track: rows[i].track || 0, position: -1 }
    }
    function titleOf(drag) {
        const src = drag.source
        if (src && src.entryIds)
            return src.title || (src.entryIds.length + " 个素材")
        if (drag.hasUrls && drag.urls.length) {
            const path = String(drag.urls[0]).replace(/\/+$/, "")
            let name = path.substring(path.lastIndexOf("/") + 1)
            try {
                name = decodeURIComponent(name)
            } catch (e) {}
            return drag.urls.length > 1 ? name + " 等 " + drag.urls.length + " 个" : name
        }
        return ""
    }
    function land(drop) {
        const z = dropZone
        const src = drop.source
        const ids = src && src.entryIds ? Array.prototype.slice.call(src.entryIds) : []
        const urls = !ids.length && drop.hasUrls ? drop.urls : []
        if (!z.kind || (!ids.length && !urls.length))
            return
        if (z.kind === "onto") {
            if (ids.length)
                dropEntries(ids, z.track)
            else
                dropFiles(urls, z.track)
        } else {
            if (ids.length)
                insertEntries(ids, z.position)
            else
                insertFiles(urls, z.position)
        }
        drop.acceptProposedAction()
    }

    // Scrolling over a lane, the ruler or the bars. A trackpad (a gesture
    // with phases, as macOS sends) moves the lanes with the fingers, one for
    // one, along the axis the gesture started on, its momentum included: a
    // swipe across that drifts up or down does not jitter; once the rows are
    // more than fit, a swipe up or down scrolls them instead. A wheel (any
    // mouse; Windows sends touchpads as fine wheel steps too) moves a tenth of
    // the view a notch, tilted or with Shift across as well; upright it
    // scrolls the rows once they are more than fit. ⌘/Ctrl, or Alt as in
    // After Effects and Premiere, zooms about the pointer, as a pinch does
    // (Windows sends a touchpad's pinch as Ctrl + wheel): a wheel's notch is
    // one fine step (macOS hands every notch over on its own, however fast the
    // wheel turns), a fraction of one on a fine wheel; a trackpad follows the
    // fingers and stops when they lift, its glide left out.
    property int swipeAxis: 0
    readonly property real notchZoom: 1.15
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
            if (swipeAxis === 2 && overflow)
                scrollRows(-p.y)
            else
                pan(-(swipeAxis === 1 ? p.x : p.y))
            return
        }
        if (overflow && Math.abs(a.y) > Math.abs(a.x) && !(wheel.modifiers & Qt.ShiftModifier)) {
            scrollRows(-a.y / 120 * rowHeight / 2)
            return
        }
        const notches = (Math.abs(a.x) > Math.abs(a.y) ? a.x : a.y) / 120
        pan(-notches * span * 0.1 * pps)
    }
    function setMark(x) {
        markTime(viewLeft + x / pps)
    }
    function markTime(seconds) {
        const t = Math.max(0, Math.min(mainTotal - 0.001, seconds))
        for (const c of clips) {
            if (t < c.start + c.length) {
                markId = c.entry.id
                markAt = Math.max(0, Math.min(c.entry.duration, t - c.start))
                break
            }
        }
        touch()
    }
    function jump() {
        if (manualSeek && markClip)
            player.play(markClip.entry, markAt)
    }

    // Tick marks in each entry's own time along the longest row (plain
    // seconds while every row is empty), at least 70 px apart. A label that
    // would run into the one before (many short entries, each starting at
    // 0:00) is left off; its mark stays.
    readonly property var ticks: {
        const out = []
        if (pps <= 0)
            return out
        const along = longest >= 0 ? layouts[longest].clips : [{ start: 0, length: extent }]
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
                out.push({ x: x, label: fits ? clock(k * step, step < 1) : "" })
            }
        }
        return out
    }

    // While playing, a main playhead that leaves the view brings it along,
    // unless the lanes were touched a moment ago.
    Timer {
        interval: 200
        repeat: true
        running: line.visible && !line.parked && line.pps > line.fitScale + 1e-6 && line.playT >= 0
        onTriggered: {
            if (Date.now() - line.touchedAt < 4000)
                return
            if (line.playT < line.viewLeft || line.playT > line.viewLeft + line.span * 0.97)
                line.viewStart = Math.max(0, line.playT - line.span * 0.1)
        }
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.leftMargin: Theme.gap
        anchors.rightMargin: Theme.gap
        anchors.topMargin: 6
        anchors.bottomMargin: 6
        spacing: 2

        // —— What belongs to no one track ——
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            spacing: 8
            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 80
                textFormat: Text.StyledText
                text: (line.setName ? "<font color='" + Theme.muted + "'>" + line.setName.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                                      + (line.shown || line.running ? "  ·  " : "") + "</font>" : "")
                      + (line.shown ? line.shown.title.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                         : line.running ? (line.phase === "searching" ? "重新搜索" : "等待识别") : "")
                font.pixelSize: Theme.sizeSm
                font.weight: Font.DemiBold
                color: Theme.text
                elide: Text.ElideRight
            }
            Text {
                text: line.shown ? line.clock(line.position, true) + " / " + line.clock(line.shown.duration, false)
                                   + (line.parked ? "   暂停 · 画面仍在「" + line.player.playingSet.name + "」"
                                                  : "   剩余 " + line.clock(line.shown.duration - line.position, false)) : ""
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: Theme.body
            }
            Rectangle { implicitWidth: 1; implicitHeight: 16; color: Theme.line }
            Text {
                text: line.markClip ? "光标 " + (line.clips.length > 1 ? line.markClip.n + " · " : "")
                                      + line.clock(line.markAt, true) : "光标 —"
                font.pixelSize: Theme.sizeSm
                font.features: { "tnum": 1 }
                color: line.markClip ? Theme.muted : Theme.faint
            }
            TextButton {
                implicitHeight: 26
                text: "跳至光标处"
                outlined: true
                enabled: line.manualSeek && !!line.markClip
                onClicked: line.jump()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "主轨从光标处播放（快捷键开着时也可按回车）；点主轨或标尺只放光标，不动画面"
            }
            Rectangle { implicitWidth: 1; implicitHeight: 16; color: Theme.line }
            RowLayout {
                spacing: 0
                IconButton {
                    implicitWidth: 26
                    implicitHeight: 26
                    iconName: "minus"
                    tip: "缩小时间轴（快捷键 −）"
                    autoRepeat: true
                    enabled: line.pps > line.fitScale + 1e-6
                    onClicked: line.zoomStep(1 / 1.3)
                }
                TextButton {
                    flat: true
                    implicitHeight: 26
                    leftPadding: 6
                    rightPadding: 6
                    text: "全览"
                    enabled: line.pps > line.fitScale + 1e-6
                    onClicked: line.fit()
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "缩回全部轨道（快捷键 \\）\n也可触控板双指捏合，或按住 ⌘ / Ctrl / Alt 滚动，在指针处缩放"
                }
                IconButton {
                    implicitWidth: 26
                    implicitHeight: 26
                    iconName: "plus"
                    tip: "放大时间轴（快捷键 =）"
                    autoRepeat: true
                    enabled: line.total > 0 && line.pps < line.maxScale - 1e-6
                    onClicked: line.zoomStep(1.3)
                }
            }
            Toggle {
                text: "快捷键"
                checked: !!line.player && line.player.keysOn
                onToggled: line.player.keysOn = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "主轨：← / →、A / D：按住时画面以 0.7 / 1.5 倍速播放，松开即恢复；暂停时按一下退后 / 前进 1 秒\n"
                              + "↑ / ↓、W / S：速度 +1% / −1%\n回车：跳至光标处\n"
                              + "− / =：缩小 / 放大时间轴，\\：全览\n"
                              + "空格不再暂停播放"
            }
            Rectangle { implicitWidth: 1; implicitHeight: 16; color: Theme.line }
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
                Layout.minimumWidth: 40
                implicitHeight: 24
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

        // —— The rows, and what waits at their right ——
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.gap

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignTop
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.rightMargin: line.barRoom
                    spacing: 0

                    Item {
                        Layout.preferredWidth: line.headerWidth
                        Layout.preferredHeight: overview.height + ruler.height
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        // The whole timeline's bar, as long as the lanes at full
                        // view: where the main picture is, a notch where one of
                        // its entries meets the next, the cursor as a hollow
                        // ball and, zoomed in, a frame round the part the lanes
                        // show. The frame drags along, and its ends make it
                        // wider or narrower; a band round it does nothing, so a
                        // press that just misses it changes nothing. Further off
                        // a press or drag sets the cursor, never the picture.
                        Item {
                            id: overview
                            Layout.fillWidth: true
                            Layout.preferredHeight: 14
                            readonly property real share: line.playT >= 0 ? Math.max(0, Math.min(1, line.playT / line.extent)) : 0
                            readonly property bool framed: line.total > 0 && line.pps > line.fitScale + 1e-6
                            // The frame in the bar's pixels, never too thin to take hold of.
                            readonly property real frameW: Math.min(width, Math.max(12, width * line.span / line.extent))
                            readonly property real frameX: Math.max(0, Math.min(width - frameW, width * (line.viewLeft + line.span / 2) / line.extent - frameW / 2))
                            function timeAt(x) {
                                return Math.max(0, Math.min(1, x / width)) * line.extent
                            }
                            // What a press at `x` takes hold of: the frame ("move"), one of
                            // its ends ("left", "right"), nothing ("near") or the cursor ("mark").
                            function zoneAt(x) {
                                if (!framed)
                                    return "mark"
                                const a = frameX
                                const b = frameX + frameW
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
                            // Zooming here keeps the second under the pointer where the
                            // lanes show it, if they do; else their middle.
                            function anchor(x) {
                                const t = timeAt(x)
                                return t >= line.viewLeft && t <= line.viewLeft + line.span ? (t - line.viewLeft) * line.pps : line.laneWidth / 2
                            }
                            Rectangle {
                                id: groove
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                height: 3
                                radius: 1.5
                                color: Theme.line
                                Rectangle {
                                    width: parent.width * overview.share
                                    height: parent.height
                                    radius: 1.5
                                    color: line.manualSeek ? Theme.muted : Theme.faint
                                }
                                Repeater {
                                    model: line.clips.filter(c => c.start > 0)
                                    Rectangle {
                                        required property var modelData
                                        x: groove.width * modelData.start / line.extent - 1
                                        width: 2
                                        height: groove.height
                                        color: Theme.raised
                                    }
                                }
                            }
                            // The part the lanes show, with a grip at each end.
                            Item {
                                id: frame
                                visible: overview.framed
                                readonly property string held: barArea.zone
                                x: overview.frameX
                                width: overview.frameW
                                height: overview.height
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 3
                                    color: Theme.text
                                    opacity: frame.held === "move" ? 0.2 : 0.12
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 3
                                    color: "transparent"
                                    border.width: frame.held === "move" || frame.held === "left" || frame.held === "right" ? 2 : 1.5
                                    border.color: frame.held === "move" ? Theme.text : Theme.muted
                                }
                                Repeater {
                                    model: ["left", "right"]
                                    Rectangle {
                                        required property string modelData
                                        visible: frame.width >= 24
                                        x: modelData === "left" ? 3 : frame.width - 3 - width
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 2
                                        height: 7
                                        radius: 1
                                        color: frame.held === modelData ? Theme.text : Theme.muted
                                    }
                                }
                            }
                            Rectangle {
                                visible: line.markT >= 0
                                x: overview.width * line.markT / line.extent - width / 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: 9
                                height: 9
                                radius: 4.5
                                color: Theme.raised
                                border.width: 2
                                border.color: Theme.muted
                                scale: barArea.zone === "mark" && barArea.pressed ? 1.2 : 1
                            }
                            Rectangle {
                                visible: line.playT >= 0
                                x: overview.width * overview.share - width / 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: 9
                                height: 9
                                radius: 4.5
                                color: line.manualSeek && !line.parked ? Theme.text : Theme.muted
                            }
                            // Where a press would put the cursor.
                            Rectangle {
                                visible: barArea.hoverZone === "mark" && !barArea.pressed && line.clips.length > 0
                                x: barArea.mouseX - width / 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: 9
                                height: 9
                                radius: 4.5
                                color: "transparent"
                                border.width: 1.5
                                border.color: Theme.faint
                            }
                            MouseArea {
                                id: barArea
                                anchors.fill: parent
                                enabled: line.total > 0
                                hoverEnabled: true
                                preventStealing: true
                                // What the press took hold of, and where the frame was then.
                                property string held: ""
                                property real grabX: 0
                                property real grabLeft: 0
                                property real grabRight: 0
                                readonly property string hoverZone: containsMouse ? overview.zoneAt(mouseX) : ""
                                readonly property string zone: pressed ? held : hoverZone
                                cursorShape: zone === "move" ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                                             : zone === "left" || zone === "right" ? Qt.SizeHorCursor
                                             : zone === "mark" && line.clips.length ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onPressed: mouse => {
                                    held = overview.zoneAt(mouse.x)
                                    grabX = mouse.x
                                    grabLeft = line.viewLeft
                                    grabRight = line.viewLeft + line.span
                                    if (held === "mark")
                                        line.markTime(overview.timeAt(mouse.x))
                                }
                                onPositionChanged: mouse => {
                                    if (!pressed)
                                        return
                                    const d = (mouse.x - grabX) / width * line.extent
                                    const least = line.laneWidth / line.maxScale
                                    if (held === "mark")
                                        line.markTime(overview.timeAt(mouse.x))
                                    else if (held === "move")
                                        line.moveView(grabLeft + d)
                                    else if (held === "left")
                                        line.setView(Math.min(grabLeft + d, grabRight - least), grabRight)
                                    else if (held === "right")
                                        line.setView(grabLeft, Math.max(grabRight + d, grabLeft + least))
                                }
                                onReleased: held = ""
                                onCanceled: held = ""
                                // Scrolling here moves the lanes' view as scrolling on them does.
                                onWheel: wheel => line.scroll(wheel, overview.anchor(wheel.x))
                            }
                        }

                        // The ruler, over every lane: the main playhead's flag and
                        // the cursor's diamond on it. A press sets the cursor.
                        Item {
                            id: ruler
                            Layout.fillWidth: true
                            Layout.preferredHeight: 18
                            clip: true
                            // By place too: panning makes the ticks afresh every frame.
                            Repeater {
                                model: line.ticks.length
                                Item {
                                    required property int index
                                    readonly property var modelData: line.ticks[index] || { x: 0, label: "" }
                                    x: modelData.x
                                    height: ruler.height
                                    Rectangle {
                                        y: ruler.height - height
                                        width: 1
                                        height: 5
                                        color: Theme.faint
                                    }
                                    Text {
                                        x: 3
                                        y: 1
                                        text: parent.modelData.label
                                        font.pixelSize: 10
                                        font.features: { "tnum": 1 }
                                        color: Theme.faint
                                    }
                                }
                            }
                            Rectangle {
                                visible: rulerArea.containsMouse && !rulerArea.pressed && line.clips.length > 0
                                x: rulerArea.mouseX
                                width: 1
                                height: ruler.height
                                color: Theme.faint
                            }
                            Rectangle {
                                visible: line.markT >= line.viewLeft && line.markT <= line.viewLeft + line.span
                                x: (line.markT - line.viewLeft) * line.pps - 5
                                y: ruler.height - 9
                                width: 10
                                height: 10
                                rotation: 45
                                color: Theme.muted
                            }
                            Rectangle {
                                visible: line.playT >= line.viewLeft && line.playT <= line.viewLeft + line.span
                                x: (line.playT - line.viewLeft) * line.pps - 6
                                y: 2
                                width: 12
                                height: ruler.height - 2
                                radius: 3
                                color: line.parked ? Theme.muted : Theme.text
                            }
                            MouseArea {
                                id: rulerArea
                                anchors.fill: parent
                                hoverEnabled: true
                                preventStealing: true
                                cursorShape: line.clips.length ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onPressed: mouse => line.setMark(mouse.x)
                                onPositionChanged: mouse => {
                                    if (pressed)
                                        line.setMark(Math.max(0, Math.min(width, mouse.x)))
                                }
                                onWheel: wheel => line.scroll(wheel, wheel.x)
                            }
                            PinchHandler {
                                target: null
                                onScaleChanged: delta => line.zoomAt(centroid.position.x, delta)
                            }
                        }
                    }
                }

                // The rows: two in view and the + under them, the rest by scrolling.
                Item {
                    id: rowsBox
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredHeight: line.visibleRows * line.pitch + line.plusHeight
                    Layout.topMargin: 2

                    Flickable {
                        id: rowsView
                        anchors.fill: parent
                        contentWidth: width
                        contentHeight: rowColumn.height
                        clip: true
                        interactive: line.overflow
                        flickableDirection: Flickable.VerticalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {
                            policy: line.overflow ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                        }

                        Column {
                            id: rowColumn
                            width: rowsView.width - line.barRoom
                            spacing: line.rowGap
                            // By place: the host makes its rows afresh whenever a Set changes.
                            Repeater {
                                model: line.rows.length
                                TrackRow {
                                    required property int index
                                    width: rowColumn.width
                                    height: line.rowHeight
                                    view: line
                                    rowIndex: index
                                    spec: line.rows[index] || ({})
                                    layout: line.layouts[index] || ({ clips: [], total: 0 })
                                }
                            }
                            // +: the next aux track, or a camera (listed only while the
                            // menu is open: listing wakes the camera stack).
                            Item {
                                id: plusRow
                                width: rowColumn.width
                                height: line.plusHeight
                                readonly property bool hot: plusArea.containsMouse || addMenu.visible
                                Rectangle {
                                    anchors.fill: parent
                                    radius: Theme.radius
                                    color: plusRow.hot ? Theme.hover : "transparent"
                                    Behavior on color { ColorAnimation { duration: Theme.quick } }
                                }
                                ColorImage {
                                    id: plusIcon
                                    x: (line.headerWidth - 8 - width) / 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    source: "icons/plus.svg"
                                    sourceSize: Qt.size(14, 14)
                                    color: plusRow.hot ? Theme.text : Theme.muted
                                }
                                MouseArea {
                                    id: plusArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: addMenu.popup(plusRow, plusIcon.x - 6, plusRow.height + 2)
                                    ToolTip.visible: containsMouse && !addMenu.visible
                                    ToolTip.delay: 600
                                    ToolTip.text: "加一条视频轨（画面 2–4）或一个相机"
                                }
                                PopMenu {
                                    id: addMenu
                                    implicitWidth: 220
                                    PopAction {
                                        text: line.nextAux > 0 ? "画面 " + (line.nextAux + 1) + "（视频轨）" : "视频轨都已加上"
                                        enabled: line.canAddTrack && line.nextAux > 0
                                        onTriggered: {
                                            line.revealing = true
                                            line.addTrack()
                                            line.revealing = false
                                        }
                                    }
                                    MenuSeparator {}
                                    Instantiator {
                                        model: addMenu.visible ? (Cameras.list.length ? Cameras.list : [{ id: "", name: "没有找到相机" }]) : []
                                        delegate: PopAction {
                                            required property var modelData
                                            text: modelData.id ? "相机：" + modelData.name : modelData.name
                                            enabled: !!modelData.id && !line.hasCamera(modelData.id)
                                            onTriggered: {
                                                line.revealing = true
                                                line.addCamera(modelData.id)
                                                line.revealing = false
                                            }
                                        }
                                        onObjectAdded: (index, object) => addMenu.insertAction(index + 2, object)
                                        onObjectRemoved: (index, object) => addMenu.removeAction(object)
                                    }
                                }
                            }
                        }

                        // Where a drop would insert a new track: an ink line on the seam.
                        Item {
                            visible: line.dropZone.kind === "insert"
                            y: line.dropZone.position * line.pitch - line.rowGap / 2 - 1
                            width: rowColumn.width
                            height: 2
                            Rectangle {
                                anchors.fill: parent
                                radius: 1
                                color: Theme.text
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 18
                                height: 18
                                radius: 9
                                color: Theme.text
                                ColorImage {
                                    anchors.centerIn: parent
                                    source: "icons/plus.svg"
                                    sourceSize: Qt.size(12, 12)
                                    color: Theme.bg
                                }
                            }
                        }
                    }

                    // Entries from the drawer and files from the desktop, onto a
                    // track or into a new one (dropZone).
                    DropArea {
                        anchors.fill: parent
                        keys: ["kvj-entry", "text/uri-list"]
                        onEntered: drag => {
                            line.dropTitle = line.titleOf(drag)
                            line.dragY = drag.y
                            line.dragging = true
                        }
                        onPositionChanged: drag => line.dragY = drag.y
                        onExited: line.dragging = false
                        onDropped: drop => {
                            line.land(drop)
                            line.dragging = false
                        }
                    }
                    // Held near the top or bottom edge, a drag scrolls the rows.
                    Timer {
                        readonly property int edge: 28
                        interval: 30
                        repeat: true
                        running: line.dragging && line.overflow && (line.dragY < edge || line.dragY > rowsBox.height - edge)
                        onTriggered: line.scrollRows(line.dragY < edge ? -8 : 8)
                    }
                }
            }

            // The audio-alignment strip, or whatever the host puts here, by the first row.
            Item {
                id: trailingSlot
                visible: children.length > 0
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: overview.height + ruler.height + 2
                implicitWidth: childrenRect.width
                implicitHeight: childrenRect.height
            }
        }
    }
}
