import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// The player's transport, across the foot of the window, laid out like a video
// editor's timeline without editing anything. On top: the play key in the
// middle, the Set and what is on the screen to its left with the cursor's keys,
// the speed and how jumps look to its right; under them the whole Set's bar,
// where the picture and the cursor are, with a frame round the part the strip
// shows that drags along and, by its ends, wider or narrower. Pressing the bar
// well away from the frame only sets the cursor there, never the picture.
// Below it the Set's entries that are on lie end to end (one turned off leaves
// at once; the picture and sound go on) as strips of the middle of their frames
// over their sound's waveform (KDJ's whole-track preview, the part played
// dimmed); pinch on the trackpad (or ⌘/Ctrl/Alt + scroll, or − / +) zooms in
// about the pointer down to a few frames, a two-finger swipe moves along.
// Over the frames runs each entry's tempo, a block a section with its BPM, and
// a line down through the frames and the sound where it changes: in a long
// mix, where one song gives way to the next. Pressing or dragging there only
// sets the cursor and leaves the picture alone; 跳至光标处 (or Enter) plays
// from it. While smart following leads the keys its helpers at work own rest:
// the speed's while 对速 works, play and seeking while 跳转 does.
// Opening another Set than the one the picture plays parks the timeline:
// that Set from its start, paused, while the picture plays on untouched.
Rectangle {
    id: line
    color: Theme.raised
    implicitHeight: content.implicitHeight + 20

    property var entries: []
    property string setId: ""
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
    // The picture comes from another Set than this one: this one is parked,
    // paused at its first entry's start, and the cursor waits there for Enter.
    // The speed, the nudge keys and the effects still work on the picture.
    readonly property bool parked: !!player && player.parked
    readonly property var live: player ? player.shownEntry : null
    readonly property var shown: parked ? (clips.length ? clips[0].entry : null) : live
    readonly property string playingId: shown ? shown.id : ""
    readonly property real position: parked ? 0 : player ? player.playhead : 0
    readonly property real tempo: player ? player.shownTempo : 1
    // The readout shows a held nudge key's bend; the bar stays on the tempo.
    readonly property real speed: player ? player.shownSpeed : 1
    readonly property int bending: speed > tempo + 1e-6 ? 1 : speed < tempo - 1e-6 ? -1 : 0
    readonly property var match: player && player.aiPicture && !parked ? player.match : null
    // The entry on the screen stays until the picture has left it.
    readonly property var lanes: entries.filter(e => e.enabled !== false || (!parked && !!live && e.id === live.id))

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
    // Each Set's view and cursor while another one is open: back on the Set
    // the picture plays, the timeline is as it was left. A parked Set opens
    // whole, from its start, with the cursor there.
    property var views: ({})
    property string viewedId: ""
    onSetIdChanged: {
        if (viewedId) {
            const next = Object.assign({}, views)
            next[viewedId] = { zoom: zoom, viewStart: viewStart, markId: markId, markAt: markAt }
            views = next
        }
        viewedId = setId
        // Once the Set's entries (and whether it is parked) have followed.
        Qt.callLater(arrive)
    }
    function arrive() {
        const kept = views[setId]
        touchedAt = 0
        if (kept && !parked) {
            zoom = kept.zoom
            viewStart = kept.viewStart
            markId = kept.markId
            markAt = kept.markAt
            return
        }
        fit()
        if (parked) {
            markId = clips.length ? clips[0].entry.id : ""
            markAt = 0
        }
    }

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
    // A tempo's colour: neighbouring tempi apart, the same tempo alike in every entry.
    function tempoColor(bpm) {
        if (bpm === null || bpm === undefined)
            return Theme.inset
        const hue = (Math.log(bpm) / Math.LN2 * 2.5) % 1
        return Theme.dark ? Qt.hsla(hue, 0.42, 0.30, 1) : Qt.hsla(hue, 0.55, 0.84, 1)
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
    // The − / + keys: a step about the playhead, or the cursor, if the strip
    // shows it, as an editor's zoom keys do; else about the middle.
    function zoomStep(factor) {
        const shows = t => t >= viewLeft && t <= viewLeft + span
        const t = shows(playT) ? playT : shows(markT) ? markT : viewLeft + span / 2
        zoomAt((t - viewLeft) * pps, factor)
    }
    // Show seconds `a` to `b` (the frame's ends dragged on the bar).
    function setView(a, b) {
        a = Math.max(0, a)
        zoom = track.width / Math.max(track.width / maxScale, Math.min(total, b) - a)
        viewStart = a
        touch()
    }
    function moveView(a) {
        viewStart = Math.max(0, Math.min(a, total - span))
        touch()
    }
    // Scrolling over the strip or the bar. A trackpad (a gesture with phases,
    // as macOS sends) moves the strip with the fingers, one for one, along the
    // axis the gesture started on, its momentum included: a swipe across that
    // drifts up or down does not jitter. A wheel (any mouse; Windows sends
    // touchpads as fine wheel steps too) moves a tenth of the view a notch,
    // tilted or with Shift across as well. ⌘/Ctrl, or Alt as in After Effects
    // and Premiere, zooms about the pointer, as a pinch does (Windows sends a
    // touchpad's pinch as Ctrl + wheel): a wheel's notch is one fine step
    // (macOS hands every notch over on its own, however fast the wheel turns),
    // a fraction of one on a fine wheel; a trackpad follows the fingers and
    // stops when they lift, its glide left out.
    property int swipeAxis: 0
    readonly property real notchZoom: 1.15
    function scroll(wheel, x) {
        const p = wheel.pixelDelta
        const a = wheel.angleDelta
        if (wheel.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier)) {
            if (wheel.phase === Qt.ScrollMomentum)
                return
            if (p.x !== 0 || p.y !== 0) {
                zoomAt(x, Math.pow(1.005, Math.max(-60, Math.min(60, p.y !== 0 ? p.y : p.x))))
            } else {
                const notches = (a.y !== 0 ? a.y : a.x) / 120
                zoomAt(x, Math.pow(notchZoom, Math.max(-2, Math.min(2, notches))))
            }
            return
        }
        if (wheel.phase !== Qt.NoScrollPhase) {
            // macOS begins a gesture as the fingers land, before they move,
            // so the begin carries no delta: each gesture picks its axis anew.
            if (wheel.phase === Qt.ScrollBegin || wheel.phase === Qt.ScrollEnd)
                swipeAxis = 0
            if (p.x === 0 && p.y === 0)
                return
            if (swipeAxis === 0)
                swipeAxis = Math.abs(p.x) >= Math.abs(p.y) ? 1 : 2
            pan(-(swipeAxis === 1 ? p.x : p.y))
            return
        }
        const notches = (Math.abs(a.x) > Math.abs(a.y) ? a.x : a.y) / 120
        pan(-notches * span * 0.1 * pps)
    }
    function setMark(x) {
        markTime(viewLeft + x / pps)
    }
    function markTime(seconds) {
        const t = Math.max(0, Math.min(total - 0.001, seconds))
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
        running: line.visible && !line.parked && line.pps > line.fitScale + 1e-6 && line.playT >= 0
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
                                           + (line.parked ? "   暂停 · 画面仍在「" + line.player.playingSet.name + "」"
                                                          : "   剩余 " + line.clock(line.shown.duration - line.position, false)) : " "
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
                    ToolTip.text: "从光标处播放（快捷键开着时也可按回车）；点时间轴或上面的总览条只放光标，不动画面"
                }
                RowLayout {
                    spacing: 0
                    IconButton {
                        iconName: "minus"
                        tip: "缩小时间轴（快捷键 −）"
                        autoRepeat: true
                        enabled: line.pps > line.fitScale + 1e-6
                        onClicked: line.zoomStep(1 / 1.3)
                    }
                    TextButton {
                        flat: true
                        leftPadding: 6
                        rightPadding: 6
                        text: "全览"
                        enabled: line.pps > line.fitScale + 1e-6
                        onClicked: line.fit()
                        ToolTip.visible: hovered
                        ToolTip.delay: 600
                        ToolTip.text: "缩回整个 Set（快捷键 \\）\n也可触控板双指捏合，或按住 ⌘ / Ctrl / Alt 滚动，在指针处缩放"
                    }
                    IconButton {
                        iconName: "plus"
                        tip: "放大时间轴（快捷键 =）"
                        autoRepeat: true
                        enabled: line.total > 0 && line.pps < line.maxScale - 1e-6
                        onClicked: line.zoomStep(1.3)
                    }
                }
                Toggle {
                    text: "快捷键"
                    checked: !!line.player && line.player.keysOn
                    onToggled: line.player.keysOn = checked
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "← / →、A / D 或小键盘 4 / 6：按住时画面以 0.7 / 1.5 倍速播放，松开即恢复；暂停时按一下退后 / 前进 1 秒\n"
                                  + "↑ / ↓、W / S 或小键盘 8 / 2：速度 +1% / −1%\n回车：跳至光标处\n"
                                  + "− / =：缩小 / 放大时间轴，\\：全览\n"
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
                enabled: line.manualSeek && (line.parked ? !!line.shown : !!line.transport && !!line.transport.entry)
                icon.source: !line.parked && (line.match || (line.transport && line.transport.playing)) ? "icons/pause.svg" : "icons/play.svg"
                icon.width: 18
                icon.height: 18
                icon.color: enabled ? Theme.bg : Theme.faint
                // Parked, it plays this Set from its start, and the picture comes over.
                onClicked: line.parked ? line.player.play(line.shown, 0) : line.player.toggle()
                background: Rectangle {
                    radius: width / 2
                    color: !playKey.enabled ? Theme.line : playKey.down ? Theme.muted : Theme.text
                    scale: playKey.down ? 0.94 : playKey.hovered ? 1.04 : 1
                    Behavior on scale { NumberAnimation { duration: 90 } }
                }
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: line.parked ? "从这个 Set 的开头播放（画面切过来）" : "播放 / 暂停"
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
                    flat: true
                    text: "复原"
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "回到素材原速（也可双击速度）"
                    enabled: line.manualTempo && !!line.transport && line.transport.tempo !== 1
                    onClicked: line.player.resetTempo()
                }
                Text {
                    text: "×" + line.speed.toFixed(3)
                    font.pixelSize: 17
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

                Rectangle {
                    Layout.leftMargin: 6
                    Layout.rightMargin: 6
                    implicitWidth: 1
                    implicitHeight: 18
                    color: Theme.line
                }
                // What happens after the Set's last entry.
                TextButton {
                    flat: true
                    implicitHeight: 26
                    iconName: line.player && line.player.loopOn ? "refresh" : "square"
                    text: line.player && line.player.loopOn ? "循环播放" : "播完即停"
                    onClicked: line.player.loopOn = !line.player.loopOn
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: line.player && line.player.loopOn ? "放完 Set 的最后一个素材后从第一个重新开始；点一下改为播完即停"
                                                                    : "放完 Set 的最后一个素材后停在最后一帧；点一下改为循环播放"
                }
                Toggle {
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
        // the picture is, a notch where one entry meets the next, the cursor
        // as a hollow ball and, zoomed in, a frame round the part the strip
        // shows. The frame drags along, and its ends make it wider or
        // narrower; a band round it does nothing, so a press that just misses
        // it changes nothing. Further off a press or drag sets the cursor (the
        // strip's follows it, shown or not), never the picture: 跳至光标处 or
        // Enter plays from it.
        Item {
            id: seekBar
            Layout.fillWidth: true
            Layout.topMargin: 6
            Layout.preferredHeight: 22
            readonly property real share: line.total > 0 && line.playT >= 0 ? Math.max(0, Math.min(1, line.playT / line.total)) : 0
            readonly property bool framed: line.total > 0 && line.pps > line.fitScale + 1e-6
            // The frame in the bar's pixels, never too thin to take hold of.
            readonly property real frameW: Math.min(width, Math.max(12, width * line.span / Math.max(1, line.total)))
            readonly property real frameX: Math.max(0, Math.min(width - frameW, width * (line.viewLeft + line.span / 2) / Math.max(1, line.total) - frameW / 2))
            function timeAt(x) {
                return Math.max(0, Math.min(1, x / width)) * line.total
            }
            // What a press at `x` takes hold of: the frame ("move"), one of
            // its ends ("left", "right"), nothing ("near") or the cursor ("mark").
            function zoneAt(x) {
                if (!framed)
                    return "mark"
                const a = frameX
                const b = frameX + frameW
                const grip = Math.min(6, frameW / 4)
                if (x >= a + grip && x <= b - grip)
                    return "move"
                if (x >= a - 8 && x < a + grip)
                    return "left"
                if (x > b - grip && x <= b + 8)
                    return "right"
                if (x >= a - 28 && x <= b + 28)
                    return "near"
                return "mark"
            }
            // Zooming here keeps the second under the pointer where the strip
            // shows it, if it does; else the strip's middle.
            function anchor(x) {
                const t = timeAt(x)
                return t >= line.viewLeft && t <= line.viewLeft + line.span ? (t - line.viewLeft) * line.pps : track.width / 2
            }
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
            // The part of the Set the strip shows, with a grip at each end.
            Item {
                id: frame
                visible: seekBar.framed
                readonly property string held: barArea.zone
                x: seekBar.frameX
                width: seekBar.frameW
                height: seekBar.height
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: Theme.text
                    opacity: frame.held === "move" ? 0.2 : 0.12
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: "transparent"
                    border.width: frame.held === "move" || frame.held === "left" || frame.held === "right" ? 2 : 1.5
                    border.color: frame.held === "move" ? Theme.text : Theme.muted
                }
                Repeater {
                    model: ["left", "right"]
                    Rectangle {
                        required property string modelData
                        visible: frame.width >= 24
                        x: modelData === "left" ? 3 : frame.width - 3 - width
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2
                        height: 10
                        radius: 1
                        color: frame.held === modelData ? Theme.text : Theme.muted
                    }
                }
            }
            // The cursor: a hollow ball, the playhead's shadow.
            Rectangle {
                visible: line.markT >= 0
                x: seekBar.width * line.markT / Math.max(1, line.total) - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 11
                height: 11
                radius: 5.5
                color: Theme.raised
                border.width: 2
                border.color: Theme.muted
                scale: barArea.zone === "mark" && barArea.pressed ? 1.2 : 1
            }
            Rectangle {
                visible: line.playT >= 0
                x: seekBar.width * seekBar.share - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 12
                height: 12
                radius: 6
                color: line.manualSeek && !line.parked ? Theme.text : Theme.muted
            }
            // Where a press would put the cursor.
            Rectangle {
                visible: barArea.hoverZone === "mark" && !barArea.pressed
                x: barArea.mouseX - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 11
                height: 11
                radius: 5.5
                color: "transparent"
                border.width: 1.5
                border.color: Theme.faint
            }
            MouseArea {
                id: barArea
                anchors.fill: parent
                enabled: line.clips.length > 0
                hoverEnabled: true
                preventStealing: true
                // What the press took hold of, and where the frame was then.
                property string held: ""
                property real grabX: 0
                property real grabLeft: 0
                property real grabRight: 0
                readonly property string hoverZone: containsMouse ? seekBar.zoneAt(mouseX) : ""
                readonly property string zone: pressed ? held : hoverZone
                cursorShape: zone === "move" ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                             : zone === "left" || zone === "right" ? Qt.SizeHorCursor
                             : zone === "mark" ? Qt.PointingHandCursor : Qt.ArrowCursor
                onPressed: mouse => {
                    held = seekBar.zoneAt(mouse.x)
                    grabX = mouse.x
                    grabLeft = line.viewLeft
                    grabRight = line.viewLeft + line.span
                    if (held === "mark")
                        line.markTime(seekBar.timeAt(mouse.x))
                }
                onPositionChanged: mouse => {
                    if (!pressed)
                        return
                    const d = (mouse.x - grabX) / width * line.total
                    const least = track.width / line.maxScale
                    if (held === "mark")
                        line.markTime(seekBar.timeAt(mouse.x))
                    else if (held === "move")
                        line.moveView(grabLeft + d)
                    else if (held === "left")
                        line.setView(Math.min(grabLeft + d, grabRight - least), grabRight)
                    else if (held === "right")
                        line.setView(grabLeft, Math.max(grabRight + d, grabLeft + least))
                }
                onReleased: held = ""
                onCanceled: held = ""
                // Scrolling here moves the strip's view as scrolling on it does.
                onWheel: wheel => line.scroll(wheel, seekBar.anchor(wheel.x))
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
                // By place too: panning makes the ticks afresh every frame.
                Repeater {
                    model: line.ticks.length
                    Item {
                        required property int index
                        readonly property var modelData: line.ticks[index] || { x: 0, label: "" }
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
                height: tempoHeight + filmHeight + 1 + waveHeight
                readonly property int tempoHeight: 18
                readonly property int filmHeight: 64
                readonly property int waveHeight: 42
                // By place, not by clip: the clips are made afresh whenever the
                // Set or the entry on the screen changes (every cut), and a
                // model of them would build every strip anew each time.
                Repeater {
                    model: line.clips.length
                    Item {
                        id: piece
                        required property int index
                        readonly property var modelData: line.clips[index]
                                                         || { entry: { id: "", path: "", title: "", duration: 0, video: false }, n: 0, start: 0, length: 0 }
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
                        // The entry's tempo, a block a section; its label stays
                        // in view while any of the block is.
                        Item {
                            id: tempoLane
                            width: parent.width
                            height: strips.tempoHeight
                            Repeater {
                                model: wave.tempo
                                Item {
                                    required property var modelData
                                    readonly property bool beat: modelData.bpm !== null && modelData.bpm !== undefined
                                    x: (modelData.start - wave.from) * line.pps
                                    width: (modelData.end - modelData.start) * line.pps
                                    height: tempoLane.height
                                    visible: x + width > 0 && x < tempoLane.width
                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.topMargin: 2
                                        anchors.bottomMargin: 2
                                        anchors.leftMargin: 1
                                        anchors.rightMargin: 1
                                        radius: 3
                                        color: line.tempoColor(parent.modelData.bpm)
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
                            y: strips.tempoHeight
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
                            y: strips.tempoHeight + strips.filmHeight + 1
                            width: parent.width
                            height: strips.waveHeight
                            // A silent entry has no waveform and no tempo to find.
                            source: piece.entry.silent ? "" : piece.entry.path
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
                            y: strips.tempoHeight + strips.filmHeight
                            width: parent.width
                            height: 1
                            color: Theme.raised
                        }
                        // Where the tempo changes, down through the frames and the sound.
                        Repeater {
                            model: wave.tempo.slice(1)
                            Rectangle {
                                required property var modelData
                                x: (modelData.start - wave.from) * line.pps - 1.5
                                visible: x > 0 && x < piece.width
                                y: strips.tempoHeight
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
                            visible: !line.manual && (piece.entry.enabled === false || !!piece.entry.silent)
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
                            y: strips.tempoHeight + 5
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
                        color: line.parked ? Theme.muted : Theme.text
                    }
                }
                Rectangle {
                    x: -6
                    y: 2
                    width: 12
                    height: ruler.height - 2
                    radius: 3
                    color: line.parked ? Theme.muted : Theme.text
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
