import QtQuick
import KVJ

// One entry on a timeline row: its tempo a block a section with its BPM, its
// frames (upright strips of each frame's middle) over its sound's waveform
// (KDJ's whole-track preview, the part played dimmed), a line down through
// both where the tempo changes, and its name. `view` is the Timeline (its
// pps, viewLeft, emptyClip and tempoColor); `clip` is { entry, n, start,
// length } in seconds along the row.
Item {
    id: piece
    property var view
    property var clip
    property real stripWidth
    property int tempoHeight: 18
    property int filmHeight: 64
    property int waveHeight: 42
    property string playingId
    property real position
    // Dimmed: entries that are off, and silent ones.
    property bool dimOff
    property bool dimSilent
    property bool numbered
    property bool small
    readonly property var modelData: clip || view.emptyClip
    readonly property var entry: modelData.entry
    readonly property real cx: (modelData.start - view.viewLeft) * view.pps
    readonly property real cw: modelData.length * view.pps
    readonly property bool playing: entry.id === playingId
    x: Math.max(0, cx)
    width: Math.max(0, Math.min(cx + cw, stripWidth) - x)
    height: tempoHeight + filmHeight + 1 + waveHeight
    visible: width > 0

    Rectangle {
        anchors.fill: parent
        color: Theme.inset
    }
    // The entry's tempo, a block a section; its label stays
    // in view while any of the block is.
    Item {
        id: tempoLane
        width: parent.width
        height: piece.tempoHeight
        Repeater {
            model: wave.tempo
            Item {
                required property var modelData
                readonly property bool beat: modelData.bpm !== null && modelData.bpm !== undefined
                x: (modelData.start - wave.from) * piece.view.pps
                width: (modelData.end - modelData.start) * piece.view.pps
                height: tempoLane.height
                visible: x + width > 0 && x < tempoLane.width
                Rectangle {
                    anchors.fill: parent
                    anchors.topMargin: 2
                    anchors.bottomMargin: 2
                    anchors.leftMargin: 1
                    anchors.rightMargin: 1
                    radius: 3
                    color: piece.view.tempoColor(parent.modelData.bpm)
                    // A tempo its beats hardly fit is told with less ink.
                    opacity: !parent.beat || parent.modelData.confidence >= 0.15 ? 1 : 0.6
                }
                Text {
                    id: bpmLabel
                    readonly property string full: parent.beat ? Math.round(parent.modelData.bpm) + " BPM" : "无拍"
                    readonly property string brief: parent.beat ? "" + Math.round(parent.modelData.bpm) : ""
                    text: parent.width >= fullMetrics.width + 12 ? full : parent.width >= briefMetrics.width + 8 ? brief : ""
                    x: Math.max(5, Math.min(-parent.x + 5, parent.width - implicitWidth - 5))
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    color: parent.beat ? Theme.text : Theme.faint
                    TextMetrics { id: fullMetrics; font: bpmLabel.font; text: bpmLabel.full }
                    TextMetrics { id: briefMetrics; font: bpmLabel.font; text: bpmLabel.brief }
                }
            }
        }
        Text {
            visible: wave.findingTempo && wave.tempo.length === 0 && piece.width > 120
            x: Math.max(6, -piece.cx + 6)
            anchors.verticalCenter: parent.verticalCenter
            text: wave.analysing ? "" : "分析速度…"
            font.pixelSize: 10
            color: Theme.faint
        }
    }
    FilmStrip {
        y: piece.tempoHeight
        width: parent.width
        height: piece.filmHeight
        // Upright strips of each frame's middle: enough to
        // know the picture, and many more of them.
        cellAspect: 0.5
        visible: piece.entry.video
        source: visible ? piece.entry.path : ""
        duration: piece.entry.duration
        from: (piece.x - piece.cx) / piece.view.pps
        pxPerSec: piece.view.pps
        gap: Theme.inset
    }
    WaveStrip {
        id: wave
        y: piece.tempoHeight + piece.filmHeight + 1
        width: parent.width
        height: piece.waveHeight
        // A silent entry has no waveform and no tempo to find.
        source: piece.entry.silent ? "" : piece.entry.path
        from: (piece.x - piece.cx) / piece.view.pps
        pxPerSec: piece.view.pps
        background: Theme.inset
        // What has played of the entry on the screen, dimmed as in KDJ.
        Rectangle {
            visible: piece.playing
            width: Math.max(0, Math.min(parent.width, (piece.position - wave.from) * piece.view.pps))
            height: parent.height
            color: Theme.dark ? "#8c000000" : "#7dffffff"
        }
        Rectangle {
            visible: !wave.ready
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            color: Theme.line
        }
        Text {
            visible: wave.analysing && piece.width > 120
            anchors.centerIn: parent
            text: "分析波形…"
            font.pixelSize: 11
            color: Theme.faint
        }
        Text {
            visible: !!piece.entry.silent && piece.width > 80
            x: Math.max(6, -piece.cx + 6)
            anchors.verticalCenter: parent.verticalCenter
            text: "无声音"
            font.pixelSize: 11
            color: Theme.faint
        }
    }
    // Between the picture and the sound: the panel's tone.
    Rectangle {
        y: piece.tempoHeight + piece.filmHeight
        width: parent.width
        height: 1
        color: Theme.raised
    }
    // Where the tempo changes, down through the frames and the sound.
    Repeater {
        model: wave.tempo.slice(1)
        Rectangle {
            required property var modelData
            x: (modelData.start - wave.from) * piece.view.pps - 1.5
            visible: x > 0 && x < piece.width
            y: piece.tempoHeight
            width: 3
            height: piece.height - y
            color: "#59000000"
            Rectangle {
                x: 1
                width: 1
                height: parent.height
                color: "#d9ffffff"
            }
        }
    }
    // Entries following does not watch are dimmed.
    Rectangle {
        anchors.fill: parent
        visible: (piece.dimOff && piece.entry.enabled === false) || (piece.dimSilent && !!piece.entry.silent)
        color: Theme.raised
        opacity: 0.6
    }
    // Where one entry ends and the next begins: a step of the panel's tone.
    Rectangle {
        visible: piece.cx >= 0 && piece.modelData.start > 0
        width: 3
        height: parent.height
        color: Theme.raised
    }
    Rectangle {
        x: 6
        y: piece.tempoHeight + (piece.small ? 3 : 5)
        width: Math.min(name.implicitWidth + 12, piece.width - 12)
        height: piece.small ? 16 : 18
        radius: 4
        visible: width > 24
        color: "#99000000"
        Text {
            id: name
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            verticalAlignment: Text.AlignVCenter
            text: (piece.numbered ? piece.modelData.n + "  " : "") + piece.entry.title
            font.pixelSize: piece.small ? 10 : 11
            font.weight: piece.playing ? Font.DemiBold : Font.Normal
            color: "white"
            elide: Text.ElideRight
        }
    }
}
