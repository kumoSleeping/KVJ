import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// The column at the window's left, as wide as the one at its right: above,
// 预备, what is ready to go on the picture (the sources waiting off it, and
// pictures kept for stickers); under a line that can be dragged, the
// folders on this computer (added with the folder key), with their videos
// and pictures. Pictures are dragged up into 预备 or straight onto the
// picture; videos only onto a track: its left half replaces what is on it,
// its right half adds after it (Timeline). Rows are chosen as in a file
// manager (⌘-click, Ctrl elsewhere, adds one; ⇧-click a run in one folder);
// a drag that starts on a chosen row takes all the chosen ones.
//
//   composer  the board (Composer): its waiting sources and kept pictures
//   app       the window (Main): placing on tracks, the drag's stand-in
Item {
    id: lib

    property var composer
    property var app

    readonly property var filters: ["*.mp4", "*.m4v", "*.mkv", "*.mov", "*.webm",
                                    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp", "*.svg", "*.bmp"]
    function isVideo(url) {
        return /\.(mp4|m4v|mkv|mov|webm)$/i.test(url)
    }
    function isImage(url) {
        return /\.(png|jpe?g|gif|webp|svg|bmp)$/i.test(url)
    }

    // 预备's share of the height, the line under it dragged.
    property real split: 0.42
    // The folders added (file URLs), and those opened or closed by hand.
    property var roots: []
    property var opened: ({})
    Settings {
        id: store
        category: "library"
        property alias split: lib.split
        property string roots: "[]"
        property string opened: "{}"
    }
    function saveRoots(list) {
        roots = list
        store.roots = JSON.stringify(list)
    }
    Component.onCompleted: {
        try {
            roots = JSON.parse(store.roots)
            opened = JSON.parse(store.opened)
        } catch (e) {
            roots = []
            opened = {}
        }
        // The first time: the folders the videos already in KVJ are in.
        if (!roots.length && app)
            saveRoots(app.libraryFolders())
    }
    function isOpen(url, root) {
        return opened[url] !== undefined ? opened[url] : root
    }
    function setOpen(url, on) {
        const next = Object.assign({}, opened)
        next[url] = on
        opened = next
        store.opened = JSON.stringify(next)
    }
    function placedTracks(url) {
        return app ? app.placedTracksOf(url) : []
    }

    // —— Choosing and dragging rows ——
    // The chosen files, URL to true, in the order chosen.
    property var selected: ({})
    property var anchor: null
    readonly property var chosen: Object.keys(selected)
    function choose(url, model, index, modifiers) {
        const add = (modifiers & Qt.ControlModifier) || (modifiers & Qt.MetaModifier)
        if ((modifiers & Qt.ShiftModifier) && anchor && anchor.model === model) {
            const next = {}
            const lo = Math.min(anchor.index, index), hi = Math.max(anchor.index, index)
            for (let i = lo; i <= hi; ++i)
                if (!model.get(i, "fileIsDir"))
                    next[String(model.get(i, "fileUrl"))] = true
            selected = next
            return
        }
        if (add) {
            const next = Object.assign({}, selected)
            if (next[url])
                delete next[url]
            else
                next[url] = true
            selected = next
        } else {
            selected = { [url]: true }
        }
        anchor = { model: model, index: index }
    }
    function beginDrag(url, at) {
        const urls = selected[url] ? chosen : [url]
        if (!selected[url])
            choose(url, null, -1, 0)
        const name = decodeURIComponent(url.substring(url.lastIndexOf("/") + 1))
        app.fileDragBegin(urls, urls.length > 1 ? name + " 等 " + urls.length + " 个" : name, at)
    }
    // A double-click: a video onto the first empty track (else after the
    // first's), a picture into 预备.
    function use(url) {
        const urls = selected[url] ? chosen : [url]
        const pictures = urls.filter(isImage)
        if (pictures.length)
            composer.addImages(pictures)
        const videos = urls.filter(isVideo)
        if (videos.length)
            app.filesAnywhere(videos)
    }
    Shortcut {
        sequence: "Esc"
        enabled: lib.chosen.length > 0 && lib.visible
        onActivated: lib.selected = {}
    }

    function rootMenu(url, item, x, y) {
        menu.url = url
        menu.popup(item, x, y)
    }
    PopMenu {
        id: menu
        property string url: ""
        PopAction {
            text: "从列表移除这个文件夹（文件不动）"
            onTriggered: lib.saveRoots(lib.roots.filter(r => r !== menu.url))
        }
    }
    FolderDialog {
        id: folderDialog
        title: "添加文件夹"
        onAccepted: {
            const url = String(selectedFolder)
            if (lib.roots.indexOf(url) < 0)
                lib.saveRoots(lib.roots.concat([url]))
        }
    }

    implicitWidth: 228

    // The picture sources 预备 always shows: { id, name, usable, why }.
    readonly property var sources: {
        const out = []
        for (const r of (app ? app.trackRows : [])) {
            const has = app.placedOn(r.track).length > 0
            out.push({ id: r.key, name: r.name, usable: has, camera: false, word: "没有视频",
                       why: r.name + " 上还没有视频：从下面的媒体库拖一个上去" })
        }
        const cams = app ? app.cameraIds : []
        for (const c of cams) {
            const key = "camera:" + c
            out.push({ id: key, name: lib.composer.sourceName(key), usable: lib.composer.known(key), camera: true, word: "未连接",
                       why: "这台相机没有连接" })
        }
        if (!cams.length)
            out.push({ id: "camera:", name: "相机", usable: false, camera: true, word: "未添加",
                       why: "还没有相机：用画面下方的「+ 相机」加一个" })
        return out
    }
    // For a track's tile while its player rests at the very start: the
    // video's path and a moment a little way in ({ path, duration, at }), or
    // null (playing, moved on, no video).
    function trackStill(id) {
        if (!app || !id.startsWith("track:"))
            return null
        const t = Number(id.substring(6))
        const e = t === 0 ? app.shownEntry : app.auxPlayers[t - 1].entry
        const playing = t === 0 ? (!!app.match || app.transport.playing) : app.auxPlayers[t - 1].playing
        const at = t === 0 ? app.transport.position : app.auxPlayers[t - 1].position
        if (!e || !e.path || playing || at > 0.5 || !(e.duration > 0))
            return null
        return { path: e.path, duration: e.duration, at: Math.min(e.duration * 0.1, 30) }
    }
    FileDialog {
        id: pictureDialog
        title: "添加图片"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["图片 (*.png *.jpg *.jpeg *.gif *.webp *.svg *.bmp)"]
        onAccepted: lib.composer.addImages(selectedFiles)
    }

    // —— 预备 ——
    Item {
        id: ready
        width: parent.width
        height: Math.max(80, Math.min(parent.height - 120, (parent.height - divider.height) * lib.split))

        RowLayout {
            id: readyHead
            width: parent.width
            height: 26
            Heading {
                Layout.fillWidth: true
                text: "预备"
            }
            IconButton {
                implicitWidth: 26
                implicitHeight: 26
                iconName: "file-plus"
                tip: "添加图片或 GIF（可多选），放在预备里备用"
                onClicked: pictureDialog.open()
            }
        }
        Flickable {
            y: readyHead.height + 4
            width: parent.width
            height: parent.height - y
            contentHeight: tiles.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: lib.composer.layerCarried === "" && !lib.composer.carrying
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            Flow {
                id: tiles
                width: parent.width
                spacing: 6
                // Three to a row: the sources fit on one.
                readonly property real tile: Math.floor((width - 2 * spacing) / 3)
                // The picture sources, always: 画面 1 and 画面 2 (画面 1 alone in
                // 单轨) and the cameras taken in (or one 相机 to say there is
                // none). Off the picture, a click brings one in at the lower
                // right and a drag puts it where it is let go; on it (an ink
                // edge), a click chooses it on the board. One with nothing to
                // show yet (an empty track, no camera) says so in its tile and
                // does nothing.
                Repeater {
                    model: lib.sources
                    Item {
                        id: srcTile
                        required property var modelData
                        readonly property string sid: modelData.id
                        readonly property int index_: lib.composer.slots.findIndex(s => s.source === sid)
                        readonly property bool usable: modelData.usable && index_ >= 0
                        readonly property bool shown: usable && Switcher.inPicture(lib.composer.slots[index_])
                        readonly property bool chosen: shown && lib.composer.selected === index_
                        width: tiles.tile
                        height: thumb.height + 18
                        Rectangle {
                            id: thumb
                            width: parent.width
                            height: Math.round(width * 9 / 16)
                            radius: Theme.radius
                            color: srcTile.usable ? "black" : Theme.inset
                            clip: true
                            opacity: lib.composer.layerCarried === srcTile.sid ? 0.4 : 1
                            Compositor {
                                visible: srcTile.usable && !still.visible
                                anchors.fill: parent
                                layout: ({ slots: [Switcher.slot({ source: srcTile.sid, x: 0, y: 0, w: 1, h: 1, fit: "contain" }, 0)] })
                                textures: lib.composer.textures
                                operator: true
                            }
                            // A track still at its start shows a frame from a
                            // little way in (a VJ video often opens on black).
                            FilmStrip {
                                id: still
                                readonly property var info: lib.trackStill(srcTile.sid)
                                visible: srcTile.usable && !!info
                                anchors.fill: parent
                                source: info ? info.path : ""
                                duration: info ? info.duration : 0
                                from: info ? info.at : 0
                                pxPerSec: width / 0.1
                                gap: "black"
                            }
                            // Nothing to show: what is missing, plainly.
                            Column {
                                visible: !srcTile.usable
                                anchors.centerIn: parent
                                spacing: 2
                                ColorImage {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    source: srcTile.modelData.camera ? "icons/camera-off.svg" : "icons/video-off.svg"
                                    sourceSize: Qt.size(16, 16)
                                    color: Theme.muted
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: srcTile.modelData.word
                                    font.pixelSize: 10
                                    color: Theme.muted
                                }
                            }
                        }
                        // On the picture: an ink edge (thicker while chosen there).
                        Rectangle {
                            visible: srcTile.shown
                            x: -2
                            y: -2
                            width: thumb.width + 4
                            height: thumb.height + 4
                            radius: Theme.radius + 2
                            color: "transparent"
                            border.width: srcTile.chosen ? 2 : 1.5
                            border.color: Theme.text
                        }
                        Text {
                            y: thumb.height + 3
                            width: parent.width
                            text: srcTile.modelData.name
                            font.pixelSize: Theme.sizeXs
                            font.weight: srcTile.shown ? Font.DemiBold : Font.Normal
                            color: sourceArea.containsMouse || srcTile.shown ? Theme.text : Theme.body
                            elide: Text.ElideRight
                        }
                        MouseArea {
                            id: sourceArea
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: !srcTile.usable ? Qt.ArrowCursor : lib.composer.layerCarried ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                            property point from
                            onPressed: mouse => from = Qt.point(mouse.x, mouse.y)
                            onPositionChanged: mouse => {
                                if (!pressed || !srcTile.usable)
                                    return
                                if (!lib.composer.layerCarried && Math.hypot(mouse.x - from.x, mouse.y - from.y) > 6)
                                    lib.composer.layerCarried = srcTile.sid
                                if (lib.composer.layerCarried)
                                    lib.composer.layerAt = mapToItem(lib.composer, mouse.x, mouse.y)
                            }
                            onReleased: {
                                if (!srcTile.usable)
                                    return
                                if (lib.composer.layerCarried)
                                    lib.composer.dropLayer()
                                else
                                    lib.composer.bringIn(srcTile.sid)
                            }
                            onCanceled: lib.composer.layerCarried = ""
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 600
                            ToolTip.text: !srcTile.usable ? srcTile.modelData.why
                                        : srcTile.shown ? "在画面中 · 点一下在画板上选中它"
                                        : "在画外，观众看不到 · 点一下放进画面右下角，或拖进画面里"
                        }
                    }
                }
                // The pictures kept: a click posts one in the middle, a drag
                // where it is let go; × lets it go from here.
                Repeater {
                    model: lib.composer.gallery
                    Item {
                        id: kept
                        required property var modelData
                        readonly property bool moving: modelData.kind === "image" && /\.(gif|webp)$/i.test(modelData.source)
                        width: tiles.tile
                        height: Math.round(width * 9 / 16) + 18
                        Rectangle {
                            id: keptBox
                            width: parent.width
                            height: Math.round(width * 9 / 16)
                            radius: Theme.radius
                            color: keptArea.containsMouse ? Theme.hover : Theme.inset
                            opacity: lib.composer.carrying && lib.composer.carrying.id === kept.modelData.id ? 0.4 : 1
                            Image {
                                id: keptThumb
                                anchors.fill: parent
                                anchors.margins: 4
                                visible: kept.modelData.kind === "image" && !(kept.moving && keptArea.containsMouse)
                                source: kept.modelData.kind === "image" ? kept.modelData.source : ""
                                sourceSize.width: 160
                                sourceSize.height: 160
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }
                            // A GIF plays while the pointer is on it.
                            Loader {
                                anchors.fill: parent
                                anchors.margins: 4
                                active: kept.moving && keptArea.containsMouse
                                sourceComponent: AnimatedImage {
                                    source: kept.modelData.source
                                    fillMode: Image.PreserveAspectFit
                                }
                            }
                            Text {
                                anchors.fill: parent
                                anchors.margins: 4
                                visible: kept.modelData.kind === "text" || keptThumb.status === Image.Error
                                text: kept.modelData.kind === "text" ? kept.modelData.text : "无法读取"
                                font.pixelSize: kept.modelData.kind === "text" ? Theme.sizeSm : Theme.sizeXs
                                font.weight: Font.DemiBold
                                color: kept.modelData.kind === "text" ? Theme.text : Theme.faint
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                wrapMode: Text.Wrap
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            y: keptBox.height + 3
                            width: parent.width
                            text: kept.modelData.name || ""
                            font.pixelSize: Theme.sizeXs
                            color: keptArea.containsMouse ? Theme.text : Theme.muted
                            elide: Text.ElideMiddle
                        }
                        MouseArea {
                            id: keptArea
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: lib.composer.carrying ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                            property point start
                            onPressed: mouse => start = mapToItem(lib.composer, mouse.x, mouse.y)
                            onPositionChanged: mouse => {
                                if (!pressed)
                                    return
                                const p = mapToItem(lib.composer, mouse.x, mouse.y)
                                if (!lib.composer.carrying && Math.hypot(p.x - start.x, p.y - start.y) > 6)
                                    lib.composer.carrying = kept.modelData
                                if (lib.composer.carrying)
                                    lib.composer.carryPoint = p
                            }
                            onReleased: {
                                if (lib.composer.carrying)
                                    lib.composer.letGo()
                                else
                                    lib.composer.postAt(kept.modelData, 0.5, 0.5)
                            }
                            onCanceled: lib.composer.carrying = null
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 600
                            ToolTip.text: "点一下贴在画面中间，或拖进画面里"
                        }
                        IconButton {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            implicitWidth: 18
                            implicitHeight: 18
                            iconSize: 10
                            iconName: "x"
                            tip: "从预备里拿掉"
                            visible: keptArea.containsMouse || hovered
                            onClicked: lib.composer.forget(kept.modelData.id)
                        }
                    }
                }
            }
        }
        // Pictures dropped here (from below or from elsewhere) wait here; a video does not.
        DropArea {
            anchors.fill: parent
            onDropped: drop => {
                const src = drop.source
                const urls = src && src.fileUrls && src.fileUrls.length ? src.fileUrls : drop.hasUrls ? drop.urls : []
                const pictures = Array.prototype.slice.call(urls).map(u => String(u)).filter(lib.isImage)
                if (pictures.length) {
                    lib.composer.addImages(pictures)
                    drop.acceptProposedAction()
                }
            }
        }
    }

    // Between them, unseen: dragged up or down.
    Item {
        id: divider
        y: ready.height
        width: parent.width
        height: 13
        MouseArea {
            id: splitArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SizeVerCursor
            onPositionChanged: mouse => {
                if (!pressed)
                    return
                const y = mapToItem(lib, mouse.x, mouse.y).y
                lib.split = Math.max(0.1, Math.min(0.85, y / Math.max(1, lib.height)))
            }
        }
    }

    // —— 媒体库: the folders on this computer ——
    Item {
        y: divider.y + divider.height
        width: parent.width
        height: parent.height - y

        RowLayout {
            id: filesHead
            width: parent.width
            height: 26
            Heading {
                Layout.fillWidth: true
                text: "媒体库"
            }
            IconButton {
                implicitWidth: 26
                implicitHeight: 26
                iconName: "folder-plus"
                tip: "添加一个文件夹（里面的视频和图片都列在这里，不会复制）"
                onClicked: folderDialog.open()
            }
        }
        Flickable {
            y: filesHead.height + 4
            width: parent.width
            height: parent.height - y
            contentHeight: tree.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            Column {
                id: tree
                // (Inside a folder `lib` is its own property.)
                readonly property Item owner: lib
                width: parent.width
                Repeater {
                    model: lib.roots
                    LibraryFolder {
                        required property string modelData
                        lib: tree.owner
                        url: modelData
                        name: {
                            const p = decodeURIComponent(modelData.replace(/\/+$/, ""))
                            return p.substring(p.lastIndexOf("/") + 1)
                        }
                        root: true
                    }
                }
            }
            Text {
                visible: lib.roots.length === 0
                y: 8
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "点右上角的文件夹键，把放视频和图片的文件夹加进来"
                font.pixelSize: Theme.sizeXs
                color: Theme.faint
            }
        }
    }
}
