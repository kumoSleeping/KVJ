import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Shapes
import KVJ

// The preview (PVW) and its slots' settings, with the key that puts it on the
// air. On the monitor a slot is chosen by pressing it, moved by dragging it and
// sized by its corners (edges snap to the picture's edges and middle; the
// arrow keys nudge it, Shift more). A curve mask shows its points there:
// dragged to shape it, a double-click on the slot adds one on the nearest
// stretch, Alt-click or Delete takes the chosen one away (three stay).
//
//   sources:    [{ id, name }] the picture sources on offer
//   textures:   the window's SourceTextures, or
//   sourceItem: id → Item (then the monitor takes its own)
//   aspect:     the projected picture's width / height
ColumnLayout {
    id: panel

    property var sources: []
    property SourceTextures textures: null
    property var sourceItem: null
    property real aspect: 16 / 9
    // The chosen slot (in Switcher.preview.slots) and, on a curve, point.
    property int selected: 0
    property int point: -1

    readonly property var layout: Switcher.preview
    readonly property var slots: layout && layout.slots ? layout.slots : []
    readonly property var slot: selected >= 0 && selected < slots.length ? slots[selected] : null
    readonly property bool curved: !!slot && slot.mask.shape === "path"
    onSlotsChanged: {
        if (selected >= slots.length)
            selected = slots.length - 1
        if (!curved || point >= slot.mask.points.length)
            point = -1
    }
    onSelectedChanged: point = -1

    spacing: 10

    function sourceName(id) {
        if (!id)
            return "未选"
        const s = (sources || []).find(s => s.id === id)
        return s ? s.name : id
    }
    function percent(v) {
        return String(Math.round(v * 1000) / 10)
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Heading {
            text: "合成预览"
        }
        Caption {
            text: "PVW"
        }
        Item { Layout.fillWidth: true }
        Text {
            visible: Switcher.pending
            text: "未应用"
            font.pixelSize: Theme.sizeXs
            color: Theme.warn
        }
    }

    // —— The monitor ——
    Item {
        id: frame
        // As tall as the picture's shape at this width, or less when the
        // panel is short; the picture fitted in it.
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: width / Math.max(0.2, panel.aspect)
        Layout.maximumHeight: width / Math.max(0.2, panel.aspect)
        Layout.minimumHeight: 60

        Rectangle {
            id: screen
            width: Math.min(frame.width, frame.height * panel.aspect)
            height: width / Math.max(0.2, panel.aspect)
            anchors.centerIn: parent
            color: "black"
            radius: 2
            clip: true

            Compositor {
                anchors.fill: parent
                layout: Switcher.preview
                textures: panel.textures
                sourceItem: panel.sourceItem
                operator: true
            }

            // Every slot's edge, faint; the chosen one's in full with its
            // corners.
            Repeater {
                model: panel.slots.length
                Rectangle {
                    id: edge
                    required property int index
                    readonly property var s: panel.slots[index]
                    readonly property bool chosen: index === panel.selected
                    x: s.x * screen.width
                    y: s.y * screen.height
                    width: s.w * screen.width
                    height: s.h * screen.height
                    z: chosen ? 2 : 1
                    color: "transparent"
                    border.width: chosen ? 1.5 : 1
                    border.color: chosen ? "#ffffff" : "#59ffffff"
                    Rectangle {
                        x: 4
                        y: 4
                        width: Math.max(16, badge.implicitWidth + 8)
                        height: 16
                        radius: 4
                        color: edge.chosen ? "#ffffff" : "#8c000000"
                        Text {
                            id: badge
                            anchors.centerIn: parent
                            text: edge.index + 1
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            color: edge.chosen ? "#000000" : "#ffffff"
                        }
                    }
                    Repeater {
                        model: edge.chosen && !panel.curved ? 4 : 0
                        Rectangle {
                            required property int index
                            x: (index % 2 ? edge.width : 0) - 4
                            y: (index > 1 ? edge.height : 0) - 4
                            width: 8
                            height: 8
                            radius: 2
                            color: "#ffffff"
                            border.width: 1
                            border.color: "#000000"
                        }
                    }
                }
            }

            // The chosen slot's curve and its points.
            Item {
                id: curveBox
                visible: panel.curved
                z: 3
                x: panel.slot ? panel.slot.x * screen.width : 0
                y: panel.slot ? panel.slot.y * screen.height : 0
                width: panel.slot ? panel.slot.w * screen.width : 0
                height: panel.slot ? panel.slot.h * screen.height : 0
                Shape {
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: "#ffffff"
                        strokeWidth: 1.5
                        PathPolyline {
                            path: panel.curved ? Switcher.curve(panel.slot.mask.points, 12).map(p => Qt.point(p[0] * curveBox.width, p[1] * curveBox.height)) : []
                        }
                    }
                }
                Repeater {
                    model: panel.curved ? panel.slot.mask.points : []
                    Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool chosen: index === panel.point
                        x: modelData[0] * curveBox.width - width / 2
                        y: modelData[1] * curveBox.height - height / 2
                        width: chosen ? 12 : 10
                        height: width
                        radius: width / 2
                        color: chosen ? "#ffffff" : "#000000"
                        border.width: 1.5
                        border.color: "#ffffff"
                    }
                }
            }

            MouseArea {
                id: hand
                anchors.fill: parent
                z: 4
                hoverEnabled: true
                focus: true
                // What a press caught: "", "move", "size", "point".
                property string mode: ""
                property int corner: 0
                property point from
                property var start: null

                function rectOf(s) {
                    return Qt.rect(s.x * width, s.y * height, s.w * width, s.h * height)
                }
                // What lies under (x, y): { mode, index, corner, point }.
                function hit(x, y) {
                    const near = (ax, ay) => Math.abs(ax - x) <= 7 && Math.abs(ay - y) <= 7
                    const s = panel.slot
                    if (s) {
                        const r = rectOf(s)
                        if (panel.curved) {
                            const pts = s.mask.points
                            for (let j = pts.length - 1; j >= 0; --j)
                                if (near(r.x + pts[j][0] * r.width, r.y + pts[j][1] * r.height))
                                    return { mode: "point", index: panel.selected, point: j }
                        } else {
                            for (let c = 0; c < 4; ++c)
                                if (near(r.x + (c % 2 ? r.width : 0), r.y + (c > 1 ? r.height : 0)))
                                    return { mode: "size", index: panel.selected, corner: c }
                        }
                    }
                    const order = panel.slots.map((s, i) => i).sort((a, b) => (panel.slots[b].z - panel.slots[a].z) || (b - a))
                    for (const i of order) {
                        const r = rectOf(panel.slots[i])
                        if (x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height)
                            return { mode: "move", index: i }
                    }
                    return { mode: "" }
                }
                // `v` pulled onto 0, ½ or 1 when within a few pixels of one.
                function snap(v, span) {
                    const reach = 6 / Math.max(1, span)
                    for (const t of [0, 0.5, 1])
                        if (Math.abs(v - t) < reach)
                            return t
                    return v
                }
                function snapEdges(a, size, span) {
                    const lo = snap(a, span)
                    if (lo !== a)
                        return lo
                    const hi = snap(a + size, span)
                    if (hi !== a + size)
                        return hi - size
                    const mid = snap(a + size / 2, span)
                    return mid !== a + size / 2 ? mid - size / 2 : a
                }

                cursorShape: {
                    const h = containsMouse || pressed ? hit(mouseX, mouseY) : { mode: "" }
                    if (pressed && mode === "move")
                        return Qt.ClosedHandCursor
                    return h.mode === "point" ? Qt.PointingHandCursor
                         : h.mode === "size" ? (h.corner === 0 || h.corner === 3 ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
                         : h.mode === "move" ? Qt.OpenHandCursor : Qt.ArrowCursor
                }

                onPressed: mouse => {
                    forceActiveFocus()
                    const h = hit(mouse.x, mouse.y)
                    mode = h.mode
                    if (h.mode === "point" && (mouse.modifiers & Qt.AltModifier)) {
                        mode = ""
                        panel.removePoint(h.point)
                        return
                    }
                    if (h.mode !== "")
                        panel.selected = h.index
                    if (h.mode === "point")
                        panel.point = h.point
                    corner = h.corner || 0
                    from = Qt.point(mouse.x, mouse.y)
                    start = panel.slot ? JSON.parse(JSON.stringify(panel.slot)) : null
                }
                onReleased: mode = ""
                onPositionChanged: mouse => {
                    if (!pressed || !start || mode === "")
                        return
                    const dx = (mouse.x - from.x) / width
                    const dy = (mouse.y - from.y) / height
                    if (mode === "move") {
                        Switcher.updateSlot(panel.selected, {
                            x: snapEdges(start.x + dx, start.w, width),
                            y: snapEdges(start.y + dy, start.h, height)
                        })
                    } else if (mode === "size") {
                        const min = 0.03
                        let x0 = start.x, y0 = start.y, x1 = start.x + start.w, y1 = start.y + start.h
                        if (corner % 2)
                            x1 = Math.max(x0 + min, snap(x1 + dx, width))
                        else
                            x0 = Math.min(x1 - min, snap(x0 + dx, width))
                        if (corner > 1)
                            y1 = Math.max(y0 + min, snap(y1 + dy, height))
                        else
                            y0 = Math.min(y1 - min, snap(y0 + dy, height))
                        Switcher.updateSlot(panel.selected, { x: x0, y: y0, w: x1 - x0, h: y1 - y0 })
                    } else if (mode === "point" && panel.point >= 0) {
                        const r = rectOf(start)
                        const pts = start.mask.points.slice()
                        pts[panel.point] = [Math.max(0, Math.min(1, (mouse.x - r.x) / Math.max(1, r.width))),
                                            Math.max(0, Math.min(1, (mouse.y - r.y) / Math.max(1, r.height)))]
                        Switcher.setMask(panel.selected, { points: pts })
                    }
                }
                onDoubleClicked: mouse => {
                    if (!panel.curved)
                        return
                    const r = rectOf(panel.slot)
                    if (mouse.x < r.x || mouse.x > r.x + r.width || mouse.y < r.y || mouse.y > r.y + r.height)
                        return
                    panel.addPoint((mouse.x - r.x) / Math.max(1, r.width), (mouse.y - r.y) / Math.max(1, r.height), r.width, r.height)
                }
                Keys.onPressed: event => {
                    if ((event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) && panel.point >= 0) {
                        panel.removePoint(panel.point)
                        event.accepted = true
                        return
                    }
                    const step = event.modifiers & Qt.ShiftModifier ? 0.02 : 0.005
                    const s = panel.slot
                    if (!s)
                        return
                    const moves = { [Qt.Key_Left]: [-step, 0], [Qt.Key_Right]: [step, 0], [Qt.Key_Up]: [0, -step], [Qt.Key_Down]: [0, step] }
                    const d = moves[event.key]
                    if (d) {
                        Switcher.updateSlot(panel.selected, { x: s.x + d[0], y: s.y + d[1] })
                        event.accepted = true
                    }
                }
            }
        }
        // The picture's edge.
        Rectangle {
            anchors.fill: screen
            anchors.margins: -1
            color: "transparent"
            radius: 3
            border.width: 1
            border.color: Theme.line
        }
    }

    // A point on the curve's nearest stretch to (x, y) (shares of the slot,
    // `w` × `h` pixels), or taken off it.
    function addPoint(x, y, w, h) {
        const pts = slot.mask.points.slice()
        let best = 0
        let bestD = Infinity
        for (let j = 0; j < pts.length; ++j) {
            const a = pts[j], b = pts[(j + 1) % pts.length]
            const ax = a[0] * w, ay = a[1] * h, bx = b[0] * w, by = b[1] * h, px = x * w, py = y * h
            const len = (bx - ax) * (bx - ax) + (by - ay) * (by - ay)
            const t = len > 0 ? Math.max(0, Math.min(1, ((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / len)) : 0
            const d = Math.hypot(px - (ax + t * (bx - ax)), py - (ay + t * (by - ay)))
            if (d < bestD) {
                bestD = d
                best = j
            }
        }
        pts.splice(best + 1, 0, [x, y])
        Switcher.setMask(selected, { points: pts })
        point = best + 1
    }
    function removePoint(j) {
        if (!curved || slot.mask.points.length <= 3)
            return
        const pts = slot.mask.points.slice()
        pts.splice(j, 1)
        point = -1
        Switcher.setMask(selected, { points: pts })
    }

    // —— The slots ——
    RowLayout {
        Layout.fillWidth: true
        spacing: 4
        Flow {
            Layout.fillWidth: true
            spacing: 4
            Repeater {
                model: panel.slots.length
                TextButton {
                    required property int index
                    text: (index + 1) + " " + panel.sourceName(panel.slots[index].source)
                    flat: index !== panel.selected
                    font.weight: index === panel.selected ? Font.DemiBold : Font.Medium
                    onClicked: panel.selected = index
                }
            }
        }
        IconButton {
            iconName: "plus"
            tip: "加一个画面"
            onClicked: panel.selected = Switcher.addSlot(panel.sources && panel.sources.length ? panel.sources[0].id : "")
        }
        IconButton {
            iconName: "trash"
            tip: "去掉这个画面"
            enabled: !!panel.slot
            onClicked: Switcher.removeSlot(panel.selected)
        }
    }

    // —— The chosen slot ——
    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 10
        rowSpacing: 6
        enabled: !!panel.slot

        Caption { text: "画面源" }
        Select {
            Layout.fillWidth: true
            readonly property var ids: [""].concat((panel.sources || []).map(s => s.id))
            model: ["未选"].concat((panel.sources || []).map(s => s.name))
            currentIndex: panel.slot ? ids.indexOf(panel.slot.source) : 0
            displayText: panel.slot ? panel.sourceName(panel.slot.source) : ""
            onActivated: index => Switcher.updateSlot(panel.selected, { source: ids[index] })
        }

        Caption { text: "适配" }
        Select {
            Layout.fillWidth: true
            model: ["铺满（裁切）", "完整（留边）"]
            currentIndex: panel.slot && panel.slot.fit === "contain" ? 1 : 0
            onActivated: index => Switcher.updateSlot(panel.selected, { fit: index === 1 ? "contain" : "cover" })
        }

        Caption { text: "遮罩" }
        Select {
            Layout.fillWidth: true
            model: ["矩形", "圆角", "圆形", "曲线"]
            currentIndex: panel.slot ? Math.max(0, Switcher.shapes.indexOf(panel.slot.mask.shape)) : 0
            onActivated: index => Switcher.setMask(panel.selected, { shape: Switcher.shapes[index] })
        }

        Caption {
            text: "圆角"
            visible: !!panel.slot && panel.slot.mask.shape === "round"
        }
        Seek {
            Layout.fillWidth: true
            visible: !!panel.slot && panel.slot.mask.shape === "round"
            from: 0
            to: 0.5
            value: panel.slot ? panel.slot.mask.radius : 0
            onMoved: Switcher.setMask(panel.selected, { radius: value })
        }

        Caption { text: "羽化" }
        Seek {
            Layout.fillWidth: true
            from: 0
            to: 0.3
            value: panel.slot ? panel.slot.mask.feather : 0
            onMoved: Switcher.setMask(panel.selected, { feather: value })
        }

        Caption {
            text: "位置 %"
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            Repeater {
                model: [{ key: "x", tip: "X" }, { key: "y", tip: "Y" }, { key: "w", tip: "宽" }, { key: "h", tip: "高" }]
                Field {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.minimumWidth: 40
                    leftPadding: 6
                    rightPadding: 6
                    horizontalAlignment: TextInput.AlignRight
                    text: panel.slot ? panel.percent(panel.slot[modelData.key]) : ""
                    placeholderText: modelData.tip
                    validator: DoubleValidator { bottom: -200; top: 300; decimals: 1 }
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: modelData.tip
                    onEditingFinished: {
                        const v = parseFloat(text)
                        if (!isNaN(v)) {
                            const changes = {}
                            changes[modelData.key] = v / 100
                            Switcher.updateSlot(panel.selected, changes)
                        }
                    }
                }
            }
        }
        Item {
            visible: panel.curved
            implicitWidth: 1
        }
        Text {
            Layout.fillWidth: true
            visible: panel.curved
            text: "拖动点改形状 · 双击加点 · Alt+点击或 Delete 删点"
            wrapMode: Text.Wrap
            font.pixelSize: Theme.sizeXs
            color: Theme.faint
        }
    }

    // —— On the air ——
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Toggle {
            text: "渐变"
            checked: Switcher.fadeMs > 0
            onToggled: Switcher.fadeMs = checked ? Switcher.fadeLength : 0
        }
        Select {
            id: fadeBox
            readonly property var values: [300, 600, 1000, 2000]
            Layout.preferredWidth: 84
            enabled: Switcher.fadeMs > 0
            model: ["0.3 秒", "0.6 秒", "1 秒", "2 秒"]
            currentIndex: values.indexOf(Switcher.fadeLength)
            displayText: currentIndex >= 0 ? currentText : (Switcher.fadeLength / 1000) + " 秒"
            onActivated: index => {
                Switcher.fadeLength = values[index]
                if (Switcher.fadeMs > 0)
                    Switcher.fadeMs = values[index]
            }
        }
        TextButton {
            text: "还原"
            flat: true
            enabled: Switcher.pending
            onClicked: Switcher.revert()
        }
        TextButton {
            Layout.fillWidth: true
            primary: true
            text: "应用"
            onClicked: Switcher.apply()
        }
    }
    // Room left over goes below, not between.
    Item {
        Layout.fillHeight: true
        Layout.preferredHeight: 0
    }
}
