import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Dialogs
import QtQuick.Layouts
import KVJ

// The library: every video the show can play, in one scrolling list grouped by
// the folders the files are in (a folder holding just one folder shows as one
// row, "a / b"). It is the document's one Set (`currentSet`), which never shows
// as such.
// An entry is on the timeline (and followed) once it is placed on a track:
// dragged onto a track row, or double-clicked (the host puts it on the first
// free track); a placed one says which picture it is in. Rows are chosen as in
// a file manager: a click, ⌘-click (Ctrl elsewhere) to add or take one away,
// ⇧-click for a run, a folder for all of it, Esc for none. A drag or a
// double-click that starts on a chosen row takes all the chosen ones. Placing
// works during the show too, onto the track an entry is already on (moving
// between tracks waits until following stops). Files dropped here go into the
// library.
// It floats as a drawer over the canvas (Main.qml), which keeps it open while
// one of its dialogs is in use (`asking`, `holding()`).
Rectangle {
    id: bar
    color: Theme.raised

    // Only `currentSet` is shown; the host keeps it the only one.
    property var sets: []
    property var currentSet: null
    property bool running: false
    property bool editable: true
    // The entry on the screen now, if any, and the Set it is in.
    property string playingId: ""
    property string playingSetId: ""
    // Folder keys to true (open) or false; a folder nobody touched is open.
    property var opened: ({})
    // The chosen entries, id to true, and the row a ⇧-click run starts from.
    property var selected: ({})
    property string anchor: ""
    // The chosen ones top to bottom, closed folders included.
    readonly property var selectedIds: order.filter(id => !!selected[id])
    // Files dragged over the list.
    property bool dropping: false
    // A menu of the drawer's that is open, and when the last one closed: a
    // press outside a menu closes it before anything under the press hears it,
    // and that press must not close the drawer as well.
    property Popup openMenu: null
    property real menuClosedAt: 0
    readonly property bool asking: (!!openMenu && openMenu.visible) || fileDialog.visible || folderDialog.visible
    function holding() {
        return bar.asking || Date.now() - bar.menuClosedAt < 300
    }

    // Kept for hosts that still connect it; nothing here chooses a Set.
    signal selectSet(string id)
    // Its key in the head was pressed.
    signal putAway()
    // Entries double-clicked: onto the first free track.
    signal place(var entryIds)
    // Entries dragged: where the pointer is, in the window's coordinates;
    // `drop` false when it was called off.
    signal dragBegin(var entryIds, string title, point at)
    signal dragMove(point at)
    signal dragEnd(bool drop)
    signal addUrls(var urls)

    readonly property var entries: currentSet ? currentSet.entries : []

    function clock(seconds) {
        const s = Math.max(0, Math.floor(seconds))
        const h = Math.floor(s / 3600)
        const m = Math.floor(s / 60) % 60
        const pad = n => (n < 10 ? "0" : "") + n
        return (h > 0 ? h + ":" + pad(m) : m) + ":" + pad(s % 60)
    }
    function isOpen(key) {
        return bar.opened[key] !== undefined ? bar.opened[key] : true
    }
    function setOpen(key, on) {
        const next = Object.assign({}, bar.opened)
        next[key] = on
        bar.opened = next
    }
    function add(urls) {
        if (bar.editable && urls && urls.length > 0)
            bar.addUrls(urls)
    }

    // The entries as a tree of the folders they are in, below the folder all
    // of them share: { name, key, dirs: [], ids: [every entry id below],
    // order: [node or { entry }, …] in the order they first appear }.
    function tree(entries) {
        const dirOf = e => {
            const parts = String(e.path).replace(/\\/g, "/").split("/")
            parts.pop()
            return parts.filter(p => p.length > 0)
        }
        const paths = entries.map(dirOf)
        let common = paths.length ? paths[0].length : 0
        for (const p of paths) {
            let k = 0
            while (k < common && k < p.length && p[k] === paths[0][k])
                ++k
            common = k
        }
        const root = { name: "", key: "", dirs: [], ids: [], order: [] }
        entries.forEach((entry, index) => {
            let node = root
            for (const name of paths[index].slice(common)) {
                let next = node.order.find(n => n.dirs !== undefined && n.name === name)
                if (!next) {
                    next = { name: name, key: node.key + "/" + name, dirs: [], ids: [], order: [] }
                    node.order.push(next)
                }
                node = next
            }
            node.order.push({ entry: entry })
        })
        // The ids below each folder, and a folder holding only one folder
        // joined with it.
        const settle = node => {
            for (let i = 0; i < node.order.length; ++i) {
                let child = node.order[i]
                if (child.dirs === undefined)
                    continue
                while (child.order.length === 1 && child.order[0].dirs !== undefined) {
                    const only = child.order[0]
                    child = { name: child.name + " / " + only.name, key: only.key, dirs: [], ids: [], order: only.order }
                }
                node.order[i] = child
                settle(child)
            }
            node.ids = []
            for (const child of node.order)
                node.ids = node.ids.concat(child.dirs !== undefined ? child.ids : [child.entry.id])
        }
        settle(root)
        return root
    }
    readonly property var root: tree(bar.entries)
    readonly property var order: root.ids
    // The rows on show, top to bottom: { kind: "dir" or "entry", key, depth,
    // ids: the entries it stands for, and its folder or entry }.
    readonly property var rows: {
        const out = []
        const walk = (node, depth) => {
            for (const child of node.order) {
                if (child.dirs !== undefined) {
                    const open = isOpen(child.key)
                    out.push({ kind: "dir", key: "d:" + child.key, dir: child.key, depth: depth, open: open,
                               name: child.name, ids: child.ids })
                    if (open)
                        walk(child, depth + 1)
                } else {
                    out.push({ kind: "entry", key: "e:" + child.entry.id, depth: depth, entry: child.entry,
                               ids: [child.entry.id] })
                }
            }
        }
        walk(bar.root, 0)
        return out
    }

    // —— Choosing, as in a file manager ——
    function chosen(ids) {
        return ids.length > 0 && ids.every(id => !!bar.selected[id])
    }
    function only(ids) {
        const next = {}
        for (const id of ids)
            next[id] = true
        return next
    }
    // A row clicked. A plain click on one of several chosen rows waits out a
    // double-click before it leaves only that one chosen.
    function pick(info, modifiers) {
        collapse.stop()
        const adding = (modifiers & Qt.ControlModifier) !== 0
        if ((modifiers & Qt.ShiftModifier) !== 0 && bar.anchor !== "") {
            const keys = bar.rows.map(r => r.key)
            const to = keys.indexOf(info.key)
            let from = keys.indexOf(bar.anchor)
            if (from < 0)
                from = to
            // A folder on the way stands for what is in it only when closed,
            // or at either end.
            const next = adding ? Object.assign({}, bar.selected) : {}
            for (let i = Math.min(from, to); i <= Math.max(from, to); ++i) {
                const row = bar.rows[i]
                if (row.kind === "entry" || !row.open || i === from || i === to)
                    for (const id of row.ids)
                        next[id] = true
            }
            bar.selected = next
            return
        }
        bar.anchor = info.key
        if (adding) {
            const next = Object.assign({}, bar.selected)
            const off = chosen(info.ids)
            for (const id of info.ids) {
                if (off)
                    delete next[id]
                else
                    next[id] = true
            }
            bar.selected = next
        } else if (chosen(info.ids) && bar.selectedIds.length > info.ids.length) {
            collapse.ids = info.ids
            collapse.restart()
        } else {
            bar.selected = only(info.ids)
        }
    }
    Timer {
        id: collapse
        property var ids: []
        interval: Qt.styleHints.mouseDoubleClickInterval
        onTriggered: bar.selected = bar.only(ids)
    }
    // What a drag or a double-click on a row takes: the chosen ones if it is
    // one of them, else that row alone, chosen now.
    function take(info) {
        collapse.stop()
        if (chosen(info.ids))
            return bar.selectedIds
        bar.selected = only(info.ids)
        bar.anchor = info.key
        return info.ids
    }
    function titled(ids) {
        const first = bar.entries.find(e => e.id === ids[0])
        const name = first ? first.title : ""
        return ids.length > 1 ? name + " 等 " + ids.length + " 个" : name
    }

    // Esc lets the chosen ones go before it puts the drawer away; ⌘A chooses
    // all. Only while a press in the drawer has the keys here.
    Keys.onShortcutOverride: event => {
        event.accepted = bar.visible && ((event.key === Qt.Key_Escape && bar.selectedIds.length > 0)
                                         || event.matches(StandardKey.SelectAll))
    }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape && bar.selectedIds.length > 0) {
            collapse.stop()
            bar.selected = ({})
            event.accepted = true
        } else if (event.matches(StandardKey.SelectAll)) {
            collapse.stop()
            bar.selected = bar.only(bar.order)
            event.accepted = true
        }
    }

    FileDialog {
        id: fileDialog
        fileMode: FileDialog.OpenFiles
        nameFilters: ["视频 (*.mp4 *.m4v *.mkv *.mov *.webm)"]
        onAccepted: bar.add(selectedFiles)
    }
    FolderDialog {
        id: folderDialog
        onAccepted: bar.add([selectedFolder])
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // —— Head: the keys that add to the library ——
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            spacing: 0
            // Where the canvas has its key while the drawer is away: it puts
            // the drawer away again.
            IconButton {
                Layout.rightMargin: 6
                iconName: "panel-left"
                active: true
                tip: "收起素材（" + (Qt.platform.os === "osx" ? "⌘B" : "Ctrl+B") + "）"
                onClicked: bar.putAway()
            }
            Caption {
                Layout.fillWidth: true
                text: "素材"
            }
            IconButton { iconName: "file-plus"; tip: "添加视频"; enabled: bar.editable; onClicked: fileDialog.open() }
            IconButton { iconName: "folder-plus"; tip: "添加文件夹里的视频（含子文件夹）"; enabled: bar.editable; onClicked: folderDialog.open() }
        }

        // —— The tree ——
        // Not flicked by a drag, which is the rows' own (onto a track); the
        // wheel and the trackpad scroll it.
        Flickable {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: column.implicitHeight + 8
            interactive: false
            clip: true
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            WheelHandler {
                target: null
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                    const step = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 48
                    const top = Math.max(0, list.contentHeight - list.height)
                    list.contentY = Math.max(0, Math.min(top, list.contentY - step))
                }
            }

            // A press on no row lets the chosen ones go.
            MouseArea {
                width: list.width
                height: Math.max(list.height, list.contentHeight)
                onPressed: bar.forceActiveFocus()
                onClicked: mouse => {
                    if (!(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))) {
                        collapse.stop()
                        bar.selected = ({})
                    }
                }
            }
            DropArea {
                width: list.width
                height: Math.max(list.height, list.contentHeight)
                enabled: bar.editable
                keys: ["text/uri-list"]
                onEntered: bar.dropping = true
                onExited: bar.dropping = false
                onDropped: drop => {
                    bar.dropping = false
                    if (drop.hasUrls)
                        bar.add(drop.urls)
                }
            }

            Column {
                id: column
                x: 8
                width: list.width - 16
                spacing: 1
                Repeater {
                    model: bar.rows
                    delegate: Item {
                        id: slot
                        required property var modelData
                        readonly property bool dir: modelData.kind === "dir"
                        readonly property bool chosen: bar.chosen(modelData.ids)
                        readonly property bool playing: !dir && bar.playingId === modelData.entry.id
                        width: column.width
                        height: dir ? 30 : Theme.row

                        HoverHandler { id: hover }
                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radius
                            color: slot.chosen ? Theme.selected : hover.hovered ? Theme.hover : "transparent"
                            // The entry on the screen: an ink edge.
                            Rectangle {
                                visible: slot.playing
                                x: 1
                                width: 3
                                height: parent.height - 14
                                anchors.verticalCenter: parent.verticalCenter
                                radius: 1.5
                                color: Theme.text
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            // A right press (a two-finger tap) does nothing.
                            acceptedButtons: Qt.LeftButton
                            onPressed: bar.forceActiveFocus()
                            onClicked: mouse => bar.pick(slot.modelData, mouse.modifiers)
                            onDoubleClicked: {
                                const ids = bar.take(slot.modelData)
                                if (ids.length)
                                    bar.place(ids)
                            }
                        }
                        // Dragged down onto a track row of the timeline, they
                        // go on that track. The window carries the drag (Main's
                        // stand-in): this row may be made anew by the drop
                        // while it is still under way. Nothing takes the drag
                        // over once it has begun. (On the row, not the
                        // MouseArea: a handler in an item opens it to every
                        // button.)
                        DragHandler {
                            id: rowDrag
                            target: null
                            grabPermissions: PointerHandler.CanTakeOverFromAnything
                            onActiveChanged: {
                                if (active) {
                                    const ids = bar.take(slot.modelData)
                                    bar.dragBegin(ids, bar.titled(ids), centroid.scenePosition)
                                } else {
                                    bar.dragEnd(true)
                                }
                            }
                            onCentroidChanged: if (active) bar.dragMove(centroid.scenePosition)
                        }
                        Component.onDestruction: if (rowDrag.active) bar.dragEnd(false)
                        Loader {
                            anchors.fill: parent
                            anchors.leftMargin: (slot.dir ? 4 : 8) + slot.modelData.depth * 16
                            anchors.rightMargin: slot.dir ? 10 : 6
                            sourceComponent: slot.dir ? dirContent : entryContent
                            onLoaded: {
                                item.info = Qt.binding(() => slot.modelData)
                                item.hovered = Qt.binding(() => hover.hovered)
                            }
                        }
                    }
                }
            }

            // Nothing in the library yet.
            ColumnLayout {
                visible: bar.entries.length === 0
                width: list.width - 48
                x: 24
                y: Math.max(24, list.height / 2 - height / 2 - 30)
                spacing: 6
                ColorImage {
                    Layout.alignment: Qt.AlignHCenter
                    source: "icons/folder-open.svg"
                    sourceSize: Qt.size(28, 28)
                    color: Theme.faint
                }
                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    text: "还没有视频"
                    font.pixelSize: Theme.size
                    font.weight: Font.DemiBold
                    color: Theme.muted
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    Layout.fillWidth: true
                    text: "把视频或文件夹拖进来，\n或点上面的按钮添加"
                    font.pixelSize: Theme.sizeXs
                    lineHeight: 1.3
                    color: Theme.faint
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }
            }
        }

        // Foot: what the library holds in all, or what is chosen.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            Layout.leftMargin: 16
            Layout.rightMargin: 12
            Text {
                Layout.fillWidth: true
                text: {
                    const chosen = bar.selectedIds
                    const of = chosen.length > 1 ? bar.entries.filter(e => !!bar.selected[e.id]) : bar.entries
                    let total = 0
                    for (const e of of)
                        total += e.duration
                    if (chosen.length > 1)
                        return "已选 " + chosen.length + " 个 · " + bar.clock(total)
                    const placed = bar.entries.filter(e => e.enabled !== false).length
                    return bar.entries.length + " 个视频 · " + placed + " 个在轨道上 · " + bar.clock(total)
                }
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: Theme.muted
                elide: Text.ElideRight
            }
            BusyIndicator {
                running: Engine.importing
                visible: running
                implicitWidth: 18
                implicitHeight: 18
                palette.dark: Theme.muted
            }
        }
    }

    // Files over the list.
    Rectangle {
        visible: bar.dropping
        x: list.x + 4
        y: list.y
        width: list.width - 8
        height: list.height
        radius: Theme.radius
        color: "transparent"
        border.width: 1.5
        border.color: Theme.muted
    }

    // The arrow that opens and closes a folder.
    component Chevron: ColorImage {
        property bool open: false
        source: "icons/chevron-right.svg"
        sourceSize: Qt.size(14, 14)
        color: Theme.faint
        rotation: open ? 90 : 0
        Behavior on rotation { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
    }

    // —— A folder the files are in: its arrow opens and closes it, the rest
    // of the row stands for all its entries ——
    Component {
        id: dirContent
        RowLayout {
            id: content
            property var info: null
            property bool hovered: false
            spacing: 6
            Chevron {
                open: !!content.info && content.info.open
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -5
                    onPressed: bar.forceActiveFocus()
                    onClicked: bar.setOpen(content.info.dir, !content.info.open)
                }
            }
            ColorImage {
                source: content.info && content.info.open ? "icons/folder-open.svg" : "icons/folder.svg"
                sourceSize: Qt.size(15, 15)
                color: Theme.muted
            }
            Text {
                id: name
                Layout.fillWidth: true
                text: content.info ? content.info.name : ""
                font.pixelSize: Theme.sizeSm
                font.weight: Font.Medium
                color: Theme.body
                elide: Text.ElideMiddle
            }
            Text {
                text: content.info ? content.info.ids.length : ""
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: Theme.faint
            }
            ToolTip.visible: hovered && name.truncated
            ToolTip.delay: 700
            ToolTip.text: name.text
        }
    }

    // —— An entry of the library: a placed one says which picture it is in ——
    Component {
        id: entryContent
        RowLayout {
            id: content
            property var info: null
            property bool hovered: false
            readonly property var entry: info ? info.entry : null
            readonly property bool placed: !!entry && entry.enabled !== false
            readonly property bool playing: !!entry && bar.playingId === entry.id
            spacing: 8
            ToolTip.visible: hovered && title.truncated
            ToolTip.delay: 700
            ToolTip.text: entry ? entry.title : ""
            Text {
                id: title
                Layout.fillWidth: true
                text: content.entry ? content.entry.title : ""
                font.pixelSize: Theme.sizeSm
                font.weight: content.playing ? Font.DemiBold : Font.Normal
                color: content.playing ? Theme.text : Theme.body
                elide: Text.ElideMiddle
            }
            Text {
                visible: content.placed
                text: "画面 " + ((content.entry ? content.entry.track || 0 : 0) + 1)
                font.pixelSize: Theme.sizeXs
                color: Theme.muted
            }
            ColorImage {
                visible: content.playing || (!!content.entry && (!content.entry.video || !!content.entry.silent))
                source: content.playing ? "icons/play.svg" : content.entry && content.entry.silent ? "icons/volume-x.svg" : "icons/music.svg"
                sourceSize: Qt.size(12, 12)
                color: content.playing ? Theme.text : Theme.faint
                ToolTip.visible: hoverTip.hovered
                ToolTip.delay: 400
                ToolTip.text: content.playing ? "正在投放" : content.entry && content.entry.silent ? "没有声音：只放画面，不跟随" : "只有声音"
                HoverHandler { id: hoverTip }
            }
            Item {
                implicitWidth: Math.max(length.implicitWidth, 22)
                implicitHeight: 22
                Text {
                    id: length
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !remove.visible
                    text: content.entry ? bar.clock(content.entry.duration) : ""
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: content.playing ? Theme.muted : Theme.faint
                }
                IconButton {
                    id: remove
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: content.hovered && bar.editable
                    iconName: "x"
                    iconSize: 14
                    tip: "从素材里移除"
                    implicitWidth: 22
                    implicitHeight: 22
                    onClicked: if (bar.currentSet) Engine.removeEntry(bar.currentSet.id, content.entry.id)
                }
            }
        }
    }
}
