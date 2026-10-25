import QtQuick
import KVJ

// The player's own clock: which entry, where in it and how fast. The picture
// runs on this unless smart following leads; then it runs on the engine's
// match, and this takes over again from wherever following left it.
QtObject {
    id: transport

    property var entry: null
    // Media seconds at `clockAtMs` (Engine.clockMs).
    property real position: 0
    property real clockAtMs: 0
    // 1 is the material's own speed.
    property real tempo: 1
    property bool playing: false
    // A nudge, as a DJ nudges a jog wheel: for a moment this much faster (or,
    // negative, slower) than `tempo`, until the picture has gained (or lost)
    // the `owed` seconds; then back to `tempo`.
    property real bend: 0
    readonly property real bendBy: 0.5
    property real owed: 0
    property real bentAt: 0
    readonly property real speed: tempo * (1 + bend)
    readonly property real rate: playing ? speed : 0
    readonly property real duration: entry ? entry.duration : 0

    readonly property real minTempo: 0.5
    readonly property real maxTempo: 1.5

    function clamp(at) {
        return Math.max(0, duration > 0 ? Math.min(at, duration) : at)
    }
    // Where the picture is now; a function, since the clock is not a property.
    function now() {
        return clamp(position + (playing ? (Engine.clockMs() - clockAtMs) / 1000 * speed : 0))
    }
    function anchor(at) {
        position = clamp(at)
        clockAtMs = Engine.clockMs()
    }
    function load(next, at, play) {
        unbend()
        entry = next
        anchor(at || 0)
        playing = play && !!next
    }
    function seek(at) {
        unbend()
        anchor(at)
    }
    function setPlaying(on) {
        const at = now()
        unbend()
        playing = on && !!entry
        // Playing again at the end starts over.
        anchor(playing && duration > 0 && at >= duration - 0.05 ? 0 : at)
    }
    function toggle() {
        setPlaying(!playing)
    }
    function setTempo(next) {
        const at = now()
        settle()
        tempo = Math.round(Math.max(minTempo, Math.min(maxTempo, next)) * 1000) / 1000
        bendFrom(at)
    }
    // Gains (positive) or loses `seconds` of picture by playing faster or
    // slower for a moment; paused, it is a plain step.
    function nudge(seconds) {
        if (!playing) {
            seek(now() + seconds)
            return
        }
        const at = now()
        settle()
        owed += seconds
        bendFrom(at)
    }
    // What the bend has paid off since it was last set.
    function settle() {
        if (bend !== 0)
            owed -= (Engine.clockMs() - bentAt) / 1000 * tempo * bend
    }
    function bendFrom(at) {
        bend = Math.abs(owed) < 0.005 ? 0 : owed > 0 ? bendBy : -bendBy
        if (bend === 0)
            owed = 0
        anchor(at)
        bentAt = clockAtMs
        if (bend !== 0) {
            bendTimer.interval = Math.max(1, Math.abs(owed) / (tempo * bendBy) * 1000)
            bendTimer.restart()
        } else {
            bendTimer.stop()
        }
    }
    function unbend() {
        bendTimer.stop()
        owed = 0
        bend = 0
    }
    property Timer bendTimer: Timer {
        onTriggered: {
            const at = transport.now()
            transport.unbend()
            transport.anchor(at)
        }
    }
}
