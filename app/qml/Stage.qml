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

    // The effects' shader drawn once, out of sight (two nearly transparent
    // pixels under the picture), for a moment after the stage first shows.
    // The first time after an update the system compiles it, which froze the
    // picture for about 0.1 s (M1, measured) the first time an effect came on;
    // on Windows it is compiled at every start. Here that happens while the
    // window opens instead.
    // Not in the projection window: nothing of the effects may hold it up as
    // it opens (on the Mac the main window's warming has done it for all).
    property bool warmUp: true
    property bool warmed: false
    readonly property bool warming: warmUp && shown && !warmed && GraphicsInfo.api !== GraphicsInfo.Software
    Timer {
        running: stage.warming
        interval: 1500
        onTriggered: stage.warmed = true
    }
    Loader {
        active: stage.warming
        width: 2
        height: 2
        sourceComponent: Item {
            Rectangle {
                id: ink
                width: 2
                height: 2
                color: "black"
            }
            ShaderEffectSource {
                id: inkSource
                sourceItem: ink
                hideSource: true
                visible: false
            }
            ShaderEffect {
                anchors.fill: parent
                opacity: 0.01
                fragmentShader: "qrc:/qt/qml/KVJ/shaders/effects.frag.qsb"
                property var source: inkSource
                property real time: 0
                property real aspect: 1
                property real kind: 99
                property real amount: 0
                property real synced: 0
                property real beat: 0
                property real shown: 1
            }
        }
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
                // Its rhythm (Live.rhythms): a moving effect goes through its
                // motion once a period, a still one shows for half of each.
                property real synced: Live.rhythmOf(pass.modelData) > 0 ? 1 : 0
                property real beat: synced ? Live.periodsAt(pass.modelData, stage.now) : 0
                property real shown: synced ? (Live.shownAt(pass.modelData, stage.now) ? 1 : 0) : 1
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
