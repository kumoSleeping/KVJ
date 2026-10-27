import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// What goes over the picture, in a narrow column at the board's right
// (where nothing of the picture lies), all in sight at once: the sticker
// gallery, then one field for words, which go up either as a sticker (onto
// the board, on the air with it) or at once as danmaku or words in the
// middle, then the reactions. Stickers are dragged onto the board
// (`composer`, which holds the gallery). The effects are a rail of their own
// (Effects) at the window's right edge.
Item {
    id: bar

    property var composer
    // The words in the field, at once: scrolling, held at the top or the
    // foot, or large in the middle.
    function send(text) {
        if (bar.mode < 3)
            Live.say(text, "", { mode: ["scroll", "top", "bottom"][bar.mode], size: Live.sizes[bar.size] })
        else
            Live.showCaption(text)
    }
    // The words as a sticker in the middle of the board, chosen, to be moved
    // and sized there; on the air with the board.
    function stick(text) {
        const words = text.trim()
        if (words.length)
            bar.composer.postAt({ kind: "text", text: words, name: words }, 0.5, 0.5)
    }
    property int mode: 0
    property int size: 1

    Settings {
        category: "desk"
        property alias wordMode: bar.mode
        property alias wordSize: bar.size
    }

    implicitWidth: 236
    Layout.preferredWidth: 236
    Layout.fillWidth: false

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 4
        anchors.rightMargin: 2
        spacing: 6

        // —— Stickers: images added, the size, the gallery ——
        RowLayout {
            Layout.fillWidth: true
            spacing: 0
            Heading { text: "贴图" }
            Item { Layout.fillWidth: true }
            IconButton { implicitWidth: 26; implicitHeight: 26; iconName: "file-plus"; tip: "添加图片或 GIF（可多选）"; onClicked: bar.composer.pickImages() }
            TextButton {
                implicitHeight: 26
                flat: true
                leftPadding: 5
                rightPadding: 5
                text: bar.composer.editing ? "完成" : "编辑"
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: bar.composer.editing ? "结束编辑（Esc）" : "显示 ×，撤下贴图或移出图库"
                onClicked: bar.composer.editing = !bar.composer.editing
            }
            IconButton {
                implicitWidth: 26
                implicitHeight: 26
                iconName: "trash"
                tip: "撤下画板上的全部贴图（投放后观众那边也撤下）"
                enabled: Live.staged.count > 0
                onClicked: {
                    Live.clearStickers()
                    bar.composer.chosenSid = ""
                }
            }
        }
        // The size of the chosen sticker, or the one posted last, and of the next.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Caption { text: "大小" }
            Seek {
                Layout.fillWidth: true
                from: 0.03
                to: 1
                value: bar.composer.sizingSize
                onMoved: bar.composer.setSize(value)
            }
            Text {
                Layout.preferredWidth: 32
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
            // The height left over, at least a row; the rest a scroll away.
            Layout.fillHeight: true
            Layout.minimumHeight: cellHeight
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


        // —— Words: one field, two ways up ——
        Field {
            id: words
            Layout.fillWidth: true
            Layout.topMargin: 8
            placeholderText: bar.mode < 3 ? "文字：回车发弹幕" : "文字：回车居中发出"
            // ⌘ / Ctrl + Enter: a sticker instead.
            Keys.onPressed: event => {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                    bar.stick(text)
                    clear()
                    event.accepted = true
                }
            }
            onAccepted: {
                if (text.trim().length)
                    bar.send(text)
                clear()
            }
        }
        // How the words go at once and how large, on one line (the sizes
        // kept in place, dimmed, for the words in the middle).
        RowLayout {
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                model: ["滚动", "顶部", "底部", "居中"]
                TextButton {
                    required property string modelData
                    required property int index
                    implicitHeight: 24
                    // As wide as its word, not a key's usual width: seven fit.
                    implicitWidth: implicitContentWidth + leftPadding + rightPadding
                    leftPadding: 5
                    rightPadding: 5
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
                    implicitHeight: 24
                    // As wide as its word, not a key's usual width: seven fit.
                    implicitWidth: implicitContentWidth + leftPadding + rightPadding
                    leftPadding: 5
                    rightPadding: 5
                    font.pixelSize: Theme.sizeXs
                    enabled: bar.mode < 3
                    flat: bar.size !== index
                    font.weight: bar.size === index ? Font.DemiBold : Font.Medium
                    text: modelData
                    onClicked: bar.size = index
                }
            }
        }
        // The two ways up, as keys too.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            TextButton {
                Layout.fillWidth: true
                // Half the row each, whatever their words.
                Layout.preferredWidth: 1
                Layout.minimumWidth: 0
                leftPadding: 6
                rightPadding: 6
                implicitHeight: 28
                outlined: true
                iconName: "image"
                text: "贴到画板"
                enabled: words.text.trim().length > 0
                onClicked: {
                    bar.stick(words.text)
                    words.clear()
                }
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "做成文字贴图，贴在画板中间，随投放上屏（" + (Qt.platform.os === "osx" ? "⌘" : "Ctrl+") + "回车）"
            }
            TextButton {
                Layout.fillWidth: true
                // Half the row each, whatever their words.
                Layout.preferredWidth: 1
                Layout.minimumWidth: 0
                leftPadding: 6
                rightPadding: 6
                implicitHeight: 28
                outlined: true
                iconName: "send"
                text: bar.mode < 3 ? "发弹幕" : "居中发出"
                enabled: words.text.trim().length > 0
                onClicked: words.accepted()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "直接发到观众画面（回车）"
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
