import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// The effects' card, as a mixing desk's channel strips: each effect's key (its
// name) turns it on at the strength it looks best at, its fader fine-tunes it,
// and the strips' order, left to right and row by row, is the order they apply.
Card {
    id: card

    // Editing shows each strip's grip to change the order, and the key that
    // forgets kept strengths.
    property bool editing: false

    // A strip's width and the room between strips; four strips to a row.
    readonly property int stripWidth: 34
    readonly property int gap: 4
    readonly property int marginLeft: 10
    // The last strip brings its own gap, so the right margin is that much less.
    readonly property int marginRight: 10 - gap
    implicitWidth: marginLeft + 4 * (stripWidth + gap) + marginRight

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Theme.pad
        anchors.bottomMargin: Theme.pad
        anchors.leftMargin: card.marginLeft
        anchors.rightMargin: card.marginRight
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Layout.rightMargin: card.gap
            spacing: 2
            Heading { text: "效果" }
            IconButton {
                implicitWidth: 24
                implicitHeight: 24
                iconName: "info"
                iconSize: 14
                tip: "点名字开关（推荐强度），按住拖过别的名字一起开关\n推子上下拖微调强度\n「编辑」里拖 ⠿ 换顺序：从左到右、一行一行，前面的先作用\n"
                     + "快捷键：1–9、0（小键盘也行）开关前十个；, / . 把最后操作的效果减弱 / 加强 5%\n"
                     + "用 , / . 调过再关掉，这个强度就记成它的推荐强度（名字上有小点）；「重置」恢复默认"
            }
            Item { Layout.fillWidth: true }
            TextButton {
                implicitHeight: 26
                leftPadding: 8
                rightPadding: 8
                flat: true
                text: card.editing ? "完成" : "编辑"
                onClicked: card.editing = !card.editing
                ToolTip.visible: hovered && !card.editing
                ToolTip.delay: 600
                ToolTip.text: "调整顺序、重置记住的强度"
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.rightMargin: card.gap
            spacing: 2
            Toggle {
                leftPadding: 0
                text: "快捷键"
                checked: Live.keysOn
                onToggled: Live.keysOn = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "1–9、0 开关效果，, / . 调强度；关掉后这些键不起作用"
            }
            Item { Layout.fillWidth: true }
            TextButton {
                implicitHeight: 26
                leftPadding: 8
                rightPadding: 8
                flat: true
                text: "重置"
                visible: card.editing
                enabled: Live.customized
                onClicked: Live.resetPresets()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "记住的强度全部恢复为默认推荐强度"
            }
            TextButton {
                implicitHeight: 26
                leftPadding: 8
                rightPadding: 8
                flat: true
                visible: !card.editing
                text: "全部关闭"
                enabled: Live.effectsOn
                onClicked: Live.resetEffects()
            }
        }

        // The strips: a number key's badge (and, while editing, the grip that
        // moves the strip), the fader, and the key with the effect's name.
        // They apply in reading order: while editing, drag one by its grip to
        // another place. The faders are dragged up and down, so the grid never
        // scrolls by dragging: only by the wheel or its scroll bar, when the
        // card is too short for every strip.
        Item {
            id: rack
            Layout.fillWidth: true
            Layout.fillHeight: true

            GridView {
                id: effectGrid
                // A strip never shorter than this (the card scrolls instead),
                // nor taller, however tall the card.
                readonly property int minCell: 120
                readonly property int maxCell: 190
                readonly property int columns: Math.max(1, Math.floor(width / (card.stripWidth + card.gap)))
                readonly property int rows: Math.max(1, Math.ceil(count / columns))
                anchors.fill: parent
                clip: true
                interactive: false
                cellWidth: Math.floor(width / columns)
                cellHeight: Math.max(minCell, Math.min(maxCell, Math.floor(height / rows)))
                model: Live.chain
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                moveDisplaced: Transition { NumberAnimation { properties: "x,y"; duration: 120; easing.type: Easing.OutQuad } }

                // The strip under a point of the grid's content, the nearest
                // one when the point is between or beyond them.
                function indexAt(px, py) {
                    const col = Math.max(0, Math.min(columns - 1, Math.floor(px / cellWidth)))
                    const row = Math.max(0, Math.floor(py / cellHeight))
                    return Math.max(0, Math.min(count - 1, row * columns + col))
                }

                delegate: Item {
                    id: effect
                    required property string key
                    required property string name
                    required property int index
                    readonly property real level: Live.level[key] || 0
                    readonly property bool on: level > 0
                    // Its number key, for the first ten.
                    readonly property string digit: Live.keysOn && index < 10 ? String((index + 1) % 10) : ""
                    width: effectGrid.cellWidth - card.gap
                    height: effectGrid.cellHeight - card.gap
                    z: grip.pressed ? 1 : 0
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radius
                        color: grip.pressed ? Theme.selected : effect.on ? Theme.inset : "transparent"
                    }
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 3

                        // The number key's badge; while editing, the grip.
                        Item {
                            Layout.fillWidth: true
                            implicitHeight: 14
                            Text {
                                x: 4
                                anchors.verticalCenter: parent.verticalCenter
                                text: effect.digit
                                font.pixelSize: 11
                                font.features: { "tnum": 1 }
                                font.weight: Live.focused === effect.key ? Font.DemiBold : Font.Normal
                                color: Live.focused === effect.key ? Theme.text : Theme.faint
                            }
                            ColorImage {
                                visible: card.editing
                                anchors.centerIn: parent
                                source: "icons/grip-vertical.svg"
                                sourceSize: Qt.size(14, 14)
                                rotation: 90
                                color: grip.pressed || grip.containsMouse ? Theme.text : Theme.faint
                            }
                            MouseArea {
                                id: grip
                                anchors.fill: parent
                                enabled: card.editing
                                hoverEnabled: true
                                preventStealing: true
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                onPositionChanged: mouse => {
                                    if (!pressed)
                                        return
                                    const p = mapToItem(effectGrid.contentItem, mouse.x, mouse.y)
                                    Live.moveEffect(effect.index, effectGrid.indexAt(p.x, p.y))
                                }
                                ToolTip.visible: containsMouse && !pressed
                                ToolTip.delay: 600
                                ToolTip.text: "拖动调整顺序（从左到右、一行一行，前面的先作用）"
                            }
                        }

                        Fader {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            from: 0
                            to: 100
                            stepSize: 1
                            value: effect.level * 100
                            opacity: effect.on ? 1 : 0.5
                            onMoved: {
                                Live.focused = effect.key
                                Live.setLevel(effect.key, value / 100)
                            }
                            // Its strength, only while it is held or pointed at.
                            ToolTip.visible: pressed || hovered
                            ToolTip.delay: pressed ? 0 : 600
                            ToolTip.text: effect.name + " · " + (value > 0 ? Math.round(value) + "%" : "关")
                        }

                        // On at its best strength, or off.
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 32
                            radius: Theme.radius - 2
                            color: effect.on ? (switchTap.pressed ? Theme.body : Theme.text)
                                             : switchTap.pressed ? Theme.selected : switchTap.containsMouse ? Theme.hover : "transparent"
                            border.width: effect.on ? 0 : 1
                            border.color: Theme.line
                            Behavior on color { ColorAnimation { duration: 90 } }
                            // Two short lines at most: the names are two to four
                            // characters, two to a line.
                            Text {
                                anchors.centerIn: parent
                                width: parent.width - 4
                                horizontalAlignment: Text.AlignHCenter
                                text: effect.name
                                font.pixelSize: 11
                                font.weight: effect.on ? Font.DemiBold : Font.Medium
                                lineHeight: 0.95
                                color: effect.on ? Theme.bg : Theme.body
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                            // A strength of its own was kept (see Live.tune).
                            Rectangle {
                                visible: Live.custom[effect.key] !== undefined
                                x: parent.width - 6
                                y: 2
                                width: 4
                                height: 4
                                radius: 2
                                color: effect.on ? Theme.bg : Theme.muted
                            }
                            // Pressed, it switches; dragged on over the other
                            // keys, it switches them the same way. Dragged back,
                            // the keys it leaves go back to how they were, the
                            // pressed one too once the drag has left it and returns.
                            MouseArea {
                                id: switchTap
                                anchors.fill: parent
                                hoverEnabled: true
                                preventStealing: true
                                cursorShape: Qt.PointingHandCursor
                                property bool turning: false
                                property bool swept: false
                                property var before: ({})
                                onPressed: {
                                    before = Live.level
                                    swept = false
                                    turning = !effect.on
                                    Live.switchEffect(effect.key, turning)
                                }
                                onPositionChanged: mouse => {
                                    if (!pressed)
                                        return
                                    const p = mapToItem(effectGrid.contentItem, mouse.x, mouse.y)
                                    const to = effectGrid.indexAt(p.x, p.y)
                                    if (to !== effect.index)
                                        swept = true
                                    const back = swept && to === effect.index
                                    const lo = Math.min(effect.index, to)
                                    const hi = Math.max(effect.index, to)
                                    for (let i = 0; i < effectGrid.count; ++i) {
                                        const k = Live.chain.get(i).key
                                        if (!back && i >= lo && i <= hi)
                                            Live.switchEffect(k, turning)
                                        else if (Live.amount(k) !== (before[k] || 0))
                                            Live.setLevel(k, before[k] || 0)
                                    }
                                }
                                ToolTip.visible: containsMouse && !pressed
                                ToolTip.delay: 900
                                ToolTip.text: effect.name + "：点一下开关；按住拖过别的名字，经过的一起开或关"
                            }
                        }
                    }
                }
            }
            // The grid takes no drags, so the wheel scrolls it.
            WheelHandler {
                target: null
                enabled: effectGrid.contentHeight > effectGrid.height
                onWheel: event => {
                    const step = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 48
                    const top = effectGrid.originY
                    const bottom = effectGrid.originY + Math.max(0, effectGrid.contentHeight - effectGrid.height)
                    effectGrid.contentY = Math.max(top, Math.min(bottom, effectGrid.contentY - step))
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

    // A desk's fader: a slim groove filled with ink from the foot up to the
    // strength, and a flat cap across it, the cap's centre travelling the
    // groove's length.
    component Fader: Slider {
        id: fader
        readonly property real capHeight: 10
        orientation: Qt.Vertical
        implicitWidth: 24
        implicitHeight: 60
        padding: 2
        background: Rectangle {
            x: fader.leftPadding + fader.availableWidth / 2 - width / 2
            y: fader.topPadding + fader.capHeight / 2
            width: 4
            height: Math.max(0, fader.availableHeight - fader.capHeight)
            radius: 2
            color: Theme.line
            Rectangle {
                y: fader.visualPosition * parent.height
                width: parent.width
                height: parent.height - y
                radius: parent.radius
                color: fader.enabled ? Theme.text : Theme.faint
            }
        }
        handle: Rectangle {
            x: fader.leftPadding + fader.availableWidth / 2 - width / 2
            y: fader.topPadding + fader.visualPosition * (fader.availableHeight - height)
            implicitWidth: 22
            implicitHeight: fader.capHeight
            radius: 3
            color: Theme.raised
            border.width: 1.5
            border.color: fader.pressed || fader.hovered ? Theme.text : Theme.muted
            scale: fader.pressed ? 1.1 : 1
            Behavior on scale { NumberAnimation { duration: 90 } }
            // The cap's line, as on a desk.
            Rectangle {
                anchors.centerIn: parent
                width: parent.width - 8
                height: 1
                color: fader.pressed || fader.hovered ? Theme.text : Theme.muted
            }
        }
    }
}
