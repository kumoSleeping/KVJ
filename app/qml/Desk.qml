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
// and the projection follows. Under the preview, the output (where the picture
// goes, and the key that projects it), the picture's sound, words, reactions
// and the sticker gallery in a row; beside it, the effects.
Item {
    id: desk

    // The projected surface the preview copies its picture from.
    property VideoSurface source
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
    readonly property bool carryOver: !!carrying && carryOnScreen.x >= 0 && carryOnScreen.y >= 0
                                      && carryOnScreen.x <= screen.width && carryOnScreen.y <= screen.height

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
                    px: Math.max(0, Math.min(1, px)), py: Math.max(0, Math.min(1, py)), size: desk.placeSize })
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
    function send(text) {
        if (modeBox.currentIndex === 0)
            Live.say(text)
        else
            Live.showCaption(text)
    }

    Settings {
        id: store
        category: "desk"
        property string gallery: "[]"
        property alias mode: modeBox.currentIndex
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
    Shortcut {
        sequence: "Esc"
        enabled: desk.chosenSid !== ""
        onActivated: desk.chosenSid = ""
    }

    RowLayout {
        anchors.fill: parent
        spacing: Theme.gap

        // —— Preview and stage, output, words and reactions ——
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12

            // As tall as a 16:9 picture of this width allows.
            Item {
                id: box
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.maximumHeight: width * 9 / 16
                Layout.verticalStretchFactor: 100

                Rectangle {
                    id: screen
                    width: Math.min(box.width, box.height * 16 / 9)
                    height: width * 9 / 16
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "black"
                    clip: true

                    // Pressing the picture away from any sticker lets the chosen one go.
                    MouseArea {
                        anchors.fill: parent
                        onPressed: desk.chosenSid = ""
                    }
                    Stage {
                        anchors.fill: parent
                        lite: true
                        entry: desk.entry
                        stickerDelegate: Component {
                            StickerFrame {
                                area: screen
                                chosen: desk.chosenSid
                                onChoose: sid => desk.chosenSid = sid
                                onResized: size => desk.placeSize = size
                            }
                        }
                        PreviewSurface {
                            id: preview
                            anchors.fill: parent
                            source: desk.source
                            fps: 24
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !preview.hasFrame && !desk.entry
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

                    // Images from elsewhere dropped on the picture: into the gallery and up.
                    DropArea {
                        anchors.fill: parent
                        onDropped: drop => {
                            if (!drop.hasUrls)
                                return
                            const added = desk.addImages(drop.urls)
                            for (let i = 0; i < added.length; ++i)
                                desk.postAt(added[i], drop.x / width + i * 0.04, drop.y / height + i * 0.04)
                        }
                    }
                }
            }

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
                    Layout.preferredWidth: 110
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

            // Words: scrolling across, or large in the middle. Enter sends.
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Select {
                    id: modeBox
                    Layout.preferredWidth: 96
                    model: ["滚动弹幕", "居中大字"]
                }
                Field {
                    id: words
                    Layout.fillWidth: true
                    placeholderText: modeBox.currentIndex === 0 ? "弹幕，回车发送" : "居中显示的文字，回车发送"
                    onAccepted: {
                        desk.send(text)
                        clear()
                    }
                }
                IconButton {
                    iconName: "send"
                    tip: "发到画面上（回车）"
                    enabled: words.text.trim().length > 0
                    onClicked: words.accepted()
                }
            }

            // Reactions, as in Google Meet: hover plays one, holding sends a
            // stream from anywhere along the foot of the screen. Held and swept
            // across the bar, the stream changes to the emoji under the pointer.
            Rectangle {
                id: reactionBar
                // Keys narrow a little before the bar outgrows the column.
                readonly property real key: Math.max(30, Math.min(40, (parent.width - 16) / Live.emoji.length - 2))
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: reactions.implicitWidth + 16
                implicitHeight: reactionBar.key + 8
                radius: height / 2
                color: Theme.raised
                Row {
                    id: reactions
                    anchors.centerIn: parent
                    spacing: 2
                    Repeater {
                        model: Live.emoji
                        Item {
                            id: key
                            required property var modelData
                            required property int index
                            readonly property bool hot: sweep.hot === index
                            width: reactionBar.key
                            height: reactionBar.key
                            AnimatedImage {
                                id: face
                                anchors.centerIn: parent
                                width: reactionBar.key * 0.75
                                height: reactionBar.key * 0.75
                                source: "emoji/" + key.modelData.file + ".webp"
                                cache: false
                                paused: !key.hot
                                scale: key.hot && sweep.pressed ? 1.15 : key.hot ? 1.35 : 1
                                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
                                // At rest it shows the frame that stands for it. WebP
                                // frames are reached only one after another from the start.
                                function rest() {
                                    currentFrame = 0
                                    for (let i = 1; i <= (key.modelData.still || 0); ++i)
                                        currentFrame = i
                                }
                                onPausedChanged: if (paused) rest()
                                onFrameCountChanged: if (paused) rest()
                            }
                        }
                    }
                }
                MouseArea {
                    id: sweep
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: Qt.PointingHandCursor
                    // The key under the pointer, -1 between and beyond them.
                    readonly property int hot: {
                        if (!containsMouse && !pressed)
                            return -1
                        const x = mouseX - reactions.x
                        const i = Math.floor(x / (reactionBar.key + reactions.spacing))
                        return x >= 0 && i < Live.emoji.length ? i : pressed ? Math.max(0, Math.min(Live.emoji.length - 1, i)) : -1
                    }
                    function send() {
                        if (hot >= 0)
                            Live.react(Live.emoji[hot].glyph)
                    }
                    onPressed: send()
                    onHotChanged: if (pressed) send()
                    Timer {
                        interval: 160
                        repeat: true
                        running: sweep.pressed
                        onTriggered: sweep.send()
                    }
                    ToolTip.visible: containsMouse && !pressed
                    ToolTip.delay: 900
                    ToolTip.text: "按住连发 · 按住左右拖动换表情"
                }
            }
            // —— Stickers, in a row under the reactions: drag one onto the picture ——
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 8
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Text {
                        text: "贴图"
                        font.pixelSize: Theme.sizeLg
                        font.weight: Font.DemiBold
                        color: Theme.text
                    }
                    Field {
                        id: wordsSticker
                        Layout.fillWidth: true
                        Layout.maximumWidth: 220
                        Layout.leftMargin: 6
                        placeholderText: "文字贴图，回车加入"
                        onAccepted: {
                            desk.addWords(text)
                            clear()
                        }
                    }
                    IconButton {
                        iconName: "plus"
                        tip: "文字加入图库"
                        enabled: wordsSticker.text.trim().length > 0
                        onClicked: wordsSticker.accepted()
                    }
                    IconButton { iconName: "file-plus"; tip: "添加图片或 GIF（可多选）"; onClicked: imageDialog.open() }
                    Item { Layout.fillWidth: true }
                    // The size of the chosen sticker, or the one posted last, and of the next.
                    Text {
                        text: "大小"
                        font.pixelSize: Theme.sizeSm
                        color: Theme.muted
                    }
                    Seek {
                        Layout.preferredWidth: 110
                        Layout.minimumWidth: 60
                        from: 0.03
                        to: 1
                        value: desk.sizingSize
                        onMoved: desk.setSize(value)
                    }
                    Text {
                        Layout.preferredWidth: 36
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(desk.sizingSize * 100) + "%"
                        font.pixelSize: Theme.sizeSm
                        font.features: { "tnum": 1 }
                        color: Theme.body
                    }
                    TextButton {
                        text: "全部撤下"
                        enabled: Live.stickers.count > 0
                        onClicked: {
                            Live.clearStickers()
                            desk.chosenSid = ""
                        }
                    }
                }
                // The gallery, side by side; it scrolls across.
                ListView {
                    id: grid
                    readonly property int cellWidth: 86
                    readonly property int cellHeight: 70
                    Layout.fillWidth: true
                    Layout.preferredHeight: cellHeight + 10
                    orientation: ListView.Horizontal
                    clip: true
                    model: desk.gallery
                    interactive: !desk.carrying
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                    delegate: Item {
                        id: tile
                        required property var modelData
                        readonly property bool moving: modelData.kind === "image" && /\.(gif|webp)$/i.test(modelData.source)
                        width: grid.cellWidth
                        height: grid.cellHeight
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 2
                            radius: Theme.radius
                            color: Theme.inset
                            opacity: desk.carrying && desk.carrying.id === tile.modelData.id ? 0.4 : 1
                            Image {
                                id: thumb
                                anchors.fill: parent
                                anchors.margins: 4
                                visible: tile.modelData.kind === "image" && !(tile.moving && pick.containsMouse)
                                source: tile.modelData.kind === "image" ? tile.modelData.source : ""
                                sourceSize.width: 128
                                sourceSize.height: 128
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }
                            // A GIF plays while the pointer is on it.
                            Loader {
                                anchors.fill: parent
                                anchors.margins: 4
                                active: tile.moving && pick.containsMouse
                                sourceComponent: AnimatedImage {
                                    source: tile.modelData.source
                                    fillMode: Image.PreserveAspectFit
                                }
                            }
                            Text {
                                anchors.fill: parent
                                anchors.margins: 4
                                visible: tile.modelData.kind === "text" || thumb.status === Image.Error
                                text: tile.modelData.kind === "text" ? tile.modelData.text : "无法读取"
                                font.pixelSize: tile.modelData.kind === "text" ? Theme.sizeSm : Theme.sizeXs
                                font.weight: Font.DemiBold
                                color: tile.modelData.kind === "text" ? Theme.text : Theme.faint
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                wrapMode: Text.Wrap
                                elide: Text.ElideRight
                            }
                        }
                        MouseArea {
                            id: pick
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: desk.carrying ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point start
                            onPressed: mouse => start = mapToItem(desk, mouse.x, mouse.y)
                            onPositionChanged: mouse => {
                                if (!pressed)
                                    return
                                const p = mapToItem(desk, mouse.x, mouse.y)
                                if (!desk.carrying && Math.hypot(p.x - start.x, p.y - start.y) > 6)
                                    desk.carrying = tile.modelData
                                if (desk.carrying)
                                    desk.carryPoint = p
                            }
                            onReleased: desk.letGo()
                            onCanceled: desk.carrying = null
                            onDoubleClicked: desk.postAt(tile.modelData, 0.5, 0.5)
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 900
                            ToolTip.text: "拖到画面上贴出 · 双击贴在中间"
                        }
                        IconButton {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            implicitWidth: 20
                            implicitHeight: 20
                            iconName: "x"
                            tip: "移出图库"
                            opacity: (pick.containsMouse || hovered) && !desk.carrying ? 1 : 0
                            enabled: opacity > 0
                            onClicked: desk.forget(tile.modelData.id)
                        }
                    }
                    // On the view itself, not its content: they work while it is empty.
                    Text {
                        parent: grid
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: -5
                        visible: grid.count === 0
                        text: "把图片拖到这里，或点上面的 + 添加"
                        font.pixelSize: Theme.sizeSm
                        color: Theme.faint
                    }
                    DropArea {
                        parent: grid
                        anchors.fill: parent
                        onDropped: drop => {
                            if (drop.hasUrls)
                                desk.addImages(drop.urls)
                        }
                    }
                }
            }
            Item {
                Layout.fillHeight: true
                Layout.verticalStretchFactor: 1
            }
        }

        // —— Effects ——
        Rectangle {
            Layout.preferredWidth: 290
            Layout.fillWidth: false
            Layout.fillHeight: true
            radius: 8
            color: Theme.raised

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: "效果"
                        font.pixelSize: Theme.sizeLg
                        font.weight: Font.DemiBold
                        color: Theme.text
                    }
                    TextButton {
                        text: "全部关闭"
                        enabled: Live.effectsOn
                        onClicked: Live.resetEffects()
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: "点名字开关（推荐强度），按住上下拖一起开关；拖条微调；拖 ⠿ 换顺序，上面的先作用"
                    font.pixelSize: Theme.sizeXs
                    color: Theme.faint
                    wrapMode: Text.Wrap
                }
                // Each effect: its key turns it on at the strength it looks best
                // at, or off; the bar fine-tunes it (double-click the number for
                // off). They apply top first: drag one by its grip to change the
                // order. The list scrolls only when it must, so a bar dragged a
                // little up or down is never taken for a scroll.
                ListView {
                    id: effectList
                    readonly property int rowHeight: 40
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 3
                    model: Live.chain
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    moveDisplaced: Transition { NumberAnimation { properties: "y"; duration: 120; easing.type: Easing.OutQuad } }
                    delegate: Item {
                        id: effect
                        required property string key
                        required property string name
                        required property int index
                        readonly property real level: Live.level[key] || 0
                        readonly property bool on: level > 0
                        width: ListView.view.width
                        height: effectList.rowHeight
                        z: grip.pressed ? 1 : 0
                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: effect.on || grip.pressed ? Theme.hover : "transparent"
                            border.width: effect.on ? 1 : 0
                            border.color: Theme.line
                        }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 2
                            anchors.rightMargin: 8
                            spacing: 6
                            Item {
                                implicitWidth: 18
                                implicitHeight: effectList.rowHeight
                                ColorImage {
                                    anchors.centerIn: parent
                                    source: "icons/grip-vertical.svg"
                                    sourceSize: Qt.size(14, 14)
                                    color: grip.pressed || grip.containsMouse ? Theme.text : Theme.faint
                                }
                                MouseArea {
                                    id: grip
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    preventStealing: true
                                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                    onPositionChanged: mouse => {
                                        if (!pressed)
                                            return
                                        const p = mapToItem(effectList.contentItem, mouse.x, mouse.y)
                                        const step = effectList.rowHeight + effectList.spacing
                                        const to = Math.max(0, Math.min(effectList.count - 1, Math.floor(p.y / step)))
                                        Live.moveEffect(effect.index, to)
                                    }
                                    ToolTip.visible: containsMouse && !pressed
                                    ToolTip.delay: 600
                                    ToolTip.text: "拖动调整顺序（上面的先作用）"
                                }
                            }
                            // On at its best strength, or off.
                            Rectangle {
                                implicitWidth: 84
                                implicitHeight: 30
                                radius: 15
                                color: effect.on ? (switchTap.pressed ? Theme.muted : Theme.text)
                                                 : switchTap.pressed ? Theme.line : switchTap.containsMouse ? Theme.hover : Theme.inset
                                border.width: effect.on ? 0 : 1
                                border.color: Theme.line
                                Text {
                                    anchors.centerIn: parent
                                    width: parent.width - 12
                                    horizontalAlignment: Text.AlignHCenter
                                    text: effect.name
                                    font.pixelSize: Theme.sizeSm
                                    font.weight: effect.on ? Font.DemiBold : Font.Medium
                                    color: effect.on ? Theme.bg : Theme.body
                                    elide: Text.ElideRight
                                }
                                // Pressed, it switches; dragged on over the other
                                // keys, it switches them the same way.
                                MouseArea {
                                    id: switchTap
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    preventStealing: true
                                    cursorShape: Qt.PointingHandCursor
                                    property bool turning: false
                                    onPressed: {
                                        turning = !effect.on
                                        Live.switchEffect(effect.key, turning)
                                    }
                                    onPositionChanged: mouse => {
                                        if (!pressed)
                                            return
                                        const p = mapToItem(effectList.contentItem, mouse.x, mouse.y)
                                        const i = effectList.indexAt(effectList.contentX + 1, p.y)
                                        if (i >= 0)
                                            Live.switchEffect(Live.chain.get(i).key, turning)
                                    }
                                    ToolTip.visible: containsMouse && !pressed
                                    ToolTip.delay: 900
                                    ToolTip.text: "点一下开关；按住上下拖，经过的一起开或关"
                                }
                            }
                            Seek {
                                Layout.fillWidth: true
                                large: true
                                from: 0
                                to: 100
                                stepSize: 1
                                value: effect.level * 100
                                opacity: effect.on ? 1 : 0.55
                                onMoved: Live.setLevel(effect.key, value / 100)
                            }
                            Text {
                                Layout.preferredWidth: 24
                                horizontalAlignment: Text.AlignRight
                                text: effect.on ? Math.round(effect.level * 100) : "关"
                                font.pixelSize: Theme.sizeSm
                                font.features: { "tnum": 1 }
                                color: effect.on ? Theme.text : Theme.faint
                                MouseArea { anchors.fill: parent; onDoubleClicked: Live.setLevel(effect.key, 0) }
                            }
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    visible: GraphicsInfo.api === GraphicsInfo.Software
                    text: "这台电脑以软件方式绘制画面，效果和表情不会出现。"
                    font.pixelSize: Theme.sizeXs
                    color: Theme.warn
                    wrapMode: Text.Wrap
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
