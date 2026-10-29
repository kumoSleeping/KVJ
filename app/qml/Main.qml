import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Window
import QtQuick.Layouts
import KVJ

// The operator's one window, a player first: a top bar (in the title bar's row
// on macOS) with the light or dark look, and under
// it the canvas, all on one plain ground: the board (the picture, made and
// seen in one place, the panel of stickers, words and reactions and effects
// out at its right when wanted), at the far right the audience's picture over
// smart following, the Sets and their entries in a drawer over its left
// side; across the whole foot the player's timeline, one track or two. While smart following is on it plays the
// picture from the music (where, and how fast) and the player's own keys rest;
// paused or stopped, the player carries on from there. The projection window
// shows only the picture.
ApplicationWindow {
    id: app
    width: Math.min(1480, Screen.desktopAvailableWidth)
    height: Math.min(900, Screen.desktopAvailableHeight)
    minimumWidth: 1180
    minimumHeight: 680
    visible: true
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
    readonly property bool running: ["indexing", "permission", "listening", "matched", "searching"].indexOf(phase) >= 0
    readonly property var match: Engine.matched && Engine.matched.entry ? Engine.matched : null
    property var lastMatch: null
    // Smart following is on. Its two helpers (Assistants) pause on their own:
    // 对速 keeps the speed with the music, 跳转 moves the picture to where the
    // music is. With both at work following draws the picture once it has found
    // the music; with one paused the player draws it and the other helper steers
    // the player (steer()); with both paused it only listens.
    readonly property bool following: running
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
    // A recording input (a microphone) hears the room: 现场模式 starts on for it
    // and off for captured audio; the operator may switch it either way.
    readonly property bool microphone: !!device && device.kind === "input"
    // The system title bar the top bar stands in for (main.cpp, macOS): room for
    // the window's keys at its left, and its height; 0 where the system keeps it.
    property real titleInset: 0
    property real titleHeight: 0
    property bool titleReachesContent: false

    // The player's keys, always on: ←/→, A/D or 4/6 on
    // the number pad, held, play the picture at 0.7 or 1.5 of its speed until
    // let go (never a jump; paused, a press steps a second); ↑/↓, W/S or 8/2
    // change the speed by 1%; Enter plays from the timeline's cursor; − and =
    // zoom the timeline out and in, \ shows the whole Set, as in Premiere.
    // None while words are typed.
    // Space is the board's 投放 (only in 投放 mode, with changes waiting).
    readonly property bool keysOn: true
    readonly property bool typing: !!activeFocusItem && typeof activeFocusItem.selectedText === "string"
    // They work from the projection window too (it takes the focus when it
    // opens).
    readonly property bool keysLive: keysOn && !typing

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
    // paused at its start, until something of it is played (Enter, 跳至
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
    // The one 渐变 (the timeline's slider): every jump, by hand or by
    // following, and every 上屏 dissolves for fadeMs; 0 cuts straight.
    readonly property bool fadeOn: fadeMs > 0
    Binding {
        target: Switcher
        property: "fadeMs"
        value: app.fadeMs
    }
    // At the end of the Set's last entry: start over from its first entry, or
    // stop on the last frame.
    property bool loopOn: false
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
    onEntriesChanged: {
        Qt.callLater(app.switchAfterReplace)
        cue()
    }

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
        // (On the first entries change the bindings above may not have run yet.)
        const first = (app.mainEntries || []).find(e => e.enabled !== false)
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
    // The keys act on the track row last pressed on the timeline (its
    // activeTrack): 画面 1's player is this window's own, the others their
    // TrackPlayer, whose keys rest while following leads it.
    readonly property int keyTrack: Math.max(0, timeline.activeTrack)
    readonly property var keyPlayer: keyTrack > 0 ? app.auxPlayers[keyTrack - 1] : null
    function toggle() {
        if (app.keyPlayer) {
            app.keyPlayer.toggle()
            return
        }
        if (!app.manualSeek)
            return
        transport.toggle()
        app.tick()
    }
    // A paused track that comes onto the picture (a quick cut, [ / ], 跳转置顶,
    // 投放, dragged in while following) starts playing. What is on the picture
    // as KVJ starts is only noted.
    property var shownBefore: null
    function noteShown() {
        app.shownBefore = Switcher.loaded ? Switcher.shownSourcesOf(Switcher.program) : null
    }
    Connections {
        target: Switcher
        function onLoadedChanged() { app.noteShown() }
        function onProgramChanged() { app.playShown() }
    }
    function playShown() {
        const before = app.shownBefore
        if (!before)
            return
        const now = Switcher.shownSourcesOf(Switcher.program)
        app.shownBefore = now
        for (const id of now) {
            if (before.indexOf(id) >= 0 || !id.startsWith("track:"))
                continue
            const t = Number(id.substring(6))
            if (t === 0) {
                if (app.manualSeek && transport.entry && !transport.playing) {
                    transport.toggle()
                    app.tick()
                }
            } else {
                const p = app.auxPlayers[t - 1]
                if (p && !p.playing)
                    p.toggle()
            }
        }
    }
    function seekBy(seconds) {
        if (app.keyPlayer) {
            const p = app.keyPlayer
            if (p.entry)
                p.seek(p.entry, p.now() + seconds)
            return
        }
        if (!app.manualSeek || !transport.entry)
            return
        transport.seek(transport.now() + seconds)
        app.tick()
    }
    function nudgeTempo(step) {
        if (app.keyPlayer && !timeline.tempoLinked) {
            if (!app.keyPlayer.lead)
                app.keyPlayer.setSpeed(app.keyPlayer.speed + step)
            return
        }
        if (app.manualTempo)
            transport.setTempo(transport.tempo + step)
    }
    // The picture ahead (direction > 0) or back by playing faster or slower
    // until `letGo` (or for `ms`), instead of a jump.
    function nudge(direction, ms) {
        // 同步变速: 画面 1 is bent and 画面 2 plays at its speed, bend and
        // all; paused, both step.
        if (timeline.tempoLinked) {
            if (!app.manualSeek || !app.manualTempo || !transport.entry)
                return
            transport.nudge(direction, ms || 0)
            if (!transport.playing && aux1.entry && !aux1.lead)
                aux1.clock.nudge(direction, ms || 0)
            app.tick()
            return
        }
        if (app.keyPlayer) {
            const p = app.keyPlayer
            if (!p.lead && p.entry)
                p.clock.nudge(direction, ms || 0)
            return
        }
        if (!app.manualSeek || !app.manualTempo || !transport.entry)
            return
        transport.nudge(direction, ms || 0)
        app.tick()
    }
    // A nudge key let go (main.cpp sees the release; 0 when the app loses the
    // keyboard, which would never hear it): every player, the row may have
    // changed meanwhile.
    function letGo(direction) {
        transport.letGo(direction)
        for (const p of app.auxPlayers)
            p.clock.letGo(direction)
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
        if (app.running)
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
            if (next || first) {
                transport.cut()
                transport.load(next || first, 0, true)
            } else {
                transport.setPlaying(false)
            }
            app.playhead = transport.now()
        }
    }

    // Development aid, through KVJ_DEV_DIR/cmd (main.cpp): drive the player
    // from a shell. "play <entry no.> <seconds>", "pause", "resume", "tempo
    // <rate>", "fade <ms>" (0 = off), "listen", "follow", "here", "stop", "hold [tempo|jump]";
    // on the timeline "zoom <factor> <x>", "mark <x>" (x in px
    // along the strip), "jump"; "post <px> <py> <words>" posts a sticker of
    // words and chooses it; "nudge <±1> <ms>" holds a nudge key that long;
    // "drop" turns the entry on the screen off as the sidebar's confirmed
    // second press does; "effect <key> <0–1>" sets an effect, "move <from>
    // <to>" reorders them; "set <no.>" chooses that Set as the sidebar does;
    // "library 0|1" puts the column at the left away or brings it out.
    // "single 0|1" switches 单轨 on or off; "zoom <0.4–1>" sizes the board's view;
    // "dragsim X Y | off" shows the track rows as a drag at (X, Y) would.
    function devCommand(line) {
        const w = String(line).trim().split(/\s+/)
        switch (w[0]) {
        case "play": app.play(app.mainEntries[Math.max(0, Number(w[1] || 1) - 1)], Number(w[2] || 0)); transport.setPlaying(true); break
        case "pause": transport.setPlaying(false); break
        case "resume": transport.setPlaying(true); break
        case "tempo": transport.setTempo(Number(w[1])); break
        case "fade": app.fadeMs = Math.max(0, Number(w[1]) || 0); break
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
        case "zoom": timeline.zoomAt(Number(w[2] || 0), Number(w[1])); break
        case "mark": timeline.setMark(Number(w[1])); break
        case "jump": timeline.jump(); break
        case "nudge": app.nudge(Number(w[1] || 1), Number(w[2] || 1000)); break
        case "drop": if (transport.entry) app.dropPlaying(transport.entry.id); break
        case "effect": Live.setLevel(w[1], Number(w[2] || 0)); break
        case "move": Live.moveEffect(Number(w[1]), Number(w[2])); break
        case "set": if (app.sets[Number(w[1] || 1) - 1]) app.chooseSet(app.sets[Number(w[1] || 1) - 1].id); break
        case "post": mixer.chosenSid = Live.post({ kind: "text", text: w.slice(3).join(" "), name: "", px: Number(w[1]), py: Number(w[2]), size: 0.15 }); break
        case "apply": Switcher.apply(); break
        case "mixfollow": Switcher.follow = Number(w[1] || 0) > 0; break
        case "line": if (mixer.selected < 0) mixer.selected = 0; mixer.addLine(); break
        case "pick": mixer.selected = Number(w[1] || 0); break
        case "fill": mixer.fill(Math.max(0, mixer.selected)); break
        case "revert": Switcher.revert(); break
        case "library": app.libraryShown = Number(w[1] || 0) > 0; break
        case "single": app.setSingle(Number(w[1] || 0) > 0); break
        case "boardzoom": mixer.setZoom(Number(w[1] || 1)); break
        case "dragsim":
            timeline.dropTitle = "测试.mp4"
            timeline.dragWidth = timeline.width
            timeline.dragX = Number(w[1] || 0)
            timeline.dragY = Number(w[2] || 0)
            timeline.dragging = w[1] !== undefined && w[1] !== "off"
            break
        case "noline": Switcher.setMask(Math.max(0, mixer.selected), { lines: [] }); break
        default: return "unknown"
        }
        app.tick()
        return "ok"
    }

    // Files into the Set shown: into its library (the drawer's keys and
    // drops), or placed on a track (dropped on the timeline; `track` set).
    function addUrls(urls, track) {
        if (!urls || urls.length === 0 || !app.editable)
            return
        if (!app.currentSet)
            Engine.createSet("Set " + (app.sets.length + 1))
        if (app.currentSet)
            Engine.importUrls(app.currentSet.id, urls, track === undefined ? 0 : track, track !== undefined)
    }
    // The drawer is the Set's library; an entry is on the timeline once it
    // is placed on a track (it is then on, and followed if the track is).
    function placeOn(ids, track) {
        for (const set of app.sets) {
            const mine = ids.filter(id => set.entries.some(e => e.id === id))
            if (!mine.length)
                continue
            // An edit, after what is on the track, in the order dropped (one
            // placed on the other track gets a copy here: the same video may
            // play on both).
            if (app.editable) {
                Engine.placeEntries(set.id, mine, track)
                continue
            }
            // While following runs only turning on works: those of this track.
            const off = mine.filter(id => set.entries.some(e => e.id === id && (e.track || 0) === track && e.enabled === false))
            if (off.length)
                Engine.enableEntries(set.id, off, true)
        }
    }
    // Entries off their track, back to the library: a copy (the same file
    // also elsewhere in the library) goes, once editing is allowed.
    function takeOffTrack(set, ids) {
        const twin = id => {
            const e = set.entries.find(e => e.id === id)
            return !!e && set.entries.some(o => o.id !== id && o.path === e.path)
        }
        const copies = app.editable ? ids.filter(twin) : []
        for (const id of copies)
            Engine.removeEntry(set.id, id)
        const rest = ids.filter(id => copies.indexOf(id) < 0)
        if (rest.length)
            Engine.enableEntries(set.id, rest, false)
    }
    // Dropped from the drawer (or the Finder) onto a track: what was on it
    // goes back to the library and the drop takes its place, as a record put
    // on a deck. Not while following runs on that track (it would lose its
    // material).
    function replaceOn(ids, track) {
        if (app.running && app.followTrack === track)
            return app.placeOn(ids, track)
        const gone = app.placedOn(track).map(e => e.id).filter(id => ids.indexOf(id) < 0)
        if (gone.length && app.currentSet)
            app.takeOffTrack(app.currentSet, gone)
        const first = app.entries.find(e => e.id === ids[0])
        if (first)
            app.switchWhenPlaced(track, String(Engine.fileUrl(first.path)))
        app.placeOn(ids, track)
    }
    // After a replace the track's player goes straight to the first of what
    // was dropped, playing on if it played (what played before is no longer
    // on the track, and would otherwise stay on screen till it ended); once
    // the engine has it placed (an import takes a moment).
    property var replacing: null  // { track, url, playing }
    function trackPlayer(t) {
        return t === 0 ? transport : app.auxPlayers[t - 1].clock
    }
    function switchWhenPlaced(track, url) {
        app.replacing = { track: track, url: url, playing: app.trackPlayer(track).playing }
        app.switchAfterReplace()
    }
    function switchAfterReplace() {
        const w = app.replacing
        if (!w)
            return
        const e = app.placedOn(w.track).find(e => String(Engine.fileUrl(e.path)) === w.url)
        if (!e)
            return
        app.replacing = null
        const p = app.trackPlayer(w.track)
        if (!p.entry || p.entry.id !== e.id)
            p.load(e, 0, w.playing)
    }
    function replaceWithFiles(urls, track) {
        if (!urls || urls.length === 0 || !app.editable)
            return
        const gone = app.placedOn(track).map(e => e.id)
        if (gone.length && app.currentSet)
            app.takeOffTrack(app.currentSet, gone)
        app.addUrls(urls, track)
    }
    // Back to the library only.
    function takeOff(id) {
        for (const set of app.sets)
            if (set.entries.some(e => e.id === id))
                app.takeOffTrack(set, [id])
    }
    // A track's entries on the timeline (placed).
    function placedOn(track) {
        return app.entries.filter(e => (e.track || 0) === track && e.enabled !== false)
    }
    // A double-click in the drawer: onto the first track from the top with
    // nothing on it, else the first track's end.
    function placeAnywhere(ids) {
        const empty = app.trackRows.find(r => app.placedOn(r.track).length === 0)
        app.placeOn(ids, empty ? empty.track : 0)
    }

    // —— The files at the left (Library) ——
    // Each library entry by its file's URL (the same file may be in it more
    // than once: one placed on each track).
    readonly property var entriesByUrl: {
        const out = {}
        for (const e of app.entries) {
            const u = String(Engine.fileUrl(e.path))
            ;(out[u] = out[u] || []).push(e)
        }
        return out
    }
    // The tracks a file is placed on.
    function placedTracksOf(url) {
        return (app.entriesByUrl[url] || []).filter(e => e.enabled !== false).map(e => e.track || 0)
                                            .filter((t, i, all) => all.indexOf(t) === i).sort()
    }
    // The folders the library's videos are in, outermost only: where the
    // file list starts the first time.
    function libraryFolders() {
        const dirs = []
        for (const u of Object.keys(app.entriesByUrl)) {
            const d = u.substring(0, u.lastIndexOf("/"))
            if (dirs.indexOf(d) < 0)
                dirs.push(d)
        }
        dirs.sort()
        return dirs.filter(d => !dirs.some(o => o !== d && d.startsWith(o + "/")))
    }
    // Video files onto `track`: after what is on it (`append`), or in its
    // place. A file already in the library is placed as that entry; the
    // others are imported.
    function dropFilesOn(urls, track, append) {
        const list = Array.prototype.slice.call(urls || []).map(u => String(u)).filter(u => /\.(mp4|m4v|mkv|mov|webm)$/i.test(u))
        if (!list.length)
            return
        const known = [], fresh = []
        for (const u of list) {
            const mine = app.entriesByUrl[u] || []
            const e = mine.find(e => (e.track || 0) === track) || mine[0]
            if (e)
                known.push(e.id)
            else
                fresh.push(u)
        }
        if (!append) {
            if (app.running && app.followTrack === track)
                return app.dropFilesOn(urls, track, true)
            const gone = app.placedOn(track).map(e => e.id).filter(id => known.indexOf(id) < 0)
            if (gone.length && app.currentSet)
                app.takeOffTrack(app.currentSet, gone)
            app.switchWhenPlaced(track, list[0])
        }
        if (known.length)
            app.placeOn(known, track)
        if (fresh.length)
            app.addUrls(fresh, track)
    }
    // A double-click on videos at the left: onto the first empty track, else after the first's.
    function filesAnywhere(urls) {
        const empty = app.trackRows.find(r => app.placedOn(r.track).length === 0)
        app.dropFilesOn(urls, empty ? empty.track : 0, true)
    }
    // KVJ keeps one library of videos (the engine's first Set): an older
    // document with several is made one, an empty one gets its library.
    function oneLibrary() {
        if (app.running || Engine.importing)
            return
        if (app.sets.length === 0)
            Engine.createSet("素材库")
        else if (app.sets.length > 1)
            Engine.mergeSets()
    }
    Connections {
        target: Engine
        function onDocumentChanged() { Qt.callLater(app.oneLibrary) }
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
        case "searching": return "重新检索"
        case "prepared": return "索引就绪"
        case "failed": return "失败"
        case "stopped": return "已停止"
        default: return ""
        }
    }

    // No screen goes dark and no computer sleeps while the picture is out or
    // the music is heard: nobody touches the computer during a show.
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
    // The aux tracks of the Set shown on the timeline; what one plays stays
    // while another Set is looked at (TrackPlayer.arrive).
    readonly property var auxEntries: app.entries
    TrackPlayer {
        id: aux1
        track: 1
        entries: app.auxEntries.filter(e => (e.track || 0) === 1)
        lead: app.aiPicture && app.followTrack === 1 ? { match: app.match, offsetMs: strip.offsetMs } : null
        // Linked (同步变速), 画面 1's speed as played, a held bend included.
        mainRate: timeline.tempoLinked ? app.shownSpeed : app.shownTempo
    }
    // 同步变速 on: 画面 2 at 画面 1's speed exactly; off: it keeps the
    // speed it had, on its own again.
    Connections {
        target: timeline
        function onTempoLinkedChanged() { app.linkTempo() }
    }
    function linkTempo() {
        if (timeline.tempoLinked) {
            aux1.speed = 1
            aux1.followMain = true
        } else if (aux1.followMain) {
            aux1.speed = Math.round(app.shownTempo * 1000) / 1000
            aux1.followMain = false
        }
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
        return { entry: p.entry, position: p.position, rate: p.rate, clockAtMs: p.clockAtMs, offsetMs: p.offsetMs,
                 // Paused (and not followed), it cuts, as the main track does.
                 cut: p.clock.cutting || (!p.lead && !p.clock.playing) }
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
        // Paused, the picture is being set up by hand: it cuts, never dissolves.
        fadeMs: app.fadeOn && !transport.cutting && (app.aiMain || transport.playing) ? app.fadeMs : 0
        maxHeight: desk.maxHeight
        maxFps: desk.maxFps
        auxTimings: [app.auxTiming(1), app.auxTiming(2), app.auxTiming(3)]
        cameraIds: app.cameraIds
        wantedIds: desk.allIds
    }
    // The picture sources on offer to the mixer (Switcher): the tracks shown
    // and the cameras taken in (on the board, not on the timeline).
    property var cameraIds: []
    Settings {
        id: sourceStore
        category: "sources"
        property string cameras: "[]"
        property string tracks: "[]"
        property alias single: app.singleTrack
        property alias solo: app.soloTrack
        Component.onCompleted: {
            try {
                app.cameraIds = JSON.parse(cameras)
            } catch (e) {
                app.cameraIds = []
            }
            // In 单轨 the track not kept waits aside, in 双轨 both are back;
            // the layers of any others wait aside.
            Qt.callLater(() => {
                for (const t of [0, 1]) {
                    if (app.singleTrack && t !== app.soloTrack)
                        Switcher.setAside("track:" + t)
                    else
                        Switcher.bringBack("track:" + t)
                }
                for (const t of [2, 3])
                    Switcher.setAside("track:" + t)
            })
        }
    }
    // 单轨: one track on the timeline and the board, the one that was
    // playing (soloTrack), so its picture and sound carry on untouched; the
    // other stops, its entries stay on it and its layer waits aside until
    // 双轨 brings it back where it was.
    property bool singleTrack: false
    property int soloTrack: 0
    // The track 单轨 set aside was playing then (setSingle).
    property bool asideWasPlaying: false
    // The track to keep: the one following follows while it runs, else the
    // one playing, else the one on top on the air when both play, else the
    // row last pressed on the timeline (the one the keys act on).
    function keptTrack() {
        if (app.running && (app.followTrack === 0 || app.followTrack === 1))
            return app.followTrack
        const playing = [transport.playing, aux1.playing]
        if (playing[0] !== playing[1])
            return playing[1] ? 1 : 0
        if (!playing[0] && (timeline.activeTrack === 0 || timeline.activeTrack === 1))
            return timeline.activeTrack
        return timeline.onTop === "track:1" ? 1 : 0
    }
    function setSingle(on) {
        if (on === app.singleTrack)
            return
        if (on) {
            const keep = app.keptTrack()
            const other = 1 - keep
            // Paused while set aside, and started again when it comes back.
            app.asideWasPlaying = other === 1 ? aux1.playing : transport.playing
            if (other === 1 && aux1.playing)
                aux1.toggle()
            else if (other === 0 && transport.playing && app.manualSeek) {
                transport.toggle()
                app.tick()
            }
            Switcher.setAside("track:" + other)
            app.soloTrack = keep
            // Following listens to the track shown.
            if (!app.running)
                strip.followTrack = keep
        } else {
            // Back where it was: not a track coming onto the picture, which
            // playShown would start, but playing again if 单轨 paused it (on
            // top, a paused one would hold the picture still).
            const other = 1 - app.soloTrack
            app.shownBefore = null
            Switcher.bringBack("track:" + other)
            app.noteShown()
            if (app.asideWasPlaying) {
                if (other === 1 && !aux1.playing)
                    aux1.toggle()
                else if (other === 0 && !transport.playing && app.manualSeek && transport.entry) {
                    transport.toggle()
                    app.tick()
                }
            }
            app.asideWasPlaying = false
        }
        app.singleTrack = on
    }
    function setCameras(ids) {
        app.cameraIds = ids
        sourceStore.cameras = JSON.stringify(ids)
    }
    function addCamera(id) {
        if (app.cameraIds.indexOf(id) < 0)
            app.setCameras(app.cameraIds.concat([id]))
    }
    // A camera taken in that goes away (unplugged, the iPhone taken off)
    // leaves the board by itself once it has been missing for 10 seconds on
    // end: one that drops out of the list for a moment stays, its layer saying
    // 相机已断开 until it is back. One not yet seen this run may still be
    // waking, and is given a few seconds from the start before that.
    property var seenCameras: ({})
    property bool camerasSettled: false
    // Since when each camera taken in has been missing (Date.now()), by id.
    property var missingCameras: ({})
    Timer {
        interval: 6000
        running: !app.camerasSettled && app.cameraIds.length > 0
        onTriggered: {
            app.camerasSettled = true
            app.checkCameras()
        }
    }
    // Looked at again while one is missing: the list may not change again.
    Timer {
        interval: 1000
        repeat: true
        running: Object.keys(app.missingCameras).length > 0
        onTriggered: app.checkCameras()
    }
    function checkCameras() {
        const now = app.cameraIds.length ? Cameras.list.map(c => c.id) : []
        // An empty list may be the camera stack not answering: nothing goes on that.
        if (!now.length) {
            if (!app.cameraIds.length)
                app.missingCameras = ({})
            return
        }
        const seen = Object.assign({}, app.seenCameras)
        for (const id of now)
            seen[id] = true
        app.seenCameras = seen
        const at = Date.now()
        const missing = {}
        const gone = []
        for (const id of app.cameraIds) {
            if (now.indexOf(id) >= 0 || !(seen[id] || app.camerasSettled))
                continue
            const since = app.missingCameras[id] !== undefined ? app.missingCameras[id] : at
            if (at - since >= 10000)
                gone.push(id)
            else
                missing[id] = since
        }
        app.missingCameras = missing
        for (const id of gone)
            app.removeCamera("camera:" + id)
    }
    onCameraIdsChanged: Qt.callLater(app.checkCameras)
    Connections {
        target: app.cameraIds.length ? Cameras : null
        function onChanged() { app.checkCameras() }
    }
    function removeCamera(key) {
        app.setCameras(app.cameraIds.filter(c => "camera:" + c !== key))
        Switcher.rename({ [key]: "" })
    }
    // Two tracks, as a DJ's two decks, or one (单轨).
    readonly property var shownTracks: app.singleTrack ? [app.soloTrack] : [0, 1]
    readonly property var shownAux: app.shownTracks.filter(t => t > 0)
    // The timeline's rows: the tracks shown.
    readonly property var trackRows: app.shownTracks.map(t => {
        if (t === 0)
            return { key: "track:0", kind: "track", track: 0, name: "画面 1",
                     entries: app.entries.filter(app.isMain), player: app }
        const p = app.auxPlayers[t - 1]
        return { key: "track:" + t, kind: "track", track: t, name: "画面 " + (t + 1), entries: p.entries, player: p }
    })
    // The mixer's sources: the tracks, then the cameras. Names only once
    // there are cameras: the list wakes the camera stack.
    readonly property var sources: {
        const list = app.trackRows.map(r => ({ id: r.key, name: r.name }))
        const cams = app.cameraIds.length ? Cameras.list : []
        const errors = projection.cameraErrors
        for (const id of app.cameraIds) {
            const c = cams.find(c => c.id === id)
            list.push({ id: "camera:" + id, name: c ? c.name : "相机（未连接）", error: errors[id] || "" })
        }
        return list
    }
    // A track emptied: what is on it goes back to the library. Not while
    // following runs (it is an edit).
    // A track's name pressed on the timeline: its layer chosen on the board.
    function pickSource(key) {
        mixer.selectSource(key)
    }
    function clearTrack(t) {
        if (!app.editable || !app.currentSet)
            return
        const placed = app.placedOn(t).map(e => e.id)
        if (placed.length)
            app.takeOffTrack(app.currentSet, placed)
    }
    // Each track's sound on its own timing (desk.hears1 / hears2: the sound
    // key on, and what it plays): the picture is a mix, the sound is chosen
    // per track; both on, one mix.
    AudioFollower {
        id: sound
        enabled: desk.hears1
        source: app.shownEntry && !app.shownEntry.silent ? app.shownEntry.path : ""
        position: projection.position
        rate: projection.rate
        clockAtMs: projection.clockAtMs
        offsetMs: projection.offsetMs
        device: desk.soundDevice
        volume: desk.soundVolume
    }
    AudioFollower {
        id: sound2
        readonly property var timing: app.auxTiming(1)
        enabled: desk.hears2
        source: timing.entry && !timing.entry.silent ? timing.entry.path : ""
        position: timing.position
        rate: timing.rate
        clockAtMs: timing.clockAtMs
        offsetMs: timing.offsetMs
        device: desk.soundDevice
        volume: desk.soundVolume2
    }
    Settings {
        category: "player"
        property alias fadeMs: app.fadeMs
        property alias loop: app.loopOn
    }
    Shortcut {
        sequences: ["Left"]
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: app.keysLive && app.manualSeek && app.manualTempo && !!transport.entry
        onActivated: app.nudge(-1)
    }
    Shortcut {
        sequences: ["Right"]
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: app.keysLive && app.manualSeek && app.manualTempo && !!transport.entry
        onActivated: app.nudge(1)
    }
    Shortcut {
        sequences: ["Up"]
        context: Qt.ApplicationShortcut
        enabled: app.keysLive && app.manualTempo
        onActivated: app.nudgeTempo(0.01)
    }
    Shortcut {
        sequences: ["Down"]
        context: Qt.ApplicationShortcut
        enabled: app.keysLive && app.manualTempo
        onActivated: app.nudgeTempo(-0.01)
    }
    // Effects: 1–9 and 0 (the number pad too) switch the first ten in the
    // list, , and . tune the last one; their own switch in the effects panel.
    readonly property bool effectKeysLive: Live.keysOn && !app.typing
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
    // Reactions: Q to P send the first ten in the rail (held, a stream).
    Instantiator {
        model: Live.reactionKeys.length
        delegate: Shortcut {
            required property int index
            sequence: Live.reactionKeys[index]
            context: Qt.ApplicationShortcut
            enabled: app.effectKeysLive && index < Live.reactions.length
            onActivated: {
                Live.react(Live.reactions[index].glyph)
                Live.reactionPressed(index)
            }
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
        enabled: app.keysLive && timeline.canJump
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
    // [ and ] put 画面 1 / 画面 2 on the air alone (a track's 投放 key).
    Shortcut {
        sequence: "["
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: app.keysLive && app.shownTracks.indexOf(0) >= 0
        onActivated: mixer.takeLive("track:0")
    }
    Shortcut {
        sequence: "]"
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: app.keysLive && app.shownTracks.indexOf(1) >= 0
        onActivated: mixer.takeLive("track:1")
    }
    Shortcut {
        sequence: "\\"
        context: Qt.ApplicationShortcut
        enabled: app.keysLive
        onActivated: timeline.fit()
    }

    // The column at the left (Library): shown or put away by its key in the
    // title bar or Ctrl+B (⌘B); kept between runs.
    property bool libraryShown: true
    Settings {
        category: "library"
        property alias shown: app.libraryShown
    }
    Shortcut {
        sequence: "Ctrl+B"
        context: Qt.ApplicationShortcut
        onActivated: app.libraryShown = !app.libraryShown
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
            id: topBar
            Layout.fillWidth: true
            inset: app.visibility === Window.FullScreen ? 0 : app.titleInset
            titleHeight: app.visibility === Window.FullScreen ? 0 : app.titleHeight
            // Projecting or not is told by 输出预览's light, not here.
            status: app.running ? app.phaseText(app.phase) : ""
            drawerOpen: app.libraryShown
            onToggleDrawer: app.libraryShown = !app.libraryShown
            singleTrack: app.singleTrack
            onToggleSingle: app.setSingle(!app.singleTrack)
        }

        // The canvas across the whole width.
        Item {
            id: canvas
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

                    // —— At the left: what is ready to go on the picture, over
                    // the folders on this computer; as wide as the right column ——
                    Library {
                        id: library
                        visible: app.libraryShown
                        Layout.preferredWidth: strip.implicitWidth
                        Layout.fillWidth: false
                        Layout.fillHeight: true
                        composer: mixer
                        app: app
                    }

                    // —— The board: the picture as the audience sees it and
                    // where it is made, as large as the room allows ——
                    Composer {
                        id: mixer
                        Layout.fillWidth: true
                        Layout.preferredWidth: 400
                        Layout.minimumWidth: 300
                        Layout.fillHeight: true
                        sources: app.sources
                        textures: desk.textures
                        aspect: desk.aspect
                        entry: projection.entry
                        output: desk
                        cameraIds: app.cameraIds
                        keysHost: timeline.keysHost
                        zoomHost: topBar.zoomSlot
                        pictureTop: rightColumn.y + pgmHolder.y - y
                        onAddCamera: id => app.addCamera(id)
                    }

                    // —— At the right: what the audience sees, small, over
                    // smart following ——
                    ColumnLayout {
                        id: rightColumn
                        Layout.preferredWidth: strip.implicitWidth
                        Layout.fillWidth: false
                        Layout.fillHeight: true
                        spacing: Theme.gap

                        // 输出预览: projecting or not, at its right.
                        RowLayout {
                            id: outHead
                            Layout.fillWidth: true
                            spacing: 6
                            Heading {
                                Layout.fillWidth: true
                                text: "输出预览"
                            }
                            StatusLight {
                                word: projection.visible ? "投屏中" : projection.waiting ? "已断开" : "未投屏"
                                on: projection.visible
                            }
                        }
                        // The program (PGM) as the projection draws it, the
                        // stickers and effects on the air included; always
                        // whole (声学追踪's picture gives way instead). The
                        // board's picture lines up with its top.
                        Item {
                            id: pgmHolder
                            Layout.fillWidth: true
                            Layout.preferredHeight: width / Math.max(0.2, desk.aspect)
                            Layout.minimumHeight: width / Math.max(0.2, desk.aspect)
                            Rectangle {
                                width: Math.min(parent.width, parent.height * Math.max(0.2, desk.aspect))
                                height: width / Math.max(0.2, desk.aspect)
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: "black"
                                clip: true
                                Stage {
                                    id: pgmStage
                                    anchors.fill: parent
                                    lite: true
                                    entry: projection.entry
                                    Program {
                                        anchors.fill: parent
                                        now: pgmStage.now
                                        textures: desk.textures
                                        operator: true
                                    }
                                }
                            }
                        }

                        // —— Smart following: one, on the track chosen in it ——
                        // Nothing here is squeezed: short of room, what is
                        // under 声学追踪's keys folds into its ⋯.
                        FollowStrip {
                            id: strip
                            Layout.fillWidth: true
                            // Against the room the canvas has (the column itself
                            // grows with what it holds), after each layout pass.
                            function refold() {
                                compact = canvas.height - 2 * Theme.gap < outHead.implicitHeight + rightColumn.width / Math.max(0.2, desk.aspect)
                                                                          + fullHeight + 2 * rightColumn.spacing
                            }
                            onFullHeightChanged: Qt.callLater(refold)
                            Component.onCompleted: Qt.callLater(refold)
                            Connections {
                                target: canvas
                                function onHeightChanged() { Qt.callLater(strip.refold) }
                            }
                            Connections {
                                target: rightColumn
                                function onWidthChanged() { Qt.callLater(strip.refold) }
                            }
                            app: app
                            surface: projection.surface
                            rowHeight: timeline.mainRowHeight
                            tracks: app.shownTracks
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // —— The reactions and the effects: two rails of keys at
                    // the window's right edge ——
                    RowLayout {
                        Layout.fillHeight: true
                        Layout.fillWidth: false
                        Layout.rightMargin: 4 - Theme.gap
                        spacing: 4
                        Reactions {
                            Layout.fillHeight: true
                        }
                        Effects {
                            Layout.fillHeight: true
                        }
                    }
                }
            }

            // The output and the sources' light copies; it takes no room.
            Desk {
                id: desk
                source: projection.surface
                entry: projection.entry
                projection: projection
                sound: sound
                sound2: sound2
                topSource: timeline.onTop
                solo: app.singleTrack ? app.soloTrack : -1
                sourceIds: app.sources.map(s => s.id)
                monitorWidth: mixer.pictureWidth
            }
        }

        // —— The player's timeline, across the whole foot ——
        Timeline {
            id: timeline
            objectName: "timeline"
            Layout.fillWidth: true
            entries: app.mainEntries
            // Two tracks, each its own play
            // bar; entries dragged from the drawer or files from the Finder
            // onto a row replace what is on that track.
            tracks: app.trackRows
            textures: desk.textures
            followTrack: app.followTrack
            onPickSource: key => app.pickSource(key)
            onClearTrack: track => app.clearTrack(track)
            onTakeLive: key => mixer.takeLive(key)
            onBringUp: key => mixer.bringUp(key)
            // The board's keys under its picture's left edge, as far as room allows.
            keysInset: mixer.x + mixer.keysInset
            // Done once the drop is over: the rows are made anew by it.
            onDropEntries: (ids, track, append) => Qt.callLater(append ? app.placeOn : app.replaceOn, ids, track)
            onDropFiles: (urls, track, append) => Qt.callLater(app.dropFilesOn, urls, track, append)
            onRemoveEntry: id => Qt.callLater(app.takeOff, id)
            setId: app.currentSet ? app.currentSet.id : ""
            setName: app.currentSet ? app.currentSet.name : ""
            running: app.running
            phase: app.phase
            player: app
        }
    }

    // Files dragged from the left (Library): this stand-in follows the
    // pointer over the window and carries the drag (internal, keys
    // "kvj-entry") to the track rows, 预备 and the board. It lives here, not
    // in the file's row, which may be made anew while the drag still runs.
    property bool draggingEntries: false
    function entryDragBegin(ids, title, at) {
        entryGhost.entryIds = ids
        entryGhost.fileUrls = []
        entryGhost.title = title
        app.entryDragMove(at)
        app.draggingEntries = true
    }
    // Files dragged from the left (Library): the same stand-in carries their URLs.
    function fileDragBegin(urls, title, at) {
        entryGhost.entryIds = []
        entryGhost.fileUrls = urls
        entryGhost.title = title
        app.entryDragMove(at)
        app.draggingEntries = true
    }
    function entryDragMove(at) {
        entryGhost.x = at.x - entryGhost.width / 2
        entryGhost.y = at.y - entryGhost.height / 2
    }
    function entryDragEnd(drop) {
        if (!app.draggingEntries)
            return
        if (drop)
            entryGhost.Drag.drop()
        else
            entryGhost.Drag.cancel()
        app.draggingEntries = false
    }
    // The drawer's list is made anew whenever an entry changes, the row a
    // drag began on with it: the pointer is followed and let go here, over
    // the whole window (a passive watch that takes nothing from anyone).
    Item {
        parent: app.contentItem
        anchors.fill: parent
        z: 999
        PointHandler {
            acceptedButtons: Qt.LeftButton
            onPointChanged: if (active && app.draggingEntries) app.entryDragMove(point.scenePosition)
            onActiveChanged: if (!active && app.draggingEntries) app.entryDragEnd(true)
        }
    }
    Rectangle {
        id: entryGhost
        property var entryIds: []
        property var fileUrls: []
        property string title: ""
        parent: app.contentItem
        z: 1000
        visible: app.draggingEntries
        width: Math.min(260, ghostText.implicitWidth + 24)
        height: 30
        radius: Theme.radius
        color: Theme.raised
        border.width: 1
        border.color: Theme.line
        opacity: 0.92
        Drag.active: app.draggingEntries
        Drag.dragType: Drag.Internal
        Drag.keys: ["kvj-entry"]
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2
        Text {
            id: ghostText
            anchors.centerIn: parent
            width: Math.min(implicitWidth, 236)
            text: entryGhost.title
            font.pixelSize: Theme.sizeSm
            font.weight: Font.Medium
            color: Theme.text
            elide: Text.ElideRight
        }
    }

    // `--add <file or folder>` adds it at start, the same way the add keys do.
    Component.onCompleted: {
        Qt.callLater(app.noteShown)
        if (timeline.tempoLinked)
            Qt.callLater(app.linkTempo)
        const args = Qt.application.arguments
        for (let i = 0; i + 1 < args.length; ++i)
            if (args[i] === "--add")
                app.addUrls([Engine.fileUrl(args[i + 1])])
        app.cue()
        app.applyScheme()
        app.oneLibrary()
    }

    // Closing the window (its key, Cmd+W, Alt+F4, quitting) during a show is
    // asked first: it would stop following and take the picture away.
    property bool quitting: false
    MessageDialog {
        id: quitDialog
        title: "退出 KVJ？"
        text: projection.visible ? "投屏正在进行，退出会收起投屏画面" + (app.running ? "并停止跟随。" : "。")
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
        title: "收起投屏？"
        text: "投屏画面会从屏幕上收起。"
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
