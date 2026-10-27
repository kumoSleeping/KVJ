import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// The reactions as a narrow rail beside the effects', top to bottom, as in
// Google Meet: the pointer on one plays it, a press sends one, held it sends a
// stream from along the foot of the screen, and swept up or down the stream
// changes to the one under the pointer. Swept out of the rail sideways (onto
// the effects, say) it keeps the last one: it never reaches past its own keys.
Item {
    id: rail

    readonly property int count: Live.emoji.length
    readonly property int gap: 3
    // As large as the rail's height allows, between 26 and 40, as the effects'.
    readonly property int key: Math.max(26, Math.min(40, Math.floor((height - gap * count) / Math.max(1, count))))

    implicitWidth: 40
    Layout.preferredWidth: key
    Layout.fillWidth: false
    clip: true

    Column {
        id: keys
        width: parent.width
        spacing: rail.gap
        Repeater {
            model: Live.emoji
            Rectangle {
                id: face
                required property var modelData
                required property int index
                readonly property bool hot: sweep.hot === index
                width: rail.key
                height: rail.key
                radius: Theme.radius - 1
                color: hot && sweep.pressed ? Theme.selected : hot ? Theme.hover : Theme.inset
                Behavior on color { ColorAnimation { duration: 90 } }
                AnimatedImage {
                    anchors.centerIn: parent
                    width: Math.round(rail.key * 0.7)
                    height: width
                    source: "emoji/" + face.modelData.file + ".webp"
                    cache: false
                    paused: !face.hot
                    scale: face.hot && sweep.pressed ? 1.1 : face.hot ? 1.2 : 1
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
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
            }
        }
    }

    MouseArea {
        id: sweep
        width: parent.width
        height: keys.height
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
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
        onHotChanged: {
            if (!pressed || hot < 0 || hot === held)
                return
            held = hot
            send()
        }
        function send() {
            if (hot >= 0)
                Live.react(Live.emoji[hot].glyph)
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
            running: sweep.pressed
            onTriggered: sweep.send()
        }
        ToolTip.visible: containsMouse && !pressed
        ToolTip.delay: 900
        ToolTip.text: "点一下发一个 · 按住连发 · 按住上下滑换表情"
    }
}
