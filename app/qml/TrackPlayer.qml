import QtCore
import QtQuick
import KVJ

// One aux track's own player (画面 2/3/4): which of the track's entries, where
// in it and how fast, on a clock of its own beside the main player's. It plays
// and pauses by itself and never follows the music; with `followMain` its
// speed is a share of the main track's, so a picture laid under the main one
// keeps its pace when the DJ's tempo changes.
//
//   track       1..3 (shown as 画面 2..4); its loop and followMain are kept
//               under the settings' "track<N>"
//   entries     the track's entries in order; those that are off are skipped
//               (the one playing finishes first, as on the main track)
//   mainRate    the main player's tempo, paused or not (app.shownTempo)
//   speed       this track's own speed, 0.5..1.5 (setSpeed)
//   followMain  the speed played is speed × mainRate
//   loop        after the last entry that is on: from the first again, or
//               (off) stop on the last frame
//   entry, position, clockAtMs, rate (0 while paused), playing, effectiveSpeed:
//               the clock, for a picture source (position at clockAtMs on
//               Engine.clockMs(), going on at rate)
//   playhead    media seconds now, refreshed every 50 ms while playing
//   now()       media seconds now
//   play(entry, at)  a seek within the entry shown keeps playing or paused;
//                    another entry starts playing
//   seek(entry, at)  there, playing or paused as it was
//   toggle(), pause(), stop() (paused where it is), setSpeed(v)
QtObject {
    id: player

    property int track: 1
    property var entries: []
    property real mainRate: 1
    property real speed: 1
    property bool followMain: false
    property bool loop: false

    // Following leads this track's picture: { match, offsetMs } from the
    // window, or null. Its picture is then the music's place and its own keys
    // rest; let go, its clock carries on from there (Main's takeOver).
    property var lead: null
    readonly property var entry: lead ? lead.match.entry : clock.entry
    readonly property real position: lead ? lead.match.position : clock.position
    readonly property real clockAtMs: lead ? lead.match.clock_at_ms : clock.clockAtMs
    readonly property real offsetMs: lead ? lead.offsetMs : 0
    readonly property bool playing: lead ? lead.match.rate > 0 : clock.playing
    readonly property real rate: lead ? lead.match.rate : clock.rate
    readonly property real duration: clock.duration
    readonly property real effectiveSpeed: Math.max(0.25, Math.min(3, followMain ? speed * Math.max(0, mainRate) : speed))
    property real playhead: 0

    readonly property real minSpeed: 0.5
    readonly property real maxSpeed: 1.5

    property Transport clock: Transport {
        tempo: 1
    }
    // The speed changes from wherever the picture is at that moment.
    onEffectiveSpeedChanged: {
        const at = clock.now()
        clock.tempo = effectiveSpeed
        clock.ownTempo = effectiveSpeed
        clock.anchor(at)
    }
    onEntriesChanged: arrive()
    Component.onCompleted: {
        clock.tempo = effectiveSpeed
        clock.ownTempo = effectiveSpeed
        arrive()
    }

    property Settings store: Settings {
        category: "track" + player.track
        property alias loop: player.loop
        property alias followMain: player.followMain
    }

    function now() {
        if (lead) {
            const m = lead.match
            return Math.max(0, m.position + (Engine.clockMs() - m.clock_at_ms + lead.offsetMs) / 1000 * m.rate)
        }
        return clock.now()
    }
    function firstOn() {
        return (player.entries || []).find(e => e.enabled !== false) || null
    }
    // Something to show from the start: the first entry that is on, paused.
    // An entry playing stays while another Set is looked at or it moves away
    // (the picture on the air never jumps by itself); a paused one gives way.
    function arrive() {
        const list = player.entries || []
        if (clock.entry && (clock.playing || list.some(e => e.id === clock.entry.id)))
            return
        const first = firstOn()
        if (first)
            clock.load(first, 0, false)
        else if (clock.entry)
            clock.load(null, 0, false)
        tick()
    }
    function play(entry, at) {
        if (lead)
            return
        if (!entry)
            return
        if (clock.entry && clock.entry.id === entry.id)
            clock.seek(at)
        else
            clock.load(entry, at, true)
        tick()
    }
    function seek(entry, at) {
        if (lead)
            return
        if (!entry)
            return
        if (clock.entry && clock.entry.id === entry.id)
            clock.seek(at)
        else
            clock.load(entry, at, clock.playing)
        tick()
    }
    function toggle() {
        if (lead)
            return
        if (!clock.entry) {
            const first = firstOn()
            if (!first)
                return
            clock.load(first, 0, true)
        } else {
            clock.toggle()
        }
        tick()
    }
    function pause() {
        if (lead)
            return
        clock.setPlaying(false)
        tick()
    }
    function stop() {
        pause()
    }
    function setSpeed(next) {
        speed = Math.round(Math.max(minSpeed, Math.min(maxSpeed, next)) * 1000) / 1000
    }
    // At the end of an entry: the next one on the track that is on, or the
    // first with `loop`, else the last frame, as the main track does.
    function tick() {
        if (lead) {
            player.playhead = now()
            return
        }
        player.playhead = clock.now()
        if (clock.playing && clock.duration > 0 && player.playhead >= clock.duration - 0.03) {
            const list = player.entries || []
            const i = list.findIndex(e => e.id === clock.entry.id)
            const next = i >= 0 ? list.slice(i + 1).find(e => e.enabled !== false) : null
            const first = player.loop ? firstOn() : null
            if (next || first)
                clock.load(next || first, 0, true)
            else
                clock.setPlaying(false)
            player.playhead = clock.now()
        }
    }
    property Timer ticker: Timer {
        interval: 50
        repeat: true
        running: player.playing || !!player.lead
        onTriggered: player.tick()
    }
}
