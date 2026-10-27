import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// What goes over the picture, in one panel taking the board's right (where
// nothing of the picture lies), its three parts side by side, all in sight
// at once: the sticker gallery, the words (scrolling, held at the top or the
// foot, or large in the middle) with the reactions, and the effects.
// Stickers are dragged onto the board (`composer`, which holds the gallery)
// and go on the air with it; words and reactions go on the air at once.
Item {
    id: bar

    property var composer
    function send(text) {
        if (bar.mode < 3)
            Live.say(text, "", { mode: ["scroll", "top", "bottom"][bar.mode], size: Live.sizes[bar.size] })
        else
            Live.showCaption(text)
    }
    property int mode: 0
    property int size: 1

    Settings {
        category: "desk"
        property alias wordMode: bar.mode
        property alias wordSize: bar.size
    }

    implicitWidth: 300
    Layout.preferredWidth: 300
    Layout.fillWidth: true

    // One column, top to bottom: the effects, the stickers, the words and
    // reactions, all in sight; it scrolls only when the board is too short.
    Flickable {
        id: column
        anchors.fill: parent
        anchors.leftMargin: 4
        contentHeight: parts.implicitHeight + 8
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: !bar.composer.carrying
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    ColumnLayout {
        id: parts
        y: 4
        width: column.width - 10
        spacing: 18

            // —— The effects ——
            Effects {
                Layout.fillWidth: true
                bare: true
                compact: true
            }

            // —— Stickers: words made into one, images added, the size, the gallery ——
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Heading { text: "贴图" }
                    Item { Layout.fillWidth: true }
                    TextButton {
                        implicitHeight: 26
                        flat: true
                        leftPadding: 6
                        rightPadding: 6
                        text: bar.composer.editing ? "完成" : "编辑"
                        ToolTip.visible: hovered
                        ToolTip.delay: 600
                        ToolTip.text: bar.composer.editing ? "结束编辑（Esc）" : "显示 ×，撤下贴图或移出图库"
                        onClicked: bar.composer.editing = !bar.composer.editing
                    }
                    IconButton {
                        iconName: "trash"
                        tip: "撤下画板上的全部贴图（投放后观众那边也撤下）"
                        enabled: Live.staged.count > 0
                        onClicked: {
                            Live.clearStickers()
                            bar.composer.chosenSid = ""
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Field {
                        id: wordsSticker
                        Layout.fillWidth: true
                        placeholderText: "文字贴图，回车加入"
                        onAccepted: {
                            bar.composer.addWords(text)
                            clear()
                        }
                    }
                    IconButton { iconName: "file-plus"; tip: "添加图片或 GIF（可多选）"; onClicked: bar.composer.pickImages() }
                }
                // The size of the chosen sticker, or the one posted last, and of the next.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Caption { text: "大小" }
                    Seek {
                        Layout.fillWidth: true
                        from: 0.03
                        to: 1
                        value: bar.composer.sizingSize
                        onMoved: bar.composer.setSize(value)
                    }
                    Text {
                        Layout.preferredWidth: 34
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(bar.composer.sizingSize * 100) + "%"
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: Theme.body
                    }
                }

                // The gallery, wrapping, scrolling down.
                GridView {
                    id: grid
                    Layout.fillWidth: true
                    // A row in sight, the rest a scroll away.
                    Layout.preferredHeight: cellHeight
                    clip: true
                    cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 72)))
                    cellHeight: 58
                    model: bar.composer.gallery
                    interactive: !bar.composer.carrying
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    delegate: Item {
                        id: tile
                        required property var modelData
                        readonly property bool moving: modelData.kind === "image" && /\.(gif|webp)$/i.test(modelData.source)
                        width: grid.cellWidth
                        height: grid.cellHeight
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: Theme.radius
                            color: pick.containsMouse ? Theme.hover : Theme.inset
                            opacity: bar.composer.carrying && bar.composer.carrying.id === tile.modelData.id ? 0.4 : 1
                            Image {
                                id: thumb
                                anchors.fill: parent
                                anchors.margins: 3
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
                            cursorShape: bar.composer.carrying ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point start
                            onPressed: mouse => start = mapToItem(bar.composer, mouse.x, mouse.y)
                            onPositionChanged: mouse => {
                                if (!pressed)
                                    return
                                const p = mapToItem(bar.composer, mouse.x, mouse.y)
                                if (!bar.composer.carrying && Math.hypot(p.x - start.x, p.y - start.y) > 6)
                                    bar.composer.carrying = tile.modelData
                                if (bar.composer.carrying)
                                    bar.composer.carryPoint = p
                            }
                            onReleased: bar.composer.letGo()
                            onCanceled: bar.composer.carrying = null
                            onDoubleClicked: bar.composer.postAt(tile.modelData, 0.5, 0.5)
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 900
                            ToolTip.text: "拖到画板上贴出 · 双击贴在中间"
                        }
                        // Only while editing.
                        IconButton {
                            id: forgetKey
                            background: Rectangle {
                                radius: Theme.radius
                                color: forgetKey.down ? Theme.selected : forgetKey.hovered ? Theme.hover : Theme.bg
                            }
                            anchors.top: parent.top
                            anchors.right: parent.right
                            implicitWidth: 20
                            implicitHeight: 20
                            iconName: "x"
                            tip: "移出图库"
                            visible: bar.composer.editing && !bar.composer.carrying
                            onClicked: bar.composer.forget(tile.modelData.id)
                        }
                    }
                    // On the view itself, not its content: they work while it is empty.
                    Text {
                        parent: grid
                        anchors.centerIn: parent
                        width: parent.width - 24
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
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
                                bar.composer.addImages(drop.urls)
                        }
                    }
                }
            }

            // —— Words, then the reactions ——
            Item {
                Layout.fillWidth: true
                implicitHeight: wordsPage.implicitHeight
                ColumnLayout {
                    id: wordsPage
                    width: parent.width
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 26
                        Heading { text: "弹幕 · 表情" }
                    }
                    // How they show and how large, on one line (the sizes kept in
                    // place, dimmed, for the words in the middle).
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Repeater {
                            model: ["滚动", "顶部", "底部", "居中"]
                            TextButton {
                                required property string modelData
                                required property int index
                                implicitHeight: 26
                                leftPadding: 6
                                rightPadding: 6
                                font.pixelSize: Theme.sizeXs
                                flat: bar.mode !== index
                                font.weight: bar.mode === index ? Font.DemiBold : Font.Medium
                                text: modelData
                                onClicked: bar.mode = index
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Repeater {
                            model: ["小", "中", "大"]
                            TextButton {
                                required property string modelData
                                required property int index
                                implicitHeight: 26
                                leftPadding: 7
                                rightPadding: 7
                                font.pixelSize: Theme.sizeXs
                                enabled: bar.mode < 3
                                flat: bar.size !== index
                                font.weight: bar.size === index ? Font.DemiBold : Font.Medium
                                text: modelData
                                onClicked: bar.size = index
                            }
                        }
                    }
                    // Enter sends; they go on the air at once.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Field {
                            id: words
                            Layout.fillWidth: true
                            placeholderText: bar.mode < 3 ? "弹幕，回车直接发到观众画面" : "居中的文字，回车直接发出"
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
                    // stream from anywhere along the foot of the screen. Held and
                    // swept across them, the stream changes to the emoji under the
                    // pointer. They wrap to the panel's width.
                    Item {
                        id: reactionBar
                        readonly property real key: Math.floor((width - 2 * 7) / 8)
                        readonly property int perRow: Math.max(1, Math.floor(width / (key + 2)))
                        Layout.fillWidth: true
                        implicitHeight: Math.ceil(Live.emoji.length / perRow) * (key + 2)
                        Flow {
                            id: reactions
                            anchors.fill: parent
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
                                const step = reactionBar.key + reactions.spacing
                                const col = Math.floor(mouseX / step)
                                const row = Math.floor(mouseY / step)
                                const i = row * reactionBar.perRow + col
                                const inside = mouseX >= 0 && mouseY >= 0 && col < reactionBar.perRow && i < Live.emoji.length
                                return inside ? i : pressed ? Math.max(0, Math.min(Live.emoji.length - 1, i)) : -1
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
                        }
                    }
                }
            }

    }
    }
}
