import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The effects as a narrow rail at the window's right edge, top to bottom in
// the order they apply: each a small key with a drawing of what it does (no
// name; the name is in its tip) and its number key in a corner, its strength
// ink filling it from the left. A press turns it on at the strength it looks
// best at, or off, and dragged on up or down switches the others it passes
// the same way; dragged sideways (or the wheel) it sets the strength; a
// double-click brings back the best strength. The ⋯ key at the foot holds
// 全关, the order (dragging the keys while it is on) and the kept strengths.
Item {
    id: rail

    // Dragging the keys changes their order while this is on.
    property bool editing: false
    // This computer draws in software: no effects show.
    readonly property bool software: GraphicsInfo.api === GraphicsInfo.Software

    readonly property int count: Live.chain.count
    readonly property int gap: 3
    // As large as the rail's height allows, between 26 and 40.
    readonly property int key: Math.max(26, Math.min(40, Math.floor((height - menuKey.height - 8 - gap * count) / Math.max(1, count))))

    implicitWidth: 40
    Layout.preferredWidth: key
    Layout.fillWidth: false

    function nameOf(k) {
        const i = Live.kind(k)
        return i >= 0 ? Live.effects[i].name : ""
    }

    Column {
        id: keys
        width: parent.width
        spacing: rail.gap
        Repeater {
            model: Live.chain
            Rectangle {
                id: fx
                required property string key
                required property string name
                required property int index
                readonly property real level: Live.level[key] || 0
                readonly property bool on: level > 0
                readonly property bool focused: Live.focused === key
                width: rail.key
                height: rail.key
                radius: Theme.radius - 1
                color: hot.pressed && !on ? Theme.selected : hot.containsMouse ? Theme.hover : Theme.inset
                border.width: rail.editing || on ? 1 : 0
                border.color: on ? Theme.text : Theme.line
                Behavior on color { ColorAnimation { duration: 90 } }

                Glyph {
                    anchors.centerIn: parent
                    size: Math.round(rail.key * 0.62)
                    kind: fx.key
                    ink: hot.containsMouse || fx.on ? Theme.text : Theme.body
                }
                // The strength: ink filling it from the left, the drawing
                // turned light where the ink is.
                Item {
                    width: Math.round(parent.width * fx.level)
                    height: parent.height
                    clip: true
                    Rectangle {
                        width: fx.width
                        height: fx.height
                        radius: fx.radius
                        color: hot.pressed ? Theme.body : Theme.text
                        Glyph {
                            anchors.centerIn: parent
                            size: Math.round(rail.key * 0.62)
                            kind: fx.key
                            ink: Theme.bg
                            lit: true
                        }
                    }
                }
                // Its number key, for the first ten.
                Text {
                    x: 3
                    y: 1
                    visible: Live.keysOn && fx.index < 10 && rail.key >= 30
                    text: String((fx.index + 1) % 10)
                    font.pixelSize: 8
                    font.features: { "tnum": 1 }
                    font.weight: fx.focused ? Font.Bold : Font.Normal
                    color: fx.level > 0.15 ? Theme.faint : Theme.muted
                }
                // A strength of its own was kept (see Live.tune).
                Rectangle {
                    visible: Live.custom[fx.key] !== undefined
                    x: parent.width - 6
                    y: 3
                    width: 3
                    height: 3
                    radius: 1.5
                    color: fx.level > 0.9 ? Theme.faint : Theme.muted
                }
                // The one , and . tune: a ring round it.
                Rectangle {
                    visible: fx.focused && !rail.editing
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: parent.radius + 2
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.muted
                }

                // Pressed, it switches (on at its best strength, or off);
                // dragged on up or down over the others, it switches them the
                // same way, and dragged back, those it leaves go back to how
                // they were, the pressed one too once the drag has left it
                // and returns. Dragged sideways instead, it sets the strength:
                // the whole range over 150 px, finer with Shift.
                MouseArea {
                    id: hot
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: rail.editing ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                                              : mode === "tune" ? Qt.SizeHorCursor : Qt.PointingHandCursor
                    property bool turning: false
                    property bool swept: false
                    property var before: ({})
                    property point from
                    property real fromLevel: 0
                    // "" until the drag shows its way, then "sweep" or "tune".
                    property string mode: ""
                    onPressed: mouse => {
                        from = mapToItem(keys, mouse.x, mouse.y)
                        mode = ""
                        if (rail.editing)
                            return
                        before = Live.level
                        fromLevel = fx.level
                        swept = false
                        turning = !fx.on
                        Live.switchEffect(fx.key, turning)
                    }
                    onPositionChanged: mouse => {
                        if (!pressed)
                            return
                        const p = mapToItem(keys, mouse.x, mouse.y)
                        const to = Math.max(0, Math.min(rail.count - 1, Math.floor(p.y / (rail.key + rail.gap))))
                        if (rail.editing) {
                            Live.moveEffect(fx.index, to)
                            return
                        }
                        const dx = p.x - from.x, dy = p.y - from.y
                        if (mode === "" && Math.abs(dx) > 5 && Math.abs(dx) > Math.abs(dy)) {
                            mode = "tune"
                            // Not a switch after all: back as it was.
                            Live.setLevel(fx.key, fromLevel)
                        } else if (mode === "" && Math.abs(dy) > 5) {
                            mode = "sweep"
                        }
                        if (mode === "tune") {
                            const range = (mouse.modifiers & Qt.ShiftModifier) ? 600 : 150
                            Live.focused = fx.key
                            Live.setLevel(fx.key, Math.max(0, Math.min(1, fromLevel + dx / range)))
                        } else if (mode === "sweep") {
                            if (to !== fx.index)
                                swept = true
                            const back = swept && to === fx.index
                            const lo = Math.min(fx.index, to)
                            const hi = Math.max(fx.index, to)
                            for (let i = 0; i < rail.count; ++i) {
                                const k = Live.chain.get(i).key
                                if (!back && i >= lo && i <= hi)
                                    Live.switchEffect(k, turning)
                                else if (Live.amount(k) !== (before[k] || 0))
                                    Live.setLevel(k, before[k] || 0)
                            }
                        }
                    }
                    onReleased: mode = ""
                    onCanceled: mode = ""
                    onDoubleClicked: {
                        if (rail.editing)
                            return
                        Live.focused = fx.key
                        Live.setLevel(fx.key, 0)
                        Live.switchEffect(fx.key, true)
                    }
                    onWheel: wheel => {
                        if (rail.editing)
                            return
                        const step = wheel.pixelDelta.x !== 0 || wheel.pixelDelta.y !== 0
                                   ? (wheel.pixelDelta.y - wheel.pixelDelta.x) / 400 : wheel.angleDelta.y / 120 * 0.02
                        Live.focused = fx.key
                        Live.setLevel(fx.key, Math.max(0, Math.min(1, fx.level + step)))
                    }
                    ToolTip.visible: (containsMouse && !rail.editing && mode !== "sweep") || mode === "tune"
                    ToolTip.delay: mode === "tune" ? 0 : 500
                    ToolTip.text: fx.name + " · " + (fx.on ? Math.round(fx.level * 100) + "%" : "关")
                }
            }
        }
    }

    // ⋯: 全关, the order, the kept strengths.
    IconButton {
        id: menuKey
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        implicitWidth: rail.key
        implicitHeight: 24
        iconName: rail.editing ? "check" : "ellipsis"
        active: rail.editing || fxMenu.visible
        tip: rail.editing ? "完成排序" : rail.software ? "这台电脑以软件方式绘制，效果不会出现" : "效果：全关、排序、强度"
        onClicked: rail.editing ? rail.editing = false : fxMenu.popup(menuKey, -fxMenu.implicitWidth - 4, menuKey.height - fxMenu.implicitHeight)
        // This computer draws in software: no effects show.
        Rectangle {
            visible: rail.software
            x: parent.width - 8
            y: 2
            width: 6
            height: 6
            radius: 3
            color: Theme.warn
        }
    }
    PopMenu {
        id: fxMenu
        implicitWidth: 230
        PopAction {
            text: "全关"
            enabled: Live.effectsOn
            onTriggered: Live.resetEffects()
        }
        PopAction {
            text: "调整顺序（拖动，上面的先作用）"
            onTriggered: rail.editing = true
        }
        PopAction {
            text: "强度恢复默认推荐"
            enabled: Live.customized
            onTriggered: Live.resetPresets()
        }
    }

    // What each effect does, drawn small: `ink` for the strokes (the key's
    // own ink), colours only where colour is the point (RGB, 色相, 故障).
    // Drawn at the screen's pixel density so it stays sharp.
    component Glyph: Item {
        id: glyph
        property int size: 22
        property string kind: ""
        property color ink: "black"
        property bool lit: false
        width: size
        height: size
        Canvas {
            id: canvas
            readonly property real dpr: Math.max(1, glyph.Screen.devicePixelRatio)
            width: glyph.size * dpr
            height: glyph.size * dpr
            scale: 1 / dpr
            transformOrigin: Item.TopLeft
            antialiasing: true
            onPaint: {
                const c = getContext("2d")
                c.reset()
                c.scale(width / 24, height / 24)
                glyph.draw(c)
            }
        }
        function draw(c) {
            const ink = String(glyph.ink)
            // As "rgba(…)": a colour's own string puts alpha first, which canvas misreads.
            const q = glyph.ink
            const rgba = a => "rgba(" + Math.round(q.r * 255) + "," + Math.round(q.g * 255) + "," + Math.round(q.b * 255) + "," + a + ")"
            const box = (x, y, w, h, r) => {
                c.beginPath()
                c.moveTo(x + r, y)
                c.arcTo(x + w, y, x + w, y + h, r)
                c.arcTo(x + w, y + h, x, y + h, r)
                c.arcTo(x, y + h, x, y, r)
                c.arcTo(x, y, x + w, y, r)
                c.closePath()
            }
            c.lineCap = "round"
            c.lineJoin = "round"
            c.strokeStyle = ink
            c.fillStyle = ink
            c.lineWidth = 1.8
            switch (glyph.kind) {
            case "mosaic": {
                // Big blocks in a few shades.
                const shades = [1, 0.35, 0.7, 0.2, 0.55, 0.9, 0.3, 0.75, 0.15]
                for (let i = 0; i < 9; ++i) {
                    c.fillStyle = rgba(shades[i])
                    c.fillRect(2 + (i % 3) * 7, 2 + Math.floor(i / 3) * 7, 6.4, 6.4)
                }
                break
            }
            case "rgb": {
                // One shape three times, in red, green and blue, pulled apart.
                c.globalAlpha = glyph.lit ? 0.95 : 0.85
                const parts = [["#ff3b30", -3.2], ["#34c759", 0], ["#0a84ff", 3.2]]
                c.lineWidth = 2.2
                for (const [col, dx] of parts) {
                    c.strokeStyle = col
                    c.beginPath()
                    c.arc(12 + dx, 12, 6.5, 0, Math.PI * 2)
                    c.stroke()
                }
                break
            }
            case "tiles":
                // The picture repeated, three by three.
                for (let i = 0; i < 9; ++i) {
                    box(2.5 + (i % 3) * 6.8, 2.5 + Math.floor(i / 3) * 6.8, 5.6, 5.6, 1.2)
                    c.fill()
                }
                break
            case "lens": {
                // A grid swelling in the middle.
                c.lineWidth = 1.4
                c.beginPath()
                c.arc(12, 12, 9.5, 0, Math.PI * 2)
                c.stroke()
                for (const k of [-1, 1]) {
                    c.beginPath()
                    c.moveTo(12 + k * 4, 3.4)
                    c.quadraticCurveTo(12 + k * 8.6, 12, 12 + k * 4, 20.6)
                    c.stroke()
                    c.beginPath()
                    c.moveTo(3.4, 12 + k * 4)
                    c.quadraticCurveTo(12, 12 + k * 8.6, 20.6, 12 + k * 4)
                    c.stroke()
                }
                c.beginPath()
                c.moveTo(12, 2.5)
                c.lineTo(12, 21.5)
                c.moveTo(2.5, 12)
                c.lineTo(21.5, 12)
                c.stroke()
                break
            }
            case "zoom":
                // Streaks out from the middle.
                c.lineWidth = 1.7
                for (let i = 0; i < 12; ++i) {
                    const a = i * Math.PI / 6 + 0.26
                    const r0 = i % 2 ? 5.5 : 3.8
                    const r1 = i % 2 ? 10.5 : 9
                    c.beginPath()
                    c.moveTo(12 + Math.cos(a) * r0, 12 + Math.sin(a) * r0)
                    c.lineTo(12 + Math.cos(a) * r1, 12 + Math.sin(a) * r1)
                    c.stroke()
                }
                c.beginPath()
                c.arc(12, 12, 1.6, 0, Math.PI * 2)
                c.fill()
                break
            case "wave":
                // Ripples.
                for (let r = 0; r < 3; ++r) {
                    c.beginPath()
                    for (let x = 2; x <= 22; x += 0.5) {
                        const y = 6 + r * 6 + Math.sin((x - 2) / 20 * Math.PI * 2 * 1.5 + r * 0.8) * 2.2
                        if (x === 2)
                            c.moveTo(x, y)
                        else
                            c.lineTo(x, y)
                    }
                    c.stroke()
                }
                break
            case "glitch":
                // Bands torn sideways, a colour edge on two.
                c.fillStyle = "#ff2d95"
                c.fillRect(7, 8.4, 13, 3)
                c.fillStyle = "#00c7d4"
                c.fillRect(2, 14.6, 12, 3)
                c.fillStyle = ink
                c.fillRect(3, 3, 15, 3)
                c.fillRect(5.5, 9, 13, 3)
                c.fillRect(3.5, 15.2, 12, 3)
                c.fillRect(8, 20, 13, 2.2)
                break
            case "scan":
                // A screen's lines.
                c.lineWidth = 1.4
                box(2.5, 3.5, 19, 17, 2.5)
                c.stroke()
                c.lineWidth = 1.2
                for (let y = 7; y <= 17.5; y += 2.6) {
                    c.strokeStyle = rgba(y > 11 && y < 14 ? 1 : 0.55)
                    c.beginPath()
                    c.moveTo(5, y)
                    c.lineTo(19, y)
                    c.stroke()
                }
                break
            case "halftone":
                // Dots, large to small.
                for (let i = 0; i < 4; ++i)
                    for (let j = 0; j < 4; ++j) {
                        const r = 2.6 - (i + j) * 0.32
                        c.beginPath()
                        c.arc(4 + i * 5.3, 4 + j * 5.3, Math.max(0.6, r), 0, Math.PI * 2)
                        c.fill()
                    }
                break
            case "posterize":
                // A smooth fall in a few flat steps.
                for (let i = 0; i < 4; ++i) {
                    c.fillStyle = rgba(1 - i * 0.26)
                    c.fillRect(2.5 + i * 4.9, 3 + i * 2.5, 4.4, 18 - i * 2.5)
                }
                break
            case "hue": {
                // The colour wheel.
                const cols = ["#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#00c7d4", "#0a84ff", "#af52de", "#ff2d95"]
                for (let i = 0; i < cols.length; ++i) {
                    c.fillStyle = cols[i]
                    c.beginPath()
                    c.moveTo(12, 12)
                    c.arc(12, 12, 9.5, i * Math.PI / 4 - Math.PI / 2, (i + 1) * Math.PI / 4 - Math.PI / 2 + 0.02)
                    c.closePath()
                    c.fill()
                }
                c.fillStyle = glyph.lit ? Theme.text.toString() : Theme.inset.toString()
                c.beginPath()
                c.arc(12, 12, 3.6, 0, Math.PI * 2)
                c.fill()
                break
            }
            case "mono":
                // Half dark, half light.
                c.beginPath()
                c.arc(12, 12, 9, 0, Math.PI * 2)
                c.stroke()
                c.beginPath()
                c.arc(12, 12, 9, -Math.PI / 2, Math.PI / 2, true)
                c.closePath()
                c.fill()
                break
            }
        }
        onInkChanged: canvas.requestPaint()
        onKindChanged: canvas.requestPaint()
        onSizeChanged: canvas.requestPaint()
    }
}
