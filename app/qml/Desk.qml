import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import KVJ

// The live desk, in the main window: a light preview of what is projected, and
// what goes over it. The preview doubles as the stage for the next sticker: the
// dot is where it will go, the slider beside it how tall, and the selected
// sticker is drawn there as it will look. Below it, words and reactions, the
// timeline and, at the foot, the sticker gallery; beside it all, the effects.
ColumnLayout {
    id: desk
    spacing: 0

    // The projected surface the preview copies its picture from.
    property VideoSurface source
    property var entry: null
    // The followed Set's entries and where following is, for the timeline.
    property var entries: []
    property bool running: false
    property string phase: ""

    // Stickers in waiting, kept between runs: { id, kind: "image" | "text", source, text, name }.
    property var gallery: []
    property string selectedId: ""
    readonly property var selected: gallery.find(g => g.id === selectedId) || null
    property real placeX: 0.5
    property real placeY: 0.5
    property real placeSize: 0.3
    readonly property var draft: selected ? Object.assign({}, selected, { x: placeX, y: placeY, size: placeSize }) : null

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
        if (!added.length)
            return
        setGallery(gallery.concat(added))
        selectedId = added[0].id
    }
    function addWords(text) {
        const words = text.trim()
        if (!words.length)
            return
        const item = { id: "g" + Date.now(), kind: "text", text: words, name: words }
        setGallery(gallery.concat([item]))
        selectedId = item.id
    }
    function forget(id) {
        setGallery(gallery.filter(g => g.id !== id))
        if (selectedId === id)
            selectedId = ""
    }
    function postSelected() {
        if (desk.draft)
            Live.post(desk.draft)
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

    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Theme.gap

        // —— Preview and stage, words and reactions ——
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12

            // As tall as a 16:9 picture of this width allows; what is left goes below.
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.maximumHeight: (width - 34) * 9 / 16
                Layout.verticalStretchFactor: 100
                spacing: 10

                Item {
                    id: box
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Rectangle {
                        id: screen
                        width: Math.min(box.width, box.height * 16 / 9)
                        height: width * 9 / 16
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: "black"
                        clip: true

                        Stage {
                            anchors.fill: parent
                            lite: true
                            entry: desk.entry
                            PreviewSurface {
                                id: preview
                                anchors.fill: parent
                                source: desk.source
                                fps: 12
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: !preview.hasFrame && !desk.entry
                            text: "投放画面会在这里预览"
                            font.pixelSize: Theme.sizeSm
                            color: Theme.faint
                        }

                        // The next sticker, as it will look once posted.
                        Sticker {
                            id: ghost
                            visible: !!desk.draft
                            sticker: desk.draft
                            area: screen
                            lite: true
                            opacity: 0.85
                        }
                        Rectangle {
                            visible: ghost.visible
                            x: ghost.x - 3
                            y: ghost.y - 3
                            width: ghost.width + 6
                            height: ghost.height + 6
                            color: "transparent"
                            radius: 2
                            border.width: 1
                            border.color: "#99ffffff"
                        }

                        // Where it goes: a dot on a faint cross.
                        Rectangle {
                            x: 0
                            y: desk.placeY * screen.height
                            width: screen.width
                            height: 1
                            color: "#33ffffff"
                        }
                        Rectangle {
                            x: desk.placeX * screen.width
                            y: 0
                            width: 1
                            height: screen.height
                            color: "#33ffffff"
                        }
                        Rectangle {
                            x: desk.placeX * screen.width - width / 2
                            y: desk.placeY * screen.height - height / 2
                            width: 10
                            height: 10
                            radius: 5
                            color: "white"
                            border.width: 2
                            border.color: "#cc000000"
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.CrossCursor
                            function place(mouse) {
                                desk.placeX = Math.max(0, Math.min(1, mouse.x / width))
                                desk.placeY = Math.max(0, Math.min(1, mouse.y / height))
                            }
                            onPressed: mouse => place(mouse)
                            onPositionChanged: mouse => place(mouse)
                            onDoubleClicked: {
                                desk.placeX = 0.5
                                desk.placeY = 0.5
                            }
                            onWheel: wheel => {
                                desk.placeSize = Math.max(0.05, Math.min(1, desk.placeSize + wheel.angleDelta.y / 120 * 0.02))
                            }
                        }
                    }
                }

                // How tall the sticker will be, as a share of the screen's height.
                ColumnLayout {
                    Layout.fillHeight: true
                    Layout.maximumHeight: screen.height
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: Math.round(desk.placeSize * 100) + "%"
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: Theme.muted
                    }
                    Slider {
                        id: sizer
                        Layout.fillHeight: true
                        Layout.alignment: Qt.AlignHCenter
                        orientation: Qt.Vertical
                        from: 0.05
                        to: 1
                        value: desk.placeSize
                        onMoved: desk.placeSize = value
                        implicitWidth: 24
                        background: Rectangle {
                            x: sizer.leftPadding + sizer.availableWidth / 2 - width / 2
                            y: sizer.topPadding
                            width: 3
                            height: sizer.availableHeight
                            radius: 1.5
                            color: Theme.line
                            Rectangle {
                                y: sizer.visualPosition * parent.height
                                width: parent.width
                                height: parent.height - y
                                radius: 1.5
                                color: Theme.text
                            }
                        }
                        handle: Rectangle {
                            x: sizer.leftPadding + sizer.availableWidth / 2 - width / 2
                            y: sizer.topPadding + sizer.visualPosition * (sizer.availableHeight - height)
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: Theme.text
                            scale: sizer.pressed ? 1.15 : 1
                        }
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "大小"
                        font.pixelSize: Theme.sizeXs
                        color: Theme.faint
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: desk.entry ? desk.entry.title : "未在跟随"
                    font.pixelSize: Theme.sizeSm
                    font.weight: Font.DemiBold
                    color: desk.entry ? Theme.text : Theme.muted
                    elide: Text.ElideRight
                }
                Text {
                    text: "预览 12 帧 · 点按定位置 · 滚轮调大小 · 双击回中心"
                    font.pixelSize: Theme.sizeXs
                    color: Theme.faint
                }
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

            // Reactions, as in Google Meet: hover plays one, holding sends a stream.
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
                            width: reactionBar.key
                            height: reactionBar.key
                            AnimatedImage {
                                id: face
                                anchors.centerIn: parent
                                width: reactionBar.key * 0.75
                                height: reactionBar.key * 0.75
                                source: "emoji/" + key.modelData.file + ".webp"
                                cache: false
                                paused: !tap.containsMouse
                                scale: tap.pressed ? 1.15 : tap.containsMouse ? 1.35 : 1
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
                            MouseArea {
                                id: tap
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPressed: Live.react(key.modelData.glyph)
                            }
                            Timer {
                                interval: 160
                                repeat: true
                                running: tap.pressed
                                onTriggered: Live.react(key.modelData.glyph)
                            }
                            ToolTip.visible: tap.containsMouse
                            ToolTip.delay: 900
                            ToolTip.text: "按住连发"
                        }
                    }
                }
            }
            Timeline {
                objectName: "timeline"
                Layout.fillWidth: true
                Layout.topMargin: 4
                entries: desk.entries
                running: desk.running
                phase: desk.phase
            }

            // —— Stickers: what is left at the foot; the gallery scrolls inside ——
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 180
                Layout.verticalStretchFactor: 1
                radius: 8
                color: Theme.raised

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Caption { text: "贴图"; Layout.rightMargin: 4 }
                        Field {
                            id: wordsSticker
                            Layout.preferredWidth: 180
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
                        IconButton { iconName: "file-plus"; tip: "添加图片（可多选）"; onClicked: imageDialog.open() }
                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 6
                            text: desk.selected ? desk.selected.name : "未选中"
                            font.pixelSize: Theme.sizeXs
                            color: desk.selected ? Theme.body : Theme.faint
                            elide: Text.ElideMiddle
                        }
                        TextButton {
                            primary: true
                            text: "贴出"
                            enabled: !!desk.selected
                            onClicked: desk.postSelected()
                        }
                        TextButton {
                            text: "全部撤下"
                            enabled: Live.stickers.length > 0
                            onClicked: Live.clearStickers()
                        }
                    }

                    GridView {
                        id: grid
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        cellWidth: Math.floor(width / Math.max(1, Math.round(width / 100)))
                        cellHeight: Math.floor(cellWidth * 0.75)
                        model: desk.gallery
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                        delegate: Item {
                            id: tile
                            required property var modelData
                            readonly property bool current: desk.selectedId === modelData.id
                            width: grid.cellWidth
                            height: grid.cellHeight
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 3
                                radius: Theme.radius
                                color: Theme.inset
                                border.width: tile.current ? 2 : 0
                                border.color: Theme.text
                                Image {
                                    id: thumb
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    visible: tile.modelData.kind === "image"
                                    source: visible ? tile.modelData.source : ""
                                    sourceSize.width: 192
                                    sourceSize.height: 192
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                }
                                Text {
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    visible: tile.modelData.kind === "text" || thumb.status === Image.Error
                                    text: tile.modelData.kind === "text" ? tile.modelData.text : "无法读取"
                                    font.pixelSize: tile.modelData.kind === "text" ? Theme.size : Theme.sizeXs
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
                                onClicked: desk.selectedId = tile.modelData.id
                                onDoubleClicked: {
                                    desk.selectedId = tile.modelData.id
                                    desk.postSelected()
                                }
                            }
                            IconButton {
                                anchors.top: parent.top
                                anchors.right: parent.right
                                implicitWidth: 22
                                implicitHeight: 22
                                iconName: "x"
                                tip: "移出图库"
                                opacity: pick.containsMouse || hovered ? 1 : 0
                                enabled: opacity > 0
                                onClicked: desk.forget(tile.modelData.id)
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            width: parent.width * 0.8
                            visible: grid.count === 0
                            text: "把图片拖进来，或点上面的按钮一次选多张"
                            font.pixelSize: Theme.sizeSm
                            color: Theme.faint
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                        }
                        DropArea {
                            anchors.fill: parent
                            onDropped: drop => {
                                if (drop.hasUrls)
                                    desk.addImages(drop.urls)
                            }
                        }
                    }

                    // What is up now; each comes down on its own.
                    Flow {
                        Layout.fillWidth: true
                        Layout.maximumHeight: 56
                        clip: true
                        spacing: 4
                        visible: Live.stickers.length > 0
                        Text {
                            height: 26
                            text: "画面上 " + Live.stickers.length
                            font.pixelSize: Theme.sizeXs
                            font.weight: Font.DemiBold
                            color: Theme.muted
                            verticalAlignment: Text.AlignVCenter
                            rightPadding: 6
                        }
                        Repeater {
                            model: Live.stickers
                            Rectangle {
                                id: chip
                                required property var modelData
                                width: Math.min(150, chipText.implicitWidth + 34)
                                height: 26
                                radius: 13
                                color: Theme.inset
                                Text {
                                    id: chipText
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.right: chipClose.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: chip.modelData.name
                                    font.pixelSize: Theme.sizeXs
                                    color: Theme.body
                                    elide: Text.ElideRight
                                }
                                IconButton {
                                    id: chipClose
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    implicitWidth: 24
                                    implicitHeight: 24
                                    iconName: "x"
                                    tip: "撤下"
                                    onClicked: Live.unpost(chip.modelData.id)
                                }
                            }
                        }
                    }
                }
            }
        }

        // —— Effects: each on and at 0; its slider brings it in ——
        Rectangle {
            Layout.preferredWidth: 280
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
                        text: "全部归零"
                        enabled: Live.effectsOn
                        onClicked: Live.resetEffects()
                    }
                }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    model: Live.effects
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    delegate: RowLayout {
                        id: effect
                        required property var modelData
                        readonly property real level: Live.level[modelData.key] || 0
                        readonly property bool on: !Live.off[modelData.key]
                        width: ListView.view.width
                        height: 34
                        spacing: 6
                        Toggle {
                            Layout.preferredWidth: 100
                            text: effect.modelData.name
                            checked: effect.on
                            onToggled: Live.setOn(effect.modelData.key, checked)
                        }
                        Seek {
                            Layout.fillWidth: true
                            from: 0
                            to: 100
                            stepSize: 1
                            value: effect.level * 100
                            enabled: effect.on
                            opacity: effect.on ? 1 : 0.5
                            onMoved: Live.setLevel(effect.modelData.key, value / 100)
                        }
                        Text {
                            Layout.preferredWidth: 28
                            horizontalAlignment: Text.AlignRight
                            text: Math.round(effect.level * 100)
                            font.pixelSize: Theme.sizeSm
                            font.features: { "tnum": 1 }
                            color: effect.level > 0 && effect.on ? Theme.text : Theme.faint
                            MouseArea { anchors.fill: parent; onDoubleClicked: Live.setLevel(effect.modelData.key, 0) }
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
                Text {
                    Layout.fillWidth: true
                    text: "拉动滑块出效果，双击数值归零；关掉开关会保留数值。效果只作用在视频上，弹幕和贴图不受影响。"
                    font.pixelSize: Theme.sizeXs
                    color: Theme.faint
                    wrapMode: Text.Wrap
                }
            }
        }
    }
}
