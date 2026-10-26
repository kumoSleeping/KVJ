import QtQuick
import QtQuick.Controls.Basic
import KVJ

// A posted sticker on the operator's preview, where it is changed live: pressed,
// it is chosen and follows the pointer; chosen, a frame shows with a point at
// each corner that sizes it about its centre, a point above that turns it
// (Shift: in steps of 15°). While the desk is editing, every sticker shows a
// faint outline and a key on its top right corner that takes it down.
Sticker {
    id: frame

    required property var model
    // The id of the chosen sticker, and the way to choose one.
    property string chosen: ""
    property bool editing: false
    signal choose(string sid)
    signal resized(real size)

    readonly property bool isChosen: chosen === model.sid
    readonly property real handle: 9

    kind: model.kind
    source: model.source
    text: model.text
    px: model.px
    py: model.py
    size: model.size
    angle: model.angle
    lite: true

    function centre() {
        return area.mapFromItem(frame, frame.width / 2, frame.height / 2)
    }
    function change(changes) {
        Live.update(model.sid, changes)
    }

    // Move: the whole sticker.
    MouseArea {
        id: grab
        anchors.fill: parent
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property point start
        property real fromX
        property real fromY
        onPressed: mouse => {
            frame.choose(frame.model.sid)
            start = frame.area.mapFromItem(grab, mouse.x, mouse.y)
            fromX = frame.model.px
            fromY = frame.model.py
        }
        onPositionChanged: mouse => {
            const p = frame.area.mapFromItem(grab, mouse.x, mouse.y)
            frame.change({
                px: Math.max(0, Math.min(1, fromX + (p.x - start.x) / frame.area.width)),
                py: Math.max(0, Math.min(1, fromY + (p.y - start.y) / frame.area.height))
            })
        }
    }

    // While editing, a faint outline on the ones not chosen, so each is found.
    Rectangle {
        visible: frame.editing && !frame.isChosen
        anchors.fill: parent
        anchors.margins: -2
        color: "transparent"
        border.width: 1
        border.color: "#80ffffff"
    }

    // The frame, outside the picture so it never covers it.
    Rectangle {
        visible: frame.isChosen
        anchors.fill: parent
        anchors.margins: -2
        color: "transparent"
        border.width: 1
        border.color: "white"
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            color: "transparent"
            border.width: 1
            border.color: "#66000000"
        }
    }

    // Corners: size about the centre, as far as the pointer is from it. While
    // editing, the top right one gives way to the key that takes it down.
    Repeater {
        model: !frame.isChosen ? []
             : frame.editing ? [Qt.point(0, 0), Qt.point(0, 1), Qt.point(1, 1)]
             : [Qt.point(0, 0), Qt.point(1, 0), Qt.point(0, 1), Qt.point(1, 1)]
        Rectangle {
            id: corner
            required property point modelData
            x: modelData.x * frame.width - width / 2
            y: modelData.y * frame.height - height / 2
            width: frame.handle
            height: frame.handle
            color: "white"
            border.width: 1
            border.color: "#99000000"
            MouseArea {
                id: pull
                anchors.fill: parent
                anchors.margins: -5
                cursorShape: corner.modelData.x === corner.modelData.y ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                property real from
                property real reach
                function distance(mouse) {
                    const c = frame.centre()
                    const p = frame.area.mapFromItem(pull, mouse.x, mouse.y)
                    return Math.max(1, Math.hypot(p.x - c.x, p.y - c.y))
                }
                onPressed: mouse => {
                    from = frame.model.size
                    reach = distance(mouse)
                }
                onPositionChanged: mouse => {
                    const size = Math.max(0.03, Math.min(1.5, from * distance(mouse) / reach))
                    frame.change({ size: size })
                    frame.resized(size)
                }
            }
        }
    }

    // Above the top edge: turn.
    Rectangle {
        visible: frame.isChosen
        x: frame.width / 2 - 0.5
        y: -20
        width: 1
        height: 18
        color: "white"
    }
    Rectangle {
        id: turn
        visible: frame.isChosen
        x: frame.width / 2 - width / 2
        y: -20 - height / 2
        width: frame.handle + 2
        height: frame.handle + 2
        radius: width / 2
        color: "white"
        border.width: 1
        border.color: "#99000000"
        MouseArea {
            id: twist
            anchors.fill: parent
            anchors.margins: -5
            cursorShape: Qt.CrossCursor
            property real from
            property real start
            function bearing(mouse) {
                const c = frame.centre()
                const p = frame.area.mapFromItem(twist, mouse.x, mouse.y)
                return Math.atan2(p.y - c.y, p.x - c.x) * 180 / Math.PI
            }
            onPressed: mouse => {
                from = frame.model.angle
                start = bearing(mouse)
            }
            onPositionChanged: mouse => {
                let angle = from + bearing(mouse) - start
                angle = ((angle + 180) % 360 + 360) % 360 - 180
                if (mouse.modifiers & Qt.ShiftModifier)
                    angle = Math.round(angle / 15) * 15
                frame.change({ angle: angle })
            }
            onDoubleClicked: frame.change({ angle: 0 })
        }
    }

    // Centred on the top right corner, so it turns with the sticker and stays on
    // it, but kept upright: take it down.
    Rectangle {
        visible: frame.editing
        z: 2
        x: frame.width - width / 2
        y: -height / 2
        width: 18
        height: 18
        radius: 9
        color: "#cc000000"
        border.width: 1
        border.color: "#b3ffffff"
        rotation: -frame.angle
        Text {
            anchors.centerIn: parent
            text: "×"
            color: "white"
            font.pixelSize: 14
            font.weight: Font.DemiBold
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -3
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            ToolTip.visible: containsMouse
            ToolTip.delay: 600
            ToolTip.text: "撤下"
            onClicked: {
                if (frame.isChosen)
                    frame.choose("")
                Live.unpost(frame.model.sid)
            }
        }
    }
}
