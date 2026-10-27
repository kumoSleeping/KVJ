import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import QtQuick.Shapes
import KVJ

// The effects' card, one column from top to bottom, as a mixer's EQ: each
// effect a row with its number key, its name (a press turns it on at the
// strength it looks best at, or off) and a round knob that fine-tunes it. The
// rows' order, top to bottom, is the order they apply. `bare`: a page of the
// board's panel, without room of its own round it.
Card {
    id: card

    property bool bare: false

    // Editing shows each row's grip to change the order, and the key that
    // forgets kept strengths.
    property bool editing: false

    readonly property int rowHeight: 30
    readonly property int rowGap: 2
    implicitWidth: 148

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: card.bare ? 0 : Theme.pad
        anchors.leftMargin: card.bare ? 0 : 10
        anchors.rightMargin: card.bare ? 0 : 10
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            Heading { text: "效果" }
            IconButton {
                implicitWidth: 24
                implicitHeight: 24
                iconName: "info"
                iconSize: 14
                tip: "点名字开关（推荐强度），按住上下拖过别的名字一起开关\n旋钮上下拖或滚轮微调强度，双击回到推荐强度\n「编辑」里拖 ⠿ 换顺序：从上到下，上面的先作用\n"
                     + "快捷键：1–9、0（小键盘也行）开关前十个；, / . 把最后操作的效果减弱 / 加强 5%\n"
                     + "用 , / . 调过再关掉，这个强度就记成它的推荐强度（名字上有小点）；「重置」恢复默认"
            }
            Item { Layout.fillWidth: true }
            TextButton {
                implicitHeight: 26
                leftPadding: 6
                rightPadding: 6
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
            spacing: 2
            Item { Layout.fillWidth: true }
            TextButton {
                implicitHeight: 26
                leftPadding: 6
                rightPadding: 6
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
                leftPadding: 6
                rightPadding: 6
                flat: true
                visible: !card.editing
                text: "全关"
                enabled: Live.effectsOn
                onClicked: Live.resetEffects()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "关掉全部效果"
            }
        }

        // The rows, in the order they apply. Knobs and names are dragged, so
        // the list never scrolls by dragging: only by the wheel or its scroll
        // bar, when the card is too short for every row.
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            interactive: false
            spacing: card.rowGap
            model: Live.chain
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            moveDisplaced: Transition { NumberAnimation { properties: "y"; duration: 120; easing.type: Easing.OutQuad } }

            // The row under a point of the list's content, the nearest one
            // when the point is between or beyond them.
            function indexAt(py) {
                return Math.max(0, Math.min(count - 1, Math.floor(py / (card.rowHeight + card.rowGap))))
            }

            WheelHandler {
                target: null
                enabled: list.contentHeight > list.height
                onWheel: event => {
                    const step = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 48
                    const bottom = list.originY + Math.max(0, list.contentHeight - list.height)
                    list.contentY = Math.max(list.originY, Math.min(bottom, list.contentY - step))
                }
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
                width: list.width - (list.contentHeight > list.height ? 8 : 0)
                height: card.rowHeight
                z: grip.pressed ? 1 : 0
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radius
                    color: grip.pressed ? Theme.selected : "transparent"
                }
                RowLayout {
                    anchors.fill: parent
                    spacing: 4

                    // The number key; while editing, the grip.
                    Item {
                        Layout.preferredWidth: 12
                        Layout.fillHeight: true
                        Text {
                            anchors.centerIn: parent
                            visible: !card.editing
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
                                const p = mapToItem(list.contentItem, mouse.x, mouse.y)
                                Live.moveEffect(effect.index, list.indexAt(p.y))
                            }
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 600
                            ToolTip.text: "拖动调整顺序（从上到下，上面的先作用）"
                        }
                    }

                    // On at its best strength, or off.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.topMargin: 2
                        Layout.bottomMargin: 2
                        radius: Theme.radius - 2
                        color: effect.on ? (switchTap.pressed ? Theme.body : Theme.text)
                                         : switchTap.pressed ? Theme.selected : switchTap.containsMouse ? Theme.hover : "transparent"
                        border.width: effect.on ? 0 : 1
                        border.color: Theme.line
                        Behavior on color { ColorAnimation { duration: 90 } }
                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 6
                            horizontalAlignment: Text.AlignHCenter
                            text: effect.name
                            font.pixelSize: 11
                            font.weight: effect.on ? Font.DemiBold : Font.Medium
                            color: effect.on ? Theme.bg : Theme.body
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
                        // names, it switches them the same way. Dragged back,
                        // the names it leaves go back to how they were, the
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
                                const p = mapToItem(list.contentItem, mouse.x, mouse.y)
                                const to = list.indexAt(p.y)
                                if (to !== effect.index)
                                    swept = true
                                const back = swept && to === effect.index
                                const lo = Math.min(effect.index, to)
                                const hi = Math.max(effect.index, to)
                                for (let i = 0; i < list.count; ++i) {
                                    const k = Live.chain.get(i).key
                                    if (!back && i >= lo && i <= hi)
                                        Live.switchEffect(k, turning)
                                    else if (Live.amount(k) !== (before[k] || 0))
                                        Live.setLevel(k, before[k] || 0)
                                }
                            }
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 900
                            ToolTip.text: effect.name + "：点一下开关；按住上下拖过别的名字，经过的一起开或关"
                        }
                    }

                    Knob {
                        Layout.preferredWidth: card.rowHeight - 4
                        Layout.preferredHeight: card.rowHeight - 4
                        value: effect.level
                        name: effect.name
                        onMoved: v => {
                            Live.focused = effect.key
                            Live.setLevel(effect.key, v)
                        }
                        onReset: {
                            Live.focused = effect.key
                            Live.switchEffect(effect.key, true)
                        }
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

    // An EQ's knob: a ring three-quarters round, inked from its foot at the
    // left up to the strength, and a pointer. Dragged up and down (the whole
    // range over 160 px; finer with Shift), or turned with the wheel; a
    // double-click brings back the strength it looks best at.
    component Knob: Item {
        id: knob
        property real value: 0
        property string name: ""
        signal moved(real v)
        signal reset()

        readonly property real sweep: 270
        readonly property real start: 135
        readonly property bool hot: turn.pressed || turn.containsMouse
        readonly property color ink: value > 0 ? Theme.text : Theme.faint

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: Theme.line
                strokeWidth: 3
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: knob.width / 2
                    centerY: knob.height / 2
                    radiusX: knob.width / 2 - 2
                    radiusY: knob.height / 2 - 2
                    startAngle: knob.start
                    sweepAngle: knob.sweep
                }
            }
            ShapePath {
                strokeColor: knob.value > 0 ? Theme.text : "transparent"
                strokeWidth: 3
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: knob.width / 2
                    centerY: knob.height / 2
                    radiusX: knob.width / 2 - 2
                    radiusY: knob.height / 2 - 2
                    startAngle: knob.start
                    sweepAngle: Math.max(0.01, knob.sweep * knob.value)
                }
            }
        }
        // The cap, and its pointer.
        Rectangle {
            anchors.centerIn: parent
            width: parent.width - 10
            height: width
            radius: width / 2
            color: knob.hot ? Theme.hover : Theme.inset
            rotation: knob.start + knob.sweep * knob.value + 90
            Rectangle {
                x: parent.width / 2 - width / 2
                y: 1
                width: 2
                height: parent.height * 0.4
                radius: 1
                color: knob.ink
            }
        }
        MouseArea {
            id: turn
            anchors.fill: parent
            anchors.margins: -2
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.SizeVerCursor
            property real fromY: 0
            property real fromValue: 0
            onPressed: mouse => {
                fromY = mouse.y
                fromValue = knob.value
            }
            onPositionChanged: mouse => {
                if (!pressed)
                    return
                const range = (mouse.modifiers & Qt.ShiftModifier) ? 600 : 160
                knob.moved(Math.max(0, Math.min(1, fromValue + (fromY - mouse.y) / range)))
            }
            onDoubleClicked: knob.reset()
            onWheel: wheel => {
                const step = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y / 400 : wheel.angleDelta.y / 120 * 0.02
                knob.moved(Math.max(0, Math.min(1, knob.value + step)))
            }
            ToolTip.visible: pressed || containsMouse
            ToolTip.delay: pressed ? 0 : 600
            ToolTip.text: knob.name + " · " + (knob.value > 0 ? Math.round(knob.value * 100) + "%" : "关")
        }
    }
}
