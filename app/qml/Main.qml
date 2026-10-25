import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Window
import QtQuick.Layouts
import KVJ

// The operator's one window, a player first, regions of one sheet: the sidebar
// with the Sets and their entries, the live desk (preview and output, words,
// reactions, stickers, effects), smart following on the raised tone, and across
// the whole foot the player's timeline. While smart following is on it plays the
// picture from the music (where, and how fast) and the player's own keys rest;
// paused or stopped, the player carries on from there. The sender for the DJ's
// computer is a small window of its own; the projection window shows only the
// picture.
ApplicationWindow {
    id: app
    width: Math.min(1480, Screen.desktopAvailableWidth)
    height: Math.min(900, Screen.desktopAvailableHeight)
    minimumWidth: 1180
    minimumHeight: 680
    visible: !app.startsSending
    title: "KVJ"
    color: Theme.bg
    font.pixelSize: Theme.size
    palette.window: Theme.bg
    palette.windowText: Theme.text
    palette.base: Theme.inset
    palette.text: Theme.text
    palette.button: Theme.raised
    palette.buttonText: Theme.text
    palette.highlight: Theme.line
    palette.highlightedText: Theme.text
    palette.toolTipBase: Theme.raised
    palette.toolTipText: Theme.text
    palette.mid: Theme.line
    palette.dark: Theme.muted

    readonly property var sets: Engine.document.sets || []
    property string setId: ""
    readonly property var currentSet: {
        for (const s of sets)
            if (s.id === setId)
                return s
        return sets.length ? sets[0] : null
    }
    readonly property var entries: currentSet ? currentSet.entries : []
    readonly property var view: Engine.view
    readonly property string phase: view.phase || ""
    readonly property bool running: ["indexing", "permission", "listening", "matched", "searching", "connecting", "sending"].indexOf(phase) >= 0
    // `--send` opens straight into the sender, for the DJ's own computer.
    readonly property bool startsSending: Qt.application.arguments.indexOf("--send") >= 0
    readonly property var match: Engine.matched && Engine.matched.entry ? Engine.matched : null
    property var lastMatch: null
    // Smart following is on. Its two helpers (Assistants) pause on their own:
    // 对速 keeps the speed with the music, 跳转 moves the picture to where the
    // music is. With both at work following draws the picture once it has found
    // the music; with one paused the player draws it and the other helper steers
    // the player (steer()); with both paused it only listens.
    readonly property bool following: running && view.mode !== "send"
    property bool tempoPaused: false
    property bool jumpPaused: false
    readonly property bool followPaused: tempoPaused && jumpPaused
    readonly property bool aiLeads: following && !followPaused
    readonly property bool aiPicture: aiLeads && !tempoPaused && !jumpPaused && !!match
    readonly property bool manual: !aiLeads
    // The player's keys no helper at work owns: the speed while 对速 is paused,
    // play and seeking while 跳转 is.
    readonly property bool manualTempo: manual || tempoPaused
    readonly property bool manualSeek: manual || jumpPaused
    readonly property bool canStart: !running && !!currentSet && entries.some(e => e.enabled !== false) && !Engine.importing
    // The engine's rule (core/engine/src/runtime.rs): further than this from the
    // followed position is a jump, closer is followed by speed.
    readonly property real jumpSeconds: 2.5
    // 跳转 is paused, 对速 at work, and the music is not where the picture is:
    // the speed is left as it was, since the music's says nothing about it.
    property bool musicAway: false
    readonly property var devices: Engine.devices
    readonly property var device: devices.length ? devices[Math.min(deviceBox.currentIndex, devices.length - 1)] : null
    // Adding never waits for a Set: the first files make "Set 1".
    readonly property bool editable: !running && !Engine.importing
    // Receiving over Bluetooth: advertise for as long as it is the chosen input,
    // so the DJ's computer can find this one before following starts.
    readonly property bool receiving: !sender.visible && !!device && device.id === "bluetooth"
    onReceivingChanged: Engine.listenBluetooth(receiving)

    // The player, for the desk and its timeline: what the picture shows, from
    // whichever leads, and the keys that move it.
    readonly property alias transport: transport
    readonly property var shownEntry: aiPicture ? match.entry : transport.entry
    readonly property real shownDuration: shownEntry ? shownEntry.duration : 0
    readonly property real shownTempo: aiPicture ? match.rate : transport.tempo
    property real playhead: 0
    // Every jump, by hand or by following, can dissolve; dragging on a lane is
    // many small jumps and cuts until it is let go.
    property bool fadeOn: false
    property int fadeMs: 400
    property bool scrubbing: false

    onMatchChanged: {
        if (match)
            lastMatch = match
        steer()
    }
    onFollowingChanged: {
        if (!following) {
            tempoPaused = false
            jumpPaused = false
        }
    }
    // Following let go of the picture: the player carries on from the same
    // frame at the same speed.
    onAiPictureChanged: if (!aiPicture) takeOver()
    onEntriesChanged: cue()

    function takeOver() {
        const m = app.lastMatch
        if (!m)
            return
        const at = m.position + (Engine.clockMs() - m.clock_at_ms + offset.value) / 1000 * m.rate
        transport.tempo = Math.max(transport.minTempo, Math.min(transport.maxTempo, m.rate))
        transport.load(m.entry, at, true)
        app.tick()
    }
    // One helper paused: the player has the picture and the helper at work moves
    // it, measured against the picture itself.
    function steer() {
        app.musicAway = false
        if (!app.aiLeads || app.aiPicture || !app.match)
            return
        const m = app.match
        const music = m.position + (Engine.clockMs() - m.clock_at_ms + offset.value) / 1000 * m.rate
        const near = !!transport.entry && transport.entry.id === m.entry.id
                     && Math.abs(transport.now() - music) < app.jumpSeconds
        if (app.tempoPaused) {
            // Jumps only, at the player's speed: once the picture is a jump
            // away from the music (or on another entry), it goes there.
            if (!near) {
                transport.load(m.entry, music, true)
                app.tick()
            }
        } else if (near) {
            // Speed only, never a jump: followed, small corrections included,
            // while the music is where the picture is and the picture plays.
            if (transport.playing) {
                transport.tempo = Math.max(transport.minTempo, Math.min(transport.maxTempo, m.rate))
                transport.anchor(music)
            }
        } else {
            app.musicAway = true
        }
    }
    // 开始监听 listens with both helpers paused: following judges where the
    // music is (its panel shows it) and the player keeps the picture. 开始跟随
    // sets both to work, listening first if it was not.
    function listen() {
        app.tempoPaused = app.jumpPaused = true
        Engine.start(app.currentSet.id, app.device ? app.device.id : "auto", channelBox.currentIndex * 2)
    }
    function follow() {
        app.tempoPaused = app.jumpPaused = false
        if (!app.following)
            Engine.start(app.currentSet.id, app.device ? app.device.id : "auto", channelBox.currentIndex * 2)
    }
    function resetTempo() {
        if (app.manualTempo)
            transport.setTempo(1)
    }
    // Something on the screen from the start: the first entry, paused.
    function cue() {
        if (!transport.entry && app.entries.length)
            transport.load(app.entries[0], 0, false)
    }
    // That entry from `at` seconds: a seek within the one shown keeps playing or
    // paused as it was; another entry starts playing.
    function play(entry, at) {
        if (!app.manualSeek)
            return
        if (transport.entry && transport.entry.id === entry.id)
            transport.seek(at)
        else
            transport.load(entry, at, true)
        app.tick()
    }
    function toggle() {
        if (!app.manualSeek)
            return
        transport.toggle()
        app.tick()
    }
    function seekBy(seconds) {
        if (!app.manualSeek || !transport.entry)
            return
        transport.seek(transport.now() + seconds)
        app.tick()
    }
    function nudgeTempo(step) {
        if (app.manualTempo)
            transport.setTempo(transport.tempo + step)
    }
    // The playhead for the timeline; at the end of an entry the player goes on
    // to the next one in the Set.
    function tick() {
        if (app.aiPicture) {
            app.playhead = Math.max(0, Math.min(app.shownDuration, app.match.position
                                    + (Engine.clockMs() - app.match.clock_at_ms + offset.value) / 1000 * app.match.rate))
            return
        }
        app.playhead = transport.now()
        if (transport.playing && transport.duration > 0 && app.playhead >= transport.duration - 0.03) {
            const i = app.entries.findIndex(e => e.id === transport.entry.id)
            if (i >= 0 && i + 1 < app.entries.length)
                transport.load(app.entries[i + 1], 0, true)
            else
                transport.setPlaying(false)
            app.playhead = transport.now()
        }
    }

    // The sender takes the place of this window, which is put away (nothing
    // is decoded or drawn here meanwhile) until the sender is closed.
    function openSender() {
        if (app.following)
            return
        transport.setPlaying(false)
        projection.closeOutput()
        sender.show()
        sender.raise()
        sender.requestActivate()
        app.hide()
    }
    function leaveSender() {
        if (app.running)
            Engine.stop()
        app.show()
        app.raise()
        app.requestActivate()
    }
    // Development aid, through KVJ_DEV_DIR/cmd (main.cpp): drive the player
    // from a shell. "play <entry no.> <seconds>", "pause", "resume", "tempo
    // <rate>", "fade <ms>" (0 = off), "listen", "follow", "stop", "hold [tempo|jump]",
    // "send", "back"; on the timeline "zoom <factor> <x>", "mark <x>" (x in px
    // along the strip), "jump"; "post <px> <py> <words>" posts a sticker of
    // words and chooses it.
    function devCommand(line) {
        const w = String(line).trim().split(/\s+/)
        switch (w[0]) {
        case "play": app.play(app.entries[Math.max(0, Number(w[1] || 1) - 1)], Number(w[2] || 0)); transport.setPlaying(true); break
        case "pause": transport.setPlaying(false); break
        case "resume": transport.setPlaying(true); break
        case "tempo": transport.setTempo(Number(w[1])); break
        case "fade": app.fadeOn = Number(w[1]) > 0; if (app.fadeOn) app.fadeMs = Number(w[1]); break
        case "listen": app.listen(); break
        case "follow": app.follow(); break
        case "stop": Engine.stop(); break
        case "hold":
            if (w[1] === "tempo")
                app.tempoPaused = !app.tempoPaused
            else if (w[1] === "jump")
                app.jumpPaused = !app.jumpPaused
            else
                app.tempoPaused = app.jumpPaused = !app.followPaused
            break
        case "send": app.openSender(); break
        case "back": sender.close(); break
        case "zoom": timeline.zoomAt(Number(w[2] || 0), Number(w[1])); break
        case "mark": timeline.setMark(Number(w[1])); break
        case "jump": timeline.jump(); break
        case "post": Live.post({ kind: "text", text: w.slice(3).join(" "), name: "", px: Number(w[1]), py: Number(w[2]), size: 0.15 }); desk.chosenSid = Live.lastSid; break
        default: return "unknown"
        }
        app.tick()
        return "ok"
    }

    function addUrls(urls) {
        if (!urls || urls.length === 0 || !app.editable)
            return
        if (!app.currentSet)
            Engine.createSet("Set " + (app.sets.length + 1))
        if (app.currentSet)
            Engine.importUrls(app.currentSet.id, urls)
    }

    function clock(seconds, tenths) {
        const s = Math.max(0, seconds)
        const m = Math.floor(s / 60)
        const rest = s - m * 60
        const text = tenths ? rest.toFixed(1) : Math.floor(rest).toString()
        return m + ":" + (rest < 10 ? "0" : "") + text
    }
    function phaseText(p) {
        switch (p) {
        case "indexing": return "建立索引 " + (view.indexed || 0) + "/" + (view.total || 0)
        case "permission": return "等待录音权限"
        case "listening": return "监听中"
        case "matched": return "跟随中"
        case "searching": return "重新搜索"
        case "prepared": return "索引就绪"
        case "failed": return "失败"
        case "stopped": return "已停止"
        default: return ""
        }
    }

    Transport {
        id: transport
    }
    Timer {
        interval: 50
        repeat: true
        running: app.visible
        onTriggered: app.tick()
    }
    Projection {
        id: projection
        // The desk's preview is up whenever this window is.
        previewing: app.visible && app.visibility !== Window.Minimized
        entry: app.shownEntry
        position: app.aiPicture ? app.match.position : transport.position
        rate: app.aiPicture ? app.match.rate : transport.rate
        clockAtMs: app.aiPicture ? app.match.clock_at_ms : transport.clockAtMs
        offsetMs: app.aiPicture ? offset.value : 0
        fadeMs: app.fadeOn && !app.scrubbing ? app.fadeMs : 0
        maxHeight: desk.maxHeight
        maxFps: desk.maxFps
    }
    // The sound of what the picture shows, on the picture's timing.
    AudioFollower {
        id: sound
        enabled: desk.soundOn
        source: app.shownEntry ? app.shownEntry.path : ""
        position: projection.position
        rate: projection.rate
        clockAtMs: projection.clockAtMs
        offsetMs: projection.offsetMs
        device: desk.soundDevice
        volume: desk.soundVolume
    }
    SendWindow {
        id: sender
        visible: app.startsSending
        running: app.running
        inputs: app.devices
        onLeaving: app.leaveSender()
    }
    Settings {
        category: "output"
        property alias offset: offset.value
    }
    Settings {
        category: "player"
        property alias fade: app.fadeOn
        property alias fadeMs: app.fadeMs
    }
    Shortcut {
        sequence: "Space"
        enabled: app.manualSeek && !!transport.entry
        onActivated: app.toggle()
    }
    Shortcut {
        sequence: "Left"
        enabled: app.manualSeek && !!transport.entry
        onActivated: app.seekBy(-5)
    }
    Shortcut {
        sequence: "Right"
        enabled: app.manualSeek && !!transport.entry
        onActivated: app.seekBy(5)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // —— Sets and their entries ——
            Sidebar {
                Layout.preferredWidth: 252
                Layout.fillWidth: false
                Layout.fillHeight: true
                sets: app.sets
                currentSet: app.currentSet
                running: app.running
                editable: app.editable
                playingId: app.shownEntry ? app.shownEntry.id : ""
                onSelectSet: id => app.setId = id
                onAddUrls: urls => app.addUrls(urls)
            }
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                color: Theme.line
            }

            // —— The live desk ——
            Desk {
                id: desk
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: Theme.gap
                source: projection.surface
                entry: projection.entry
                projection: projection
                sound: sound
            }

            // —— Live controls ——
            Rectangle {
                Layout.preferredWidth: 330
                Layout.fillWidth: false
                Layout.fillHeight: true
                color: Theme.raised

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.gap
                    spacing: 14

                    // The DJ's computer runs only the sender, in a small window.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: -6
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: "这台是 DJ 电脑？"
                            font.pixelSize: Theme.sizeXs
                            color: Theme.faint
                            elide: Text.ElideRight
                        }
                        TextButton {
                            iconName: "send"
                            text: "只发送"
                            enabled: !app.following
                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: "收起播放器，打开只采集 Master、经蓝牙发给投影电脑的小窗"
                            onClicked: app.openSender()
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Text {
                            Layout.fillWidth: true
                            text: "智能跟随音频跳转与调速"
                            font.pixelSize: Theme.sizeLg
                            font.weight: Font.DemiBold
                            color: Theme.text
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "监听：听 Master 音频，小窗显示判断的位置，画面仍归播放器。跟随：按判断跳转和调速；下方两个助手可各自暂停，交回播放器。"
                            font.pixelSize: Theme.sizeXs
                            color: Theme.muted
                            wrapMode: Text.Wrap
                        }
                    }

                    // Where following itself puts the picture; the desk shows
                    // what really plays, the same while following draws it.
                    FollowMonitor {
                        Layout.fillWidth: true
                        active: app.following
                        mirror: app.aiPicture
                        match: app.match
                        offsetMs: offset.value
                        source: projection.surface
                    }

                    // What following is doing now. Empty while off, and then it
                    // must not take a share of the height (layouts fill by default).
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: false
                        spacing: 4
                        visible: app.following
                        Text {
                            Layout.fillWidth: true
                            visible: text.length > 0
                            text: app.match ? app.match.entry.title : app.phaseText(app.phase)
                            font.pixelSize: 18
                            font.weight: Font.DemiBold
                            color: app.match && !app.followPaused ? Theme.text : Theme.muted
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: !!app.match
                            text: app.match ? (app.followPaused ? "只监听" : app.phaseText(app.phase)) + " · " + app.clock(app.match.position, true)
                                              + " · ×" + app.match.rate.toFixed(3) : ""
                            font.pixelSize: Theme.sizeSm
                            font.features: { "tnum": 1 }
                            color: Theme.muted
                        }
                        // Input level of the selected channels.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            Layout.preferredHeight: 3
                            radius: 1.5
                            color: Theme.line
                            Rectangle {
                                readonly property real db: app.view.input && app.view.input.rms_dbfs !== null ? app.view.input.rms_dbfs : -70
                                width: parent.width * Math.max(0, Math.min(1, (db + 70) / 70))
                                height: parent.height
                                radius: 1.5
                                color: Theme.text
                                Behavior on width { NumberAnimation { duration: 120 } }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        // Listening: the engine hears the music and judges where it is.
                        TextButton {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 34
                            iconName: app.following ? "square" : "play"
                            text: app.following ? "停止监听" : "开始监听"
                            // At least one entry on; more can be turned on while listening.
                            enabled: app.following || app.canStart
                            onClicked: app.following ? Engine.stop() : app.listen()
                        }
                        // Following: that judgement moves the picture. Stopping
                        // it keeps listening.
                        TextButton {
                            Layout.fillWidth: true
                            primary: true
                            iconName: app.aiLeads ? "pause" : "play"
                            text: app.aiLeads ? "停止跟随" : "开始跟随"
                            enabled: app.following || app.canStart
                            onClicked: {
                                if (app.aiLeads)
                                    app.tempoPaused = app.jumpPaused = true
                                else
                                    app.follow()
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Caption { text: "声音输入" }
                        Select {
                            id: deviceBox
                            Layout.fillWidth: true
                            enabled: !app.running
                            model: app.devices.map(d => d.label + (d.error ? "（不可用）" : ""))
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Select {
                                id: channelBox
                                Layout.preferredWidth: 120
                                enabled: !app.running
                                model: {
                                    const channels = app.device ? Math.max(1, app.device.channels) : 2
                                    const pairs = []
                                    for (let i = 0; i < channels; i += 2)
                                        pairs.push(i + 1 < channels ? "CH " + (i + 1) + "/" + (i + 2) : "CH " + (i + 1))
                                    return pairs
                                }
                            }
                            Item { Layout.fillWidth: true }
                            IconButton {
                                iconName: "refresh"
                                tip: "刷新设备"
                                enabled: !app.running && !Engine.busy
                                onClicked: Engine.refreshDevices()
                            }
                        }
                    }

                    // Receiving over Bluetooth: the operator picks the current DJ.
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        visible: app.receiving
                        Caption { text: "DJ" }
                        Repeater {
                            model: (app.view.connections && app.view.connections.incoming) || []
                            ItemDelegate {
                                id: dj
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 32
                                topPadding: 0
                                bottomPadding: 0
                                leftPadding: 8
                                onClicked: Engine.selectBluetooth(modelData.selected ? "" : modelData.link.peer)
                                contentItem: RowLayout {
                                    Text {
                                        Layout.fillWidth: true
                                        text: dj.modelData.device.name
                                        font.pixelSize: Theme.size
                                        font.weight: dj.modelData.selected ? Font.DemiBold : Font.Normal
                                        color: dj.modelData.selected ? Theme.text : Theme.muted
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        text: dj.modelData.link.state === "receiving" ? "发送中"
                                            : dj.modelData.link.state === "connected" ? "待命" : "已断开"
                                        font.pixelSize: Theme.sizeXs
                                        color: Theme.muted
                                    }
                                }
                                background: Rectangle {
                                    radius: Theme.radius
                                    color: dj.hovered ? Theme.hover : "transparent"
                                }
                            }
                        }
                    }

                    // Calibration of the followed picture against the music.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text { text: "画面偏移"; font.pixelSize: Theme.sizeSm; color: Theme.muted }
                        Seek {
                            id: offset
                            Layout.fillWidth: true
                            from: -400
                            to: 400
                            stepSize: 10
                            value: 0
                        }
                        Text {
                            Layout.preferredWidth: 58
                            horizontalAlignment: Text.AlignRight
                            text: (offset.value > 0 ? "+" : "") + offset.value.toFixed(0) + " ms"
                            font.pixelSize: Theme.sizeSm
                            font.features: { "tnum": 1 }
                            color: offset.value === 0 ? Theme.muted : Theme.text
                            MouseArea { anchors.fill: parent; onDoubleClicked: offset.value = 0 }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: Engine.error.length > 0
                        text: Engine.error
                        font.pixelSize: Theme.sizeSm
                        color: Theme.warn
                        wrapMode: Text.Wrap
                        MouseArea { anchors.fill: parent; onClicked: Engine.clearError() }
                    }

                    Item { Layout.fillHeight: true }

                    // The two helpers at work: tempo, and whether to jump.
                    Assistants {
                        Layout.fillWidth: true
                        active: app.following
                        tempoPaused: app.tempoPaused
                        jumpPaused: app.jumpPaused
                        musicAway: app.musicAway
                        tempo: app.shownTempo
                        onTempoToggled: app.tempoPaused = !app.tempoPaused
                        onJumpToggled: app.jumpPaused = !app.jumpPaused
                        onTempoReset: app.resetTempo()
                        view: app.view
                        match: app.match
                    }
                }
            }
        }

        // —— The player's timeline, across the whole foot ——
        Timeline {
            id: timeline
            objectName: "timeline"
            Layout.fillWidth: true
            entries: app.entries
            running: app.running
            phase: app.phase
            player: app
        }
    }

    // `--add <file or folder>` adds it at start, the same way the add keys do.
    Component.onCompleted: {
        const args = Qt.application.arguments
        for (let i = 0; i + 1 < args.length; ++i)
            if (args[i] === "--add")
                app.addUrls([Engine.fileUrl(args[i + 1])])
        app.cue()
    }

    onClosing: {
        if (app.running)
            Engine.stop()
        projection.closeOutput()
    }
}
