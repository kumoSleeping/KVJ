import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// The reactions as a narrow rail beside the effects', top to bottom, as in
// Google Meet, the first ten with their key (Q to P) in a corner: the pointer
// on one plays it, a press sends one (the key bounces), held it sends a
// stream from along the foot of the screen, and swept up or down the stream
// changes to the one under the pointer. Swept out of the rail sideways (onto
// the effects, say) it keeps the last one: it never reaches past its own
// keys. The ⋯ key at the foot orders them (dragging the keys while it is on).
Item {
    id: rail

    // Dragging the keys changes their order while this is on.
    property bool editing: false

    readonly property int count: Live.reactions.length
    readonly property int gap: 3
    // One size always, as the effects'; a rail taller than its room scrolls
    // with the wheel.
    readonly property int key: 36
    property real scroll: 0
    readonly property real maxScroll: Math.max(0, keys.height - view.height)
    onMaxScrollChanged: scroll = Math.min(scroll, maxScroll)

    implicitWidth: 40
    Layout.preferredWidth: key
    Layout.fillWidth: false

    Connections {
        target: Live
        function onReactionPressed(index) {
            const k = faces.itemAt(index)
            if (k)
                k.pop()
        }
    }

    Item {
        id: view
        width: parent.width
        height: parent.height - menuKey.height - 8
        clip: true
        Column {
            id: keys
            y: -rail.scroll
            width: parent.width
            spacing: rail.gap
            Repeater {
                id: faces
                model: Live.reactions
                Item {
                    id: face
                    required property var modelData
                    required property int index
                    readonly property bool hot: sweep.hot === index
                    width: rail.key
                    height: rail.key
                    // Sent: a quick squeeze and a ring going out.
                    function pop() {
                        bounce.restart()
                        ring.restart()
                    }
                    Rectangle {
                        id: plate
                        anchors.fill: parent
                        radius: Theme.radius - 1
                        color: face.hot && sweep.pressed ? Theme.selected : face.hot ? Theme.hover : Theme.inset
                        border.width: rail.editing ? 1 : 0
                        border.color: Theme.line
                        Behavior on color { ColorAnimation { duration: 90 } }
                        SequentialAnimation on scale {
                            id: bounce
                            running: false
                            NumberAnimation { to: 0.82; duration: 60; easing.type: Easing.OutQuad }
                            NumberAnimation { to: 1; duration: 220; easing.type: Easing.OutBack; easing.overshoot: 3 }
                        }
                    }
                    Rectangle {
                        id: ringShape
                        anchors.centerIn: parent
                        width: parent.width
                        height: parent.height
                        radius: Theme.radius + 2
                        color: "transparent"
                        border.width: 2
                        border.color: Theme.text
                        opacity: 0
                        ParallelAnimation {
                            id: ring
                            NumberAnimation { target: ringShape; property: "scale"; from: 0.9; to: 1.35; duration: 320; easing.type: Easing.OutCubic }
                            NumberAnimation { target: ringShape; property: "opacity"; from: 0.5; to: 0; duration: 320; easing.type: Easing.OutCubic }
                        }
                    }
                    AnimatedImage {
                        anchors.centerIn: parent
                        width: Math.round(rail.key * 0.7)
                        height: width
                        source: "emoji/" + face.modelData.file + ".webp"
                        cache: false
                        paused: !face.hot
                        scale: plate.scale * (face.hot && sweep.pressed ? 1.1 : face.hot ? 1.2 : 1)
                        Behavior on scale { enabled: !bounce.running; NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
                        // At rest it shows the frame that stands for it. WebP
                        // frames are reached only one after another from the start.
                        function rest() {
                            currentFrame = 0
                            for (let i = 1; i <= (face.modelData.still || 0); ++i)
                                currentFrame = i
                        }
                        onPausedChanged: if (paused) rest()
                        onFrameCountChanged: if (paused) rest()
                    }
                    // Its key, for the first ten.
                    Text {
                        x: 3
                        y: 1
                        visible: Live.keysOn && face.index < Live.reactionKeys.length && rail.key >= 30
                        text: Live.reactionKeys[face.index] || ""
                        font.pixelSize: 8
                        color: Theme.muted
                    }
                }
            }
        }

        MouseArea {
            id: sweep
            y: keys.y
            width: parent.width
            height: keys.height
            hoverEnabled: true
            preventStealing: true
            cursorShape: rail.editing ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.PointingHandCursor
            // The key under the pointer (-1 between and beyond them); held, the
            // one at its height while it is over the rail, else the last one.
            property int held: -1
            readonly property int hot: {
                const step = rail.key + rail.gap
                const at = Math.floor(mouseY / step)
                const over = mouseX >= 0 && mouseX < width
                if (pressed)
                    return over ? Math.max(0, Math.min(rail.count - 1, at)) : held
                if (!containsMouse || mouseY - at * step > rail.key)
                    return -1
                return at < rail.count ? at : -1
            }
            // A press may move `hot` before onPressed: one send for it either way.
            // While ordering, the one held moves to where the pointer is.
            onHotChanged: {
                if (!pressed || hot < 0 || hot === held)
                    return
                if (rail.editing)
                    Live.moveReaction(held, hot)
                else
                    send()
                held = hot
            }
            function send() {
                if (hot < 0 || rail.editing)
                    return
                Live.react(Live.reactions[hot].glyph)
                const k = faces.itemAt(hot)
                if (k)
                    k.pop()
            }
            onPressed: {
                if (held !== hot) {
                    held = hot
                    send()
                }
            }
            onReleased: held = -1
            onCanceled: held = -1
            Timer {
                interval: 160
                repeat: true
                running: sweep.pressed && !rail.editing
                onTriggered: sweep.send()
            }
            onWheel: wheel => {
                const dy = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 120 * 36
                rail.scroll = Math.max(0, Math.min(rail.maxScroll, rail.scroll - dy))
            }
        }
    }

    // ⋯: the order.
    IconButton {
        id: menuKey
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        implicitWidth: rail.key
        implicitHeight: 24
        iconName: rail.editing ? "check" : "ellipsis"
        active: rail.editing || reactMenu.visible
        tip: rail.editing ? "完成排序" : "表情：排序"
        onClicked: rail.editing ? rail.editing = false : reactMenu.popup(menuKey, -reactMenu.implicitWidth - 4, menuKey.height - reactMenu.implicitHeight)
    }
    PopMenu {
        id: reactMenu
        implicitWidth: 200
        PopAction {
            text: "调整顺序（拖动）"
            onTriggered: rail.editing = true
        }
        PopAction {
            text: "恢复默认顺序"
            enabled: Live.reactionOrder.length > 0
            onTriggered: Live.resetReactions()
        }
    }
}
