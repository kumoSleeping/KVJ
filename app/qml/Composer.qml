import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Window
import KVJ

// The board: the one place the picture is seen and made, the projected
// picture in the middle of a wide stage. Every picture source is a layer on
// it; a source newly there waits on the stage at the picture's right
// (Switcher.stack) until it is dragged in; cameras are taken in with the key at
// the foot of that stage (+ 相机) and let go from their layer's menu. Stickers
// from the gallery (LiveBar, the panel at the board's right) are posted here too; the effects, the words and the reactions on the air
// show on it as they do for the audience. Right under the picture: 跟随 | 投放,
// the picture's sound, the output and 投放. In 跟随 every change here is on
// the air at once; in 投放 the audience keeps what was last put out until 投放
// (Switcher.apply, also Space); the PGM monitor above 音频对位 shows it meanwhile.
//
// A layer is chosen by pressing it, moved by dragging it (its edges snap to
// the picture's edges and middle and to the other layers'; laid nearly over
// the picture it takes it whole), sized by its handles (corners keep its shape,
// Shift frees them). A split line (+ 分割线) hides the layer above it, softened
// over a band whose width its handle sets: its ends are dragged, a press on a
// straight line pulls out its one bend (a press on a bent one only chooses
// it), with Shift (or the 折角 key) the bend is a corner; right-click for
// more. Delete takes the chosen bend (the line goes straight), the line or
// the layer (back to the stage) away; the trash key takes the chosen line or
// all the layer's lines. Esc lets go. (The arrow keys stay the player's.)
//
//   sources:  [{ id, name }] the picture sources (the tracks, the cameras)
//   cameraIds the cameras taken in; addCamera(id), removeCamera(key) ask the host
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
    signal removeCamera(string key)
    // How wide the picture is drawn here: the sources' light copies are made this large.
    readonly property real pictureWidth: screen.width
    // 画外: the column at the picture's right where the sources not on it wait.
    readonly property real shelfWidth: 112

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

    // Layer `i` onto the picture centred at (cx, cy) (picture shares), a
    // quarter wide in its own shape, chosen and on top: dropped from the shelf.
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
    // The chosen layer's camera let go, and the camera with it (it stops).
    // Later: letting go destroys the menu item that asked.
    function dropCamera() {
        if (!slot || !slot.source.startsWith("camera:"))
            return
        const key = slot.source
        Qt.callLater(() => {
            selected = -1
            removeCamera(key)
        })
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
        } else if (slot && slot.source.startsWith("camera:")) {
            // A camera goes for good (it stops), not off the picture.
            dropCamera()
        } else if (slot) {
            park(selected)
        }
    }

    // —— Stickers, posted here from the gallery ——
    // Stickers in waiting, kept between runs: { id, kind: "image" | "text", source, text, name }.
    property var gallery: []
    // How tall the next sticker is, as a share of the screen's height.
    property real placeSize: 0.3
    // The sticker chosen on the canvas; the size bar works on it, or else on
    // the one posted last.
    property string chosenSid: ""
    onChosenSidChanged: if (chosenSid) selected = -1
    // Editing the stickers: each posted one and each in the gallery shows a key
    // that takes it down or out. Off at every start.
    property bool editing: false
    readonly property string sizing: {
        Live.revision
        return chosenSid && Live.find(chosenSid) >= 0 ? chosenSid
             : Live.lastSid && Live.find(Live.lastSid) >= 0 ? Live.lastSid : ""
    }
    readonly property real sizingSize: {
        Live.revision
        const s = sizing ? Live.sticker(sizing) : null
        return s ? s.size : placeSize
    }
    // A gallery item being dragged, and where the pointer is (composer coordinates).
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
    function addImages(urls) {
        const added = []
        for (let i = 0; i < urls.length; ++i) {
            const url = urls[i].toString()
            if (!/\.(png|jpe?g|gif|webp|svg|bmp)$/i.test(url))
                continue
            const name = decodeURIComponent(url.substring(url.lastIndexOf("/") + 1))
            added.push({ id: "g" + Date.now() + "_" + i, kind: "image", source: url, name: name })
        }
        if (added.length)
            setGallery(gallery.concat(added))
        return added
    }
    function addWords(text) {
        const words = text.trim()
        if (words.length)
            setGallery(gallery.concat([{ id: "g" + Date.now(), kind: "text", text: words, name: words }]))
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
    function setSize(size) {
        placeSize = size
        if (sizing)
            Live.update(sizing, { size: size })
    }
    function pickImages() {
        imageDialog.open()
    }

    Settings {
        id: store
        category: "desk"
        property string gallery: "[]"
        property alias size: composer.placeSize
    }
    FileDialog {
        id: imageDialog
        fileMode: FileDialog.OpenFiles
        nameFilters: ["图片 (*.png *.jpg *.jpeg *.gif *.webp *.svg *.bmp)"]
        onAccepted: composer.addImages(selectedFiles)
    }
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
    // Esc lets the chosen sticker or layer go and ends editing.
    Shortcut {
        sequence: "Esc"
        enabled: composer.chosenSid !== "" || composer.editing || composer.selected >= 0
        onActivated: {
            composer.chosenSid = ""
            composer.editing = false
            composer.selected = -1
        }
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

        // The picture, at the top left with a small margin on the left, top
        // and foot (`room`), enough to reach a split line's point on its edge;
        // at its right the stage where sources wait, under it the keys that
        // put it on the air and the layer tools.
        Rectangle {
            id: screen
            readonly property real room: 16
            readonly property real roomTop: room
            readonly property real roomLeft: room
            // Fixed, so the picture never changes size as the tools do.
            readonly property real roomFoot: room + airRow.implicitHeight + 10
            // At least one column of parked sources fits at its right.
            width: Math.max(1, Math.min(box.width - roomLeft - 12 - composer.shelfWidth - 8, (box.height - roomTop - roomFoot) * composer.aspect))
            height: width / Math.max(0.2, composer.aspect)
            x: roomLeft
            y: roomTop
            color: "black"
        }
        // —— 画外: the sources not on the picture, a column at its right ——
        // Each a small picture with its name: a click brings it onto the
        // picture (lower right), a drag puts it where it is let go. A layer
        // moved wholly off the picture comes here. + 相机 at the foot.
        Item {
            id: shelf
            z: 7
            x: screen.x + screen.width + 12
            y: screen.y
            width: composer.shelfWidth
            height: screen.height
            readonly property var waiting: composer.slots.map((s, i) => ({ source: s.source, index: i }))
                                                          .filter(o => !Switcher.inPicture(composer.slots[o.index]))
            Flickable {
                width: parent.width
                height: parent.height - cameraKey.height - 8
                contentHeight: shelfColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: !shelf.carrying
                Column {
                    id: shelfColumn
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: shelf.waiting
                        Item {
                            id: tile
                            required property var modelData
                            width: shelfColumn.width
                            height: thumb.height + 18
                            Rectangle {
                                id: thumb
                                width: parent.width
                                height: Math.round(width * 9 / 16)
                                radius: Theme.radius
                                color: "black"
                                clip: true
                                opacity: shelf.carrying && shelf.carried === tile.modelData.source ? 0.4 : 1
                                Compositor {
                                    anchors.fill: parent
                                    layout: ({ slots: [Switcher.slot({ source: tile.modelData.source, x: 0, y: 0, w: 1, h: 1, fit: "contain" }, 0)] })
                                    textures: composer.textures
                                    operator: true
                                }
                            }
                            Text {
                                y: thumb.height + 3
                                width: parent.width
                                text: composer.sourceName(tile.modelData.source)
                                font.pixelSize: Theme.sizeXs
                                color: tileArea.containsMouse ? Theme.text : Theme.muted
                                elide: Text.ElideRight
                            }
                            MouseArea {
                                id: tileArea
                                anchors.fill: parent
                                hoverEnabled: true
                                preventStealing: true
                                cursorShape: shelf.carrying ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                property point from
                                onPressed: mouse => from = Qt.point(mouse.x, mouse.y)
                                onPositionChanged: mouse => {
                                    if (!pressed)
                                        return
                                    if (!shelf.carrying && Math.hypot(mouse.x - from.x, mouse.y - from.y) > 6) {
                                        shelf.carried = tile.modelData.source
                                        shelf.carrying = true
                                    }
                                    if (shelf.carrying)
                                        shelf.at = mapToItem(box, mouse.x, mouse.y)
                                }
                                // The drag ends before the layer moves: moved onto the
                                // picture it leaves the shelf, and this tile with it,
                                // so nothing of the tile is reached after that.
                                onReleased: mouse => {
                                    const source = tile.modelData.source
                                    const i = composer.slots.findIndex(s => s.source === source)
                                    const carried = shelf.carrying
                                    const p = mapToItem(screen, mouse.x, mouse.y)
                                    shelf.carrying = false
                                    if (!carried)
                                        composer.bringIn(source)
                                    else if (p.x >= 0 && p.y >= 0 && p.x <= screen.width && p.y <= screen.height)
                                        composer.placeAt(i, p.x / screen.width, p.y / screen.height)
                                }
                                onCanceled: shelf.carrying = false
                                ToolTip.visible: containsMouse && !pressed
                                ToolTip.delay: 600
                                ToolTip.text: "在画外，观众看不到 · 点一下放进画面右下角，或拖进画面里"
                            }
                        }
                    }
                }
            }
            // A drag from the shelf: where the layer would go, at the pointer.
            // Its source gone from the shelf (put on the picture another way,
            // a camera let go), the drag is over.
            onWaitingChanged: if (carrying && !waiting.some(o => o.source === carried)) carrying = false
            property bool carrying: false
            property string carried: ""
            property point at
            // + 相机: a camera taken in comes onto the picture, at its lower
            // right. Listed only while the menu is open (listing wakes the
            // camera stack).
            TextButton {
                id: cameraKey
                anchors.bottom: parent.bottom
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
        }
        // The layer being dragged in from the shelf, as large as it will land.
        Rectangle {
            visible: shelf.carrying
            z: 9
            readonly property real w: screen.width * 0.4
            width: w
            height: Math.min(screen.height * 0.9, w / Math.max(0.1, composer.ratio(shelf.carried)))
            x: shelf.at.x - width / 2
            y: shelf.at.y - height / 2
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
        // The keys under the picture on the board's own ground: a layer
        // reaching down past the picture never makes them hard to read.
        Rectangle {
            z: 7
            x: airRow.x - 6
            y: airRow.y - 4
            width: airRow.width + 12
            height: airRow.height + 8
            radius: Theme.radius
            color: Theme.bg
        }
        // —— Right under the picture: the mode, and the keys that put it on the air ——
        RowLayout {
            id: airRow
            z: 8
            x: screen.x
            y: screen.y + screen.height + screen.room
            width: Math.min(screen.width, box.width - x - 8)
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
                tip: "撤回：画板回到观众正在看的样子"
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
            // The picture's own sound: on or off, where and how loud, in a popover.
            TextButton {
                id: soundKey
                readonly property var out: composer.output
                outlined: true
                iconName: out && out.anySound ? "volume-2" : "volume-x"
                text: !out || !out.anySound ? "声音关"
                      : out.topOnly ? "顶层声音"
                      : !out.dual ? "声音 · " + Math.round(out.soundVolume * 100) + "%"
                      : out.hears1 && out.hears2 ? "画面 1+2"
                      : out.hears1 ? "画面 1 · " + Math.round(out.soundVolume * 100) + "%"
                      : "画面 2 · " + Math.round(out.soundVolume2 * 100) + "%"
                widest: "画面 2 · 100%"
                leftPadding: 8
                rightPadding: 10
                onClicked: out.openSound(soundKey)
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "轨道的声音：画面 1、画面 2 各自开关和音量，可同时开（cue mix），输出设备"
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
                // Only what is on the picture: those off it wait on the shelf.
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
                    Switcher.setMask(composer.selected, { blend: Math.min(0.5, 2 * reach / Math.max(1, Math.min(r.width, r.height))) })
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
        Item {
            id: ink
            width: parent.width
            // As the layers: nothing over the keys under the picture.
            height: screen.y + screen.height + 6
            clip: true

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
                    // Its name, on a plate at its top left.
                    Rectangle {
                        x: 4
                        y: 4
                        width: label.implicitWidth + 10
                        height: 16
                        radius: 4
                        visible: edge.width > 40 && edge.height > 24
                        color: edge.chosen ? "#ffffff" : "#99000000"
                        Text {
                            id: label
                            anchors.centerIn: parent
                            text: composer.sourceName(edge.s.source) + (edge.lost ? " · 已移除" : "")
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            color: edge.chosen ? "#000000" : "#ffffff"
                        }
                    }
                    // Its way off, on the chosen one, at its top right inside:
                    // a camera is let go (it stops), a layer gone from the
                    // sources leaves, a track goes off the picture.
                    IconButton {
                        readonly property bool camera: edge.s.source.startsWith("camera:")
                        visible: edge.chosen && (camera || edge.lost || Switcher.inPicture(edge.s))
                        x: Math.max(0, edge.width - width - 6)
                        y: 6
                        z: 3
                        implicitWidth: 22
                        implicitHeight: 22
                        iconSize: 12
                        iconName: "x"
                        icon.color: "#000000"
                        background: Rectangle {
                            radius: 11
                            color: parent.down ? "#d0d0d0" : parent.hovered ? "#ececec" : "#ffffff"
                        }
                        tip: camera ? "移除这个相机（相机随即关掉）"
                           : edge.lost ? "从合成中删除"
                           : "移出画面（放到右边画外）" + (Switcher.follow ? "" : "，按「投放」后观众那边也移出")
                        onClicked: {
                            composer.selected = edge.index
                            if (camera)
                                composer.dropCamera()
                            else
                                composer.park(edge.index)
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

            // The chosen layer's split lines: the course, faint past its ends
            // (it goes on straight), the soft band of the chosen one, its points.
            Item {
                id: lineBox
                readonly property var s: composer.slot
                visible: !!s && s.mask.lines.length > 0
                z: 3
                x: s ? screen.x + s.x * screen.width : 0
                y: s ? screen.y + s.y * screen.height : 0
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
                    editing: composer.editing
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


        // Images from elsewhere dropped on the canvas: into the gallery and posted.
        DropArea {
            anchors.fill: parent
            onDropped: drop => {
                if (!drop.hasUrls)
                    return
                const added = composer.addImages(drop.urls)
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
            // A camera's layer: the camera let go, its layer with it.
            Instantiator {
                model: composer.slot && composer.slot.source.startsWith("camera:") ? 1 : 0
                delegate: PopAction {
                    risky: true
                    text: "移除相机"
                    onTriggered: composer.dropCamera()
                }
                onObjectAdded: (index, object) => layerMenu.addAction(object)
                onObjectRemoved: (index, object) => layerMenu.removeAction(object)
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
                        if (!taken)
                            composer.addCamera(modelData.id)
                        // After the stack has taken it in (a moment later).
                        Qt.callLater(() => composer.bringIn(key))
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

        // The chosen layer's keys, on a plate that pops up under it and goes
        // where it goes (inside the picture's foot when there is no room
        // under it, above the keys under the picture); its corner, band and
        // feather on a second line when it has them. Presses stay on it.
        Item {
            id: tools
            z: 9
            readonly property rect at: composer.slot ? hand.rectOf(composer.slot) : Qt.rect(0, 0, 0, 0)
            readonly property real spread: 6
            visible: !!composer.slot
            width: toolColumn.implicitWidth + 12
            height: toolColumn.implicitHeight + 8
            x: Math.max(4, Math.min(box.width - width - 4, at.x + at.width / 2 - width / 2))
            y: {
                // Over the picture, the keys under it are not to be covered.
                const floor = at.x < screen.x + screen.width ? airRow.y - 6 : box.height - 4
                const below = at.y + at.height + 8
                return below + height <= floor ? below : Math.max(4, Math.min(floor, at.y + at.height - 8) - height)
            }
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
                            { icon: "spline", tip: "加分割线：上面遮住、下面露出，中间渐变", act: () => composer.addLine() },
                            { icon: "polyline", tip: "中间点拉成折角（同按住 Shift）", toggle: true, act: () => composer.straight = !composer.straight },
                        { icon: "trash", tip: "删除选中的分割线；没选中线时删除这个画面的全部分割线", lines: true, act: () => composer.removeLines() },
                            { sep: true },
                            { icon: "arrow-up-to-line", tip: "置顶", act: () => Switcher.raiseSlot(composer.selected) },
                            { icon: "arrow-down-to-line", tip: "置底", act: () => Switcher.lowerSlot(composer.selected) },
                            { icon: "arrow-right-to-line", tip: "移到画外（Delete）", act: () => composer.park(composer.selected) },
                            { icon: "x", tip: "移除这个相机（相机随即关掉）", camera: true, act: () => composer.dropCamera() }
                        ]
                        Item {
                            id: key
                            required property var modelData
                            visible: !modelData.camera || (!!composer.slot && composer.slot.source.startsWith("camera:"))
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
                        to: 0.5
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
