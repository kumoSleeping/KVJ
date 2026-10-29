import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Window
import KVJ

// The board: the one place the picture is seen and made. Every picture
// source is a layer on it; a source newly there waits off the picture
// (Switcher.stack), listed in 预备 at the window's left (Library) until it
// is brought in; cameras are taken in with + 相机 and let go from their
// layer's menu. Images dragged in are posted as stickers where they are let
// go on the picture; the effects, the words (文字, beside + 相机) and the
// reactions on the air show on it as they do for the audience. Right under the picture: 跟随 | 投放,
// the picture's sound, the output and 投放. In 跟随 every change here is on
// the air at once; in 投放 the audience keeps what was last put out until 投放
// (Switcher.apply, also Space); the PGM monitor (输出预览) above 声学追踪 shows it meanwhile.
//
// A layer is chosen by pressing it, moved by dragging it (its edges snap to
// the picture's edges and middle and to the other layers'; laid nearly over
// the picture it takes it whole), sized by its handles (corners keep its shape,
// Shift frees them). A split line (+ 分割线) hides the layer above it, softened
// over a band whose width its handle sets: its ends are dragged, a press on a
// straight line pulls out its one bend (a press on a bent one only chooses
// it), with Shift (or the 折角 key) the bend is a corner; right-click for
// more. Delete takes the chosen bend (the line goes straight), the line or
// the layer (back to 预备, a camera too) away; the trash key takes the chosen line or
// all the layer's lines. Esc lets go. (The arrow keys stay the player's.)
//
//   sources:  [{ id, name, error }] the picture sources (the tracks, the
//             cameras; a camera's error is what is wrong with it, or "")
//   cameraIds the cameras taken in; addCamera(id) asks the host (a camera is let
//             go from 预备, Library)
//   textures: the window's SourceTextures
//   aspect:   the projected picture's width / height
//   entry:    the entry the picture shows (an audio-only one shows its title)
//   output:   the Desk, whose popovers the sound and output keys open
ColumnLayout {
    id: composer

    property var sources: []
    property SourceTextures textures: null
    property real aspect: 16 / 9
    property var entry: null
    property var output: null
    property var cameraIds: []
    signal addCamera(string id)
    // How wide the picture is drawn here at most: the sources' light copies are made this large.
    readonly property real pictureWidth: screen.fitWidth
    // Where the keys under the picture go (the timeline's top line), and
    // how far in from the board's left edge the picture starts.
    property Item keysHost: null
    readonly property real keysInset: screen.fitX
    // The view's size: 1 = the picture as large as the room allows; less,
    // drawn smaller about the middle of that room, so a layer
    // reaching past the picture is seen whole. Its bar is in the title bar
    // over the board's right end (`zoomHost`).
    property real zoom: 1
    readonly property real minZoom: 0.4
    property Item zoomHost: null
    function setZoom(z) {
        zoom = Math.max(minZoom, Math.min(1, Math.round(z * 100) / 100))
    }

    // The chosen layer (in Switcher.preview.slots), and on it a line and a point.
    property int selected: -1
    property int lineAt: -1
    property int point: -1
    // Pulls go straight, as with Shift held.
    property bool straight: false

    readonly property var slots: Switcher.preview && Switcher.preview.slots ? Switcher.preview.slots : []
    readonly property var slot: selected >= 0 && selected < slots.length ? slots[selected] : null
    readonly property var lines: slot ? slot.mask.lines : []
    readonly property var chosenLine: lineAt >= 0 && lineAt < lines.length ? lines[lineAt] : null
    onSlotsChanged: {
        if (selected >= slots.length)
            selected = -1
        if (!chosenLine) {
            lineAt = -1
            point = -1
        } else if (point >= chosenLine.points.length) {
            point = -1
        }
    }
    onSelectedChanged: {
        lineAt = -1
        point = -1
        if (selected >= 0)
            chosenSid = ""
    }

    spacing: Theme.gap

    function sourceName(id) {
        const s = (sources || []).find(s => s.id === id)
        return s ? s.name : id.startsWith("camera:") ? "相机（未连接）" : "画面 " + (Number(id.substring(6)) + 1)
    }
    function known(id) {
        return (sources || []).some(s => s.id === id)
    }
    // What is wrong with a source (a camera that cannot show), or "".
    function sourceError(id) {
        const s = (sources || []).find(s => s.id === id)
        return s && s.error ? s.error : ""
    }
    function ratio(id) {
        return textures ? textures.aspect(id) : 16 / 9
    }
    // Layer `i` chosen, and brought over every other: the one pressed last
    // is always on top.
    function choose(i) {
        if (i < 0 || i >= slots.length)
            return
        selected = i
        if (slots.some((s, k) => k !== i && s.z >= slots[i].z))
            Switcher.raiseSlot(i)
    }
    // The layer that shows `id`, chosen (a track's picture pressed on the timeline).
    function selectSource(id) {
        choose(slots.findIndex(s => s.source === id))
    }

    // Every source on the canvas: one newly there goes on the stack at the right.
    readonly property var sourceIds: (sources || []).map(s => s.id)
    onSourceIdsChanged: Qt.callLater(stackSources)
    Component.onCompleted: {
        try {
            gallery = JSON.parse(store.gallery)
        } catch (e) {
            gallery = []
        }
        Qt.callLater(stackSources)
    }
    // Once a run, those already waiting are parked anew (see Switcher.restack)
    // and cameras removed before are taken off.
    property bool restacked: false
    function stackSources() {
        if (!Switcher.loaded)
            return
        Switcher.stack(sourceIds, id => ratio(id), aspect)
        if (!restacked) {
            restacked = true
            // A camera no longer taken in is gone for good (a track may only
            // be loading): its layer goes.
            const gone = {}
            for (const s of Switcher.preview.slots.concat(Switcher.program.slots))
                if (s.source.startsWith("camera:") && sourceIds.indexOf(s.source) < 0)
                    gone[s.source] = ""
            if (Object.keys(gone).length)
                Switcher.rename(gone)
            Switcher.restack(id => ratio(id), aspect)
        }
    }

    // The sources off the picture, waiting in 预备 (Library): { source, index }.
    readonly property var waiting: slots.map((s, i) => ({ source: s.source, index: i }))
                                        .filter(o => !Switcher.inPicture(slots[o.index]))
    // A layer dragged from 预备: its source, and the pointer (composer
    // coordinates); dropLayer() lands it where the pointer is on the picture.
    property string layerCarried: ""
    property point layerAt
    onWaitingChanged: if (layerCarried && !waiting.some(o => o.source === layerCarried)) layerCarried = ""
    function dropLayer() {
        const id = layerCarried
        layerCarried = ""
        const i = slots.findIndex(s => s.source === id)
        const p = screen.mapFromItem(composer, layerAt.x, layerAt.y)
        if (i >= 0 && p.x >= 0 && p.y >= 0 && p.x <= screen.width && p.y <= screen.height)
            placeAt(i, p.x / screen.width, p.y / screen.height)
    }
    // Layer `i` onto the picture centred at (cx, cy) (picture shares), a
    // quarter wide in its own shape, chosen and on top: dropped from 预备.
    function placeAt(i, cx, cy) {
        if (i < 0 || i >= slots.length)
            return
        const id = slots[i].source
        const w = 0.4
        const h = Math.min(0.9, w * aspect / Math.max(0.1, ratio(id)))
        Switcher.updateSlot(i, { x: Math.max(-w / 2, Math.min(1 - w / 2, cx - w / 2)), y: Math.max(-h / 2, Math.min(1 - h / 2, cy - h / 2)), w: w, h: h })
        choose(i)
    }
    // Source `id` onto the picture, chosen and on top: one waiting off it
    // comes in at the lower right, a quarter wide, in its own shape.
    function bringIn(id) {
        const i = slots.findIndex(s => s.source === id)
        if (i < 0)
            return
        if (!Switcher.inPicture(slots[i])) {
            const w = 0.4
            const h = Math.min(0.9, w * aspect / Math.max(0.1, ratio(id)))
            Switcher.updateSlot(i, { x: 1 - w - 0.04, y: 1 - h - 0.05, w: w, h: h })
        }
        choose(i)
    }
    // The quick cut (a track's 投放): `id`'s layer floated to the top as it is
    // sized, on the air with the dissolve set here.
    function takeLive(id) {
        Qt.callLater(stackSources)
        Switcher.take(id, id => ratio(id), aspect)
    }
    // A track's 置顶: its layer floated to the top and chosen here, on the
    // board only (from 画外 it fills the picture); 投放 puts it on the air.
    function bringUp(id) {
        const i = slots.findIndex(s => s.source === id)
        if (i < 0)
            return
        if (!Switcher.inPicture(slots[i]))
            Switcher.updateSlot(i, { x: 0, y: 0, w: 1, h: 1, fit: "contain" })
        choose(i)
    }

    // —— Layer keys ——
    // Larger or smaller by `factor`, about its middle.
    function scaleLayer(i, factor) {
        if (i < 0 || i >= slots.length)
            return
        const s = slots[i]
        // Its shape kept, never below a fiftieth of the picture.
        const k = Math.max(factor, 0.02 / Math.min(s.w, s.h))
        const w = s.w * k, h = s.h * k
        Switcher.updateSlot(i, { x: s.x + (s.w - w) / 2, y: s.y + (s.h - h) / 2, w: w, h: h })
    }
    function fill(i) {
        Switcher.updateSlot(i, { x: 0, y: 0, w: 1, h: 1 })
    }
    // The layer resized to its picture's own shape, about its centre.
    function trueShape(i) {
        const s = slots[i]
        const want = ratio(s.source) / aspect
        const area = s.w * s.h
        const w = Math.sqrt(area * want), h = Math.sqrt(area / want)
        Switcher.updateSlot(i, { x: s.x + (s.w - w) / 2, y: s.y + (s.h - h) / 2, w: w, h: h })
    }
    function park(i) {
        if (i < 0 || i >= slots.length)
            return
        if (known(slots[i].source))
            Switcher.park(i, ratio(slots[i].source), aspect)
        else
            Switcher.removeSlot(i)
        selected = -1
    }
    function addLine() {
        if (!slot)
            return
        lineAt = Switcher.addLine(selected)
        point = -1
    }
    // The chosen line taken away, or else every line of the chosen layer.
    function removeLines() {
        if (!slot)
            return
        if (chosenLine)
            Switcher.removeLine(selected, lineAt)
        else
            Switcher.setMask(selected, { lines: [] })
        lineAt = -1
        point = -1
    }
    // A line's point between its ends, its bend (a line has one at most).
    readonly property bool bendChosen: !!chosenLine && chosenLine.points.length === 3 && point === 1
    // Takes away what is chosen: the line's bend (it goes straight), the
    // line, or the layer.
    function takeAway() {
        if (bendChosen) {
            const pts = chosenLine.points.slice()
            pts.splice(1, 1)
            Switcher.setLine(selected, lineAt, { points: pts })
            point = -1
        } else if (chosenLine) {
            Switcher.removeLine(selected, lineAt)
            lineAt = -1
            point = -1
        } else if (slot) {
            // Off the picture, into 预备 (a camera too: it is let go only from there).
            park(selected)
        }
    }

    // —— Stickers: images dropped on the picture, or kept in 画外 ——
    // The images waiting in 画外, kept between runs: { id, kind: "image" | "text", source, text, name }.
    property var gallery: []
    // How tall the next sticker is, as a share of the screen's height (the
    // size the last one was given).
    property real placeSize: 0.3
    // The sticker chosen on the canvas.
    property string chosenSid: ""
    onChosenSidChanged: if (chosenSid) selected = -1
    // An image from 画外 being dragged, and where the pointer is (composer coordinates).
    property var carrying: null
    property point carryPoint
    readonly property point carryOnScreen: screen.mapFromItem(composer, carryPoint.x, carryPoint.y)
    readonly property bool carryOver: {
        if (!carrying)
            return false
        const p = box.mapFromItem(composer, carryPoint.x, carryPoint.y)
        return p.x >= 0 && p.y >= 0 && p.x <= box.width && p.y <= box.height
    }
    // What the canvas shows of the stage, in shares of the picture.
    readonly property rect stageBounds: {
        const w = Math.max(1, screen.width)
        const h = Math.max(1, screen.height)
        return Qt.rect(-screen.x / w, -screen.y / h, box.width / w, box.height / h)
    }

    function setGallery(items) {
        gallery = items
        store.gallery = JSON.stringify(items)
    }
    // The images among `urls`, as stickers to post or keep.
    function imagesIn(urls) {
        const added = []
        for (let i = 0; i < urls.length; ++i) {
            const url = urls[i].toString()
            if (!/\.(png|jpe?g|gif|webp|svg|bmp)$/i.test(url))
                continue
            const name = decodeURIComponent(url.substring(url.lastIndexOf("/") + 1))
            added.push({ id: "g" + Date.now() + "_" + i, kind: "image", source: url, name: name })
        }
        return added
    }
    function addImages(urls) {
        const added = imagesIn(urls)
        if (added.length)
            setGallery(gallery.concat(added))
        return added
    }
    function forget(id) {
        setGallery(gallery.filter(g => g.id !== id))
    }
    // Posts `item` centred at (px, py) of the picture, at the next size.
    function postAt(item, px, py) {
        const b = stageBounds
        chosenSid = Live.post({ kind: item.kind, source: item.source, text: item.text, name: item.name,
                                px: Math.max(b.x, Math.min(b.x + b.width, px)),
                                py: Math.max(b.y, Math.min(b.y + b.height, py)), size: placeSize })
    }
    function letGo() {
        if (carrying && carryOver)
            postAt(carrying, carryOnScreen.x / screen.width, carryOnScreen.y / screen.height)
        carrying = null
    }

    Settings {
        id: store
        category: "desk"
        property string gallery: "[]"
        property alias size: composer.placeSize
        property alias zoom: composer.zoom
        property alias toolsAt: composer.toolsAt
    }
    // Where the chosen layer's keys sit on the board: their middle, as shares
    // of the board's width and height ("" until moved: over the picture's foot).
    property string toolsAt: ""
    readonly property Item focusItem: Window.activeFocusItem
    readonly property bool typing: !!focusItem && typeof focusItem.selectedText === "string"
    // The chosen sticker comes down with Delete, unless words are being typed.
    Shortcut {
        sequences: [StandardKey.Delete, "Backspace"]
        // From the projection window too, which takes the focus when it opens.
        context: Qt.ApplicationShortcut
        enabled: composer.chosenSid !== "" && !composer.typing
        onActivated: {
            Live.unpost(composer.chosenSid)
            composer.chosenSid = ""
        }
    }
    // The chosen layer (or its line) with Delete / Backspace, wherever the
    // keys are: a camera is let go, a track goes off the picture.
    Shortcut {
        sequences: [StandardKey.Delete, "Backspace"]
        context: Qt.ApplicationShortcut
        enabled: composer.chosenSid === "" && composer.selected >= 0 && !composer.typing
        onActivated: composer.takeAway()
    }
    // Esc lets the chosen sticker or layer go.
    Shortcut {
        sequence: "Esc"
        enabled: composer.chosenSid !== "" || composer.selected >= 0
        onActivated: {
            composer.chosenSid = ""
            composer.selected = -1
        }
    }

    // ⌘Z (Ctrl+Z elsewhere) is 撤回: the board back as the audience sees it,
    // never while words are typed.
    Shortcut {
        sequences: [StandardKey.Undo]
        context: Qt.ApplicationShortcut
        enabled: !Switcher.follow && Switcher.pending && !composer.typing
        onActivated: Switcher.revert()
    }
    // Space puts the board on the air (投放), never while words are typed;
    // Enter stays the timeline's.
    Shortcut {
        sequence: "Space"
        context: Qt.ApplicationShortcut
        enabled: !Switcher.follow && Switcher.pending && !composer.typing
        onActivated: Switcher.apply()
    }

    // —— The canvas ——
    Rectangle {
        id: box
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: 120
        color: Theme.bg
        clip: true

        // The picture, in the middle of the board with a small margin round
        // it (`room`), enough to reach a split line's point on its edge. The
        // keys that put it on the air are on the timeline's top line
        // (keysHost). Zoomed out, it shrinks about its middle.
        Rectangle {
            id: screen
            readonly property real room: 16
            readonly property real fitWidth: Math.max(1, Math.min(box.width - 2 * room, (box.height - 2 * room) * composer.aspect))
            readonly property real fitHeight: fitWidth / Math.max(0.2, composer.aspect)
            // Where it is at full size: in the middle of the board above the
            // keys' strip, both ways.
            readonly property real fitX: (box.width - fitWidth) / 2
            readonly property real fitY: (box.height - fitHeight) / 2
            width: fitWidth * composer.zoom
            height: width / Math.max(0.2, composer.aspect)
            x: (box.width - width) / 2
            y: fitY + fitHeight * (1 - composer.zoom) / 2
            color: "black"
        }
        // A layer being dragged in from 预备 (Library), as large as it will
        // land, while the pointer is over the board.
        Rectangle {
            readonly property point at: box.mapFromItem(composer, composer.layerAt.x, composer.layerAt.y)
            visible: composer.layerCarried !== "" && at.x >= 0 && at.y >= 0 && at.x <= box.width && at.y <= box.height
            z: 9
            readonly property real w: screen.width * 0.4
            width: w
            height: Math.min(screen.height * 0.9, w / Math.max(0.1, composer.ratio(composer.layerCarried)))
            x: at.x - width / 2
            y: at.y - height / 2
            radius: Theme.radius
            color: "#33ffffff"
            border.width: 1.5
            border.color: "#ffffff"
        }
        // The picture itself as the audience will see it: the layers inside
        // it through the effects, with the words and reactions on the air.
        // (The stickers waiting here are drawn over it, with their handles.)
        Stage {
            id: board
            x: screen.x
            y: screen.y
            width: screen.width
            height: screen.height
            lite: true
            entry: composer.entry
            showStickers: false
            Rectangle {
                anchors.fill: parent
                color: "black"
            }
            Compositor {
                anchors.fill: parent
                clip: true
                layout: Switcher.preview
                textures: composer.textures
                operator: true
            }
            // A quick cut (a track's 投放, [ / ]) dissolves here as on the
            // air: the layout before, fading out over the new one.
            Item {
                id: taking
                readonly property var t: Switcher.transition
                readonly property bool on: !!t && !!t.take && board.now < t.born + t.ms
                anchors.fill: parent
                visible: on
                opacity: on ? 1 - Math.max(0, Math.min(1, (board.now - t.born) / Math.max(1, t.ms))) : 0
                layer.enabled: visible
                Rectangle {
                    anchors.fill: parent
                    color: "black"
                }
                Compositor {
                    anchors.fill: parent
                    clip: true
                    layout: taking.on ? taking.t.from : null
                    textures: composer.textures
                    operator: true
                }
            }
        }
        // —— The view's size: − bar +, 复原 ——
        // In the title bar (zoomHost), its right end over the picture's.
        Row {
            parent: composer.zoomHost
            visible: !!parent
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined
            x: {
                const h = composer.zoomHost
                if (!h)
                    return 0
                // What moves it: the board's place and size, the window's.
                composer.x; composer.width; h.width
                return box.mapToItem(h, screen.fitX + screen.fitWidth, 0).x - width
            }
            spacing: 2
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 22
                implicitHeight: 22
                iconSize: 12
                iconName: "minus"
                tip: "画板缩小（画面和画外一起）"
                autoRepeat: true
                enabled: composer.zoom > composer.minZoom + 1e-6
                onClicked: composer.setZoom(composer.zoom - 0.05)
            }
            Seek {
                anchors.verticalCenter: parent.verticalCenter
                width: 80
                implicitHeight: 22
                from: composer.minZoom
                to: 1
                value: composer.zoom
                onMoved: composer.setZoom(value)
                ToolTip.visible: hovered && !pressed
                ToolTip.delay: 600
                ToolTip.text: "画板大小：缩小后伸出画面的部分也看得到（双击复原）"
                TapHandler {
                    onDoubleTapped: composer.setZoom(1)
                }
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 22
                implicitHeight: 22
                iconSize: 12
                iconName: "plus"
                tip: "画板放大"
                autoRepeat: true
                enabled: composer.zoom < 1 - 1e-6
                onClicked: composer.setZoom(composer.zoom + 0.05)
            }
            TextButton {
                anchors.verticalCenter: parent.verticalCenter
                flat: true
                implicitHeight: 22
                leftPadding: 6
                rightPadding: 6
                font.pixelSize: Theme.sizeXs
                text: "复原"
                enabled: composer.zoom < 1 - 1e-6
                onClicked: composer.setZoom(1)
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "画板回到铺满的大小"
            }
        }

        // —— The mode, and the keys that put it on the air, then + 相机 ——
        // Shown by the host on the timeline's top line (`keys`), as wide as
        // the picture, + 相机 and 文字 past it.
        RowLayout {
            id: airRow
            parent: composer.keysHost
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined
            // As wide as the picture, + 相机 past it; narrower (down to the
            // keys' own widths) when the line is short of room.
            readonly property real wanted: screen.fitWidth + 12 + cameraKey.implicitWidth + wordsKey.implicitWidth + 8
            width: parent ? parent.width : wanted
            spacing: 8
            // 跟随 or 投放, a segmented key: the mode shown in ink on a plate.
            Rectangle {
                implicitWidth: modes.implicitWidth + 4
                implicitHeight: Theme.control
                radius: Theme.radius
                color: Theme.inset
                Row {
                    id: modes
                    anchors.centerIn: parent
                    spacing: 2
                    Repeater {
                        model: [{ text: "跟随", follow: true, tip: "跟随：在这里的每一下改动，观众立刻看到" },
                                { text: "投放", follow: false, tip: "投放：观众一直看上一次投放的画面，在这里改好后按「投放」才换" }]
                        Rectangle {
                            required property var modelData
                            readonly property bool on: Switcher.follow === modelData.follow
                            width: modeText.implicitWidth + 20
                            height: Theme.control - 4
                            radius: Theme.radius - 1
                            color: on ? Theme.raised : modeMouse.containsMouse ? Theme.hover : "transparent"
                            border.width: on && Theme.dark ? 1 : 0
                            border.color: Theme.line
                            Text {
                                id: modeText
                                anchors.centerIn: parent
                                text: parent.modelData.text
                                font.pixelSize: Theme.sizeSm
                                font.weight: parent.on ? Font.DemiBold : Font.Medium
                                color: parent.on ? Theme.text : Theme.muted
                            }
                            MouseArea {
                                id: modeMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Switcher.follow = parent.modelData.follow
                                ToolTip.visible: containsMouse
                                ToolTip.delay: 600
                                ToolTip.text: parent.modelData.tip
                            }
                        }
                    }
                }
            }
            IconButton {
                iconName: "undo-2"
                tip: "撤回：画板回到观众正在看的样子（" + (Qt.platform.os === "osx" ? "⌘Z" : "Ctrl+Z") + "）"
                // Kept in 跟随 too (there is nothing to take back), so the row stays put.
                enabled: !Switcher.follow && Switcher.pending
                onClicked: Switcher.revert()
            }
            Item { Layout.fillWidth: true }
            // The dissolve: on or off, and how long, a click each.
            Toggle {
                text: "渐变"
                checked: Switcher.fadeMs > 0
                onToggled: Switcher.fadeMs = checked ? Switcher.fadeLength : 0
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: Switcher.follow ? "轨道上的「投放」快切用这个渐变；跟随模式下画板上的改动仍是直接切"
                                              : "投放（空格）和轨道上的「投放」快切用这个渐变"
            }
            TextButton {
                readonly property var values: [300, 600, 1000, 2000]
                flat: true
                leftPadding: 6
                rightPadding: 6
                // Always there (greyed while off), so nothing beside it moves.
                enabled: Switcher.fadeMs > 0
                text: (Switcher.fadeLength / 1000) + " 秒"
                widest: "0.3 秒"
                font.features: { "tnum": 1 }
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "渐变时长，点一下换一档"
                onClicked: {
                    const next = values[(values.indexOf(Switcher.fadeLength) + 1) % values.length]
                    Switcher.fadeLength = next
                    Switcher.fadeMs = next
                }
            }
            // The picture's own sound: the key (an icon only) turns it on or
            // off; the small key beside it opens what on plays (顶层声音, 画面 1,
            // 画面 2, how loud, where) in a popover.
            RowLayout {
                spacing: -1
                TextButton {
                    id: soundKey
                    readonly property var out: composer.output
                    outlined: true
                    iconName: out && out.anySound ? "volume-2" : "volume-x"
                    display: AbstractButton.IconOnly
                    icon.width: 16
                    icon.height: 16
                    implicitWidth: Theme.control
                    leftPadding: 0
                    rightPadding: 0
                    // What plays, said only in its tooltip.
                    readonly property string playing: !out || !out.soundLive ? ""
                          : out.topOnly ? "顶层声音"
                          // On, but 单轨 shows a track not chosen: nothing plays.
                          : !out.anySound ? "这条轨道没选"
                          : out.solo >= 0 ? "画面 " + (out.solo + 1) + " · " + Math.round((out.solo === 1 ? out.soundVolume2 : out.soundVolume) * 100) + "%"
                          : out.hears1 && out.hears2 ? "画面 1+2"
                          : out.hears1 ? "画面 1 · " + Math.round(out.soundVolume * 100) + "%"
                          : "画面 2 · " + Math.round(out.soundVolume2 * 100) + "%"
                    onClicked: out.soundLive = !out.soundLive
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: out && out.soundLive ? "声音开：" + playing + "（点一下关）"
                                                       : "声音关（点一下开，播放什么在右边的小键里选）"
                    Rectangle {
                        visible: !!soundKey.out && soundKey.out.soundError.length > 0
                        x: parent.width - 9
                        y: 3
                        width: 7
                        height: 7
                        radius: 3.5
                        color: Theme.warn
                    }
                }
                TextButton {
                    id: soundMore
                    outlined: true
                    iconName: "chevron-down"
                    display: AbstractButton.IconOnly
                    icon.width: 12
                    icon.height: 12
                    implicitWidth: 22
                    leftPadding: 0
                    rightPadding: 0
                    onClicked: soundKey.out.openSound(soundKey)
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "开声音时播放什么：顶层声音，或画面 1、画面 2（可同时开）、各自音量，输出设备"
                }
            }
            // The output: where it goes and the key that projects, in a popover;
            // red while the picture is out.
            TextButton {
                id: outputKey
                readonly property bool out: !!composer.output && !!composer.output.projection && composer.output.projection.visible
                outlined: true
                iconName: "monitor"
                text: out ? "投屏中" : "投屏"
                widest: "投屏中"
                leftPadding: 8
                rightPadding: 10
                onClicked: composer.output.openOutput(outputKey)
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "投屏：屏幕、清晰度、帧率、全屏、画面声音，打开或收起投屏"
                icon.color: out ? Theme.danger : contentColor
                font.weight: out ? Font.DemiBold : Font.Medium
            }
            // Changes waiting to go on the air light a dot on the key, so
            // nothing beside it moves.
            TextButton {
                primary: true
                iconName: "cast"
                text: "投放"
                // Kept in 跟随 too (every change is on the air already), so the keys stay put.
                enabled: !Switcher.follow && Switcher.pending
                onClicked: Switcher.apply()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: (Switcher.pending ? "有未投放的改动。" : "")
                              + "把画板上的画面和贴图给观众（空格）"
                Rectangle {
                    visible: !Switcher.follow && Switcher.pending
                    x: parent.width - 6
                    y: -2
                    width: 8
                    height: 8
                    radius: 4
                    color: Theme.warn
                    border.width: 1.5
                    border.color: Theme.bg
                }
            }
            // A camera taken in comes onto the picture, at its lower right. Listed only while the menu is open (listing wakes
            // the camera stack).
            TextButton {
                id: cameraKey
                Layout.leftMargin: 4
                flat: true
                iconName: "plus"
                text: "相机"
                leftPadding: 6
                rightPadding: 8
                onClicked: cameraMenu.popup(cameraKey, 0, cameraKey.height + 2)
                ToolTip.visible: hovered && !cameraMenu.visible
                ToolTip.delay: 600
                ToolTip.text: "加一个相机画面，放在画面右下角"
            }
            // Words for the audience: danmaku, words in the middle, a text
            // sticker; in a popover from its key.
            TextButton {
                id: wordsKey
                flat: !wordsPop.visible
                iconName: "message-square"
                text: "文字"
                leftPadding: 6
                rightPadding: 8
                onClicked: wordsPop.visible ? wordsPop.close() : wordsPop.open()
                ToolTip.visible: hovered && !wordsPop.visible
                ToolTip.delay: 600
                ToolTip.text: "弹幕、居中文字、文字贴图"
                Popup {
                    id: wordsPop
                    y: -height - 6
                    width: 300
                    padding: 12
                    margins: 8
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                    onOpened: words.focusField()
                    background: Rectangle {
                        radius: Theme.radiusLg
                        color: Theme.raised
                        border.width: 1
                        border.color: Theme.line
                    }
                    contentItem: Words {
                        id: words
                        composer: composer
                    }
                }
            }
        }

        // Presses, drags and the wheel on layers and lines.
        MouseArea {
            id: hand
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            focus: true
            // What a press caught: "", "move", "size", "point", "blend".
            property string mode: ""
            property real hx: 0
            property real hy: 0
            property point from
            property var start: null
            // Snap guides while dragging, in picture shares (NaN: none).
            property real guideX: NaN
            property real guideY: NaN

            readonly property real pw: screen.width
            readonly property real ph: screen.height
            function rectOf(s) {
                return Qt.rect(screen.x + s.x * pw, screen.y + s.y * ph, s.w * pw, s.h * ph)
            }
            function toBox(r, p) {
                return Qt.point(r.x + p[0] * r.width, r.y + p[1] * r.height)
            }
            // The line's course in box pixels.
            function coursePx(s, l) {
                const r = rectOf(s)
                return Switcher.course(l, 16).map(p => toBox(r, p))
            }
            // Where the band handle of line `l` of `s` sits: off the middle of its
            // course, along its hidden side's normal, half the band away.
            function bandHandle(s, l) {
                const c = coursePx(s, l)
                if (c.length < 2)
                    return null
                const m = Math.floor(c.length / 2)
                const a = c[Math.max(0, m - 1)], b = c[Math.min(c.length - 1, m + 1)]
                const len = Math.max(1e-6, Math.hypot(b.x - a.x, b.y - a.y))
                let nx = (b.y - a.y) / len, ny = -(b.x - a.x) / len
                if (l.flip)
                    nx = -nx, ny = -ny
                const r = rectOf(s)
                const reach = Math.max(10, s.mask.blend * Math.min(r.width, r.height) / 2)
                return { at: c[m], x: c[m].x + nx * reach, y: c[m].y + ny * reach, nx: nx, ny: ny }
            }
            function near(ax, ay, x, y, d) {
                return Math.abs(ax - x) <= d && Math.abs(ay - y) <= d
            }
            // Distance from (x, y) to the course; { d, piece (the point before it) }.
            function onCourse(s, l, x, y) {
                const c = coursePx(s, l)
                const n = l.points.length
                const per = 16
                let best = { d: Infinity, piece: 0 }
                for (let i = 0; i + 1 < c.length; ++i) {
                    const a = c[i], b = c[i + 1]
                    const len = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)
                    const t = len > 0 ? Math.max(0, Math.min(1, ((x - a.x) * (b.x - a.x) + (y - a.y) * (b.y - a.y)) / len)) : 0
                    const d = Math.hypot(x - (a.x + t * (b.x - a.x)), y - (a.y + t * (b.y - a.y)))
                    if (d < best.d)
                        best = { d: d, piece: Math.min(l.closed ? n - 1 : n - 2, Math.floor(i / per)) }
                }
                return best
            }
            // What lies under (x, y).
            function hit(x, y) {
                const s = composer.slot
                if (s) {
                    const r = rectOf(s)
                    const ls = s.mask.lines
                    const order = ls.map((l, k) => k).sort((a, b) => (b === composer.lineAt) - (a === composer.lineAt))
                    for (const k of order)
                        for (let j = ls[k].points.length - 1; j >= 0; --j) {
                            const p = toBox(r, ls[k].points[j])
                            if (near(p.x, p.y, x, y, 7))
                                return { mode: "point", line: k, point: j }
                        }
                    if (composer.chosenLine) {
                        const h = bandHandle(s, composer.chosenLine)
                        if (h && near(h.x, h.y, x, y, 7))
                            return { mode: "blend", line: composer.lineAt }
                    }
                    for (const hy of [0, 0.5, 1])
                        for (const hx of [0, 0.5, 1])
                            if (!(hx === 0.5 && hy === 0.5) && near(r.x + hx * r.width, r.y + hy * r.height, x, y, 6))
                                return { mode: "size", hx: hx, hy: hy }
                    for (const k of order) {
                        const o = onCourse(s, ls[k], x, y)
                        if (o.d <= 5)
                            return { mode: "bend", line: k, piece: o.piece }
                    }
                }
                // Only what is on the picture: those off it wait in 预备.
                const order = composer.slots.map((s, i) => i).filter(i => Switcher.inPicture(composer.slots[i]))
                                            .sort((a, b) => (composer.slots[b].z - composer.slots[a].z) || (b - a))
                for (const i of order) {
                    const r = rectOf(composer.slots[i])
                    if (x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height)
                        return { mode: "move", index: i }
                }
                return { mode: "" }
            }

            // Snapping: the picture's edges and middle pull from further than
            // another layer's edges and middle.
            function targets(axis, skip) {
                const out = [{ v: 0, reach: 10 }, { v: 0.5, reach: 10 }, { v: 1, reach: 10 }]
                composer.slots.forEach((s, i) => {
                    if (i === skip)
                        return
                    const a = axis === "x" ? s.x : s.y, len = axis === "x" ? s.w : s.h
                    out.push({ v: a, reach: 6 }, { v: a + len / 2, reach: 6 }, { v: a + len, reach: 6 })
                })
                return out
            }
            // The offset that brings one of `edges` onto a target, and the target.
            function pull(edges, axis, span) {
                let best = { d: 0, at: NaN, gap: Infinity }
                for (const t of targets(axis, composer.selected))
                    for (const e of edges) {
                        const gap = Math.abs(t.v - e) * span
                        if (gap <= t.reach && gap < best.gap)
                            best = { d: t.v - e, at: t.v, gap: gap }
                    }
                return best
            }

            cursorShape: {
                if (pressed && mode === "move")
                    return Qt.ClosedHandCursor
                const h = containsMouse ? hit(mouseX, mouseY) : { mode: "" }
                return h.mode === "point" || h.mode === "blend" ? Qt.PointingHandCursor
                     : h.mode === "bend" ? Qt.CrossCursor
                     : h.mode === "size" ? (h.hx === 0.5 ? Qt.SizeVerCursor : h.hy === 0.5 ? Qt.SizeHorCursor
                                            : (h.hx === h.hy ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor))
                     : h.mode === "move" ? Qt.OpenHandCursor : Qt.ArrowCursor
            }

            onPressed: mouse => {
                forceActiveFocus()
                composer.chosenSid = ""
                const h = hit(mouse.x, mouse.y)
                if (mouse.button === Qt.RightButton) {
                    mode = ""
                    if (h.mode === "point" || h.mode === "bend") {
                        composer.lineAt = h.line
                        composer.point = h.mode === "point" ? h.point : -1
                        lineMenu.popup()
                    } else if (h.mode === "move" || h.mode === "size") {
                        if (h.mode === "move")
                            composer.choose(h.index)
                        layerMenu.popup()
                    }
                    return
                }
                mode = h.mode
                if (h.mode === "move") {
                    if (composer.selected === h.index)
                        composer.lineAt = -1
                    composer.choose(h.index)
                } else if (h.mode === "point") {
                    composer.lineAt = h.line
                    composer.point = h.point
                } else if (h.mode === "bend") {
                    // A straight line gets its bend where it was pressed,
                    // pulled from there; one that has it is only chosen.
                    const l = composer.lines[h.line]
                    composer.lineAt = h.line
                    if (l.points.length >= 3) {
                        composer.point = -1
                        mode = ""
                    } else {
                        const r = rectOf(composer.slot)
                        const pts = l.points.slice()
                        const sharp = (mouse.modifiers & Qt.ShiftModifier) || composer.straight ? 1 : 0
                        pts.splice(1, 0, [(mouse.x - r.x) / Math.max(1, r.width), (mouse.y - r.y) / Math.max(1, r.height), sharp])
                        Switcher.setLine(composer.selected, h.line, { points: pts })
                        composer.point = 1
                        mode = "point"
                    }
                } else if (h.mode === "blend") {
                    composer.lineAt = h.line
                } else if (h.mode === "") {
                    composer.selected = -1
                }
                hx = h.hx || 0
                hy = h.hy || 0
                from = Qt.point(mouse.x, mouse.y)
                start = composer.slot ? JSON.parse(JSON.stringify(composer.slot)) : null
            }
            onReleased: {
                // Laid nearly over the picture, a layer takes it whole.
                if (mode === "move" && composer.slot) {
                    const s = composer.slot
                    const close = 0.04
                    if (Math.abs(s.x) < close && Math.abs(s.y) < close && Math.abs(s.x + s.w - 1) < close && Math.abs(s.y + s.h - 1) < close)
                        composer.fill(composer.selected)
                }
                mode = ""
                guideX = NaN
                guideY = NaN
            }
            onPositionChanged: mouse => {
                if (!pressed || !start || mode === "")
                    return
                const dx = (mouse.x - from.x) / pw
                const dy = (mouse.y - from.y) / ph
                if (mode === "move") {
                    let x = start.x + dx, y = start.y + dy
                    const sx = pull([x, x + start.w / 2, x + start.w], "x", pw)
                    const sy = pull([y, y + start.h / 2, y + start.h], "y", ph)
                    guideX = sx.at
                    guideY = sy.at
                    Switcher.updateSlot(composer.selected, { x: x + sx.d, y: y + sy.d })
                } else if (mode === "size") {
                    const min = 0.03
                    let x0 = start.x, y0 = start.y, x1 = start.x + start.w, y1 = start.y + start.h
                    if (hx === 0) x0 = Math.min(x1 - min, x0 + dx)
                    if (hx === 1) x1 = Math.max(x0 + min, x1 + dx)
                    if (hy === 0) y0 = Math.min(y1 - min, y0 + dy)
                    if (hy === 1) y1 = Math.max(y0 + min, y1 + dy)
                    guideX = NaN
                    guideY = NaN
                    const corner = hx !== 0.5 && hy !== 0.5
                    if (corner && !(mouse.modifiers & Qt.ShiftModifier)) {
                        // Its shape kept: the height follows the width.
                        const h = (x1 - x0) * start.h / start.w
                        if (hy === 0) y0 = y1 - h
                        else y1 = y0 + h
                    } else {
                        if (hx === 0) { const s = pull([x0], "x", pw); x0 += s.d; guideX = s.at }
                        if (hx === 1) { const s = pull([x1], "x", pw); x1 += s.d; guideX = s.at }
                        if (hy === 0) { const s = pull([y0], "y", ph); y0 += s.d; guideY = s.at }
                        if (hy === 1) { const s = pull([y1], "y", ph); y1 += s.d; guideY = s.at }
                    }
                    Switcher.updateSlot(composer.selected, { x: x0, y: y0, w: Math.max(min, x1 - x0), h: Math.max(min, y1 - y0) })
                } else if (mode === "point" && composer.chosenLine && composer.point >= 0) {
                    const r = rectOf(start)
                    const pts = composer.chosenLine.points.slice()
                    const was = pts[composer.point]
                    const sharp = (mouse.modifiers & Qt.ShiftModifier) || composer.straight ? 1 : was[2]
                    pts[composer.point] = [(mouse.x - r.x) / Math.max(1, r.width), (mouse.y - r.y) / Math.max(1, r.height), sharp]
                    Switcher.setLine(composer.selected, composer.lineAt, { points: pts })
                } else if (mode === "blend" && composer.chosenLine) {
                    const h = bandHandle(composer.slot, composer.chosenLine)
                    if (!h)
                        return
                    const r = rectOf(composer.slot)
                    const reach = Math.max(0, (mouse.x - h.at.x) * h.nx + (mouse.y - h.at.y) * h.ny)
                    Switcher.setMask(composer.selected, { blend: Math.min(1, 2 * reach / Math.max(1, Math.min(r.width, r.height))) })
                }
            }
            onDoubleClicked: mouse => {
                // A double-click on a layer without lines brings it into the
                // picture whole, or back to where it was.
                const h = hit(mouse.x, mouse.y)
                if (h.mode === "move" && composer.slot && composer.slot.mask.lines.length === 0) {
                    const s = composer.slot
                    if (s.x === 0 && s.y === 0 && s.w === 1 && s.h === 1)
                        composer.trueShape(composer.selected)
                    else
                        composer.fill(composer.selected)
                }
            }
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                    composer.takeAway()
                    event.accepted = true
                    return
                }
            }
        }

        // —— Over the layers: their edges, the chosen one's handles and lines ——
        // Only the chosen layer's frame and handles reach past the picture
        // (what is there is still grabbed); the other layers' edges and the
        // split lines stop at its edge.
        Item {
            id: ink
            anchors.fill: parent

            Item {
                id: lineClip
                x: screen.x
                y: screen.y
                width: screen.width
                height: screen.height
                clip: true
                z: 3
            }

            Repeater {
                model: composer.slots.length
                Item {
                    id: edge
                    required property int index
                    readonly property var s: composer.slots[index]
                    readonly property bool chosen: index === composer.selected
                    readonly property bool lost: !composer.known(s.source)
                    visible: Switcher.inPicture(s)
                    x: screen.x + s.x * screen.width
                    y: screen.y + s.y * screen.height
                    width: s.w * screen.width
                    height: s.h * screen.height
                    z: chosen ? 2 : 1
                    // Another layer's edge and name stop at the picture's edge.
                    Item {
                        id: cut
                        clip: !edge.chosen
                        x: edge.chosen ? 0 : screen.x - edge.x
                        y: edge.chosen ? 0 : screen.y - edge.y
                        width: edge.chosen ? edge.width : screen.width
                        height: edge.chosen ? edge.height : screen.height
                        Item {
                            x: -cut.x
                            y: -cut.y
                            width: edge.width
                            height: edge.height
                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"
                                border.width: edge.chosen ? 1.5 : 1
                                border.color: edge.chosen ? "#ffffff" : "#40ffffff"
                            }
                            // The chosen one's frame also in ink just outside: where
                            // it reaches past the picture (onto the light ground) its
                            // edge and handles still read as its own.
                            Rectangle {
                                visible: edge.chosen
                                anchors.fill: parent
                                anchors.margins: -1.5
                                color: "transparent"
                                border.width: 1
                                border.color: Theme.dark ? "#c3c8d0" : "#55555c"
                            }
                            // A camera that cannot show says why, plainly, in its middle.
                            Rectangle {
                                id: whyPlate
                                readonly property string why: composer.sourceError(edge.s.source)
                                visible: why !== "" && edge.width > 40 && edge.height > 24
                                anchors.centerIn: parent
                                width: Math.min(parent.width - 8, whyText.implicitWidth + 28)
                                height: 20
                                radius: 4
                                color: "#000000"
                                Row {
                                    x: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4
                                    ColorImage {
                                        anchors.verticalCenter: parent.verticalCenter
                                        source: "icons/camera-off.svg"
                                        sourceSize: Qt.size(12, 12)
                                        color: "#ffffff"
                                    }
                                    Text {
                                        id: whyText
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.max(0, whyPlate.width - 28)
                                        text: whyPlate.why
                                        font.pixelSize: 10
                                        font.weight: Font.DemiBold
                                        color: "#ffffff"
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                            // Its name, on a plate at its top left, while chosen.
                            Rectangle {
                                x: 4
                                y: 4
                                width: label.implicitWidth + 10
                                height: 16
                                radius: 4
                                visible: edge.chosen && edge.width > 40 && edge.height > 24
                                color: "#ffffff"
                                Text {
                                    id: label
                                    anchors.centerIn: parent
                                    text: composer.sourceName(edge.s.source) + (edge.lost ? " · 已移除" : "")
                                    font.pixelSize: 10
                                    font.weight: Font.DemiBold
                                    color: "#000000"
                                }
                            }
                            // Corners and edge middles size it.
                            Repeater {
                                model: edge.chosen ? [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]] : []
                                Rectangle {
                                    required property var modelData
                                    readonly property bool side: modelData[0] === 0.5 || modelData[1] === 0.5
                                    width: side ? (modelData[0] === 0.5 ? 14 : 5) : 8
                                    height: side ? (modelData[1] === 0.5 ? 14 : 5) : 8
                                    x: modelData[0] * edge.width - width / 2
                                    y: modelData[1] * edge.height - height / 2
                                    radius: side ? 2.5 : 2
                                    color: "#ffffff"
                                    border.width: 1
                                    border.color: "#000000"
                                }
                            }
                        }
                    }
                }
            }

            // The chosen layer's split lines: the course, faint past its ends
            // (it goes on straight), the soft band of the chosen one, its points.
            Item {
                id: lineBox
                parent: lineClip
                readonly property var s: composer.slot
                visible: !!s && s.mask.lines.length > 0
                x: s ? s.x * screen.width : 0
                y: s ? s.y * screen.height : 0
                width: s ? s.w * screen.width : 0
                height: s ? s.h * screen.height : 0
                clip: true
                function px(p) {
                    return Qt.point(p[0] * width, p[1] * height)
                }
                Repeater {
                    model: lineBox.s ? lineBox.s.mask.lines : []
                    Item {
                        id: drawn
                        required property var modelData
                        required property int index
                        readonly property bool chosen: index === composer.lineAt
                        readonly property var course: Switcher.course(modelData, 16).map(p => lineBox.px(p))
                        // The course pushed `d` pixels along its normal.
                        function offset(d) {
                            const c = course
                            const out = []
                            for (let i = 0; i < c.length; ++i) {
                                const a = c[Math.max(0, i - 1)], b = c[Math.min(c.length - 1, i + 1)]
                                const len = Math.max(1e-6, Math.hypot(b.x - a.x, b.y - a.y))
                                out.push(Qt.point(c[i].x + (b.y - a.y) / len * d, c[i].y - (b.x - a.x) / len * d))
                            }
                            return out
                        }
                        readonly property real band: lineBox.s ? lineBox.s.mask.blend * Math.min(lineBox.width, lineBox.height) / 2 : 0
                        anchors.fill: parent
                        // The guides (past the ends, the band) plain and off the
                        // main thread: dashes are many pieces.
                        Shape {
                            anchors.fill: parent
                            asynchronous: true
                            // Past the ends.
                            ShapePath {
                                strokeColor: "#80ffffff"
                                strokeWidth: 1
                                strokeStyle: ShapePath.DashLine
                                dashPattern: [3, 3]
                                fillColor: "transparent"
                                PathMultiline {
                                    paths: {
                                        const c = drawn.course
                                        if (drawn.modelData.closed || c.length < 2)
                                            return []
                                        // Far enough to leave the layer, no further.
                                        const far = 2 * Math.hypot(lineBox.width, lineBox.height)
                                        const ext = (p, q) => {
                                            const len = Math.max(1e-6, Math.hypot(p.x - q.x, p.y - q.y))
                                            return [p, Qt.point(p.x + (p.x - q.x) / len * far, p.y + (p.y - q.y) / len * far)]
                                        }
                                        return [ext(c[0], c[1]), ext(c[c.length - 1], c[c.length - 2])]
                                    }
                                }
                            }
                            // The soft band's edges.
                            ShapePath {
                                strokeColor: drawn.chosen && drawn.band > 1 ? "#66ffffff" : "transparent"
                                strokeWidth: 1
                                fillColor: "transparent"
                                PathMultiline {
                                    paths: drawn.chosen && drawn.band > 1 ? [drawn.offset(drawn.band), drawn.offset(-drawn.band)] : []
                                }
                            }
                        }
                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            // The line, dark under light so it reads on any picture.
                            ShapePath {
                                strokeColor: "#99000000"
                                strokeWidth: 3.5
                                fillColor: "transparent"
                                PathPolyline { path: drawn.course }
                            }
                            ShapePath {
                                strokeColor: drawn.chosen ? "#ffffff" : "#ccffffff"
                                strokeWidth: drawn.chosen ? 1.75 : 1.25
                                fillColor: "transparent"
                                PathPolyline { path: drawn.course }
                            }
                        }
                    }
                }
            }
            // Points and the band's handle, outside the clip so ends at the
            // layer's edge stay whole.
            Repeater {
                model: composer.slot ? composer.slot.mask.lines : []
                Item {
                    id: dots
                    required property var modelData
                    required property int index
                    readonly property bool chosen: index === composer.lineAt
                    z: 4
                    Repeater {
                        model: dots.modelData.points
                        Rectangle {
                            required property var modelData
                            required property int index
                            readonly property bool picked: dots.chosen && index === composer.point
                            readonly property bool sharp: modelData[2] === 1
                            readonly property point at: hand.toBox(hand.rectOf(composer.slot), modelData)
                            width: picked ? 12 : 10
                            height: width
                            x: at.x - width / 2
                            y: at.y - height / 2
                            // Square where it goes straight, round where it curves.
                            radius: sharp ? 2 : width / 2
                            rotation: sharp ? 45 : 0
                            color: picked ? "#ffffff" : "#000000"
                            border.width: 1.5
                            border.color: "#ffffff"
                        }
                    }
                }
            }
            Rectangle {
                readonly property var h: composer.chosenLine ? hand.bandHandle(composer.slot, composer.chosenLine) : null
                visible: !!h
                z: 4
                width: 10
                height: 10
                x: h ? h.x - 5 : 0
                y: h ? h.y - 5 : 0
                rotation: 45
                color: "#ffd166"
                border.width: 1
                border.color: "#000000"
                ToolTip.visible: bandTip.containsMouse
                ToolTip.text: "拖动调渐变宽度"
                MouseArea {
                    id: bandTip
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                }
            }

            // Snap guides.
            Rectangle {
                visible: !isNaN(hand.guideX)
                x: screen.x + (isNaN(hand.guideX) ? 0 : hand.guideX) * screen.width
                width: 1
                height: box.height
                color: "#ff4fa3"
                z: 5
            }
            Rectangle {
                visible: !isNaN(hand.guideY)
                y: screen.y + (isNaN(hand.guideY) ? 0 : hand.guideY) * screen.height
                height: 1
                width: box.width
                color: "#ff4fa3"
                z: 5
            }
        }

        // The stickers waiting here, over everything, each moved and sized
        // where it is (StickerFrame).
        Item {
            id: stickerLayer
            x: screen.x
            y: screen.y
            width: screen.width
            height: screen.height
            z: 6
            Repeater {
                model: Live.staged
                StickerFrame {
                    area: stickerLayer
                    bounds: composer.stageBounds
                    chosen: composer.chosenSid
                    onChoose: sid => composer.chosenSid = sid
                    onResized: size => composer.placeSize = size
                }
            }
            // The sticker being dragged in, as it will look where it is let go.
            Sticker {
                visible: composer.carryOver
                kind: composer.carrying ? composer.carrying.kind : "image"
                source: composer.carrying && composer.carrying.source ? composer.carrying.source : ""
                text: composer.carrying && composer.carrying.text ? composer.carrying.text : ""
                px: composer.carryOnScreen.x / Math.max(1, screen.width)
                py: composer.carryOnScreen.y / Math.max(1, screen.height)
                size: composer.placeSize
                area: stickerLayer
                lite: true
                opacity: 0.8
            }
        }


        // Images dropped on the canvas, from elsewhere or from the files at
        // the window's left: posted where they are let go (videos go to tracks).
        DropArea {
            anchors.fill: parent
            onDropped: drop => {
                const src = drop.source
                const urls = src && src.fileUrls && src.fileUrls.length ? src.fileUrls : drop.hasUrls ? drop.urls : []
                const added = composer.imagesIn(urls)
                const at = screen.mapFromItem(box, drop.x, drop.y)
                for (let i = 0; i < added.length; ++i)
                    composer.postAt(added[i], at.x / screen.width + i * 0.04, at.y / screen.height + i * 0.04)
            }
        }

        PopMenu {
            id: layerMenu
            PopAction { text: "铺满画面"; onTriggered: composer.fill(composer.selected) }
            PopAction { text: "恢复画面比例"; onTriggered: composer.trueShape(composer.selected) }
            PopAction {
                text: composer.slot && composer.slot.fit === "cover" ? "完整显示（留边）" : "裁切填满"
                onTriggered: Switcher.updateSlot(composer.selected, { fit: composer.slot.fit === "cover" ? "contain" : "cover" })
            }
            PopAction { text: "加分割线"; onTriggered: composer.addLine() }
            PopAction {
                enabled: !!composer.slot && composer.slot.mask.lines.length > 0
                risky: true
                text: "删除全部分割线"
                onTriggered: composer.removeLines()
            }
            PopAction { text: "置顶"; onTriggered: Switcher.raiseSlot(composer.selected) }
            PopAction { text: "置底"; onTriggered: Switcher.lowerSlot(composer.selected) }
            PopAction {
                text: composer.slot && !composer.known(composer.slot.source) ? "从合成中删除" : "移到画外"
                onTriggered: composer.park(composer.selected)
            }
        }

        PopMenu {
            id: cameraMenu
            implicitWidth: 240
            Instantiator {
                model: cameraMenu.visible ? (Cameras.list.length ? Cameras.list : [{ id: "", name: "没有找到相机" }]) : []
                delegate: PopAction {
                    required property var modelData
                    readonly property bool taken: composer.cameraIds.indexOf(modelData.id) >= 0
                    text: modelData.id ? modelData.name + (taken ? "（已加 · 放回画面）" : "") : modelData.name
                    enabled: !!modelData.id
                    onTriggered: {
                        const key = "camera:" + modelData.id
                        // Held here: this entry is gone once the menu closes.
                        const board = composer
                        if (!taken)
                            board.addCamera(modelData.id)
                        // After the stack has taken it in (a moment later).
                        Qt.callLater(() => board.bringIn(key))
                    }
                }
                onObjectAdded: (index, object) => cameraMenu.insertAction(index, object)
                onObjectRemoved: (index, object) => cameraMenu.removeAction(object)
            }
        }
        PopMenu {
            id: lineMenu
            readonly property var bend: composer.chosenLine && composer.chosenLine.points.length === 3 ? composer.chosenLine.points[1] : null
            PopAction {
                enabled: !!lineMenu.bend
                text: lineMenu.bend && lineMenu.bend[2] ? "中间点：改为曲线" : "中间点：改为折角"
                onTriggered: {
                    const pts = composer.chosenLine.points.slice()
                    const p = pts[1]
                    pts[1] = [p[0], p[1], p[2] ? 0 : 1]
                    Switcher.setLine(composer.selected, composer.lineAt, { points: pts })
                }
            }
            PopAction {
                enabled: !!lineMenu.bend
                text: "删除中间点（拉直）"
                onTriggered: {
                    composer.point = 1
                    composer.takeAway()
                }
            }
            PopAction {
                text: "翻转遮住的一边"
                onTriggered: Switcher.setLine(composer.selected, composer.lineAt, { flip: !composer.chosenLine.flip })
            }
            PopAction {
                risky: true
                text: "删除分割线"
                onTriggered: composer.removeLines()
            }
        }

        // The chosen layer's keys, on a plate over the foot of the picture
        // until it is moved by the grip at its left: it stays where it was
        // put (kept as shares of the board, between runs), whatever the
        // layer or the view's size do; shown while a layer is chosen; its
        // corner, band and feather on a second line. Presses stay on it.
        Item {
            id: tools
            z: 9
            readonly property real spread: 6
            readonly property var at: {
                const p = composer.toolsAt.split(",").map(Number)
                return p.length === 2 && !isNaN(p[0]) && !isNaN(p[1]) ? p : null
            }
            visible: !!composer.slot
            width: toolColumn.implicitWidth + 12
            height: toolColumn.implicitHeight + 8
            x: Math.max(4, Math.min(box.width - width - 4, at ? at[0] * box.width - width / 2
                                                              : screen.fitX + screen.fitWidth / 2 - width / 2))
            y: Math.max(4, Math.min(box.height - height - 4, at ? at[1] * box.height - height / 2
                                                                : screen.fitY + screen.fitHeight - height - 12))
            // A soft shadow, in layers that fade outwards.
            Repeater {
                model: 4
                Rectangle {
                    required property int index
                    x: -(index + 1) * tools.spread / 4
                    y: x + 1
                    width: tools.width - 2 * x
                    height: tools.height - 2 * x
                    radius: Theme.radiusLg - x
                    color: Qt.rgba(0, 0, 0, Theme.shadow.a / 6)
                }
            }
            Rectangle {
                anchors.fill: parent
                radius: Theme.radiusLg
                color: Theme.raised
            }
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: wheel => wheel.accepted = true
            }
            ColumnLayout {
                id: toolColumn
                anchors.centerIn: parent
                spacing: 4
                // —— The keys for the chosen layer ——
                RowLayout {
                    spacing: 2
                    // The grip: the plate dragged anywhere on the board;
                    // double-clicked, back over the picture's foot.
                    Item {
                        implicitWidth: 18
                        implicitHeight: 26
                        ColorImage {
                            anchors.centerIn: parent
                            source: "icons/grip-vertical.svg"
                            sourceSize: Qt.size(14, 14)
                            color: grip.containsMouse || grip.pressed ? Theme.text : Theme.faint
                        }
                        MouseArea {
                            id: grip
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point offset
                            onPressed: mouse => {
                                const p = mapToItem(box, mouse.x, mouse.y)
                                offset = Qt.point(p.x - (tools.x + tools.width / 2), p.y - (tools.y + tools.height / 2))
                            }
                            onPositionChanged: mouse => {
                                if (!pressed)
                                    return
                                const p = mapToItem(box, mouse.x, mouse.y)
                                const cx = Math.max(tools.width / 2 + 4, Math.min(box.width - tools.width / 2 - 4, p.x - offset.x))
                                const cy = Math.max(tools.height / 2 + 4, Math.min(box.height - tools.height / 2 - 4, p.y - offset.y))
                                composer.toolsAt = (cx / Math.max(1, box.width)).toFixed(4) + "," + (cy / Math.max(1, box.height)).toFixed(4)
                            }
                            onDoubleClicked: composer.toolsAt = ""
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 600
                            ToolTip.text: "拖动可放到画板上任意位置（记住位置）· 双击回到画面底部"
                        }
                    }
                    // Small keys, a word each in its tip.
                    Repeater {
                        model: [
                            { icon: "maximize", tip: "铺满画面（双击画面也可）", act: () => composer.fill(composer.selected) },
                            { icon: "proportions", tip: "恢复画面本身的比例", act: () => composer.trueShape(composer.selected) },
                            { icon: "minus", tip: "缩小（以中心，按住连续）", repeat: true, act: () => composer.scaleLayer(composer.selected, 1 / 1.08) },
                            { icon: "plus", tip: "放大（以中心，按住连续）", repeat: true, act: () => composer.scaleLayer(composer.selected, 1.08) },
                            { icon: "fit-contain", tip: "完整显示（留边）", fit: "contain", act: () => Switcher.updateSlot(composer.selected, { fit: "contain" }) },
                            { icon: "crop", tip: "裁切填满", fit: "cover", act: () => Switcher.updateSlot(composer.selected, { fit: "cover" }) },
                            { sep: true },
                            { icon: "square-sharp", tip: "直角", shape: "rect", act: () => Switcher.setMask(composer.selected, { shape: "rect" }) },
                            { icon: "square-round", tip: "圆角", shape: "round", act: () => Switcher.setMask(composer.selected, { shape: "round" }) },
                            { icon: "circle", tip: "圆形", shape: "circle", act: () => Switcher.setMask(composer.selected, { shape: "circle" }) },
                            { sep: true },
                            { icon: "spline", tip: "加分割线：左下到右上的一道弧线，左上那边遮住、右下露出，中间渐变", act: () => composer.addLine() },
                            { icon: "polyline", tip: "中间点拉成折角（同按住 Shift）", toggle: true, act: () => composer.straight = !composer.straight },
                        { icon: "trash", tip: "删除选中的分割线；没选中线时删除这个画面的全部分割线", lines: true, act: () => composer.removeLines() },
                            { sep: true },
                            { icon: "arrow-up-to-line", tip: "置顶", act: () => Switcher.raiseSlot(composer.selected) },
                            { icon: "arrow-down-to-line", tip: "置底", act: () => Switcher.lowerSlot(composer.selected) },
                            { icon: "arrow-right-to-line", tip: "移出画面，放回预备（Delete）", act: () => composer.park(composer.selected) }
                        ]
                        Item {
                            id: key
                            required property var modelData
                            implicitWidth: modelData.sep ? 10 : 26
                            implicitHeight: 26
                            IconButton {
                                visible: !key.modelData.sep
                                anchors.fill: parent
                                iconSize: 14
                                iconName: key.modelData.icon || ""
                                tip: key.modelData.tip || ""
                                enabled: key.modelData.lines ? !!composer.slot && composer.slot.mask.lines.length > 0
                                                         : !!composer.slot || !!key.modelData.toggle
                                active: !!composer.slot && (key.modelData.fit ? composer.slot.fit === key.modelData.fit
                                                            : key.modelData.shape ? composer.slot.mask.shape === key.modelData.shape : false)
                                        || (!!key.modelData.toggle && composer.straight)
                                autoRepeat: !!key.modelData.repeat
                                onClicked: key.modelData.act()
                            }
                        }
                    }
                }
                // The chosen layer's round corners or split lines' band, when it has them.
                RowLayout {
                    id: maskRow
                    Layout.fillWidth: false
                    visible: !!composer.slot && (composer.slot.mask.shape === "round" || composer.slot.mask.lines.length > 0)
                    spacing: 8
                    Caption {
                        visible: !!composer.slot && composer.slot.mask.shape === "round"
                        text: "圆角"
                    }
                    Seek {
                        Layout.preferredWidth: 80
                        visible: !!composer.slot && composer.slot.mask.shape === "round"
                        from: 0
                        to: 0.5
                        value: composer.slot ? composer.slot.mask.radius : 0
                        onMoved: Switcher.setMask(composer.selected, { radius: value })
                    }
                    Caption {
                        visible: !!composer.slot && composer.slot.mask.lines.length > 0
                        text: "渐变"
                    }
                    Seek {
                        Layout.preferredWidth: 80
                        visible: !!composer.slot && composer.slot.mask.lines.length > 0
                        from: 0
                        to: 1
                        value: composer.slot ? composer.slot.mask.blend : 0
                        onMoved: Switcher.setMask(composer.selected, { blend: value })
                    }
                    Caption { text: "边缘羽化" }
                    Seek {
                        Layout.preferredWidth: 80
                        from: 0
                        to: 0.3
                        value: composer.slot ? composer.slot.mask.feather : 0
                        onMoved: Switcher.setMask(composer.selected, { feather: value })
                    }
                }
            }
        }
    }

    // A press anywhere else in the window lets the chosen layer and sticker
    // go (a press on the board decides for itself). Passive: the press goes
    // on to what is under it.
    Item {
        parent: composer.Window.contentItem
        anchors.fill: parent
        z: 998
        PointHandler {
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onActiveChanged: {
                if (!active)
                    return
                const p = box.mapFromItem(null, point.scenePosition.x, point.scenePosition.y)
                if (p.x < 0 || p.y < 0 || p.x > box.width || p.y > box.height) {
                    composer.selected = -1
                    composer.chosenSid = ""
                }
            }
        }
    }

    // The sticker being dragged, small at the pointer until it is over the canvas.
    Rectangle {
        parent: composer.Window.contentItem
        readonly property point at: parent ? parent.mapFromItem(composer, composer.carryPoint.x, composer.carryPoint.y) : Qt.point(0, 0)
        visible: !!composer.carrying && !composer.carryOver
        z: 1000
        x: at.x - width / 2
        y: at.y - height / 2
        width: 64
        height: 48
        radius: Theme.radius
        color: Theme.inset
        opacity: 0.9
        Image {
            anchors.fill: parent
            anchors.margins: 4
            visible: !!composer.carrying && composer.carrying.kind === "image"
            source: visible ? composer.carrying.source : ""
            sourceSize.height: 96
            fillMode: Image.PreserveAspectFit
        }
        Text {
            anchors.fill: parent
            anchors.margins: 4
            visible: !!composer.carrying && composer.carrying.kind === "text"
            text: visible ? composer.carrying.text : ""
            font.pixelSize: Theme.sizeXs
            font.weight: Font.DemiBold
            color: Theme.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
}
