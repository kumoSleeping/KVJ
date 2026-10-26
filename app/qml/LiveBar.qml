import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// What goes over the picture, in one bar under the desk: words (scrolling,
// held at the top or the foot, or large in the middle), reactions, and the
// sticker gallery. Folded, it is one row of words and reactions; opened, the
// gallery shows under it. The gallery's items and the dragging onto the
// preview belong to the desk (`desk`), which holds the preview.
Card {
    id: bar

    property var desk
    // Folded at first; the operator's choice is kept.
    property bool open: false

    implicitHeight: column.implicitHeight + 16

    function send(text) {
        if (modeBox.currentIndex < 3)
            Live.say(text, "", { mode: ["scroll", "top", "bottom"][modeBox.currentIndex], size: Live.sizes[sizeBox.currentIndex] })
        else
            Live.showCaption(text)
    }

    Settings {
        category: "desk"
        property alias wordMode: modeBox.currentIndex
        property alias wordSize: sizeBox.currentIndex
        property alias liveBarOpen: bar.open
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: 8
        anchors.leftMargin: Theme.gap
        anchors.rightMargin: Theme.gap
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.gap

            // Words: scrolling across, held at the top or the foot, at a
            // size of three, or large in the middle. Enter sends.
            RowLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 320
                spacing: 6
                Select {
                    id: modeBox
                    Layout.preferredWidth: 96
                    model: ["滚动弹幕", "顶部弹幕", "底部弹幕", "居中大字"]
                }
                Select {
                    id: sizeBox
                    Layout.preferredWidth: 56
                    visible: modeBox.currentIndex < 3
                    currentIndex: 1
                    model: ["小", "中", "大"]
                }
                Field {
                    id: words
                    Layout.fillWidth: true
                    placeholderText: modeBox.currentIndex < 3 ? "弹幕，回车发送" : "居中显示的文字，回车发送"
                    onAccepted: {
                        bar.send(text)
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
                readonly property real key: 30
                implicitWidth: Live.emoji.length * (key + 2) + 8
                implicitHeight: reactionBar.key + 6
                radius: Theme.radiusLg
                color: "transparent"
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

            // The gallery's key: how many stickers are up, and it opens the gallery.
            TextButton {
                flat: true
                iconName: bar.open ? "chevron-down" : "chevron-right"
                text: "贴图" + (Live.stickers.count > 0 ? " · " + Live.stickers.count : "")
                onClicked: bar.open = !bar.open
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: bar.open ? "收起贴图库" : "展开贴图库"
            }
        }

        // —— Stickers, in a row under the reactions: drag one onto the picture ——
        ColumnLayout {
            Layout.fillWidth: true
            visible: bar.open
            spacing: 6
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Text {
                    text: "贴图"
                    font.pixelSize: Theme.sizeSm
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
                IconButton { iconName: "file-plus"; tip: "添加图片或 GIF（可多选）"; onClicked: bar.desk.pickImages() }
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
                    flat: true
                    text: desk.editing ? "完成" : "编辑"
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: desk.editing ? "结束编辑（Esc）" : "显示 ×，撤下贴图或移出图库"
                    onClicked: desk.editing = !desk.editing
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
                readonly property int cellWidth: 76
                readonly property int cellHeight: 60
                Layout.fillWidth: true
                Layout.preferredHeight: cellHeight + 8
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
                    // Only while editing, on a plate so it reads over the picture.
                    IconButton {
                        id: forgetKey
                        background: Rectangle {
                            radius: Theme.radius
                            color: forgetKey.down ? Theme.selected : forgetKey.hovered ? Theme.hover : Theme.inset
                        }
                        anchors.top: parent.top
                        anchors.right: parent.right
                        implicitWidth: 20
                        implicitHeight: 20
                        iconName: "x"
                        tip: "移出图库"
                        visible: desk.editing && !desk.carrying
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
    }
}
