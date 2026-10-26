import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// The effects' card: each effect's key turns it on at the strength it looks
// best at, its bar fine-tunes it, and the list's order is the order they apply.
Card {
    id: card

    // Editing shows each row's grip to change the order, and the key that
    // forgets kept strengths; otherwise the rows keep that room for their bars.
    property bool editing: false

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pad
        anchors.rightMargin: Theme.pad - 4
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            Heading { text: "效果" }
            IconButton {
                implicitWidth: 24
                implicitHeight: 24
                iconName: "info"
                iconSize: 14
                tip: "点名字开关（推荐强度），按住上下拖一起开关\n拖条微调，双击数字关掉\n「编辑」里拖 ⠿ 换顺序，上面的先作用\n"
                     + "快捷键：1–9、0（小键盘也行）开关前十个；, / . 把最后操作的效果减弱 / 加强 5%\n"
                     + "用 , / . 调过再关掉，这个强度就记成它的推荐强度（名字上有小点）；「重置」恢复默认"
            }
            Item { Layout.fillWidth: true }
            Toggle {
                text: "快捷键"
                checked: Live.keysOn
                onToggled: Live.keysOn = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "1–9、0 开关效果，, / . 调强度；关掉后这些键不起作用"
            }
            TextButton {
                implicitHeight: 26
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
                flat: true
                text: card.editing ? "完成" : "编辑"
                onClicked: card.editing = !card.editing
                ToolTip.visible: hovered && !card.editing
                ToolTip.delay: 600
                ToolTip.text: "调整顺序、重置记住的强度"
            }
            TextButton {
                implicitHeight: 26
                flat: true
                visible: !card.editing
                text: "全部关闭"
                enabled: Live.effectsOn
                onClicked: Live.resetEffects()
            }
        }
        // Each effect: its key turns it on at the strength it looks best
        // at, or off; the bar fine-tunes it (double-click the number for
        // off). They apply top first: while editing, drag one by its grip to
        // change the order. The list scrolls only when it must, so a bar dragged a
        // little up or down is never taken for a scroll.
        ListView {
            id: effectList
            readonly property int rowHeight: 34
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
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
                // Its number key, for the first ten.
                readonly property string digit: Live.keysOn && index < 10 ? String((index + 1) % 10) : ""
                width: ListView.view.width
                height: effectList.rowHeight
                z: grip.pressed ? 1 : 0
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radius
                    color: grip.pressed ? Theme.selected : effect.on ? Theme.inset : "transparent"
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: card.editing ? 0 : 4
                    anchors.rightMargin: 6
                    spacing: 5
                    Item {
                        visible: card.editing
                        implicitWidth: 16
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
                    Text {
                        Layout.preferredWidth: 10
                        horizontalAlignment: Text.AlignHCenter
                        text: effect.digit
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: Live.focused === effect.key ? Theme.text : Theme.faint
                    }
                    // On at its best strength, or off.
                    Rectangle {
                        implicitWidth: 76
                        implicitHeight: 26
                        radius: Theme.radius
                        color: effect.on ? (switchTap.pressed ? Theme.body : Theme.text)
                                         : switchTap.pressed ? Theme.selected : switchTap.containsMouse ? Theme.hover : "transparent"
                        border.width: effect.on ? 0 : 1
                        border.color: Theme.line
                        Behavior on color { ColorAnimation { duration: 90 } }
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
                        // A strength of its own was kept (see Live.tune).
                        Rectangle {
                            visible: Live.custom[effect.key] !== undefined
                            x: parent.width - 8
                            y: 4
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
                                const p = mapToItem(effectList.contentItem, mouse.x, mouse.y)
                                const step = effectList.rowHeight + effectList.spacing
                                const to = Math.max(0, Math.min(effectList.count - 1, Math.floor(p.y / step)))
                                if (to !== effect.index)
                                    swept = true
                                const back = swept && to === effect.index
                                const lo = Math.min(effect.index, to)
                                const hi = Math.max(effect.index, to)
                                for (let i = 0; i < effectList.count; ++i) {
                                    const k = Live.chain.get(i).key
                                    if (!back && i >= lo && i <= hi)
                                        Live.switchEffect(k, turning)
                                    else if (Live.amount(k) !== (before[k] || 0))
                                        Live.setLevel(k, before[k] || 0)
                                }
                            }
                            ToolTip.visible: containsMouse && !pressed
                            ToolTip.delay: 900
                            ToolTip.text: "点一下开关；按住上下拖，经过的一起开或关"
                        }
                    }
                    Seek {
                        Layout.fillWidth: true
                        // Fills what the row leaves, never pushing the value out.
                        Layout.preferredWidth: 40
                        Layout.minimumWidth: 30
                        large: true
                        from: 0
                        to: 100
                        stepSize: 1
                        value: effect.level * 100
                        opacity: effect.on ? 1 : 0.5
                        onMoved: {
                            Live.focused = effect.key
                            Live.setLevel(effect.key, value / 100)
                        }
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
