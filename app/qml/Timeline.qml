import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// The player's transport, across the foot of the window, laid out like a video
// editor's timeline without editing anything. On top: the play key in the
// middle, the Set and what is on the screen to its left with the cursor's keys,
// the speed and how jumps look to its right; under them the whole Set's bar,
// which jumps the picture and frames the part the strip shows. Below it the Set's entries that
// are on lie end to end (one turned off leaves at once; the picture and sound
// go on) as strips of the middle of their frames over their sound's waveform
// (KDJ's whole-track preview, the part played dimmed); pinch on the trackpad
// (or ⌘/Ctrl + scroll) zooms in about the pointer down to a few frames, a
// two-finger swipe moves along. Pressing or dragging there only sets the cursor
// and leaves the picture alone; 跳至光标处 (or Enter) plays from it. While smart
// following leads the keys its helpers at work own rest: the speed's while 对速
// works, play and seeking while 跳转 does.
Rectangle {
    id: line
    color: Theme.raised
    implicitHeight: content.implicitHeight + 20

    property var entries: []
    property string setName: ""
    property bool running: false
    property string phase: ""
    // The window's player: its clock (transport), who leads and what is shown.
    property var player: null

    readonly property bool manual: !!player && player.manual
    // The speed is the player's (对速 paused), play and seeking are (跳转 paused).
    readonly property bool manualTempo: !!player && player.manualTempo
    readonly property bool manualSeek: !!player && player.manualSeek
    readonly property var transport: player ? player.transport : null
    readonly property var shown: player ? player.shownEntry : null
    readonly property string playingId: shown ? shown.id : ""
    readonly property real position: player ? player.playhead : 0
    readonly property real tempo: player ? player.shownTempo : 1
    // The readout shows a held nudge key's bend; the bar stays on the tempo.
    readonly property real speed: player ? player.shownSpeed : 1
    readonly property int bending: speed > tempo + 1e-6 ? 1 : speed < tempo - 1e-6 ? -1 : 0
    readonly property var match: player && player.aiPicture ? player.match : null
    // The entry on the screen stays until the picture has left it.
    readonly property var lanes: entries.filter(e => e.enabled !== false || e.id === playingId)

    // The entries end to end: { entry, n (its number), start, length } in seconds along the strip.
    readonly property var clips: {
        let at = 0
        return lanes.map((e, i) => {
            const clip = { entry: e, n: i + 1, start: at, length: Math.max(1, e.duration) }
            at += clip.length
            return clip
        })
    }
    readonly property real total: clips.length ? clips[clips.length - 1].start + clips[clips.length - 1].length : 0

    // The view: pixels a second (0 = the whole Set fits) and the second at the left edge.
    property real zoom: 0
    property real viewStart: 0
    readonly property real maxScale: 400
    readonly property real fitScale: track.width / Math.max(1, total)
    readonly property real pps: zoom > 0 ? Math.max(fitScale, Math.min(maxScale, zoom)) : fitScale
    readonly property real span: track.width / Math.max(1e-6, pps)
    readonly property real viewLeft: Math.max(0, Math.min(viewStart, total - span))
    // When the strip was last touched; until a while after, it does not follow the playhead.
    property real touchedAt: 0

    // The mark: an entry and a second in it.
    property string markId: ""
    property real markAt: 0
    readonly property var markClip: clips.find(c => c.entry.id === markId) || null
    readonly property var playClip: clips.find(c => c.entry.id === playingId) || null
    readonly property real markT: markClip ? markClip.start + Math.min(markAt, markClip.length) : -1
    readonly property real playT: playClip ? playClip.start + Math.min(position, playClip.length) : -1

    function clock(seconds, tenths) {
        const s = Math.max(0, seconds)
        const m = Math.floor(s / 60)
        const rest = s - m * 60
        const text = tenths ? rest.toFixed(1) : Math.floor(rest).toString()
        return m + ":" + (rest < 10 ? "0" : "") + text
    }
    function signed(rate) {
        const pct = (rate - 1) * 100
        return (pct >= 0 ? "+" : "−") + Math.abs(pct).toFixed(1) + "%"
    }
    function touch() {
        touchedAt = Date.now()
    }
    // Zoom by `factor` keeping the second under `x` where it is.
    function zoomAt(x, factor) {
        const t = viewLeft + x / pps
        const next = Math.max(fitScale, Math.min(maxScale, pps * factor))
        zoom = next
        viewStart = Math.max(0, Math.min(t - x / next, total - track.width / next))
        touch()
    }
    function pan(pixels) {
        viewStart = Math.max(0, Math.min(viewLeft + pixels / pps, total - span))
        touch()
    }
    function fit() {
        zoom = 0
        viewStart = 0
    }
    // Scrolling over the strip or the bar. A trackpad (a gesture with phases,
    // as macOS sends) moves the strip with the fingers, one for one, along the
    // axis the gesture started on, its momentum included: a swipe across that
    // drifts up or down does not jitter. A wheel (any mouse; Windows sends
    // touchpads as fine wheel steps too) moves a tenth of the view a notch,
    // tilted or with Shift across as well. ⌘/Ctrl zooms about the pointer, as
    // a pinch does (Windows sends a touchpad's pinch as Ctrl + wheel).
    property int swipeAxis: 0
    function scroll(wheel, x) {
        const p = wheel.pixelDelta
        const a = wheel.angleDelta
        if (wheel.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) {
            const delta = p.y !== 0 ? p.y * 4 : a.y !== 0 ? a.y : a.x
            zoomAt(x, Math.pow(1.0015, delta))
            return
        }
        if (wheel.phase !== Qt.NoScrollPhase && (p.x !== 0 || p.y !== 0)) {
            if (wheel.phase === Qt.ScrollBegin)
                swipeAxis = 0
            if (swipeAxis === 0)
                swipeAxis = Math.abs(p.x) >= Math.abs(p.y) ? 1 : 2
            pan(-(swipeAxis === 1 ? p.x : p.y))
            return
        }
        const notches = (Math.abs(a.x) > Math.abs(a.y) ? a.x : a.y) / 120
        pan(-notches * span * 0.1 * pps)
    }
    function setMark(x) {
        const t = Math.max(0, Math.min(total - 0.001, viewLeft + x / pps))
        for (const c of clips) {
            if (t < c.start + c.length) {
                markId = c.entry.id
                markAt = Math.max(0, Math.min(c.entry.duration, t - c.start))
                break
            }
        }
        touch()
    }
    function jump() {
        if (manualSeek && markClip)
            player.play(markClip.entry, markAt)
    }

    // Tick marks in each entry's own time, at least 70 px apart. A label that
    // would run into the one before (many short entries, each starting at
    // 0:00) is left off; its mark stays.
    readonly property var ticks: {
        const out = []
        if (!clips.length || pps <= 0)
            return out
        const steps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        const step = steps.find(s => s * pps >= 70) || 7200
        let labelled = -1e9
        for (const c of clips) {
            const a = Math.max(c.start, viewLeft)
            const b = Math.min(c.start + c.length, viewLeft + span)
            // None so near an entry's end that its label runs into the next entry's 0:00.
            for (let k = Math.ceil((a - c.start) / step - 1e-6); b > a && c.start + k * step <= b && out.length < 300; ++k) {
                if (k !== 0 && (c.length - k * step) * pps < 48)
                    continue
                const x = (c.start + k * step - viewLeft) * pps
                const fits = x - labelled >= 48
                if (fits)
                    labelled = x
                out.push({ x: x, label: fits ? clock(k * step, step < 1) : "" })
            }
        }
        return out
    }

    // While playing, a playhead that leaves the view brings it along, unless
    // the strip was touched a moment ago.
    Timer {
        interval: 200
        repeat: true
        running: line.visible && line.pps > line.fitScale + 1e-6 && line.playT >= 0
        onTriggered: {
            if (Date.now() - line.touchedAt < 4000)
                return
            if (line.playT < line.viewLeft || line.playT > line.viewLeft + line.span * 0.97)
                line.viewStart = Math.max(0, line.playT - line.span * 0.1)
        }
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.leftMargin: Theme.gap
        anchors.rightMargin: Theme.gap
        anchors.topMargin: 10
        anchors.bottomMargin: 10
        spacing: 0

        // The play key in the middle. To its left the Set, what is on the
        // screen and where, the cursor and the key that goes there; to its
        // right the speed and how every jump looks.
        Item {
            Layout.fillWidth: true
            implicitHeight: Math.max(playKey.height, left.implicitHeight, right.implicitHeight)

            RowLayout {
                id: left
                anchors.left: parent.left
                anchors.right: playKey.left
                anchors.rightMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 80
                    spacing: 1
                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.StyledText
                        text: (line.setName ? "<font color='" + Theme.muted + "'>" + line.setName.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                                              + (line.shown ? "  ·  " : "") + "</font>" : "")
                              + (line.shown ? line.shown.title.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                                 : line.running ? (line.phase === "searching" ? "重新搜索" : "等待识别") : "")
                        font.pixelSize: Theme.sizeSm
                        font.weight: Font.DemiBold
                        color: Theme.text
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: line.shown ? line.clock(line.position, true) + " / " + line.clock(line.shown.duration, false)
                                           + "   剩余 " + line.clock(line.shown.duration - line.position, false) : " "
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: Theme.body
                        elide: Text.ElideRight
                    }
                }
                Text {
                    text: line.markClip ? "光标 " + (line.clips.length > 1 ? line.markClip.n + " · " : "")
                                          + line.clock(line.markAt, true) : "光标 —"
                    font.pixelSize: Theme.sizeSm
                    font.features: { "tnum": 1 }
                    color: line.markClip ? Theme.muted : Theme.faint
                }
                TextButton {
                    text: "跳至光标处"
                    outlined: true
                    enabled: line.manualSeek && !!line.markClip
                    onClicked: line.jump()
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "从下面时间轴上的光标处播放（快捷键开着时也可按回车）"
                }
                TextButton {
                    text: "全览"
                    enabled: line.pps > line.fitScale + 1e-6
                    onClicked: line.fit()
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "缩回整个 Set（触控板双指捏合或 ⌘ + 滚动缩放）"
                }
                Toggle {
                    text: "快捷键"
                    checked: !!line.player && line.player.keysOn
                    onToggled: line.player.keysOn = checked
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "← / →、A / D 或小键盘 4 / 6：按住时画面以 0.7 / 1.5 倍速播放，松开即恢复；暂停时按一下退后 / 前进 1 秒\n"
                                  + "↑ / ↓、W / S 或小键盘 8 / 2：速度 +1% / −1%\n回车：跳至光标处\n"
                                  + "空格不再暂停播放"
                }
            }

            // Play and pause, as a player's own key.
            RoundButton {
                id: playKey
                anchors.centerIn: parent
                width: 42
                height: 42
                padding: 0
                enabled: line.manualSeek && !!line.transport && !!line.transport.entry
                icon.source: line.match || (line.transport && line.transport.playing) ? "icons/pause.svg" : "icons/play.svg"
                icon.width: 18
                icon.height: 18
                icon.color: enabled ? Theme.bg : Theme.faint
                onClicked: line.player.toggle()
                background: Rectangle {
                    radius: width / 2
                    color: !playKey.enabled ? Theme.line : playKey.down ? Theme.muted : Theme.text
                    scale: playKey.down ? 0.94 : playKey.hovered ? 1.04 : 1
                    Behavior on scale { NumberAnimation { duration: 90 } }
                }
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "播放 / 暂停"
            }

            RowLayout {
                id: right
                anchors.left: playKey.right
                anchors.leftMargin: 24
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Item { Layout.fillWidth: true }
                Text {
                    text: "速度"
                    font.pixelSize: Theme.sizeSm
                    color: line.manualTempo ? Theme.muted : Theme.faint
                }
                IconButton {
                    iconName: "minus"
                    tip: "慢 1%"
                    autoRepeat: true
                    enabled: line.manualTempo && line.transport.tempo > line.transport.minTempo
                    onClicked: line.player.nudgeTempo(-0.01)
                }
                Seek {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 120
                    Layout.maximumWidth: 140
                    Layout.minimumWidth: 50
                    from: line.transport ? (line.transport.minTempo - 1) * 100 : -50
                    to: line.transport ? (line.transport.maxTempo - 1) * 100 : 50
                    value: (line.tempo - 1) * 100
                    enabled: line.manualTempo
                    onMoved: line.transport.setTempo(1 + value / 100)
                    // Double-click: back to the material's own speed.
                    TapHandler {
                        enabled: line.manualTempo
                        onDoubleTapped: line.player.resetTempo()
                    }
                }
                IconButton {
                    iconName: "plus"
                    tip: "快 1%"
                    autoRepeat: true
                    enabled: line.manualTempo && line.transport.tempo < line.transport.maxTempo
                    onClicked: line.player.nudgeTempo(0.01)
                }
                TextButton {
                    text: "复原"
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "回到素材原速（也可双击速度）"
                    enabled: line.manualTempo && !!line.transport && line.transport.tempo !== 1
                    onClicked: line.player.resetTempo()
                }
                Text {
                    text: "×" + line.speed.toFixed(3)
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    color: line.bending ? Theme.warn : line.shown ? Theme.text : Theme.faint
                    // Double-click: back to the material's own speed.
                    MouseArea { anchors.fill: parent; enabled: line.manualTempo; onDoubleClicked: line.player.resetTempo() }
                }
                ColumnLayout {
                    spacing: 0
                    Text {
                        text: line.signed(line.speed)
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: line.bending ? Theme.warn : Theme.body
                        MouseArea { anchors.fill: parent; enabled: line.manualTempo; onDoubleClicked: line.player.resetTempo() }
                    }
                    Text {
                        text: line.match ? (line.match.rate_confidence >= 0.7 ? "智能 · 已稳定" : "智能 · 校准中")
                                         : line.player && line.player.aiLeads ? (line.player.tempoPaused ? "智能跳转 · 手动速度" : "智能调速 · 不跳转")
                                         : line.bending ? (line.bending > 0 ? "按住加速" : "按住减速")
                                         : line.manual ? "手动" : "智能跟随"
                        font.pixelSize: 11
                        color: Theme.faint
                    }
                }

                Toggle {
                    Layout.leftMargin: 10
                    text: "跳转渐变"
                    checked: !!line.player && line.player.fadeOn
                    onToggled: line.player.fadeOn = checked
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "手动跳转和智能跟随的跳转都从上一个画面溶过去；关掉是直接切"
                }
                Seek {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 80
                    Layout.maximumWidth: 80
                    Layout.minimumWidth: 40
                    from: 100
                    to: 2000
                    stepSize: 50
                    snapMode: Slider.SnapAlways
                    value: line.player ? line.player.fadeMs : 400
                    enabled: !!line.player && line.player.fadeOn
                    onMoved: line.player.fadeMs = value
                }
                Text {
                    Layout.preferredWidth: 40
                    horizontalAlignment: Text.AlignRight
                    text: ((line.player ? line.player.fadeMs : 400) / 1000).toFixed(2) + " s"
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: line.player && line.player.fadeOn ? Theme.body : Theme.faint
                }
            }
        }

        // The whole Set's bar, as long as the strip below at full view: where
        // the picture is, a notch where one entry meets the next, and, zoomed
        // in, a frame round the part the strip shows. Pressing or dragging on
        // it moves the picture there, into whichever entry that is.
        Item {
            id: seekBar
            Layout.fillWidth: true
            Layout.topMargin: 6
            Layout.preferredHeight: 18
            readonly property real share: line.total > 0 && line.playT >= 0 ? Math.max(0, Math.min(1, line.playT / line.total)) : 0
            Rectangle {
                id: groove
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: 2
                color: Theme.line
                Rectangle {
                    width: parent.width * seekBar.share
                    height: parent.height
                    radius: 2
                    color: line.manualSeek ? Theme.text : Theme.muted
                }
                Repeater {
                    model: line.clips.filter(c => c.start > 0)
                    Rectangle {
                        required property var modelData
                        x: groove.width * modelData.start / Math.max(1, line.total) - 1
                        width: 2
                        height: groove.height
                        color: Theme.raised
                    }
                }
            }
            // The part of the Set the strip shows.
            Item {
                visible: line.total > 0 && line.pps > line.fitScale + 1e-6
                x: seekBar.width * line.viewLeft / Math.max(1, line.total)
                width: Math.max(8, seekBar.width * line.span / Math.max(1, line.total))
                height: seekBar.height
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: Theme.text
                    opacity: 0.12
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: "transparent"
                    border.width: 1.5
                    border.color: Theme.muted
                }
            }
            Rectangle {
                visible: line.playT >= 0
                x: seekBar.width * seekBar.share - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 12
                height: 12
                radius: 6
                color: line.manualSeek ? Theme.text : Theme.muted
                scale: seekArea.pressed ? 1.2 : 1
            }
            MouseArea {
                id: seekArea
                anchors.fill: parent
                enabled: line.manualSeek && line.clips.length > 0
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                preventStealing: true
                function seek(mouse) {
                    const t = Math.max(0, Math.min(1, mouse.x / width)) * line.total
                    const clip = line.clips.find(c => t < c.start + c.length) || line.clips[line.clips.length - 1]
                    line.player.play(clip.entry, Math.max(0, Math.min(clip.entry.duration, t - clip.start)))
                }
                onPressed: mouse => {
                    line.player.scrubbing = true
                    seek(mouse)
                }
                onPositionChanged: mouse => seek(mouse)
                onReleased: line.player.scrubbing = false
                onCanceled: line.player.scrubbing = false
                // Scrolling here moves the strip's view as scrolling on it does.
                onWheel: wheel => line.scroll(wheel, track.width / 2)
            }
        }

        // The strip: a ruler in each entry's own time over the frames.
        Item {
            id: track
            Layout.fillWidth: true
            Layout.topMargin: 6
            Layout.preferredHeight: ruler.height + strips.height
            clip: true

            Item {
                id: ruler
                width: parent.width
                height: 18
                Repeater {
                    model: line.ticks
                    Item {
                        required property var modelData
                        x: modelData.x
                        height: ruler.height
                        Rectangle {
                            y: ruler.height - height
                            width: 1
                            height: 5
                            color: Theme.faint
                        }
                        Text {
                            x: 3
                            y: 0
                            text: parent.modelData.label
                            font.pixelSize: 10
                            font.features: { "tnum": 1 }
                            color: Theme.faint
                        }
                    }
                }
            }

            Item {
                id: strips
                y: ruler.height
                width: parent.width
                height: filmHeight + 1 + waveHeight
                readonly property int filmHeight: 64
                readonly property int waveHeight: 42
                Repeater {
                    model: line.clips
                    Item {
                        id: piece
                        required property var modelData
                        readonly property var entry: modelData.entry
                        readonly property real cx: (modelData.start - line.viewLeft) * line.pps
                        readonly property real cw: modelData.length * line.pps
                        readonly property bool playing: entry.id === line.playingId
                        x: Math.max(0, cx)
                        width: Math.max(0, Math.min(cx + cw, strips.width) - x)
                        height: strips.height
                        visible: width > 0

                        Rectangle {
                            anchors.fill: parent
                            color: Theme.inset
                        }
                        FilmStrip {
                            width: parent.width
                            height: strips.filmHeight
                            // Upright strips of each frame's middle: enough to
                            // know the picture, and many more of them.
                            cellAspect: 0.5
                            visible: piece.entry.video
                            source: visible ? piece.entry.path : ""
                            duration: piece.entry.duration
                            from: (piece.x - piece.cx) / line.pps
                            pxPerSec: line.pps
                            gap: Theme.inset
                        }
                        WaveStrip {
                            id: wave
                            y: strips.filmHeight + 1
                            width: parent.width
                            height: strips.waveHeight
                            source: piece.entry.path
                            from: (piece.x - piece.cx) / line.pps
                            pxPerSec: line.pps
                            background: Theme.inset
                            // What has played of the entry on the screen, dimmed as in KDJ.
                            Rectangle {
                                visible: piece.playing
                                width: Math.max(0, Math.min(parent.width, (line.position - wave.from) * line.pps))
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
                        }
                        // Between the picture and the sound: the panel's tone.
                        Rectangle {
                            y: strips.filmHeight
                            width: parent.width
                            height: 1
                            color: Theme.raised
                        }
                        // Entries following does not watch are dimmed.
                        Rectangle {
                            anchors.fill: parent
                            visible: !line.manual && piece.entry.enabled === false
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
                            y: 5
                            width: Math.min(name.implicitWidth + 12, piece.width - 12)
                            height: 18
                            radius: 4
                            visible: width > 24
                            color: "#99000000"
                            Text {
                                id: name
                                anchors.fill: parent
                                anchors.leftMargin: 6
                                anchors.rightMargin: 6
                                verticalAlignment: Text.AlignVCenter
                                text: (line.clips.length > 1 ? piece.modelData.n + "  " : "") + piece.entry.title
                                font.pixelSize: 11
                                font.weight: piece.playing ? Font.DemiBold : Font.Normal
                                color: "white"
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }

            // Where the pointer is, the mark and the playhead.
            Rectangle {
                visible: hover.containsMouse && !hover.pressed
                x: hover.mouseX
                width: 1
                height: track.height
                color: "#80ffffff"
            }
            Item {
                visible: line.markT >= line.viewLeft && line.markT <= line.viewLeft + line.span
                x: (line.markT - line.viewLeft) * line.pps
                height: track.height
                Rectangle {
                    x: -1.5
                    y: ruler.height
                    width: 3
                    height: strips.height
                    color: "#99000000"
                    Rectangle {
                        x: 1
                        width: 1
                        height: parent.height
                        color: "white"
                    }
                }
                Rectangle {
                    x: -5
                    y: ruler.height - 9
                    width: 10
                    height: 10
                    rotation: 45
                    color: Theme.muted
                }
            }
            Item {
                visible: line.playT >= line.viewLeft && line.playT <= line.viewLeft + line.span
                x: (line.playT - line.viewLeft) * line.pps
                height: track.height
                Rectangle {
                    x: -2
                    y: ruler.height
                    width: 4
                    height: strips.height
                    radius: 1
                    color: "#99000000"
                    Rectangle {
                        x: 1
                        width: 2
                        height: parent.height
                        color: Theme.text
                    }
                }
                Rectangle {
                    x: -6
                    y: 2
                    width: 12
                    height: ruler.height - 2
                    radius: 3
                    color: Theme.text
                }
            }

            // Press or drag: the cursor, never the picture; 跳至光标处 or Enter plays from it.
            MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                onPressed: mouse => line.setMark(mouse.x)
                onPositionChanged: mouse => {
                    if (pressed)
                        line.setMark(Math.max(0, Math.min(width, mouse.x)))
                }
                onWheel: wheel => line.scroll(wheel, wheel.x)
            }
            // Trackpad pinch.
            PinchHandler {
                target: null
                onScaleChanged: delta => line.zoomAt(centroid.position.x, delta)
            }
        }
    }
}
