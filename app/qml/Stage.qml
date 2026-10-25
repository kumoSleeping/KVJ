import QtQuick
import QtQuick.Window
import KVJ

// What the audience sees, at any size: the picture (this item's children)
// through the effects, the title of an audio-only entry, the posted stickers and
// the live overlay. The projection draws it in full; the operator's preview
// draws it `lite`, moving at a low steady rate instead of every display frame.
Item {
    id: stage

    property bool lite: false
    property var entry: null
    default property alias picture: picture.data

    // One clock for everything that moves, running only while something does.
    property real now: Date.now()
    readonly property bool shown: Window.window ? Window.window.visible : false
    readonly property bool moving: shown && (overlay.busy || Live.effectsMoving)

    FrameAnimation {
        running: !stage.lite && stage.moving
        onTriggered: stage.now = Date.now()
    }
    Timer {
        interval: 83
        repeat: true
        running: stage.lite && stage.moving
        onTriggered: stage.now = Date.now()
    }

    Item {
        id: picture
        anchors.fill: parent
        // No effect, no layer: the picture is drawn straight as before. The
        // software renderer has no shaders and would draw nothing.
        layer.enabled: Live.effectsOn && GraphicsInfo.api !== GraphicsInfo.Software
        layer.effect: ShaderEffect {
            fragmentShader: "qrc:/qt/qml/KVJ/shaders/effects.frag.qsb"
            property real time: ((stage.now - Live.epoch) / 1000) % 1000
            property real aspect: stage.width / Math.max(1, stage.height)
            property real mosaic: Live.amount("mosaic")
            property real rgb: Live.amount("rgb")
            property real tiles: Live.amount("tiles")
            property real lens: Live.amount("lens")
            property real zoom: Live.amount("zoom")
            property real wave: Live.amount("wave")
            property real glitch: Live.amount("glitch")
            property real scan: Live.amount("scan")
            property real halftone: Live.amount("halftone")
            property real posterize: Live.amount("posterize")
            property real hue: Live.amount("hue")
            property real mono: Live.amount("mono")
            property real vignette: Live.amount("vignette")
        }
    }
    Text {
        anchors.centerIn: parent
        width: parent.width * 0.8
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        visible: !!stage.entry && !stage.entry.video
        text: stage.entry ? stage.entry.title : ""
        color: "white"
        font.pixelSize: stage.height / 12
        font.weight: Font.DemiBold
    }
    Repeater {
        model: Live.stickers
        Sticker {
            required property var modelData
            sticker: modelData
            area: stage
            lite: stage.lite
        }
    }
    Overlay {
        id: overlay
        anchors.fill: parent
        now: stage.now
        lite: stage.lite
    }
}
