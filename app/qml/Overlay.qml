import QtQuick
import QtQuick.Window
import KVJ

// Live messages over the picture: words fly across, reactions rise up the sides
// the way Google Meet's do, and a caption takes the middle. Everything moves on
// `now` (Date.now() ms) given by the Stage, so the projection and the preview,
// which advance it at different rates, show the same moment.
Item {
    id: overlay
    clip: true

    property real now: Date.now()
    // The preview: animated emoji step with `now` instead of playing on their own.
    property bool lite: false
    property int alive: 0
    readonly property bool captionUp: !!Live.caption && now - Live.caption.born < Live.caption.hold + 600
    readonly property bool busy: alive > 0 || captionUp
    // Spawn only where it is seen; a hidden window would only pile them up.
    readonly property bool shown: Window.window ? Window.window.visible : false
    readonly property real bulletSize: height / 16

    function texture(glyph) {
        for (let i = 0; i < faces.count; ++i) {
            const face = faces.itemAt(i)
            if (face && face.modelData.glyph === glyph)
                return face
        }
        return null
    }

    Connections {
        target: Live
        function onBullet(item) {
            if (overlay.shown)
                bullet.createObject(overlay, { item: item })
        }
        function onReaction(item) {
            if (overlay.shown && overlay.texture(item.emoji))
                riser.createObject(overlay, { item: item })
        }
    }

    // One decoder per emoji, however many are in the air: every copy draws the
    // texture of its emoji's source, which plays only while a copy is up.
    Repeater {
        id: faces
        model: Live.emoji
        ShaderEffectSource {
            id: face
            required property var modelData
            property int users: 0
            // Drawn (a pixel, clipped off the edge) so that its texture is kept.
            x: -2
            width: 1
            height: 1
            live: users > 0
            hideSource: true
            textureSize: Qt.size(224, 224)
            sourceItem: AnimatedImage {
                id: motion
                parent: overlay
                x: -width
                width: 224
                height: 224
                source: "emoji/" + face.modelData.file + ".webp"
                cache: false
                // Paused rather than stopped: a stopped one cannot be stepped.
                playing: face.users > 0
                paused: overlay.lite
            }
            // The preview steps it with its own clock, a frame a tick (WebP frames
            // are reached only one after another), wrapping to the start.
            Connections {
                target: overlay
                enabled: overlay.lite && face.users > 0 && motion.frameCount > 0
                function onNowChanged() {
                    motion.currentFrame = (motion.currentFrame + 1) % motion.frameCount
                }
            }
        }
    }

    Component {
        id: bullet
        Text {
            id: line
            required property var item
            readonly property real t: Math.max(0, overlay.now - item.born)
            readonly property real duration: (overlay.width + width) / Math.max(1, overlay.width) * 8000
            x: overlay.width - (overlay.width + width) * Math.min(1, t / duration)
            y: overlay.height * (0.04 + item.lane * 0.1)
            text: item.from ? item.from + "：" + item.text : item.text
            color: "white"
            font.pixelSize: overlay.bulletSize
            font.weight: Font.DemiBold
            style: Text.Outline
            styleColor: "#99000000"
            onTChanged: if (t > duration) destroy()
            Component.onCompleted: overlay.alive += 1
            Component.onDestruction: overlay.alive -= 1
        }
    }

    // A reaction pops in at the foot of the screen, drifts up with a sway and a
    // tilt, and fades near the top. Many of one emoji at once also burst.
    Component {
        id: riser
        Item {
            id: rise
            required property var item
            readonly property var face: overlay.texture(item.emoji)
            readonly property real t: Math.max(0, overlay.now - item.born) / 1000
            readonly property real life: 3.8
            readonly property real p: Math.min(1, t / life)
            readonly property real size: overlay.height / 7
            // Where it started, which the riser itself leaves behind.
            readonly property real startX: item.x * overlay.width - size / 2
            readonly property real startY: overlay.height - size * 0.6

            function backOut(k) {
                const s = 1.9
                const u = k - 1
                return u * u * ((s + 1) * u + s) + 1
            }

            width: size
            height: size
            x: startX + Math.sin(t * 2.3 + item.seed * 6.283) * size * 0.32
            y: startY - overlay.height * 0.82 * (1 - Math.pow(1 - p, 1.5))

            ShaderEffect {
                anchors.fill: parent
                property variant source: rise.face
                scale: rise.t < 0.35 ? 0.4 + 0.6 * rise.backOut(rise.t / 0.35) : 1
                rotation: Math.sin(rise.t * 3.1 + rise.item.seed * 10) * 7
                opacity: Math.min(1, rise.t / 0.12) * (rise.p > 0.72 ? (1 - rise.p) / 0.28 : 1)
            }
            Repeater {
                model: rise.item.burst ? 7 : 0
                ShaderEffect {
                    required property int index
                    readonly property real angle: Math.PI * (1.1 + index * 0.8 / 6) + rise.item.seed * 0.3
                    readonly property real k: Math.min(1, rise.t / 0.9)
                    readonly property real reach: rise.size * 1.7 * (1 - Math.pow(1 - k, 3))
                    property variant source: rise.face
                    width: rise.size * 0.5
                    height: width
                    x: rise.startX - rise.x + rise.size / 4 + Math.cos(angle) * reach
                    y: rise.startY - rise.y + rise.size / 4 + Math.sin(angle) * reach
                    opacity: 1 - k
                    visible: k < 1
                }
            }

            onTChanged: if (t > life) destroy()
            Component.onCompleted: {
                overlay.alive += 1
                if (face)
                    face.users += 1
            }
            Component.onDestruction: {
                overlay.alive -= 1
                if (face)
                    face.users -= 1
            }
        }
    }

    // The caption: large in the middle, in and out softly.
    Text {
        readonly property real t: Live.caption ? Math.max(0, overlay.now - Live.caption.born) : 0
        readonly property real hold: Live.caption ? Live.caption.hold : 0
        anchors.centerIn: parent
        width: parent.width * 0.86
        visible: overlay.captionUp
        text: Live.caption ? Live.caption.text : ""
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: "white"
        font.pixelSize: overlay.height / 9
        font.weight: Font.Bold
        style: Text.Outline
        styleColor: "#aa000000"
        scale: t < 260 ? 0.86 + 0.14 * (t / 260) : 1
        opacity: t < 260 ? t / 260 : t > hold ? Math.max(0, 1 - (t - hold) / 600) : 1
    }
}
