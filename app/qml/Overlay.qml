import QtQuick

// Live messages over the picture: words fly across, emoji pop up and fade.
Item {
    id: overlay
    clip: true

    readonly property int lanes: Math.max(3, Math.floor(height / (bulletSize * 1.6)) - 1)
    readonly property real bulletSize: Math.max(24, height / 16)
    property int nextLane: 0

    function say(text) {
        const words = text.trim()
        if (!words.length)
            return
        const lane = nextLane
        nextLane = (nextLane + 1) % lanes
        bullet.createObject(overlay, { text: words, y: bulletSize * 0.6 + lane * bulletSize * 1.6 })
    }
    function pop(emoji) {
        const size = Math.max(64, height / 5)
        sticker.createObject(overlay, {
            text: emoji,
            x: size * 0.5 + Math.random() * Math.max(1, width - size * 2),
            y: size * 0.5 + Math.random() * Math.max(1, height - size * 2),
            size: size
        })
    }

    Component {
        id: bullet
        Text {
            id: line
            x: overlay.width
            color: "white"
            font.pixelSize: overlay.bulletSize
            font.weight: Font.DemiBold
            style: Text.Outline
            styleColor: "#99000000"
            NumberAnimation on x {
                to: -line.width
                duration: (overlay.width + line.width) / Math.max(1, overlay.width) * 8000
                onFinished: line.destroy()
            }
        }
    }
    Component {
        id: sticker
        Text {
            id: face
            property real size: 96
            font.pixelSize: size
            scale: 0
            transformOrigin: Item.Center
            SequentialAnimation {
                running: true
                NumberAnimation { target: face; property: "scale"; to: 1; duration: 280; easing.type: Easing.OutBack }
                PauseAnimation { duration: 1800 }
                ParallelAnimation {
                    NumberAnimation { target: face; property: "opacity"; to: 0; duration: 500 }
                    NumberAnimation { target: face; property: "y"; to: face.y - face.size * 0.4; duration: 500 }
                }
                ScriptAction { script: face.destroy() }
            }
        }
    }
}
