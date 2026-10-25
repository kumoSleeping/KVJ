import QtQuick

// One sticker: an image (animated when it is a GIF or WebP) or words, centred at
// (px, py) of `area`, `size` of its height tall and turned by `angle` degrees.
// The preview loads it small.
Item {
    id: root

    property string kind: "image"
    property string source: ""
    property string text: ""
    property real px: 0.5
    property real py: 0.5
    property real size: 0.3
    property real angle: 0
    property Item area
    property bool lite: false
    readonly property real tall: size * (area ? area.height : 0)
    readonly property bool words: kind === "text"
    readonly property bool moving: !words && /\.(gif|webp)$/i.test(source)
    readonly property Item shown: words ? label : moving ? motion : still

    width: shown.implicitHeight > 0 && !words ? tall * shown.implicitWidth / shown.implicitHeight : words ? label.implicitWidth : tall
    height: tall
    x: px * (area ? area.width : 0) - width / 2
    y: py * (area ? area.height : 0) - height / 2
    rotation: angle

    Image {
        id: still
        anchors.fill: parent
        visible: !root.words && !root.moving
        source: visible ? root.source : ""
        sourceSize.height: root.lite ? 256 : 1440
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: !root.lite
    }
    // GIFs play in the preview too, so what is posted is seen moving. Each
    // frame is decoded when due, never all kept: a long 1080p GIF cached whole
    // takes gigabytes, once for the projection and once for the preview.
    AnimatedImage {
        id: motion
        anchors.fill: parent
        visible: root.moving
        cache: false
        source: visible ? root.source : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
    }
    Text {
        id: label
        anchors.centerIn: parent
        visible: root.words
        text: root.words ? root.text : ""
        color: "white"
        font.pixelSize: Math.max(1, root.tall * 0.8)
        font.weight: Font.Bold
        style: Text.Outline
        styleColor: "#aa000000"
    }

    // Posted ones pop in on the projection.
    NumberAnimation on scale {
        running: !root.lite
        from: 0.6
        to: 1
        duration: 260
        easing.type: Easing.OutBack
    }
}
