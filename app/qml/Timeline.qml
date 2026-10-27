import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// The track area across the foot of the window, laid out like a video
// editor's: a row a source, each on a clock of its own, all of them alike.
// On top a slim bar for the active row (the track row pressed last, its
// header inked): what it shows, its cursor and 跳至光标处 (Enter does the
// same), its zoom keys − 全览 + (− = \ too), then 快捷键 and how jumps
// look. Then the rows (TrackRow), two in view, more by scrolling: the tracks
// (画面 1..4) and the cameras. Each has its header (its picture, which a press puts
// in the preview; its name; ⋯), its own play bar, its own ruler and view
// (zoom and scroll are a row's own) and its own cursor: a press on a row's
// timeline only places that row's cursor, and only Enter, 跳至光标处 / 跳至,
// the play key or the nudge keys ever move a picture. While smart following
// leads a player the keys its helpers at work own rest. Entries from the
// drawer (an internal drag whose source has `entryIds` and `title`), or
// files, dropped on the body of a track's row go on that track, which lights
// up with a block where they will land; dropped on the seam between two rows,
// above the first or below the last, they go on a new track there, shown by
// an ink line (only while a track can be added). Near the
// rows' top or bottom edge a drag scrolls them. Under the rows a slim + adds
// a track or a camera.
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
//             who leads, the keys, the fade
//   setId     keys the rows' kept views and cursors (nothing of it is shown)
//   trailing  an item placed right of the rows, top-aligned with the first
//   rowHeight / mainRowHeight  one row's height (the trailing item's too)
//   activeRow / activeTrack  the active row's tracks[] item and its track
//             (-1 while there is none); markClip / canJump: its cursor's
//             clip, and whether a jump would go now
//   pickSource(key), addTrack(), addCamera(id), removeRow(key): asked of the host
//   dropEntries(ids, track), dropFiles(urls, track): onto a track
//   insertEntries(ids, position), insertFiles(urls, position): onto a new
//             track that appears at `position` in `tracks` (0..tracks.length)
//   removeEntry(id): an entry's 移出轨道 (right click on it)
//   jump(), zoomAt(x, factor), zoomStep(factor), fit(), setMark(x): the
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
    property bool canAddTrack: false
    property alias trailing: trailingSlot.data
    property int rowHeight: 120
    readonly property int mainRowHeight: rowHeight
    // Rows in view before the rest scroll.
    property int visibleRows: 2
    readonly property int headerWidth: 170
    readonly property int rowGap: 4
    // Room at the rows' right for their scroll bar.
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
                                : [{ key: "track:0", kind: "track", track: 0, name: "画面 1", entries: entries, player: player }]
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
    function jump() {
        if (activeItem)
            activeItem.jump()
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
    // the last, or at the top of the first), or kind "" (a camera, or nowhere).
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
            if (y < seam)
                return { kind: "insert", index: -1, track: -1, position: 0 }
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
            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 80
                textFormat: Text.StyledText
                text: {
                    const r = parent.act
                    if (!r)
                        return ""
                    const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    const what = r.shown ? esc(r.shown.title)
                               : r.main && line.running ? (line.phase === "searching" ? "重新搜索" : "等待识别") : ""
                    return "<font color='" + Theme.muted + "'>" + esc(r.name) + (what ? "  ·  " : "") + "</font>" + what
                }
                font.pixelSize: Theme.sizeSm
                font.weight: Font.DemiBold
                color: Theme.text
                elide: Text.ElideRight
            }
            Text {
                text: parent.act && parent.act.markClip
                      ? "光标 " + (parent.act.clips.length > 1 ? parent.act.markClip.n + " · " : "") + line.clock(parent.act.markAt, true)
                      : "光标 —"
                font.pixelSize: Theme.sizeSm
                font.features: { "tnum": 1 }
                color: parent.act && parent.act.markClip ? Theme.muted : Theme.faint
            }
            TextButton {
                implicitHeight: 26
                text: "跳至光标处"
                outlined: true
                enabled: line.canJump
                onClicked: line.jump()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "从光标处播放" + (parent.act ? parent.act.name : "") + "（快捷键开着时也可按回车）\n点轨道的进度条、标尺或画面条只放光标，不动画面"
            }
            Rectangle { implicitWidth: 1; implicitHeight: 16; color: Theme.line }
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
            Rectangle { implicitWidth: 1; implicitHeight: 16; color: Theme.line }
            Toggle {
                text: "快捷键"
                checked: !!line.player && line.player.keysOn
                onToggled: line.player.keysOn = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "画面 1：← / →、A / D：按住时画面以 0.7 / 1.5 倍速播放，松开即恢复；暂停时按一下退后 / 前进 1 秒\n"
                              + "↑ / ↓、W / S：速度 +1% / −1%\n"
                              + "选中的轨道：回车从光标处播放；− / =：缩小 / 放大，\\：整条显示\n"
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
                        y: Math.max(0, line.dropZone.position * line.pitch - line.rowGap / 2 - 1)
                        width: rowColumn.width
                        height: 2
                        Rectangle {
                            anchors.fill: parent
                            radius: 1
                            color: Theme.text
                        }
                        // At the very top it hangs below the line, not clipped above it.
                        Rectangle {
                            y: line.dropZone.position === 0 ? 0 : -8
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

            // The audio-alignment strip, or whatever the host puts here, by the first row.
            Item {
                id: trailingSlot
                visible: children.length > 0
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 2
                implicitWidth: childrenRect.width
                implicitHeight: childrenRect.height
            }
        }
    }
}
