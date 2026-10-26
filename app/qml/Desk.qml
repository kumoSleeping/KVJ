import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The live desk, in the main window: a light preview of what is projected, and
// what goes over it. Stickers are dragged from the gallery onto the preview and
// posted where they are let go; posted ones are moved, sized and turned there
// and the projection follows. Under the preview, one card in three parts: the
// output (where the picture goes, and the key that projects it) and the
// picture's sound; words and reactions; the sticker gallery. Beside it, the
// effects' card.
Item {
    id: desk

    // The projected surface the preview copies its picture from.
    property VideoSurface source
    // The picture sources the operator sees here (the 画面 column's), besides
    // those the layouts use.
    property var sourceIds: []
    readonly property var allIds: {
        const ids = sourceIds.slice()
        const add = list => list.forEach(id => { if (ids.indexOf(id) < 0) ids.push(id) })
        add(Switcher.sourcesOf(Switcher.program))
        add(Switcher.sourcesOf(Switcher.preview))
        if (Switcher.transition)
            add(Switcher.sourcesOf(Switcher.transition.from))
        return ids
    }
    // This window's light copy of a source (a PreviewSurface), or null.
    function previewItem(id) {
        for (let i = 0; i < bank.count; ++i) {
            const item = bank.itemAt(i)
            if (item && item.key === id)
                return item
        }
        return null
    }
    // Every source of this window as a texture, for the monitors and tiles.
    readonly property alias textures: textures
    SourceTextures {
        id: textures
        sourceItem: desk.previewItem
        ids: desk.allIds
    }
    property var entry: null
    // The projection window the output keys open and put away.
    property var projection: null
    // The output's quality: frames at most this tall (0 = source) and this many
    // a second (0 = the material's own). The first choice of each is the one
    // recommended for the chosen screen and the video now on it.
    readonly property int maxHeight: heightBox.currentIndex > 0 ? [480, 720, 1080, 0][heightBox.currentIndex - 1] ?? 720 : recommendedHeight
    readonly property int maxFps: fpsBox.currentIndex > 0 ? [24, 30, 60, 0][fpsBox.currentIndex - 1] ?? 30 : recommendedFps
    readonly property var targetScreen: Qt.application.screens[Math.min(screenBox.currentIndex, Qt.application.screens.length - 1)] || null
    // Pixel rows the output shows: the whole screen, or a window 960 wide.
    readonly property int screenRows: targetScreen ? Math.round(targetScreen.height * targetScreen.devicePixelRatio) : 1080
    readonly property int outputRows: fullscreen.checked ? screenRows
                                      : Math.min(screenRows, Math.round(540 * (targetScreen ? targetScreen.devicePixelRatio : 1)))
    readonly property size videoSize: source ? source.sourceSize : Qt.size(0, 0)
    readonly property real videoFps: source ? source.sourceFps : 0
    // As sharp as the screen shows and the video holds, no sharper: the lighter
    // the better on a computer that also runs the DJ software.
    readonly property int recommendedHeight: {
        const need = videoSize.height > 0 ? Math.min(outputRows, videoSize.height) : outputRows
        return need <= 500 ? 480 : need <= 760 ? 720 : need <= 1600 ? 1080 : 0
    }
    // Every frame the video has, up to 60.
    readonly property int recommendedFps: videoFps <= 0 ? 30 : videoFps <= 24.5 ? 24 : videoFps <= 30.5 ? 30 : 60
    function heightText(h) {
        return h > 0 ? h + "p" : "原始"
    }
    // The picture's own sound (AudioFollower): whether it plays, on which output
    // (an id from its devices, empty for the system's default) and how loud.
    property var sound: null
    property bool soundOn: false
    property string soundDevice: ""
    property real soundVolume: 0.8

    // Stickers in waiting, kept between runs: { id, kind: "image" | "text", source, text, name }.
    property var gallery: []
    // How tall the next sticker is, as a share of the screen's height.
    property real placeSize: 0.3
    // The posted sticker chosen on the preview; the size bar works on it, or
    // else on the one posted last.
    property string chosenSid: ""
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
    // A gallery item being dragged, and where the pointer is (desk coordinates).
    property var carrying: null
    property point carryPoint
    readonly property point carryOnScreen: screen.mapFromItem(desk, carryPoint.x, carryPoint.y)
    readonly property bool carryOver: !!carrying && inBounds(carryOnScreen.x / Math.max(1, screen.width),
                                                             carryOnScreen.y / Math.max(1, screen.height))

    // The picture's shape, the projection's (Projection.aspect): the preview,
    // the stickers and the danmaku lanes all take it.
    readonly property real aspect: projection ? projection.aspect : 16 / 9
    // The stage: the picture and half its size again on every side, as much
    // of it as the preview has room for. Stickers can wait there, unseen by
    // the audience, and be dragged in. In shares of the picture.
    readonly property rect stageBounds: {
        const w = Math.max(1, screen.width)
        const h = Math.max(1, screen.height)
        const x0 = Math.max(-0.5, -screen.x / w)
        const y0 = Math.max(-0.5, -screen.y / h)
        const x1 = Math.min(1.5, (box.width - screen.x) / w)
        const y1 = Math.min(1.5, (box.height - screen.y) / h)
        return Qt.rect(x0, y0, x1 - x0, y1 - y0)
    }
    function inBounds(px, py) {
        const b = stageBounds
        return px >= b.x && px <= b.x + b.width && py >= b.y && py <= b.y + b.height
    }

    readonly property Item focusItem: Window.activeFocusItem

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
    // Posts `item` centred at (px, py) of the screen, at the next size.
    function postAt(item, px, py) {
        Live.post({ kind: item.kind, source: item.source, text: item.text, name: item.name,
                    px: Math.max(stageBounds.x, Math.min(stageBounds.x + stageBounds.width, px)),
                    py: Math.max(stageBounds.y, Math.min(stageBounds.y + stageBounds.height, py)), size: desk.placeSize })
        desk.chosenSid = ""
    }
    function letGo() {
        if (desk.carrying && desk.carryOver)
            postAt(desk.carrying, carryOnScreen.x / screen.width, carryOnScreen.y / screen.height)
        desk.carrying = null
    }
    function setSize(size) {
        desk.placeSize = size
        if (desk.sizing)
            Live.update(desk.sizing, { size: size })
    }
    function pickImages() {
        imageDialog.open()
    }

    Settings {
        id: store
        category: "desk"
        property string gallery: "[]"
        property alias size: desk.placeSize
    }
    Settings {
        category: "output"
        property alias quality: heightBox.currentIndex
        property alias frames: fpsBox.currentIndex
        property alias fullscreen: fullscreen.checked
        property alias sound: desk.soundOn
        property alias soundDevice: desk.soundDevice
        property alias soundVolume: desk.soundVolume
    }
    // The shape the projection will have before it opens: the chosen screen's
    // when it fills it, else its 16:9 window.
    Binding {
        target: desk.projection
        property: "fullscreenNext"
        value: fullscreen.checked
    }
    Binding {
        target: desk.projection
        property: "screenNext"
        value: desk.targetScreen
    }
    Binding {
        target: Live
        property: "aspect"
        value: desk.aspect
    }
    Component.onCompleted: {
        try {
            gallery = JSON.parse(store.gallery)
        } catch (e) {
            gallery = []
        }
    }
    FileDialog {
        id: imageDialog
        fileMode: FileDialog.OpenFiles
        nameFilters: ["图片 (*.png *.jpg *.jpeg *.gif *.webp *.svg *.bmp)"]
        onAccepted: desk.addImages(selectedFiles)
    }
    // The chosen sticker comes down with Delete, unless words are being typed.
    Shortcut {
        sequences: [StandardKey.Delete, "Backspace"]
        // From the projection window too, which takes the focus when it opens.
        context: Qt.ApplicationShortcut
        enabled: desk.chosenSid !== "" && !(desk.focusItem && typeof desk.focusItem.selectedText === "string")
        onActivated: {
            Live.unpost(desk.chosenSid)
            desk.chosenSid = ""
        }
    }
    // Esc lets the chosen sticker go and ends editing.
    Shortcut {
        sequence: "Esc"
        enabled: desk.chosenSid !== "" || desk.editing
        onActivated: {
            desk.chosenSid = ""
            desk.editing = false
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: Theme.gap

        // —— Preview and stage, output, words and reactions ——
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.gap

            // The stage, all the height the column has; the picture in its
            // middle with a band of the stage around it.
            Rectangle {
                id: box
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Theme.radiusLg
                color: Theme.inset
                clip: true

                // Pressing the stage away from any sticker lets the chosen one go.
                MouseArea {
                    anchors.fill: parent
                    onPressed: desk.chosenSid = ""
                }
                Text {
                    x: 44
                    y: 6
                    visible: box.height - screen.height > 30 || box.width - screen.width > 120
                    text: "画外 · 贴图可停在这里，拖进画面才会投放"
                    font.pixelSize: Theme.sizeXs
                    color: Theme.faint
                }

                Rectangle {
                    id: screen
                    // A band of the stage stays in sight all round.
                    width: Math.min(box.width * 0.9, box.height * 0.84 * desk.aspect)
                    height: width / desk.aspect
                    anchors.centerIn: parent
                    color: "black"
                    // The picture's edge, over what it shows.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -1
                        z: 3
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.faint
                    }
                    // Each source's light copy, under the picture (z below the
                    // screen's own black) and as large as it: the monitors here
                    // draw them through `textures`, never these items themselves.
                    Repeater {
                        id: bank
                        model: desk.allIds
                        onItemAdded: textures.refresh()
                        onItemRemoved: textures.refresh()
                        PreviewSurface {
                            required property string modelData
                            readonly property string key: modelData
                            z: -1
                            width: screen.width
                            height: screen.height
                            fps: 24
                            source: {
                                desk.projection ? desk.projection.sourceRevision : 0
                                return desk.projection ? desk.projection.sourceItem(modelData) : null
                            }
                        }
                    }
                    Stage {
                        id: deskStage
                        anchors.fill: parent
                        lite: true
                        entry: desk.entry
                        stickerDelegate: Component {
                            StickerFrame {
                                area: screen
                                bounds: desk.stageBounds
                                chosen: desk.chosenSid
                                editing: desk.editing
                                onChoose: sid => desk.chosenSid = sid
                                onResized: size => desk.placeSize = size
                            }
                        }
                        // What is on the air, as the projection composes it.
                        Program {
                            anchors.fill: parent
                            now: deskStage.now
                            textures: textures
                            operator: true
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !desk.entry
                        text: "播放的画面在这里预览"
                        font.pixelSize: Theme.sizeSm
                        color: Theme.faint
                    }

                    // The sticker being dragged in, as it will look where it is let go.
                    Sticker {
                        visible: desk.carryOver
                        kind: desk.carrying ? desk.carrying.kind : "image"
                        source: desk.carrying && desk.carrying.source ? desk.carrying.source : ""
                        text: desk.carrying && desk.carrying.text ? desk.carrying.text : ""
                        px: desk.carryOnScreen.x / Math.max(1, screen.width)
                        py: desk.carryOnScreen.y / Math.max(1, screen.height)
                        size: desk.placeSize
                        area: screen
                        lite: true
                        opacity: 0.8
                    }

                }
                // Images from elsewhere dropped on the stage: into the gallery and up.
                DropArea {
                    anchors.fill: parent
                    onDropped: drop => {
                        if (!drop.hasUrls)
                            return
                        const added = desk.addImages(drop.urls)
                        const at = screen.mapFromItem(box, drop.x, drop.y)
                        for (let i = 0; i < added.length; ++i)
                            desk.postAt(added[i], at.x / screen.width + i * 0.04, at.y / screen.height + i * 0.04)
                    }
                }
            }

            Card {
                Layout.fillWidth: true
                implicitHeight: controls.implicitHeight + 20
                ColumnLayout {
                    id: controls
                    anchors.fill: parent
                    anchors.margins: 10
                    anchors.leftMargin: Theme.gap
                    anchors.rightMargin: Theme.gap
                    spacing: 8

                    // The output: which screen, how, and the key that projects. Lower
                    // quality is lighter on a machine that also runs the DJ software.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Select {
                            id: screenBox
                            Layout.fillWidth: true
                            Layout.minimumWidth: 90
                            model: Qt.application.screens.map((s, i) => (s.name || ("屏幕 " + (i + 1))) + " · " + s.width + "×" + s.height)
                            currentIndex: Qt.application.screens.length > 1 ? 1 : 0
                        }
                        Select {
                            id: heightBox
                            Layout.preferredWidth: 118
                            model: ["推荐", "480p", "720p", "1080p", "原始"]
                            currentIndex: 0
                            displayText: currentIndex === 0 ? "推荐 " + desk.heightText(desk.recommendedHeight) : currentText
                            ToolTip.visible: hovered && !popup.visible
                            ToolTip.delay: 600
                            ToolTip.text: "推荐：投放画面 " + desk.outputRows + " 行" + (fullscreen.checked ? "（全屏）" : "（窗口）")
                                          + (desk.videoSize.height > 0 ? "，视频 " + desk.videoSize.width + "×" + desk.videoSize.height : "")
                                          + " → " + desk.heightText(desk.recommendedHeight)
                        }
                        Select {
                            id: fpsBox
                            Layout.preferredWidth: 118
                            model: ["推荐", "24 帧", "30 帧", "60 帧", "原帧率"]
                            currentIndex: 0
                            displayText: currentIndex === 0 ? "推荐 " + desk.recommendedFps + " 帧" : currentText
                            ToolTip.visible: hovered && !popup.visible
                            ToolTip.delay: 600
                            ToolTip.text: "推荐：" + (desk.videoFps > 0 ? "视频 " + desk.videoFps.toFixed(2).replace(/\.?0+$/, "") + " 帧，" : "")
                                          + "每帧都放，最多 60 → " + desk.recommendedFps + " 帧"
                        }
                        Toggle {
                            id: fullscreen
                            text: "全屏"
                            checked: Qt.application.screens.length > 1
                        }
                        TextButton {
                            primary: true
                            iconName: desk.projection && desk.projection.visible ? "square" : "monitor"
                            text: desk.projection && desk.projection.visible ? "收起投放" : "开始投放"
                            onClicked: desk.projection.visible ? desk.projection.closeOutput()
                                                               : desk.projection.openOn(screenBox.currentIndex, fullscreen.checked)
                        }
                    }

                    // The picture's sound, off by default (the room hears the DJ), on an
                    // output of its own: headphones to listen in, or the speakers. Where
                    // and how loud can be set before it is turned on.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Toggle {
                            text: "播放声音"
                            checked: desk.soundOn
                            onToggled: desk.soundOn = checked
                        }
                        Select {
                            id: outputBox
                            readonly property var outputs: desk.sound ? desk.sound.devices : []
                            Layout.fillWidth: true
                            Layout.minimumWidth: 90
                            model: ["系统默认输出"].concat(outputs.map(d => d.name))
                            currentIndex: outputs.findIndex(d => d.id === desk.soundDevice) + 1
                            onActivated: index => desk.soundDevice = index > 0 ? outputs[index - 1].id : ""
                        }
                        Seek {
                            Layout.preferredWidth: 96
                            from: 0
                            to: 1
                            value: desk.soundVolume
                            onMoved: desk.soundVolume = value
                        }
                        Text {
                            Layout.preferredWidth: 34
                            horizontalAlignment: Text.AlignRight
                            text: Math.round(desk.soundVolume * 100) + "%"
                            font.pixelSize: Theme.sizeSm
                            font.features: { "tnum": 1 }
                            color: Theme.body
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: desk.soundOn && !!desk.sound && desk.sound.error.length > 0
                        text: desk.sound ? desk.sound.error : ""
                        font.pixelSize: Theme.sizeXs
                        color: Theme.warn
                        elide: Text.ElideRight
                    }

                }
            }
        }
    }

    // The sticker being dragged, small at the pointer until it is over the picture.
    Rectangle {
        visible: !!desk.carrying && !desk.carryOver
        x: desk.carryPoint.x - width / 2
        y: desk.carryPoint.y - height / 2
        width: 64
        height: 48
        radius: Theme.radius
        color: Theme.inset
        opacity: 0.9
        Image {
            anchors.fill: parent
            anchors.margins: 4
            visible: !!desk.carrying && desk.carrying.kind === "image"
            source: visible ? desk.carrying.source : ""
            sourceSize.height: 96
            fillMode: Image.PreserveAspectFit
        }
        Text {
            anchors.fill: parent
            anchors.margins: 4
            visible: !!desk.carrying && desk.carrying.kind === "text"
            text: visible ? desk.carrying.text : ""
            font.pixelSize: Theme.sizeXs
            font.weight: Font.DemiBold
            color: Theme.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
}
