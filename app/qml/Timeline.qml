import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// The track area across the foot of the window, laid out like a video
// editor's, as a DJ's two decks (画面 1, 画面 2), each on a clock of its
// own, alike. On top a slim bar
// for the active row (the track row pressed last, its name inked): its
// cursor and 跳至光标处 (Enter does the same), its zoom keys −
// 全览 + (− = \ too), then the switches and how jumps look. Then the rows
// (TrackRow), each its own play bar (its name at the left; pressed, its
// layer is chosen on the board), its own ruler and view (zoom and scroll
// are a row's own) and its own cursor: a press on a row's timeline only
// places that row's cursor, and only Enter, 跳至光标处 / 跳至, the play key
// or the nudge keys ever move a picture. While smart following leads a
// player the keys its helpers at work own rest. Entries from the drawer (an
// internal drag whose source has `entryIds` and `title`), or files, dropped
// on a track's row replace what is on that track (the host puts that back
// in the library), and the row lights up saying so. The track followed and the cameras are chosen elsewhere (音频对位,
// the board).
//
//   tracks    [{ key, kind: "track", track, name, entries, player }] in row
//             order. A track's entries are all of them (those that are off
//             are left out unless on the screen); its player is `player` for
//             track 0, a TrackPlayer for track 1. Empty: one main row from
//             `entries`.
//   textures  the window's SourceTextures
//   followTrack  the track following listens to
//   player    the window's player (Main's `app`): the main track's clock,
//             who leads, the keys, the fade
//   setId     keys the rows' kept views and cursors (nothing of it is shown)
//   rowHeight / mainRowHeight  one row's height
//   activeRow / activeTrack  the active row's tracks[] item and its track
//             (-1 while there is none); markClip / canJump: its cursor's
//             clip, and whether a jump would go now
//   pickSource(key), clearTrack(track), takeLive(key) (a
//             row's 投放, the quick cut): asked of the host
//   dropEntries(ids, track), dropFiles(urls, track): onto a track, in place
//             of what is on it
//   removeEntry(id): an entry's 移出轨道 (right click on it)
//   jump(), jumpRow(row), syncPlay(row), zoomAt(x, factor), zoomStep(factor), fit(), setMark(x): the
//             active row's (Enter, − = \)
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
    property int rowHeight: 172
    readonly property int mainRowHeight: rowHeight
    readonly property int rowGap: 6

    signal pickSource(string key)
    signal clearTrack(int track)
    signal takeLive(string key)
    signal dropEntries(var entryIds, int track)
    signal dropFiles(var urls, int track)
    signal removeEntry(string entryId)

    readonly property var rows: tracks.length ? tracks
                                : [{ key: "track:0", kind: "track", track: 0, name: "画面 1", entries: entries, player: player }]
    readonly property var mainSpec: rows.find(r => r.kind !== "camera" && (r.track || 0) === 0) || null
    readonly property var mainEntries: mainSpec ? (mainSpec.entries || []).filter(e => (e.track || 0) === 0) : []
    readonly property var onAir: Switcher.shownSourcesOf(Switcher.program)
    // The source whose layer is topmost on the air.
    readonly property string onTop: {
        const shown = Switcher.program.slots.filter(s => Switcher.inPicture(s))
        return shown.length ? shown.reduce((a, b) => b.z >= a.z ? b : a).source : ""
    }
    readonly property var inPreview: Switcher.shownSourcesOf(Switcher.preview)

    readonly property bool manual: !!player && player.manual
    // The speed is the player's (对速 paused), play and seeking are (跳转 paused).
    readonly property bool manualTempo: !!player && player.manualTempo
    readonly property bool manualSeek: !!player && player.manualSeek
    readonly property var transport: player ? player.transport : null
    readonly property var shown: player ? player.shownEntry : null
    readonly property string playingId: shown ? shown.id : ""
    readonly property real position: player ? player.playhead : 0
    readonly property real tempo: player ? player.shownTempo : 1
    // The readout shows a held nudge key's bend; the bar stays on the tempo.
    readonly property real speed: player ? player.shownSpeed : 1
    readonly property int bending: speed > tempo + 1e-6 ? 1 : speed < tempo - 1e-6 ? -1 : 0
    readonly property var match: player && player.aiMain ? player.match : null
    // The entry on the screen stays until the picture has left it.
    readonly property var lanes: mainEntries.filter(e => e.enabled !== false || (!!shown && e.id === shown.id))

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

    // The row items, the main one and the active one.
    readonly property var rowItems: {
        const out = []
        for (let i = 0; i < rowRepeater.count; ++i)
            out.push(rowRepeater.itemAt(i))
        return out
    }
    // The row Enter, 跳至光标处 and the zoom keys act on: the track row
    // pressed last, else the first track row.
    property string activeKey: ""
    readonly property var activeItem: rowItems.find(r => !!r && !r.camera && r.key === activeKey)
                                      || rowItems.find(r => !!r && !r.camera) || null
    readonly property var activeRow: activeItem ? activeItem.spec : null
    readonly property int activeTrack: activeItem ? activeItem.track : -1
    readonly property var markClip: activeItem ? activeItem.markClip : null
    readonly property bool canJump: !!activeItem && activeItem.canJump
    function activate(key) {
        activeKey = key
        states[setId + "|active"] = key
    }
    // Each row's view and cursor, by Set and row (changed in place: nothing binds to it).
    property var states: ({})
    function keep(key, state) {
        states[setId + "|" + key] = state
    }
    function kept(key) {
        return states[setId + "|" + key] || null
    }
    onSetIdChanged: Qt.callLater(() => line.activeKey = line.states[line.setId + "|active"] || "")

    // The keys, on the active row: Enter plays it from its cursor, − = \ zoom it.
    // Enter, 跳至光标处 and a row's 跳至: played from its cursor and, with
    // 跳转置顶 on, its layer floated to the top on the air first.
    property bool jumpRaises: false
    function jumpRow(r) {
        if (!r || !r.canJump)
            return
        activate(r.key)
        if (jumpRaises)
            takeLive(r.key)
        r.jump()
    }
    function jump() {
        jumpRow(activeItem)
    }
    // A row's 同步播放: the other row playing (started if paused), this one
    // put at the other's time at this very instant and playing too, so the
    // same videos run (and sound) as one.
    function syncPlay(r) {
        const o = r ? r.other : null
        if (!o || o.playT < 0)
            return
        activate(r.key)
        if (!o.playing)
            o.togglePlay()
        r.playAtTime(o.liveT())
        if (!r.playing)
            r.togglePlay()
    }
    function zoomAt(x, factor) {
        if (activeItem)
            activeItem.zoomAt(x, factor)
    }
    function zoomStep(factor) {
        if (activeItem)
            activeItem.zoomStep(factor)
    }
    function fit() {
        if (activeItem)
            activeItem.fit()
    }
    // 缩放同步: every track row shows the same seconds at the same scale as the
    // one moved last (the same two videos line up, each with its own
    // playhead). Only the active row brings the view along with its playhead.
    property bool viewsLocked: false
    // 同步变速: 画面 2 plays at 画面 1's speed; either row's speed keys
    // change both (the host links the players).
    property bool tempoLinked: false
    Settings {
        category: "timeline"
        property alias viewsLocked: line.viewsLocked
        property alias tempoLinked: line.tempoLinked
        property alias jumpRaises: line.jumpRaises
    }
    function mirror(from) {
        if (!viewsLocked || !from)
            return
        for (const r of rowItems) {
            if (!r || r === from || r.camera)
                continue
            r.zoom = from.pps
            r.viewStart = from.viewLeft
            r.touchedAt = from.touchedAt
            r.keep()
        }
    }
    onViewsLockedChanged: if (viewsLocked) mirror(activeItem)
    // Synced, the one view follows the playheads it shows: one outside it is
    // let be; once one inside reaches its right end the view moves on,
    // keeping both in sight when they fit (centred between them), else
    // paging on with the one that reached the end. Not for a while after a
    // row was zoomed or moved by hand.
    // Which rows' playheads the view showed at the last look: one that was
    // shown and is past the end now crossed it between two looks.
    property var shownBefore: ({})
    function followTogether() {
        const rows = rowItems.filter(r => !!r && !r.camera)
        const ref = activeItem
        if (!ref || !ref.zoomed)
            return
        const left = ref.viewLeft, span = ref.span, end = left + span * 0.97
        const shown = {}
        for (const r of rows)
            shown[r.key] = r.playing && r.playT >= left && r.playT <= end
        const before = shownBefore
        shownBefore = shown
        if (rows.some(r => Date.now() - r.touchedAt < 4000))
            return
        // Reached the end: inside it now, or was shown a moment ago.
        const reached = rows.filter(r => r.playing && r.playT > end && (before[r.key] || r.playT <= left + span))
        if (!reached.length)
            return
        const seen = rows.filter(r => shown[r.key] || reached.indexOf(r) >= 0).map(r => r.playT)
        const lo = Math.min(...seen), hi = Math.max(...seen)
        const next = hi - lo <= span * 0.8 ? Math.max(hi - span * 0.9, (lo + hi) / 2 - span / 2)
                                          : hi - span * 0.1
        ref.viewStart = Math.max(0, Math.min(next, ref.extent - span))
        ref.keep()
        mirror(ref)
        shownBefore = {}
        for (const r of rows)
            shownBefore[r.key] = r.playing && r.playT >= ref.viewLeft && r.playT <= ref.viewLeft + span * 0.97
    }
    Timer {
        interval: 100
        repeat: true
        running: line.viewsLocked && line.visible
        onTriggered: line.followTogether()
    }
    function setMark(x) {
        if (activeItem)
            activeItem.setMark(x)
    }

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

    // —— Dropping on the rows ——
    readonly property real pitch: rowHeight + rowGap
    // A drag over the rows: where it is and what it carries.
    property bool dragging: false
    property real dragY: 0
    property string dropTitle: ""
    // Where it would land: { kind: "onto", index, track } on a track's row, or kind "".
    readonly property var noZone: ({ kind: "", index: -1, track: -1 })
    readonly property var dropZone: {
        if (!dragging)
            return noZone
        const i = Math.max(0, Math.min(rows.length - 1, Math.floor(dragY / pitch)))
        return rows.length ? { kind: "onto", index: i, track: rows[i].track || 0 } : noZone
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
        if (ids.length)
            dropEntries(ids, z.track)
        else
            dropFiles(urls, z.track)
        drop.acceptProposedAction()
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.leftMargin: Theme.gap
        anchors.rightMargin: Theme.gap
        anchors.topMargin: 6
        anchors.bottomMargin: 6
        spacing: 2

        // —— What belongs to no one row: the active row and its cursor, the keys, the fade ——
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            spacing: 8
            readonly property var act: line.activeItem
            Item { Layout.fillWidth: true }
            TextButton {
                implicitHeight: 26
                text: "跳至光标处"
                outlined: true
                enabled: line.canJump
                onClicked: line.jump()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "从光标处播放" + (parent.act ? parent.act.name : "") + "（也可按回车）\n点轨道的进度条、标尺或画面条只放光标，不动画面"
            }
            Item { implicitWidth: 6 }
            // The active row's zoom.
            RowLayout {
                spacing: 0
                IconButton {
                    implicitWidth: 26
                    implicitHeight: 26
                    iconName: "minus"
                    tip: "缩小选中的轨道（快捷键 −）"
                    autoRepeat: true
                    enabled: !!line.activeItem && line.activeItem.zoomed
                    onClicked: line.zoomStep(1 / 1.3)
                }
                TextButton {
                    flat: true
                    implicitHeight: 26
                    leftPadding: 6
                    rightPadding: 6
                    text: "全览"
                    enabled: !!line.activeItem && line.activeItem.zoomed
                    onClicked: line.fit()
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "选中的轨道整条显示（快捷键 \\，或双击它的标尺）\n也可在轨道上双指捏合，或按住 ⌘ / Ctrl / Alt 滚动，在指针处缩放"
                }
                IconButton {
                    implicitWidth: 26
                    implicitHeight: 26
                    iconName: "plus"
                    tip: "放大选中的轨道（快捷键 =）"
                    autoRepeat: true
                    enabled: !!line.activeItem && line.activeItem.total > 0 && line.activeItem.pps < line.activeItem.maxScale - 1e-6
                    onClicked: line.zoomStep(1.3)
                }
            }
            Toggle {
                text: "缩放同步"
                checked: line.viewsLocked
                onToggled: line.viewsLocked = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "画面 1 和画面 2 用同样的缩放、显示同一段时间，调一条另一条跟着变；各自播到哪里互不影响。\n同一段视频放在两条轨道上时，上下完全对齐"
            }
            Toggle {
                text: "同步变速"
                checked: line.tempoLinked
                onToggled: line.tempoLinked = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "画面 2 和画面 1 一起变速：调任一条的速度（键、滑条、复原、↑↓），两条都变；画面 1 跟随音乐时画面 2 也跟着同样的速度"
            }
            Toggle {
                text: "跳转置顶"
                checked: line.jumpRaises
                onToggled: line.jumpRaises = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "开着时，回车、跳至光标处和轨道上的「跳至」会先把这条轨道的画面升到最上层投给观众（保留它的大小和位置），再从光标处播放"
            }
            Item { implicitWidth: 6 }
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

        // —— The rows, one or two ——
        Item {
            id: rowsBox
            Layout.fillWidth: true
            Layout.preferredHeight: line.rows.length * line.pitch - line.rowGap
            Layout.topMargin: 2

            Column {
                id: rowColumn
                width: parent.width
                spacing: line.rowGap
                // By place: the host makes its rows afresh whenever a Set changes.
                Repeater {
                    id: rowRepeater
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
            }

            // Entries from the drawer and files from the desktop, onto a track.
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
        }
    }
}
