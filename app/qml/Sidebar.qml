import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Dialogs
import QtQuick.Layouts
import KVJ

// Everything about Sets, and only here, as one tree in one scrolling list: each
// Set is a folder that opens onto its entries, grouped by the folders they were
// imported from (a folder holding just one folder shows as one row, "a / b").
// The chosen Set is the one on the timeline and followed; choosing another
// opens it and stops following, while the picture plays on from its own Set
// until something of the new one is played.
// Each entry has a key that turns it on or off, at once and also during the
// show: an entry that is off leaves the timeline and is not followed. At a
// handover between DJs the next one is turned on while the last stays on, and
// the last is turned off once the next is under way. Turning off the entry on
// the screen asks again, in red under it; the second press goes on to the next
// entry that is on. Files dropped on a Set go into that Set.
// It floats as a drawer over the canvas (Main.qml), which keeps it open while
// one of its menus or dialogs is in use (`asking`, `holding()`).
Rectangle {
    id: bar
    color: Theme.raised

    property var sets: []
    property var currentSet: null
    property bool running: false
    property bool editable: true
    // The entry on the screen now, if any, and the Set it is in.
    property string playingId: ""
    property string playingSetId: ""
    // The entry on the screen whose key was pressed once to turn it off.
    property string confirmId: ""
    // Opened and closed by hand: Set ids and folder keys to true (open) or
    // false. A Set nobody touched is open while it is the chosen one; a folder,
    // always.
    property var opened: ({})
    // The Set a drag of files is over.
    property string dropSetId: ""
    // A Set's menu that is open, and when the last one closed: a press outside
    // a menu closes it before anything under the press hears it, and that
    // press must not close the drawer as well.
    property Popup openMenu: null
    property real menuClosedAt: 0
    readonly property bool asking: (!!openMenu && openMenu.visible) || fileDialog.visible || folderDialog.visible
    function holding() {
        return bar.asking || Date.now() - bar.menuClosedAt < 300
    }

    signal selectSet(string id)
    signal addUrls(var urls)
    // The entry on the screen is turned off, confirmed.
    signal dropPlaying(string id)

    readonly property var entries: currentSet ? currentSet.entries : []

    function clock(seconds) {
        const s = Math.max(0, Math.floor(seconds))
        const h = Math.floor(s / 3600)
        const m = Math.floor(s / 60) % 60
        const pad = n => (n < 10 ? "0" : "") + n
        return (h > 0 ? h + ":" + pad(m) : m) + ":" + pad(s % 60)
    }
    function isOpen(key, byDefault) {
        return bar.opened[key] !== undefined ? bar.opened[key] : byDefault
    }
    function setOpen(key, on) {
        const next = Object.assign({}, bar.opened)
        next[key] = on
        bar.opened = next
    }
    function isCurrent(set) {
        return !!bar.currentSet && bar.currentSet.id === set.id
    }
    // Choosing a Set opens it; pressing the chosen one opens or closes it.
    // Choosing another stops following (Main.qml), never the picture.
    function choose(set) {
        if (isCurrent(set)) {
            setOpen(set.id, !isOpen(set.id, true))
        } else {
            bar.selectSet(set.id)
            setOpen(set.id, true)
        }
    }
    function addTo(set, urls) {
        if (!bar.editable || !urls || urls.length === 0)
            return
        if (set && !isCurrent(set))
            bar.selectSet(set.id)
        if (set)
            setOpen(set.id, true)
        bar.addUrls(urls)
    }
    // A key of an add dialog pressed on a Set's menu: it adds to that Set.
    function openDialog(set, dialog) {
        if (set && !isCurrent(set))
            bar.selectSet(set.id)
        dialog.open()
    }
    function enableAll(set, on) {
        const ids = set.entries.filter(e => (e.enabled !== false) !== on).map(e => e.id)
        // All off keeps the one on the screen: it is turned off on its own key.
        const chosen = on ? ids : ids.filter(id => id !== bar.playingId)
        if (chosen.length)
            Engine.enableEntries(set.id, chosen, on)
    }
    // A key pressed on an entry. Off for the one on the screen asks first.
    function press(set, entry, on) {
        if (!on && entry.id === bar.playingId && entry.enabled !== false) {
            if (bar.confirmId !== entry.id) {
                bar.confirmId = entry.id
                confirmTimer.restart()
                return
            }
            bar.confirmId = ""
            bar.dropPlaying(entry.id)
            return
        }
        bar.confirmId = ""
        Engine.enableEntries(set.id, [entry.id], on)
    }
    onPlayingIdChanged: confirmId = ""
    Timer {
        id: confirmTimer
        interval: 6000
        onTriggered: bar.confirmId = ""
    }

    // A Set's entries as a tree of the folders they came from, below the
    // folder all of them share: { name, key, dirs: [], items: [{ entry, index }],
    // order: [node or item, …] in the order they first appear }.
    function tree(set) {
        const dirOf = e => {
            const parts = String(e.path).replace(/\\/g, "/").split("/")
            parts.pop()
            return parts.filter(p => p.length > 0)
        }
        const paths = set.entries.map(dirOf)
        let common = paths.length ? paths[0].length : 0
        for (const p of paths) {
            let k = 0
            while (k < common && k < p.length && p[k] === paths[0][k])
                ++k
            common = k
        }
        const root = { name: "", key: set.id, order: [], total: 0, on: 0 }
        set.entries.forEach((entry, index) => {
            let node = root
            for (const name of paths[index].slice(common)) {
                let next = node.order.find(n => n.dirs !== undefined && n.name === name)
                if (!next) {
                    next = { name: name, key: node.key + "/" + name, dirs: [], order: [], total: 0, on: 0 }
                    node.order.push(next)
                }
                node = next
            }
            node.order.push({ entry: entry, index: index })
        })
        // Counts, and a folder holding only one folder joined with it.
        const settle = node => {
            for (let i = 0; i < node.order.length; ++i) {
                let child = node.order[i]
                if (child.dirs === undefined)
                    continue
                while (child.order.length === 1 && child.order[0].dirs !== undefined) {
                    const only = child.order[0]
                    child = { name: child.name + " / " + only.name, key: only.key, dirs: [], order: only.order, total: 0, on: 0 }
                }
                node.order[i] = child
                settle(child)
            }
            node.total = 0
            node.on = 0
            for (const child of node.order) {
                node.total += child.dirs !== undefined ? child.total : 1
                node.on += child.dirs !== undefined ? child.on : child.entry.enabled !== false ? 1 : 0
            }
        }
        settle(root)
        return root
    }
    // The rows on show, top to bottom.
    readonly property var rows: {
        const out = []
        for (const set of bar.sets) {
            const current = isCurrent(set)
            const open = isOpen(set.id, current)
            const on = set.entries.filter(e => e.enabled !== false).length
            out.push({ kind: "set", set: set, depth: 0, open: open, current: current, on: on })
            if (!open)
                continue
            if (set.entries.length === 0) {
                out.push({ kind: "empty", set: set, depth: 1 })
                continue
            }
            const walk = (node, depth) => {
                for (const child of node.order) {
                    if (child.dirs !== undefined) {
                        const dirOpen = isOpen(child.key, true)
                        out.push({ kind: "dir", set: set, depth: depth, open: dirOpen, key: child.key,
                                   name: child.name, total: child.total, on: child.on })
                        if (dirOpen)
                            walk(child, depth + 1)
                    } else {
                        out.push({ kind: "entry", set: set, depth: depth, entry: child.entry, index: child.index,
                                   current: current })
                        if (bar.confirmId === child.entry.id)
                            out.push({ kind: "confirm", set: set, depth: depth })
                    }
                }
            }
            walk(tree(set), 1)
        }
        return out
    }

    FileDialog {
        id: fileDialog
        fileMode: FileDialog.OpenFiles
        nameFilters: ["视频 (*.mp4 *.m4v *.mkv *.mov *.webm)"]
        onAccepted: bar.addTo(bar.currentSet, selectedFiles)
    }
    FolderDialog {
        id: folderDialog
        onAccepted: bar.addTo(bar.currentSet, [selectedFolder])
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // —— Head: the Sets, and the keys that add to them ——
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            Layout.leftMargin: 16
            Layout.rightMargin: 8
            spacing: 0
            Caption {
                Layout.fillWidth: true
                text: "素材"
            }
            IconButton { iconName: "file-plus"; tip: "添加视频到当前 Set"; enabled: bar.editable; onClicked: fileDialog.open() }
            IconButton { iconName: "folder-plus"; tip: "添加文件夹里的视频（含子文件夹）到当前 Set"; enabled: bar.editable; onClicked: folderDialog.open() }
            IconButton {
                iconName: "plus"
                tip: "新建 Set"
                enabled: !bar.running
                onClicked: {
                    const name = "Set " + (bar.sets.length + 1)
                    Engine.createSet(name)
                    const made = bar.sets.find(s => s.name === name)
                    if (made && !bar.running) {
                        bar.selectSet(made.id)
                        bar.setOpen(made.id, true)
                    }
                }
            }
        }

        // —— The tree ——
        Flickable {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: column.implicitHeight + 8
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            // Files dropped between the Sets go into the chosen one.
            DropArea {
                width: list.width
                height: Math.max(list.height, list.contentHeight)
                enabled: bar.editable
                onEntered: bar.dropSetId = bar.currentSet ? bar.currentSet.id : ""
                onExited: bar.dropSetId = ""
                onDropped: drop => {
                    bar.dropSetId = ""
                    if (drop.hasUrls)
                        bar.addTo(bar.currentSet, drop.urls)
                }
            }

            Column {
                id: column
                x: 8
                width: list.width - 16
                spacing: 1
                Repeater {
                    model: bar.rows
                    delegate: Loader {
                        required property var modelData
                        width: column.width
                        sourceComponent: modelData.kind === "set" ? setRow
                                       : modelData.kind === "dir" ? dirRow
                                       : modelData.kind === "entry" ? entryRow
                                       : modelData.kind === "confirm" ? confirmRow : emptyRow
                        onLoaded: item.info = Qt.binding(() => modelData)
                    }
                }
            }

            // No Set yet.
            ColumnLayout {
                visible: bar.sets.length === 0
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
                    text: "还没有 Set"
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

        // Foot: what the chosen Set holds in all.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            Layout.leftMargin: 16
            Layout.rightMargin: 12
            Text {
                Layout.fillWidth: true
                visible: !!bar.currentSet
                text: {
                    let total = 0
                    for (const e of bar.entries)
                        total += e.duration
                    const on = bar.entries.filter(e => e.enabled !== false).length
                    return bar.entries.length + " 个素材 · " + on + " 启用 · " + bar.clock(total)
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

    // The arrow that opens and closes a Set or a folder.
    component Chevron: ColorImage {
        property bool open: false
        source: "icons/chevron-right.svg"
        sourceSize: Qt.size(14, 14)
        color: Theme.faint
        rotation: open ? 90 : 0
        Behavior on rotation { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
    }

    // —— A Set: a folder that opens onto its entries ——
    Component {
        id: setRow
        ItemDelegate {
            id: row
            property var info: null
            readonly property var set: info ? info.set : null
            readonly property bool current: !!info && info.current
            readonly property bool dropping: !!set && bar.dropSetId === set.id
            height: Theme.row
            topPadding: 0
            bottomPadding: 0
            leftPadding: 4
            rightPadding: 2
            onClicked: bar.choose(set)
            contentItem: RowLayout {
                spacing: 6
                Chevron { open: !!row.info && row.info.open }
                ColorImage {
                    source: row.info && row.info.open ? "icons/folder-open.svg" : "icons/folder.svg"
                    sourceSize: Qt.size(16, 16)
                    color: row.current ? Theme.text : Theme.muted
                }
                Text {
                    Layout.fillWidth: true
                    text: row.set ? row.set.name : ""
                    font.pixelSize: Theme.size
                    font.weight: row.current ? Font.DemiBold : Font.Medium
                    color: row.current ? Theme.text : Theme.body
                    elide: Text.ElideRight
                }
                // The picture plays from this Set while another one is open.
                ColorImage {
                    visible: !row.current && !!row.set && row.set.id === bar.playingSetId
                    source: "icons/play.svg"
                    sourceSize: Qt.size(12, 12)
                    color: Theme.muted
                    ToolTip.visible: playTip.hovered
                    ToolTip.delay: 400
                    ToolTip.text: "画面正在播这个 Set"
                    HoverHandler { id: playTip }
                }
                Text {
                    visible: !more.visible
                    text: row.set ? (row.info.on < row.set.entries.length ? row.info.on + "/" : "") + row.set.entries.length : ""
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                    rightPadding: 8
                }
                IconButton {
                    id: more
                    visible: row.hovered || menu.visible
                    implicitWidth: 24
                    implicitHeight: 24
                    iconName: "ellipsis"
                    tip: "更多"
                    onClicked: menu.popup(more, 0, more.height + 2)
                }
            }
            background: Rectangle {
                radius: Theme.radius
                color: row.current ? Theme.selected : row.hovered ? Theme.hover : "transparent"
                border.width: row.dropping ? 1.5 : 0
                border.color: Theme.muted
            }
            DropArea {
                anchors.fill: parent
                enabled: bar.editable
                onEntered: bar.dropSetId = row.set.id
                onExited: if (bar.dropSetId === row.set.id) bar.dropSetId = ""
                onDropped: drop => {
                    bar.dropSetId = ""
                    if (drop.hasUrls)
                        bar.addTo(row.set, drop.urls)
                }
            }
            PopMenu {
                id: menu
                onAboutToShow: bar.openMenu = menu
                onClosed: {
                    bar.menuClosedAt = Date.now()
                    if (bar.openMenu === menu)
                        bar.openMenu = null
                }
                PopAction { text: "添加视频…"; enabled: bar.editable; onTriggered: bar.openDialog(row.set, fileDialog) }
                PopAction { text: "添加文件夹…"; enabled: bar.editable; onTriggered: bar.openDialog(row.set, folderDialog) }
                MenuSeparator {
                    contentItem: Rectangle { implicitHeight: 1; color: Theme.line }
                }
                PopAction {
                    text: "全部启用"
                    enabled: !!row.set && row.info.on < row.set.entries.length
                    onTriggered: bar.enableAll(row.set, true)
                }
                PopAction {
                    text: "全部停用"
                    enabled: !!row.set && row.info.on > 0
                    onTriggered: bar.enableAll(row.set, false)
                }
                MenuSeparator {
                    contentItem: Rectangle { implicitHeight: 1; color: Theme.line }
                }
                PopAction {
                    text: "删除这个 Set"
                    risky: true
                    enabled: bar.editable
                    onTriggered: Engine.deleteSet(row.set.id)
                }
            }
        }
    }

    // —— A folder the entries came from ——
    Component {
        id: dirRow
        ItemDelegate {
            id: row
            property var info: null
            height: 30
            topPadding: 0
            bottomPadding: 0
            leftPadding: 4 + (row.info ? row.info.depth : 1) * 16
            rightPadding: 10
            onClicked: bar.setOpen(row.info.key, !row.info.open)
            contentItem: RowLayout {
                spacing: 6
                Chevron { open: !!row.info && row.info.open }
                ColorImage {
                    source: row.info && row.info.open ? "icons/folder-open.svg" : "icons/folder.svg"
                    sourceSize: Qt.size(15, 15)
                    color: Theme.muted
                }
                Text {
                    Layout.fillWidth: true
                    text: row.info ? row.info.name : ""
                    font.pixelSize: Theme.sizeSm
                    font.weight: Font.Medium
                    color: Theme.body
                    elide: Text.ElideMiddle
                }
                Text {
                    text: row.info ? (row.info.on < row.info.total ? row.info.on + "/" : "") + row.info.total : ""
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                }
            }
            background: Rectangle {
                radius: Theme.radius
                color: row.hovered ? Theme.hover : "transparent"
            }
        }
    }

    // —— An entry: the whole row is its key, one tap at the booth ——
    Component {
        id: entryRow
        ItemDelegate {
            id: row
            property var info: null
            readonly property var entry: info ? info.entry : null
            readonly property bool on: !!entry && entry.enabled !== false
            readonly property bool playing: !!entry && bar.playingId === entry.id
            readonly property int track: entry ? entry.track || 0 : 0
            height: Theme.row
            topPadding: 0
            bottomPadding: 0
            leftPadding: 8 + (row.info ? row.info.depth : 1) * 16
            rightPadding: 6
            onClicked: bar.press(row.info.set, entry, !on)
            ToolTip.visible: hovered && title.truncated
            ToolTip.delay: 700
            ToolTip.text: entry ? entry.title : ""
            contentItem: RowLayout {
                spacing: 8
                Toggle {
                    padding: 0
                    checked: row.on
                    onToggled: {
                        // The document says whether it is on; a press only asks.
                        checked = Qt.binding(() => row.on)
                        bar.press(row.info.set, row.entry, !row.on)
                    }
                }
                Text {
                    id: title
                    Layout.fillWidth: true
                    text: row.entry ? row.entry.title : ""
                    font.pixelSize: Theme.sizeSm
                    font.weight: row.playing ? Font.DemiBold : Font.Normal
                    color: row.playing ? Theme.text : row.on ? Theme.body : Theme.faint
                    elide: Text.ElideRight
                }
                // Which picture it plays in, when not the main one (Live tracks).
                Text {
                    visible: row.track > 0
                    text: "画面 " + (row.track + 1)
                    font.pixelSize: Theme.sizeXs
                    color: Theme.muted
                }
                ColorImage {
                    visible: row.playing || (!!row.entry && (!row.entry.video || !!row.entry.silent))
                    source: row.playing ? "icons/play.svg" : row.entry && row.entry.silent ? "icons/volume-x.svg" : "icons/music.svg"
                    sourceSize: Qt.size(12, 12)
                    color: row.playing ? Theme.text : Theme.faint
                    ToolTip.visible: hoverTip.hovered
                    ToolTip.delay: 400
                    ToolTip.text: row.playing ? "正在投放" : row.entry && row.entry.silent ? "没有声音：只放画面，不跟随" : "只有声音"
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
                        text: row.entry ? bar.clock(row.entry.duration) : ""
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: row.playing ? Theme.muted : Theme.faint
                    }
                    IconButton {
                        id: remove
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.hovered && bar.editable
                        iconName: "x"
                        iconSize: 14
                        tip: "移出 Set"
                        implicitWidth: 22
                        implicitHeight: 22
                        onClicked: Engine.removeEntry(row.info.set.id, row.entry.id)
                    }
                }
            }
            background: Rectangle {
                radius: Theme.radius
                color: row.hovered ? Theme.hover : "transparent"
                // The entry on the screen: an ink edge.
                Rectangle {
                    visible: row.playing
                    x: 1
                    width: 3
                    height: parent.height - 14
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 1.5
                    color: Theme.text
                }
            }
            // A right press puts it on another track: the main one is followed
            // and played by the player, the others play side by side with it.
            TapHandler {
                acceptedButtons: Qt.RightButton
                enabled: bar.editable && !!row.entry
                onTapped: trackMenu.popup()
            }
            PopMenu {
                id: trackMenu
                onAboutToShow: bar.openMenu = trackMenu
                onClosed: {
                    bar.menuClosedAt = Date.now()
                    if (bar.openMenu === trackMenu)
                        bar.openMenu = null
                }
                PopAction {
                    text: (row.track === 0 ? "✓ " : "") + "放到主轨（画面 1）"
                    enabled: row.track !== 0
                    onTriggered: Engine.setTrack(row.info.set.id, [row.entry.id], 0)
                }
                PopAction {
                    text: (row.track === 1 ? "✓ " : "") + "放到画面 2"
                    enabled: row.track !== 1
                    onTriggered: Engine.setTrack(row.info.set.id, [row.entry.id], 1)
                }
                PopAction {
                    text: (row.track === 2 ? "✓ " : "") + "放到画面 3"
                    enabled: row.track !== 2
                    onTriggered: Engine.setTrack(row.info.set.id, [row.entry.id], 2)
                }
                PopAction {
                    text: (row.track === 3 ? "✓ " : "") + "放到画面 4"
                    enabled: row.track !== 3
                    onTriggered: Engine.setTrack(row.info.set.id, [row.entry.id], 3)
                }
            }
            DropArea {
                anchors.fill: parent
                enabled: bar.editable && !!row.info
                onEntered: bar.dropSetId = row.info.set.id
                onExited: if (bar.dropSetId === row.info.set.id) bar.dropSetId = ""
                onDropped: drop => {
                    bar.dropSetId = ""
                    if (drop.hasUrls)
                        bar.addTo(row.info.set, drop.urls)
                }
            }
        }
    }

    // —— Turning off the entry on the screen, asked in place ——
    Component {
        id: confirmRow
        Item {
            property var info: null
            height: warning.implicitHeight + 16
            Rectangle {
                x: 8 + (parent.info ? parent.info.depth : 1) * 16
                y: 2
                width: parent.width - x - 4
                height: parent.height - 4
                radius: Theme.radius
                color: Theme.danger
                Text {
                    id: warning
                    anchors.fill: parent
                    anchors.margins: 6
                    anchors.leftMargin: 9
                    text: "正在播放这个视频。再点一次取消勾选，画面将跳到下一个启用视频的开头。"
                    font.pixelSize: Theme.sizeXs
                    font.weight: Font.Medium
                    color: "white"
                    wrapMode: Text.Wrap
                    verticalAlignment: Text.AlignVCenter
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: bar.confirmId = ""
                }
            }
        }
    }

    // —— An open Set with nothing in it yet ——
    Component {
        id: emptyRow
        Item {
            property var info: null
            height: 30
            Text {
                x: 30
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - x - 8
                text: bar.running ? "空" : "把视频或文件夹拖到这里"
                font.pixelSize: Theme.sizeXs
                color: Theme.faint
                elide: Text.ElideRight
            }
        }
    }
}
