import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The effects as a rail of two columns at the window's right edge: each a
// small key with a drawing of what it does (no name; the name is in its tip),
// its strength ink filling it from the left. The first eight rows are the
// nanoKONTROL2's strips, the left key its knob and the right its fader (the
// keys show 1–8 and ⇧1–⇧8, the number keys that switch them); the rest of the
// effects follow below (Live.layout). A press turns an effect on at the
// strength it looks best at, or off, and dragged on up
// or down its column switches the others it passes the same way; dragged
// sideways (or the wheel) it sets the strength. The ⋯ key at the foot holds
// 全关, 分配控件 (press one key and then another: the two change places), the
// kept strengths and the controller. A knob or fader not yet level with its
// effect shows where it stands as an amber tick at the key's foot.
Item {
    id: rail

    // 分配控件: a press picks a key, a second press swaps the two.
    property bool editing: false
    property int picked: -1
    onEditingChanged: picked = -1
    // This computer draws in software: no effects show.
    readonly property bool software: GraphicsInfo.api === GraphicsInfo.Software

    readonly property int gap: 3
    // The room between the controller's rows and the rest.
    readonly property int apart: 10
    // One size always; a rail taller than its room scrolls with the wheel.
    readonly property int key: 36
    property real scroll: 0
    readonly property real maxScroll: Math.max(0, keys.height - view.height)
    readonly property bool scrolls: maxScroll > 0
    onMaxScrollChanged: scroll = Math.min(scroll, maxScroll)
    function scrollBy(dy) {
        scroll = Math.max(0, Math.min(maxScroll, scroll - dy))
    }

    implicitWidth: key * 2 + gap
    Layout.preferredWidth: key * 2 + gap
    Layout.fillWidth: false

    function nameOf(k) {
        const i = Live.kind(k)
        return i >= 0 ? Live.effects[i].name : ""
    }
    // Where place p's key sits in the column of keys.
    function placeY(p) {
        const row = Math.floor(p / 2)
        return row < 8 ? row * (key + gap) : 8 * (key + gap) - gap + apart + (row - 8) * (key + gap)
    }
    // The place under y in column `col` (0 left, 1 right), within p's part.
    function placeAt(y, col, p) {
        const rows = Math.ceil(Live.layout.length / 2)
        const lower = p >= Live.places
        const top = lower ? placeY(Live.places) : 0
        const first = lower ? 8 : 0
        const last = lower ? rows - 1 : 7
        const row = Math.max(first, Math.min(last, first + Math.floor((y - top) / (key + gap))))
        return Math.min(Live.layout.length - 1, row * 2 + col)
    }

    Item {
        id: view
        width: parent.width
        height: parent.height - menuKey.height - 8
        clip: true
        Item {
            id: keys
            y: -rail.scroll
            width: parent.width
            height: rail.placeY(Live.layout.length - 1) + rail.key
            Repeater {
                model: Live.layout
                FxKey {}
            }
        }
    }

    component FxKey: Rectangle {
        id: fx
        required property string modelData
        required property int index
        readonly property string key: modelData
        readonly property string name: rail.nameOf(key)
        readonly property int row: Math.floor(index / 2)
        readonly property int col: index % 2
        // On the controller: its strip (row), knob (left) or fader (right).
        readonly property bool placed: index < Live.places
        readonly property real hardware: placed && Midi.connected ? (col ? Live.faders[row] : Live.knobs[row]) : -1
        readonly property bool rate: Live.kind(key) >= 0 && !!Live.effects[Live.kind(key)].rate
        readonly property real level: Live.level[key] || 0
        readonly property bool on: level > 0
        readonly property bool focused: Live.focused === key
        x: col * (rail.key + rail.gap)
        y: rail.placeY(index)
        width: rail.key
        height: rail.key
        radius: Theme.radius - 1
        color: hot.pressed && !on ? Theme.selected : hot.containsMouse ? Theme.hover : Theme.inset
        border.width: rail.editing || on ? 1 : 0
        border.color: rail.picked === index ? Theme.warn : on ? Theme.text : Theme.line
        Behavior on color { ColorAnimation { duration: 90 } }

        Glyph {
            anchors.centerIn: parent
            size: Math.round(rail.key * 0.62)
            kind: fx.key
            ink: hot.containsMouse || fx.on ? Theme.text : Theme.body
        }
        // The strength: ink filling it from the left, the drawing turned
        // light where the ink is.
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
        // Its number key: 1–8 on the right, ⇧1–⇧8 on the left.
        Text {
            x: 3
            y: 1
            visible: Live.keysOn && fx.placed
            text: (fx.col ? "" : "⇧") + (fx.row + 1)
            font.pixelSize: 8
            font.features: { "tnum": 1 }
            font.weight: fx.focused ? Font.Bold : Font.Normal
            color: fx.level > 0.15 ? Theme.faint : Theme.muted
        }
        // Its knob or fader, not level with it yet: where it stands.
        Rectangle {
            visible: fx.hardware >= 0 && Math.abs(fx.hardware - fx.level) > 0.03 && !rail.editing
            x: Math.round(fx.hardware * (parent.width - width))
            y: parent.height - height
            width: 3
            height: 5
            radius: 1
            color: Theme.warn
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

        // Pressed, it switches (on at its best strength, or off); dragged on
        // up or down its column over the others, it switches them the same
        // way, and dragged back, those it leaves go
        // back to how they were, the pressed one too once the drag has left
        // it and returns. Dragged sideways instead, it sets the strength: the
        // whole range over 150 px, finer with Shift.
        MouseArea {
            id: hot
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            cursorShape: mode === "tune" ? Qt.SizeHorCursor : Qt.PointingHandCursor
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
                if (rail.editing) {
                    if (rail.picked < 0) {
                        rail.picked = fx.index
                    } else {
                        Live.swapPlaces(rail.picked, fx.index)
                        rail.picked = -1
                    }
                    return
                }
                before = Live.level
                fromLevel = fx.level
                swept = false
                turning = !fx.on
                Live.switchEffect(fx.key, turning)
            }
            onPositionChanged: mouse => {
                if (!pressed || rail.editing)
                    return
                const p = mapToItem(keys, mouse.x, mouse.y)
                const to = rail.placeAt(p.y, fx.col, fx.index)
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
                    const lower = fx.index >= Live.places
                    for (let i = fx.col; i < Live.layout.length; i += 2) {
                        if ((i >= Live.places) !== lower)
                            continue
                        const k = Live.layout[i]
                        if (!back && i >= lo && i <= hi)
                            Live.switchEffect(k, turning)
                        else if (Live.amount(k) !== (before[k] || 0))
                            Live.setLevel(k, before[k] || 0)
                    }
                }
            }
            onReleased: mode = ""
            onCanceled: mode = ""
            // A second quick press is a second switch, never a double-click.
            // The wheel up and down scrolls a rail that does not fit;
            // otherwise (and sideways) it sets the strength.
            onWheel: wheel => {
                const dy = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 120 * 36
                const dx = wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.angleDelta.x / 120 * 36
                if (rail.scrolls && Math.abs(dy) >= Math.abs(dx)) {
                    rail.scrollBy(dy)
                    return
                }
                if (rail.editing)
                    return
                const step = wheel.pixelDelta.x !== 0 || wheel.pixelDelta.y !== 0
                           ? (wheel.pixelDelta.y - wheel.pixelDelta.x) / 400 : wheel.angleDelta.y / 120 * 0.02
                Live.focused = fx.key
                Live.setLevel(fx.key, Math.max(0, Math.min(1, fx.level + step)))
            }
            ToolTip.visible: (containsMouse && mode !== "sweep") || mode === "tune"
            ToolTip.delay: mode === "tune" ? 0 : 500
            ToolTip.text: rail.editing ? fx.name + (rail.picked < 0 ? " · 按下再按另一个，两者换位" : " · 和选中的换位")
                        : fx.name + " · " + (fx.rate ? Live.stepName(fx.key) : fx.on ? Math.round(fx.level * 100) + "%" : "关")
                          + (fx.placed ? " · " + (fx.col ? "推子 " : "旋钮 ") + (fx.row + 1) : "")
                          + (fx.hardware >= 0 && Math.abs(fx.hardware - fx.level) > 0.03
                             ? " · " + (fx.col ? "推子" : "旋钮") + "在 " + Math.round(fx.hardware * 100) + "%，推动时逐渐对齐" : "")
        }
    }

    // What a fader or knob of the controller just set, beside its key for a
    // moment: "故障 · 45%". On this window only, never on the projection.
    property string hintKey: ""
    property string hintControl: ""
    Connections {
        target: Live
        function onTouched(key, control) {
            rail.hintKey = key
            rail.hintControl = control
            hint.opacity = 1
            hintFade.restart()
        }
    }
    Timer {
        id: hintFade
        interval: 1000
        onTriggered: hint.opacity = 0
    }
    Rectangle {
        id: hint
        readonly property int place: Live.layout.indexOf(rail.hintKey)
        visible: opacity > 0 && place >= 0
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 250 } }
        z: 100
        x: -width - 6
        y: Math.max(0, Math.min(rail.height - height, rail.placeY(place) - rail.scroll + (rail.key - height) / 2))
        width: hintText.implicitWidth + 16
        height: hintText.implicitHeight + 10
        radius: Theme.radius
        color: Theme.raised
        border.width: 1
        border.color: Theme.line
        Text {
            id: hintText
            anchors.centerIn: parent
            font.pixelSize: Theme.sizeSm
            font.features: { "tnum": 1 }
            color: Theme.text
            text: {
                const key = rail.hintKey
                if (!key)
                    return ""
                const name = rail.nameOf(key)
                const level = Live.level[key] || 0
                const i = Live.kind(key)
                if (i >= 0 && Live.effects[i].rate)
                    return name + " · " + Live.stepName(key)
                return name + " · " + (level > 0 ? Math.round(level * 100) + "%" : "关")
            }
        }
    }

    // ⋯: 全关, 分配控件, the kept strengths, the controller.
    IconButton {
        id: menuKey
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        implicitWidth: rail.key
        implicitHeight: 24
        iconName: rail.editing ? "check" : "ellipsis"
        active: rail.editing || fxMenu.visible
        tip: rail.editing ? "完成分配" : rail.software ? "这台电脑以软件方式绘制，效果不会出现"
           : Midi.dawMode ? "nanoKONTROL2 在 DAW 模式：拔下，按住 SET MARKER 和 CYCLE 再插上，换成 CC 模式"
           : "效果：全关、分配控件、强度、控制器"
        onClicked: rail.editing ? rail.editing = false : fxMenu.popup(menuKey, -fxMenu.implicitWidth - 4, menuKey.height - fxMenu.implicitHeight)
        // This computer draws in software (no effects show), or the
        // controller is not in CC mode.
        Rectangle {
            visible: rail.software || Midi.dawMode
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
            text: "分配控件（按两个键，两者换位）"
            onTriggered: rail.editing = true
        }
        PopAction {
            text: "分配恢复默认"
            enabled: Live.laidOutOwn
            onTriggered: Live.resetLayout()
        }
        PopAction {
            text: "强度恢复默认推荐"
            enabled: Live.customized
            onTriggered: Live.resetPresets()
        }
        PopAction {
            text: !Midi.enabled ? "使用 nanoKONTROL2" : Midi.connected ? "停用 nanoKONTROL2（已连接）" : "停用 nanoKONTROL2（未连接）"
            onTriggered: Live.setMidi(!Midi.enabled)
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
            case "mirror":
                // A shape and its reflection across a line.
                c.beginPath()
                c.moveTo(12, 2.5)
                c.lineTo(12, 21.5)
                c.stroke()
                c.beginPath()
                c.moveTo(10, 6)
                c.lineTo(3.5, 12)
                c.lineTo(10, 18)
                c.closePath()
                c.fill()
                c.fillStyle = rgba(0.45)
                c.beginPath()
                c.moveTo(14, 6)
                c.lineTo(20.5, 12)
                c.lineTo(14, 18)
                c.closePath()
                c.fill()
                break
            case "twirl":
                // A spiral.
                c.beginPath()
                for (let t = 0; t <= 1; t += 0.02) {
                    const a = t * Math.PI * 5
                    const r = 1 + t * 9
                    const x = 12 + Math.cos(a) * r, y = 12 + Math.sin(a) * r
                    if (t === 0)
                        c.moveTo(x, y)
                    else
                        c.lineTo(x, y)
                }
                c.stroke()
                break
            case "punch":
                // A small frame thrown out to a large one.
                c.lineWidth = 1.4
                box(8.5, 8.5, 7, 7, 1.2)
                c.stroke()
                box(2.5, 2.5, 19, 19, 2.5)
                c.stroke()
                for (const [x, y] of [[1, 1], [-1, 1], [1, -1], [-1, -1]]) {
                    c.beginPath()
                    c.moveTo(12 + x * 4.5, 12 + y * 4.5)
                    c.lineTo(12 + x * 8, 12 + y * 8)
                    c.stroke()
                }
                break
            case "shake":
                // A frame, and two thrown aside behind it.
                c.lineWidth = 1.4
                c.strokeStyle = rgba(0.35)
                box(2, 5.5, 15, 12, 2)
                c.stroke()
                box(7, 6.5, 15, 12, 2)
                c.stroke()
                c.strokeStyle = ink
                c.lineWidth = 1.8
                box(4.5, 4, 15, 12, 2)
                c.stroke()
                break
            case "ghost":
                // A figure, and a larger faint one leaving it.
                c.fillStyle = rgba(0.3)
                c.beginPath()
                c.arc(12, 8, 5.5, 0, Math.PI * 2)
                c.fill()
                c.fillRect(5, 14, 14, 8)
                c.fillStyle = ink
                c.beginPath()
                c.arc(12, 10, 3.5, 0, Math.PI * 2)
                c.fill()
                c.fillRect(7.5, 15, 9, 6)
                break
            case "rain":
                // Drops on glass, one running with a trail.
                for (const [x, y, r] of [[7, 7, 2.4], [16, 5, 1.6], [17, 15, 2.8], [6, 17, 1.4]]) {
                    c.beginPath()
                    c.arc(x, y, r, 0, Math.PI * 2)
                    c.stroke()
                }
                c.fillStyle = rgba(0.5)
                for (const y of [9.5, 12, 14])
                    c.fillRect(6.6, y, 0.9, 0.9)
                break
            case "fire": {
                // A flame.
                c.fillStyle = glyph.lit ? ink : "#ff5a1f"
                c.beginPath()
                c.moveTo(12, 2.5)
                c.bezierCurveTo(16, 7, 20, 10, 18.5, 15.5)
                c.bezierCurveTo(17.5, 19.5, 14.5, 21.5, 12, 21.5)
                c.bezierCurveTo(8, 21.5, 5, 18.5, 5.5, 14.5)
                c.bezierCurveTo(6, 11, 9, 10, 9.5, 6.5)
                c.bezierCurveTo(11, 8, 11.5, 9.5, 11.5, 11)
                c.bezierCurveTo(13, 8.5, 13, 5.5, 12, 2.5)
                c.closePath()
                c.fill()
                c.fillStyle = glyph.lit ? Theme.text.toString() : "#ffd23a"
                c.beginPath()
                c.moveTo(12, 12)
                c.bezierCurveTo(14.5, 14, 15, 16.5, 14, 18.5)
                c.bezierCurveTo(13, 20, 11, 20, 10, 18.5)
                c.bezierCurveTo(9, 16.5, 10.5, 15, 12, 12)
                c.closePath()
                c.fill()
                break
            }
            case "vhs":
                // A tape: two reels in a case.
                c.lineWidth = 1.4
                box(2.5, 5, 19, 14, 2)
                c.stroke()
                c.beginPath()
                c.arc(8.5, 11, 2.6, 0, Math.PI * 2)
                c.stroke()
                c.beginPath()
                c.arc(15.5, 11, 2.6, 0, Math.PI * 2)
                c.stroke()
                c.fillRect(7, 15.5, 10, 1.6)
                break
            case "edge":
                // Only an outline, glowing.
                c.lineWidth = 2.2
                c.strokeStyle = glyph.lit ? ink : "#ff2d95"
                c.beginPath()
                c.moveTo(3, 19)
                c.lineTo(9, 7)
                c.lineTo(13, 14)
                c.lineTo(16, 9)
                c.lineTo(21, 19)
                c.closePath()
                c.stroke()
                break
            case "duotone": {
                // Light as heat: blue to red to yellow.
                const g = c.createLinearGradient(3, 0, 21, 0)
                g.addColorStop(0, "#2a0a6b")
                g.addColorStop(0.45, "#e0261a")
                g.addColorStop(1, "#ffd21a")
                c.fillStyle = g
                box(2.5, 4, 19, 16, 2.5)
                c.fill()
                break
            }
            case "threshold":
                // Black and white only, a hard line between.
                c.beginPath()
                c.arc(12, 12, 9, 0, Math.PI * 2)
                c.stroke()
                c.fillRect(12, 3, 9, 18)
                c.globalCompositeOperation = "destination-in"
                c.beginPath()
                c.arc(12, 12, 9, 0, Math.PI * 2)
                c.fill()
                c.globalCompositeOperation = "source-over"
                c.beginPath()
                c.arc(12, 12, 9, 0, Math.PI * 2)
                c.stroke()
                break
            case "invert":
                // A frame half filled, the other half its negative.
                c.lineWidth = 1.4
                box(3, 5, 18, 14, 2)
                c.stroke()
                c.fillRect(12, 5, 9, 14)
                c.fillStyle = glyph.lit ? Theme.text.toString() : Theme.inset.toString()
                c.beginPath()
                c.arc(12, 12, 3.5, 0, Math.PI * 2)
                c.fill()
                c.fillStyle = ink
                c.beginPath()
                c.arc(12, 12, 3.5, Math.PI / 2, Math.PI * 1.5)
                c.fill()
                break
            case "flash":
            case "flashBlack": {
                // A burst, filled (white) or hollow (black).
                c.beginPath()
                for (let i = 0; i < 16; ++i) {
                    const a = i * Math.PI / 8 - Math.PI / 2
                    const r = i % 2 ? 4.5 : 10
                    const x = 12 + Math.cos(a) * r, y = 12 + Math.sin(a) * r
                    if (i === 0)
                        c.moveTo(x, y)
                    else
                        c.lineTo(x, y)
                }
                c.closePath()
                if (glyph.kind === "flash") {
                    c.stroke()
                } else {
                    c.fill()
                }
                break
            }
            case "strobe":
                // Flashes in a row.
                c.lineWidth = 1.6
                for (let i = 0; i < 3; ++i) {
                    const x = 4 + i * 8
                    c.beginPath()
                    c.moveTo(x + 2, 3)
                    c.lineTo(x - 1, 12)
                    c.lineTo(x + 3, 12)
                    c.lineTo(x, 21)
                    c.stroke()
                }
                break
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
