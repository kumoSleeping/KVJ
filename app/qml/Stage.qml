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
    // How each posted sticker is drawn; the operator's preview puts handles on them.
    property Component stickerDelegate: posted
    // The stickers on the air drawn here; the board draws its own (those it
    // stages) over it instead.
    property bool showStickers: true

    // One clock for everything that moves, running only while something does.
    property real now: Date.now()
    readonly property bool shown: Window.window ? Window.window.visible : false
    readonly property bool moving: shown && (overlay.busy || Live.effectsMoving || Switcher.fading)

    FrameAnimation {
        running: !stage.lite && stage.moving
        onTriggered: stage.now = Date.now()
    }
    // Smoother while a dissolve lasts, so it reads as one.
    Timer {
        interval: Switcher.fading ? 33 : 83
        repeat: true
        running: stage.lite && stage.moving
        onTriggered: stage.now = Date.now()
    }

    Item {
        id: picture
        anchors.fill: parent
    }

    // The effects that are on, a pass each in the desk's order, each reading
    // the picture the one before made; the last one is what is seen. No
    // effect, no pass: the picture is drawn straight. The software renderer
    // has no shaders and would draw nothing.
    readonly property string wanted: GraphicsInfo.api === GraphicsInfo.Software ? "" : Live.active.join(",")
    // Rebuilt only when the passes change, not on every move of a slider.
    property var passList: []
    onWantedChanged: if (wanted !== passList.join(",")) passList = wanted ? wanted.split(",") : []
    ShaderEffectSource {
        id: plain
        sourceItem: stage.passList.length ? picture : null
        hideSource: stage.passList.length > 0
        visible: false
    }
    Repeater {
        id: passes
        model: stage.passList
        Item {
            id: pass
            required property string modelData
            required property int index
            readonly property bool last: index === passes.count - 1
            readonly property alias output: output
            readonly property var input: {
                passes.count
                if (index === 0)
                    return plain
                const before = passes.itemAt(index - 1)
                return before ? before.output : null
            }
            anchors.fill: parent
            ShaderEffect {
                id: fx
                anchors.fill: parent
                visible: !!pass.input
                fragmentShader: "qrc:/qt/qml/KVJ/shaders/effects.frag.qsb"
                property var source: pass.input
                property real time: ((stage.now - Live.epoch) / 1000) % 1000
                property real aspect: stage.width / Math.max(1, stage.height)
                property real kind: Live.kind(pass.modelData)
                property real amount: Live.amount(pass.modelData)
            }
            ShaderEffectSource {
                id: output
                sourceItem: pass.last ? null : fx
                hideSource: !pass.last
                visible: false
            }
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
    Component {
        id: posted
        Sticker {
            required property var model
            kind: model.kind
            source: model.source
            text: model.text
            px: model.px
            py: model.py
            size: model.size
            angle: model.angle
            area: stage
            lite: stage.lite
        }
    }
    Repeater {
        model: stage.showStickers ? Live.stickers : null
        delegate: stage.stickerDelegate
    }
    Overlay {
        id: overlay
        anchors.fill: parent
        now: stage.now
        lite: stage.lite
    }
}
