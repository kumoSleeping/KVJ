import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Window
import QtQuick.Layouts
import KVJ

// The operator's one window, a player first: a top bar (in the title bar's row
// on macOS) with the way into the sender and the light or dark look, and under
// it the canvas: the live desk (preview and output, words, reactions, stickers,
// effects) and smart following as cards, the Sets and their entries in a drawer
// over its left side; across the whole foot the player's timeline. While smart following is on it plays the
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
    // Tracks: every entry is on one, 0 the main track, 1..3 the aux ones (画面
    // 2..4); `e.track || 0` since the engine may leave it out. This window's
    // player (transport, the timeline, cue/nextOn/tick) plays the main track
    // only; the aux tracks get players of their own.
    function isMain(e) { return (e.track || 0) === 0 }
    readonly property var mainEntries: entries.filter(app.isMain)
    // The track following listens for (Engine.start); only its entries are
    // matched. The engine says which one a session follows in `view.track`.
    readonly property int followTrack: strip.followTrack
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
    // Following leads the main track's picture (the player's), or else that of
    // the aux track it follows (its TrackPlayer): the main one plays on.
    readonly property bool aiMain: aiPicture && followTrack === 0
    // The player following steers and hands back to: the main one's, or the
    // followed aux track's.
    readonly property var followedPlayer: followTrack === 0 ? transport : auxPlayers[followTrack - 1].clock
    readonly property bool manual: !aiLeads
    // The player's keys no helper at work owns: the speed while 对速 is paused,
    // play and seeking while 跳转 is.
    // The main player's own keys: free unless following leads it (following
    // an aux track leaves the main one to the operator).
    readonly property bool manualTempo: manual || tempoPaused || followTrack !== 0
    readonly property bool manualSeek: manual || jumpPaused || followTrack !== 0
    // Something on the followed track to follow that can be heard: a silent
    // entry is never followed.
    readonly property bool canStart: !running && !!currentSet && entries.some(e => e.enabled !== false && !e.silent && (e.track || 0) === followTrack) && !Engine.importing
    // The engine's rule (core/engine/src/runtime.rs): further than this from the
    // followed position is a jump, closer is followed by speed.
    readonly property real jumpSeconds: 2.5
    // 跳转 is paused, 对速 at work, and the music is not where the picture is:
    // the speed is left as it was, since the music's says nothing about it.
    property bool musicAway: false
    readonly property var devices: Engine.devices
    readonly property var device: strip.device
    // Adding never waits for a Set: the first files make "Set 1".
    readonly property bool editable: !running && !Engine.importing
    // Receiving over Bluetooth (an input among the others). This computer
    // advertises while it is the chosen input, and otherwise too while it may be
    // found (可被发现), so a DJ can pair or come back at any time; never while
    // it is itself the sender.
    readonly property bool receiving: !sender.visible && !!device && device.id === "bluetooth"
    property bool discoverable: true
    readonly property bool advertising: receiving || (discoverable && !sender.visible)
    onReceivingChanged: Engine.listenBluetooth(advertising, receiving)
    onAdvertisingChanged: Engine.listenBluetooth(advertising, receiving)
    readonly property var incoming: (view.connections && view.connections.incoming) || []
    readonly property var knownDjs: ((view.connections && view.connections.known) || []).filter(k => k.role === "dj")
    // Paired DJs not connected now, so they can be forgotten from here too.
    readonly property var awayDjs: knownDjs.filter(k => !incoming.some(p => p.token === k.token && p.link.state !== "disconnected"))
    // A recording input (a microphone) hears the room: 现场模式 starts on for it
    // and off for captured or received audio; the operator may switch it either way.
    readonly property bool microphone: !!device && device.kind === "input"
    // The system title bar the top bar stands in for (main.cpp, macOS): room for
    // the window's keys at its left, and its height; 0 where the system keeps it.
    property real titleInset: 0
    property real titleHeight: 0
    property bool titleReachesContent: false

    // The player's keys (keysOn, switched on the timeline): ←/→, A/D or 4/6 on
    // the number pad, held, play the picture at 0.7 or 1.5 of its speed until
    // let go (never a jump; paused, a press steps a second); ↑/↓, W/S or 8/2
    // change the speed by 1%; Enter plays from the timeline's cursor; − and =
    // zoom the timeline out and in, \ shows the whole Set, as in Premiere.
    // None while words are typed.
    // Space does nothing: one touch of it during a show is too easy.
    property bool keysOn: true
    readonly property bool typing: !!activeFocusItem && typeof activeFocusItem.selectedText === "string"
    // They work from the projection window too (it takes the focus when it
    // opens), not while the sender stands in for the player.
    readonly property bool keysLive: keysOn && !typing && !sender.visible

    // The player, for the desk and its timeline: what the picture shows, from
    // whichever leads, and the keys that move it.
    readonly property alias transport: transport
    readonly property var shownEntry: aiMain ? match.entry : transport.entry
    readonly property real shownDuration: shownEntry ? shownEntry.duration : 0
    readonly property real shownTempo: aiMain ? match.rate : transport.tempo
    // What it plays at this moment: the tempo, bent while a nudge key is held.
    readonly property real shownSpeed: aiMain ? match.rate : transport.speed
    property real playhead: 0
    // The Set the picture comes from. Opening another Set leaves it playing
    // there, effects and speed included: the other Set's timeline is parked,
    // paused at its start, until something of it is played (Enter, 跳至光标处
    // or its play key), and coming back to this Set shows the player again.
    readonly property var playingSet: {
        const id = shownEntry ? shownEntry.id : ""
        for (const s of sets)
            if (s.entries.some(e => e.id === id))
                return s
        return null
    }
    // The main track's, for the player (see isMain).
    readonly property var playingEntries: (playingSet ? playingSet.entries : entries).filter(app.isMain)
    readonly property bool parked: !!playingSet && !!currentSet && playingSet.id !== currentSet.id
    // Every jump, by hand or by following, can dissolve.
    property bool fadeOn: false
    // At the end of the Set's last entry: start over from its first entry, or
    // stop on the last frame.
    property bool loopOn: false
    // The 画面 column's width, dragged at its edge.
    property real sourceWidth: 168
    property int fadeMs: 400

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
    // Following stopped (or only listens): the speed is the operator's own
    // again, once the player has taken the picture over.
    onAiLeadsChanged: if (!aiLeads) Qt.callLater(giveTempoBack)
    onEntriesChanged: cue()

    function takeOver() {
        const p = app.followedPlayer
        const m = app.lastMatch
        if (!m)
            return
        const at = m.position + (Engine.clockMs() - m.clock_at_ms + strip.offsetMs) / 1000 * m.rate
        p.tempo = Math.max(p.minTempo, Math.min(p.maxTempo, m.rate))
        p.load(m.entry, at, true)
        app.tick()
    }
    function giveTempoBack() {
        const p = app.followedPlayer
        if (app.aiLeads || p.tempo === p.ownTempo)
            return
        // An aux track's own speed may lie beyond the main player's range.
        if (p === transport) {
            p.setTempo(p.ownTempo)
        } else {
            const at = p.now()
            p.tempo = p.ownTempo
            p.anchor(at)
        }
    }
    // One helper paused: the player has the picture and the helper at work moves
    // it, measured against the picture itself.
    function steer() {
        const p = app.followedPlayer
        app.musicAway = false
        if (!app.aiLeads || app.aiPicture || !app.match)
            return
        const m = app.match
        const music = m.position + (Engine.clockMs() - m.clock_at_ms + strip.offsetMs) / 1000 * m.rate
        const near = !!p.entry && p.entry.id === m.entry.id
                     && Math.abs(p.now() - music) < app.jumpSeconds
        if (app.tempoPaused) {
            // Jumps only, at the player's speed: once the picture is a jump
            // away from the music (or on another entry), it goes there.
            if (!near) {
                p.load(m.entry, music, true)
                app.tick()
            }
        } else if (near) {
            // Speed only, never a jump: followed, small corrections included,
            // while the music is where the picture is and the picture plays.
            if (p.playing) {
                p.tempo = Math.max(p.minTempo, Math.min(p.maxTempo, m.rate))
                p.anchor(music)
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
        Engine.start(app.currentSet.id, app.device ? app.device.id : "auto", strip.channel, strip.roomMode, app.followTrack)
    }
    function follow() {
        app.tempoPaused = app.jumpPaused = false
        if (!app.following)
            Engine.start(app.currentSet.id, app.device ? app.device.id : "auto", strip.channel, strip.roomMode, app.followTrack)
    }
    // 跳至此处: the player goes once to where following hears the music.
    function jumpToMatch() {
        const p = app.followedPlayer
        const m = app.match
        if (!m || !app.manualSeek)
            return
        p.load(m.entry, m.position + (Engine.clockMs() - m.clock_at_ms + strip.offsetMs) / 1000 * m.rate, true)
        app.tick()
    }
    function resetTempo() {
        if (app.manualTempo)
            transport.setTempo(1)
    }
    // Something on the screen from the start: the first entry of the main
    // track that is on, paused.
    function cue() {
        const first = app.mainEntries.find(e => e.enabled !== false)
        if (!transport.entry && first)
            transport.load(first, 0, false)
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
    // The picture ahead (direction > 0) or back by playing faster or slower
    // until `letGo` (or for `ms`), instead of a jump.
    function nudge(direction, ms) {
        if (!app.manualSeek || !app.manualTempo || !transport.entry)
            return
        transport.nudge(direction, ms || 0)
        app.tick()
    }
    // A nudge key let go (main.cpp sees the release; 0 when the app loses the
    // keyboard, which would never hear it).
    function letGo(direction) {
        transport.letGo(direction)
    }
    Connections {
        target: Qt.application
        function onStateChanged() {
            if (Qt.application.state !== Qt.ApplicationActive)
                app.letGo(0)
        }
    }
    // The entry after `id` that is on, from its start; past the last one, the
    // first that is on.
    function nextOn(id) {
        const list = app.playingEntries
        const i = list.findIndex(e => e.id === id)
        for (let k = 1; k <= list.length; ++k) {
            const e = list[(i + k) % list.length]
            if (e.id !== id && e.enabled !== false)
                return e
        }
        return null
    }
    // The entry on the screen is turned off (confirmed in the sidebar): the
    // picture goes on to the next one that is on, with the dissolve if it is
    // on; with none left it stops there. Following finds its own way.
    function dropPlaying(id) {
        const next = app.nextOn(id)
        Engine.enableEntries((app.playingSet || app.currentSet).id, [id], false)
        if (!app.manualSeek || !transport.entry || transport.entry.id !== id)
            return
        if (next)
            transport.load(next, 0, true)
        else
            transport.setPlaying(false)
        app.tick()
    }
    // Another Set is chosen: listening and following stop at once (they hear
    // for the Set they started on), and the player carries the picture on.
    function chooseSet(id) {
        if (app.currentSet && app.currentSet.id === id)
            return
        if (app.running && !sender.visible)
            Engine.stop()
        app.setId = id
    }
    // The playhead for the timeline; at the end of an entry the player goes on
    // to the next one in its Set that is on.
    function tick() {
        if (app.aiMain) {
            app.playhead = Math.max(0, Math.min(app.shownDuration, app.match.position
                                    + (Engine.clockMs() - app.match.clock_at_ms + strip.offsetMs) / 1000 * app.match.rate))
            return
        }
        app.playhead = transport.now()
        if (transport.playing && transport.duration > 0 && app.playhead >= transport.duration - 0.03) {
            const list = app.playingEntries
            const i = list.findIndex(e => e.id === transport.entry.id)
            const next = i >= 0 ? list.slice(i + 1).find(e => e.enabled !== false) : null
            const first = app.loopOn ? list.find(e => e.enabled !== false) : null
            if (next || first)
                transport.load(next || first, 0, true)
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
    // <rate>", "fade <ms>" (0 = off), "listen", "follow", "here", "stop", "hold [tempo|jump]",
    // "send", "back"; on the timeline "zoom <factor> <x>", "mark <x>" (x in px
    // along the strip), "jump"; "post <px> <py> <words>" posts a sticker of
    // words and chooses it; "nudge <±1> <ms>" holds a nudge key that long;
    // "drop" turns the entry on the screen off as the sidebar's confirmed
    // second press does; "effect <key> <0–1>" sets an effect, "move <from>
    // <to>" reorders them; "set <no.>" chooses that Set as the sidebar does.
    function devCommand(line) {
        const w = String(line).trim().split(/\s+/)
        switch (w[0]) {
        case "play": app.play(app.mainEntries[Math.max(0, Number(w[1] || 1) - 1)], Number(w[2] || 0)); transport.setPlaying(true); break
        case "pause": transport.setPlaying(false); break
        case "resume": transport.setPlaying(true); break
        case "tempo": transport.setTempo(Number(w[1])); break
        case "fade": app.fadeOn = Number(w[1]) > 0; if (app.fadeOn) app.fadeMs = Number(w[1]); break
        case "listen": app.listen(); break
        case "follow": app.follow(); break
        case "here": app.jumpToMatch(); break
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
        case "nudge": app.nudge(Number(w[1] || 1), Number(w[2] || 1000)); break
        case "drop": if (transport.entry) app.dropPlaying(transport.entry.id); break
        case "effect": Live.setLevel(w[1], Number(w[2] || 0)); break
        case "move": Live.moveEffect(Number(w[1]), Number(w[2])); break
        case "set": if (app.sets[Number(w[1] || 1) - 1]) app.chooseSet(app.sets[Number(w[1] || 1) - 1].id); break
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

    // No screen goes dark and no computer sleeps while the picture is out or
    // the music is heard (or sent): nobody touches the computer during a show.
    Binding {
        target: Engine
        property: "keepAwake"
        value: projection.visible || projection.waiting || app.running
    }
    Transport {
        id: transport
    }
    // The aux tracks' own players (画面 2..4), each on its own clock; the
    // one following follows plays the music's place instead (auxTiming).
    readonly property var auxPlayers: [aux1, aux2, aux3]
    // The aux tracks play from the Set the picture comes from, like the main
    // one: opening another Set to look at it changes nothing on the air.
    readonly property var auxEntries: (app.playingSet || app.currentSet || { entries: [] }).entries
    TrackPlayer {
        id: aux1
        track: 1
        entries: app.auxEntries.filter(e => (e.track || 0) === 1)
        lead: app.aiPicture && app.followTrack === 1 ? { match: app.match, offsetMs: strip.offsetMs } : null
        mainRate: app.shownTempo
    }
    TrackPlayer {
        id: aux2
        track: 2
        entries: app.auxEntries.filter(e => (e.track || 0) === 2)
        lead: app.aiPicture && app.followTrack === 2 ? { match: app.match, offsetMs: strip.offsetMs } : null
        mainRate: app.shownTempo
    }
    TrackPlayer {
        id: aux3
        track: 3
        entries: app.auxEntries.filter(e => (e.track || 0) === 3)
        lead: app.aiPicture && app.followTrack === 3 ? { match: app.match, offsetMs: strip.offsetMs } : null
        mainRate: app.shownTempo
    }
    // What an aux track's picture shows: its player's clock, or the music's
    // place while following follows it (TrackPlayer.lead).
    function auxTiming(track) {
        const p = app.auxPlayers[track - 1]
        return { entry: p.entry, position: p.position, rate: p.rate, clockAtMs: p.clockAtMs, offsetMs: p.offsetMs }
    }
    Timer {
        interval: 50
        repeat: true
        running: app.visible
        onTriggered: app.tick()
    }
    Projection {
        id: projection
        guarded: !app.quitting
        // The desk's preview is up whenever this window is.
        previewing: app.visible && app.visibility !== Window.Minimized
        entry: app.shownEntry
        position: app.aiMain ? app.match.position : transport.position
        rate: app.aiMain ? app.match.rate : transport.rate
        clockAtMs: app.aiMain ? app.match.clock_at_ms : transport.clockAtMs
        offsetMs: app.aiMain ? strip.offsetMs : 0
        fadeMs: app.fadeOn ? app.fadeMs : 0
        maxHeight: desk.maxHeight
        maxFps: desk.maxFps
        auxTimings: [app.auxTiming(1), app.auxTiming(2), app.auxTiming(3)]
        cameraIds: app.cameraIds
        wantedIds: desk.allIds
    }
    // The picture sources on offer to the mixer (Switcher): the main track,
    // the aux tracks that have entries, the cameras taken in.
    property var cameraIds: []
    Settings {
        id: sourceStore
        category: "sources"
        property string cameras: "[]"
        Component.onCompleted: {
            try {
                app.cameraIds = JSON.parse(cameras)
            } catch (e) {
                app.cameraIds = []
            }
        }
    }
    function setCameras(ids) {
        app.cameraIds = ids
        sourceStore.cameras = JSON.stringify(ids)
    }
    readonly property var sources: {
        const list = [{ id: "track:0", name: "画面 1 · 主轨", kind: "track", track: 0, player: app }]
        for (const p of app.auxPlayers)
            if (p.entries.length > 0)
                list.push({ id: "track:" + p.track, name: "画面 " + (p.track + 1), kind: "track", track: p.track, player: p })
        // Names only once there are cameras: the list wakes the camera stack.
        const cams = app.cameraIds.length ? Cameras.list : []
        for (const id of app.cameraIds) {
            const c = cams.find(c => c.id === id)
            list.push({ id: "camera:" + id, name: c ? c.name : "相机（未连接）", kind: "camera" })
        }
        return list
    }
    // The sound of what the picture shows, on the picture's timing.
    AudioFollower {
        id: sound
        enabled: desk.soundOn
        source: app.shownEntry && !app.shownEntry.silent ? app.shownEntry.path : ""
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
        category: "bluetooth"
        property alias discoverable: app.discoverable
    }
    Settings {
        category: "player"
        property alias fade: app.fadeOn
        property alias fadeMs: app.fadeMs
        property alias keys: app.keysOn
        property alias loop: app.loopOn
        property alias sourceWidth: app.sourceWidth
    }
    Shortcut {
        sequences: ["Left", "A"]
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: app.keysLive && app.manualSeek && app.manualTempo && !!transport.entry
        onActivated: app.nudge(-1)
    }
    Shortcut {
        sequences: ["Right", "D"]
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: app.keysLive && app.manualSeek && app.manualTempo && !!transport.entry
        onActivated: app.nudge(1)
    }
    Shortcut {
        sequences: ["Up", "W"]
        context: Qt.ApplicationShortcut
        enabled: app.keysLive && app.manualTempo
        onActivated: app.nudgeTempo(0.01)
    }
    Shortcut {
        sequences: ["Down", "S"]
        context: Qt.ApplicationShortcut
        enabled: app.keysLive && app.manualTempo
        onActivated: app.nudgeTempo(-0.01)
    }
    // Effects: 1–9 and 0 (the number pad too) switch the first ten in the
    // list, , and . tune the last one; their own switch in the effects panel.
    readonly property bool effectKeysLive: Live.keysOn && !app.typing && !sender.visible
    Instantiator {
        model: 10
        delegate: Shortcut {
            required property int index
            readonly property string digit: String((index + 1) % 10)
            sequences: [digit, "Num+" + digit]
            context: Qt.ApplicationShortcut
            autoRepeat: false
            enabled: app.effectKeysLive && index < Live.order.length
            onActivated: Live.toggleEffect(Live.order[index])
        }
    }
    Shortcut {
        sequences: [","]
        context: Qt.ApplicationShortcut
        enabled: app.effectKeysLive
        onActivated: Live.tune(-0.05)
    }
    Shortcut {
        sequences: ["."]
        context: Qt.ApplicationShortcut
        enabled: app.effectKeysLive
        onActivated: Live.tune(0.05)
    }
    Shortcut {
        sequences: ["Return", "Enter"]
        context: Qt.ApplicationShortcut
        enabled: app.keysLive && app.manualSeek && !!timeline.markClip
        onActivated: timeline.jump()
    }
    Shortcut {
        sequences: ["-", "Num+-"]
        context: Qt.ApplicationShortcut
        enabled: app.keysLive
        onActivated: timeline.zoomStep(1 / 1.3)
    }
    Shortcut {
        sequences: ["=", "+", "Num++"]
        context: Qt.ApplicationShortcut
        enabled: app.keysLive
        onActivated: timeline.zoomStep(1.3)
    }
    Shortcut {
        sequence: "\\"
        context: Qt.ApplicationShortcut
        enabled: app.keysLive
        onActivated: timeline.fit()
    }

    // The Sets' drawer over the canvas's left side: put away at every start,
    // brought out by its key in the top bar, Ctrl+B (⌘B) or files dragged to
    // it; a press elsewhere on the canvas or Esc puts it away. Choosing a Set
    // leaves it out, and so does anything of its own in use, a menu or a
    // dialog. The red question about turning off the entry on the screen is
    // never put away unseen: such a press answers it with no and leaves the
    // drawer out.
    property bool setsOpen: false
    function closeSets() {
        if (sidebar.confirmId !== "")
            sidebar.confirmId = ""
        else if (!sidebar.holding())
            app.setsOpen = false
    }
    function toggleSets() {
        if (app.setsOpen)
            app.closeSets()
        else
            app.setsOpen = true
    }
    Shortcut {
        sequence: "Ctrl+B"
        context: Qt.ApplicationShortcut
        enabled: !sender.visible
        onActivated: app.toggleSets()
    }
    // Not while a sticker is chosen (the desk's Esc lets it go first) or the
    // drawer's own menu closes on it. Another popup of this window that closes
    // on Esc shares the key: each press then puts one of them away.
    Shortcut {
        sequence: "Esc"
        enabled: app.setsOpen && desk.chosenSid === "" && !desk.editing && !sidebar.asking
        onActivated: app.closeSets()
        onActivatedAmbiguously: app.closeSets()
    }

    // Light or dark for what the system draws too (dialogs, menus, the
    // window's keys), where it allows that.
    function applyScheme() {
        if (Theme.scheme === "")
            return
        try {
            Qt.styleHints.colorScheme = Theme.dark ? Qt.ColorScheme.Dark : Qt.ColorScheme.Light
        } catch (e) {
        }
    }
    Connections {
        target: Theme
        function onDarkChanged() { app.applyScheme() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        TopBar {
            Layout.fillWidth: true
            inset: app.visibility === Window.FullScreen ? 0 : app.titleInset
            titleHeight: app.visibility === Window.FullScreen ? 0 : app.titleHeight
            status: [projection.visible ? "投放中" : projection.waiting ? "投放屏已断开，接回后自动恢复" : "",
                     app.running ? app.phaseText(app.phase) : ""].filter(t => t).join(" · ")
            live: projection.visible
            canSend: !app.following
            onSend: app.openSender()
        }

        // The canvas across the whole width, the Sets' drawer over its left side.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // —— The canvas: the live desk, and smart following; under them
            // what goes over the picture ——
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.gap
                spacing: Theme.gap
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Theme.gap

                    Desk {
                        id: desk
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        source: projection.surface
                        entry: projection.entry
                        projection: projection
                        sound: sound
                        sourceIds: app.sources.map(s => s.id)
                    }

                    // —— The sources, then the preview to put on the air ——
                    SourceColumn {
                        Layout.preferredWidth: app.sourceWidth
                        Layout.fillWidth: false
                        Layout.fillHeight: true
                        sources: app.sources
                        textures: desk.textures
                        slot: mixer.selected
                        cameraIds: app.cameraIds
                        onAddCamera: id => app.setCameras(app.cameraIds.concat([id]))
                        onRemoveCamera: id => app.setCameras(app.cameraIds.filter(c => c !== id))
                        // Its right edge widens or narrows it.
                        MouseArea {
                            anchors.right: parent.right
                            anchors.rightMargin: -Theme.gap / 2 - 3
                            width: 6
                            height: parent.height
                            cursorShape: Qt.SplitHCursor
                            property real from
                            property real start
                            onPressed: mouse => {
                                from = app.sourceWidth
                                start = mapToItem(null, mouse.x, 0).x
                            }
                            onPositionChanged: mouse => app.sourceWidth = Math.max(120, Math.min(360, from + mapToItem(null, mouse.x, 0).x - start))
                        }
                    }
                    Card {
                        Layout.preferredWidth: 340
                        Layout.fillWidth: false
                        Layout.fillHeight: true
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.gap
                            spacing: Theme.gap
                            SwitcherPanel {
                                id: mixer
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                sources: app.sources
                                textures: desk.textures
                                aspect: desk.aspect
                            }
                            LayoutPresets {
                                Layout.fillWidth: true
                                columns: 6
                                columnSpacing: 4
                                sources: app.sources
                                aspect: desk.aspect
                            }
                        }
                    }

                    // —— Effects, at the far right ——
                    Effects {
                        Layout.preferredWidth: 300
                        Layout.fillWidth: false
                        Layout.fillHeight: true
                    }
                }
                LiveBar {
                    Layout.fillWidth: true
                    desk: desk
                }
            }

            // While the drawer is out a press anywhere else on the canvas puts
            // it away and does nothing more; the picture is never dimmed.
            MouseArea {
                anchors.fill: parent
                visible: app.setsOpen
                onPressed: app.closeSets()
            }
            // Files dragged to the canvas's left edge bring the drawer out, to
            // be dropped on a Set.
            DropArea {
                width: Theme.gap
                height: parent.height
                enabled: !app.setsOpen
                onEntered: drag => {
                    drag.accepted = false
                    app.setsOpen = true
                }
            }

            // The drawer's key, at the top left of the canvas where the drawer's
            // own head has it: put away, only the key stays, over the stage's
            // corner. Files dragged onto it bring the drawer out too.
            IconButton {
                x: 8
                y: (44 - height) / 2
                z: 2
                visible: !app.setsOpen
                iconName: "panel-left"
                tip: "素材（" + (Qt.platform.os === "osx" ? "⌘B" : "Ctrl+B") + "）"
                onClicked: app.toggleSets()
                background: Rectangle {
                    radius: Theme.radius
                    color: parent.hovered ? Theme.hover : Theme.raised
                    border.width: 1
                    border.color: Theme.line
                }
                DropArea {
                    anchors.fill: parent
                    onEntered: drag => {
                        drag.accepted = false
                        app.setsOpen = true
                    }
                }
            }

            // —— Sets and their entries: the drawer ——
            Item {
                id: drawer
                readonly property real spread: 24
                width: 280
                height: parent.height
                x: -width - spread
                visible: x > -width - spread
                states: State {
                    name: "out"
                    when: app.setsOpen
                    PropertyChanges { drawer.x: 0 }
                }
                transitions: [
                    Transition {
                        to: "out"
                        NumberAnimation { property: "x"; duration: Theme.quick; easing.type: Easing.OutCubic }
                    },
                    Transition {
                        from: "out"
                        NumberAnimation { property: "x"; duration: 200; easing.type: Easing.InCubic }
                    }
                ]

                // A soft shadow over the canvas, in layers that fade outwards.
                Repeater {
                    model: 8
                    Rectangle {
                        required property int index
                        width: drawer.width + (index + 1) * drawer.spread / 8
                        height: drawer.height
                        radius: Theme.radiusLg + (index + 1) * drawer.spread / 8
                        topLeftRadius: 0
                        bottomLeftRadius: 0
                        color: Qt.rgba(0, 0, 0, Theme.shadow.a / 8)
                    }
                }
                // Presses and the wheel on the drawer stay on it, never reach
                // the canvas under it.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    hoverEnabled: true
                    onWheel: wheel => wheel.accepted = true
                }
                Sidebar {
                    id: sidebar
                    anchors.fill: parent
                    radius: Theme.radiusLg
                    topLeftRadius: 0
                    bottomLeftRadius: 0
                    sets: app.sets
                    currentSet: app.currentSet
                    running: app.running
                    editable: app.editable
                    playingId: app.shownEntry ? app.shownEntry.id : ""
                    playingSetId: app.playingSet ? app.playingSet.id : ""
                    onSelectSet: id => app.chooseSet(id)
                    onAddUrls: urls => app.addUrls(urls)
                    onDropPlaying: id => app.dropPlaying(id)
                    onPutAway: app.closeSets()
                }
            }
        }

        // —— The player's timeline, across the whole foot ——
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.line
        }
        Timeline {
            id: timeline
            objectName: "timeline"
            Layout.fillWidth: true
            entries: app.mainEntries
            // The main track, and the aux ones that have something on them.
            tracks: [{ track: 0, name: "画面 1", entries: app.mainEntries, player: app }].concat(
                app.auxPlayers.filter(p => p.entries.length > 0)
                    .map(p => ({ track: p.track, name: "画面 " + (p.track + 1), entries: p.entries, player: p })))
            trailing: FollowStrip {
                id: strip
                app: app
                surface: projection.surface
                rowHeight: timeline.mainRowHeight
            }
            setId: app.currentSet ? app.currentSet.id : ""
            setName: app.currentSet ? app.currentSet.name : ""
            running: app.running
            phase: app.phase
            player: app
        }
    }

    // `--add <file or folder>` adds it at start, the same way the add keys do.
    Component.onCompleted: {
        if (advertising)
            Engine.listenBluetooth(true, receiving)
        const args = Qt.application.arguments
        for (let i = 0; i + 1 < args.length; ++i)
            if (args[i] === "--add")
                app.addUrls([Engine.fileUrl(args[i + 1])])
        app.cue()
        app.applyScheme()
        // A first start has no Set yet: show where they are made.
        if (!app.sets || app.sets.length === 0)
            app.setsOpen = true
    }

    // Closing the window (its key, Cmd+W, Alt+F4, quitting) during a show is
    // asked first: it would stop following and take the picture away.
    property bool quitting: false
    MessageDialog {
        id: quitDialog
        title: "退出 KVJ？"
        text: projection.visible ? "投放正在进行，退出会收起投放画面" + (app.running ? "并停止跟随。" : "。")
                                 : "跟随正在进行，退出会停止它。"
        buttons: MessageDialog.Ok | MessageDialog.Cancel
        onAccepted: {
            app.quitting = true
            Qt.quit()
        }
    }
    // The projection's own close (its key, Alt+F4 while it has the focus) is
    // asked here, on the operator's screen, never on the audience's.
    MessageDialog {
        id: hideDialog
        title: "收起投放？"
        text: "投放画面会从屏幕上收起。"
        buttons: MessageDialog.Ok | MessageDialog.Cancel
        onAccepted: projection.closeOutput()
    }
    Connections {
        target: projection
        function onCloseAsked() { hideDialog.open() }
    }
    onClosing: close => {
        if (!app.quitting && app.visible && (app.running || projection.visible)) {
            close.accepted = false
            quitDialog.open()
            return
        }
        app.quitting = true
        if (app.running)
            Engine.stop()
        projection.closeOutput()
    }
}
