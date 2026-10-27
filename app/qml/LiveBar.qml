import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// What goes over the picture, in one panel at the board's foot, two
// pages sharing it: the sticker gallery (the page it opens on: stickers are
// what the operator reaches for most), and the words (scrolling, held at the
// top or the foot, or large in the middle) with the reactions. Each page
// scrolls in the panel's own room, so neither pushes anything else aside.
// Stickers are dragged onto the mixer's preview (`composer`, which holds the
// gallery) and go on the air with it; words and reactions go on the air at
// once.
Card {
    id: bar

    property var composer
    // 0 stickers, 1 words and reactions: stickers at every start.
    property int page: 0

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

    // Room round the content: none where the bar sits inside another card.
    property int margin: 8
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: bar.margin
        anchors.leftMargin: bar.margin > 0 ? Theme.gap : 0
        anchors.rightMargin: bar.margin > 0 ? Theme.gap : 0
        spacing: 6

        // —— The two pages' keys, and the page's own tools ——
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            // A segmented key: the page shown in ink on a plate.
            Rectangle {
                implicitWidth: tabs.implicitWidth + 4
                implicitHeight: Theme.control
                radius: Theme.radius
                color: Theme.inset
                Row {
                    id: tabs
                    anchors.centerIn: parent
                    spacing: 2
                    Repeater {
                        model: ["贴图", "弹幕 · 表情"]
                        Rectangle {
                            required property string modelData
                            required property int index
                            readonly property bool on: bar.page === index
                            width: tabText.implicitWidth + 20
                            height: Theme.control - 4
                            radius: Theme.radius - 1
                            color: on ? Theme.raised : tabMouse.containsMouse ? Theme.hover : "transparent"
                            border.width: on && Theme.dark ? 1 : 0
                            border.color: Theme.line
                            Text {
                                id: tabText
                                anchors.centerIn: parent
                                text: parent.modelData
                                font.pixelSize: Theme.sizeSm
                                font.weight: parent.on ? Font.DemiBold : Font.Medium
                                color: parent.on ? Theme.text : Theme.muted
                            }
                            MouseArea {
                                id: tabMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: bar.page = parent.index
                            }
                        }
                    }
                }
            }

            // Stickers: words made into one, images added, the size, editing.
            RowLayout {
                visible: bar.page === 0
                Layout.fillWidth: true
                spacing: 4
                Field {
                    id: wordsSticker
                    Layout.fillWidth: true
                    Layout.minimumWidth: 70
                    Layout.maximumWidth: 200
                    Layout.leftMargin: 4
                    placeholderText: "文字贴图，回车加入"
                    onAccepted: {
                        bar.composer.addWords(text)
                        clear()
                    }
                }
                IconButton { iconName: "file-plus"; tip: "添加图片或 GIF（可多选）"; onClicked: bar.composer.pickImages() }
                Item { Layout.fillWidth: true }
                // The size of the chosen sticker, or the one posted last, and of the next.
                Seek {
                    Layout.preferredWidth: 80
                    Layout.minimumWidth: 50
                    from: 0.03
                    to: 1
                    value: bar.composer.sizingSize
                    onMoved: bar.composer.setSize(value)
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "贴图大小"
                }
                Text {
                    Layout.preferredWidth: 32
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(bar.composer.sizingSize * 100) + "%"
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: Theme.body
                }
                TextButton {
                    flat: true
                    leftPadding: 8
                    rightPadding: 8
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

            // Words: how they show, and how large, a key each.
            Row {
                visible: bar.page === 1
                Layout.fillWidth: true
                spacing: 2
                Repeater {
                    model: ["滚动", "顶部", "底部", "居中大字"]
                    TextButton {
                        required property string modelData
                        required property int index
                        leftPadding: 8
                        rightPadding: 8
                        flat: bar.mode !== index
                        font.weight: bar.mode === index ? Font.DemiBold : Font.Medium
                        text: modelData
                        onClicked: bar.mode = index
                    }
                }
                Item { width: 8; height: 1 }
                Repeater {
                    model: bar.mode < 3 ? ["小", "中", "大"] : []
                    TextButton {
                        required property string modelData
                        required property int index
                        leftPadding: 8
                        rightPadding: 8
                        flat: bar.size !== index
                        font.weight: bar.size === index ? Font.DemiBold : Font.Medium
                        text: modelData
                        onClicked: bar.size = index
                    }
                }
            }
        }

        // —— The pages, each scrolling in the room there is ——
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: bar.page

            // The gallery, wrapping, scrolling down.
            GridView {
                id: grid
                clip: true
                cellWidth: Math.max(64, Math.floor(width / Math.max(1, Math.floor(width / 76))))
                cellHeight: 60
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
                        anchors.margins: 2
                        radius: Theme.radius
                        color: Theme.inset
                        opacity: bar.composer.carrying && bar.composer.carrying.id === tile.modelData.id ? 0.4 : 1
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
                        visible: bar.composer.editing && !bar.composer.carrying
                        onClicked: bar.composer.forget(tile.modelData.id)
                    }
                }
                // On the view itself, not its content: they work while it is empty.
                Text {
                    parent: grid
                    anchors.centerIn: parent
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

            // Words, then the reactions, scrolling down when short.
            Flickable {
                clip: true
                contentHeight: wordsPage.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ColumnLayout {
                    id: wordsPage
                    width: parent.width
                    spacing: 8
                    // Enter sends; they go on the air at once.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Field {
                            id: words
                            Layout.fillWidth: true
                            placeholderText: bar.mode < 3 ? "弹幕，回车直接发到观众画面" : "居中显示的文字，回车直接发到观众画面"
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
                        readonly property real key: 32
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
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 900
                            ToolTip.text: "按住连发 · 按住拖动换表情"
                        }
                    }
                }
            }
        }
    }
}
