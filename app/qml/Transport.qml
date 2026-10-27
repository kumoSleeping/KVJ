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
    // The speed last set by hand (setTempo); following sets `tempo` itself and
    // gives this back when it lets go.
    property real ownTempo: 1
    property bool playing: false
    // A nudge, as a DJ holds a pitch bend: while a key is held the picture
    // plays half as fast again as `tempo` (ahead) or at 0.7 of it (back); let
    // go, it is back at `tempo`.
    property real bend: 0
    readonly property real bendUp: 0.5
    readonly property real bendDown: -0.3
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
        tempo = Math.round(Math.max(minTempo, Math.min(maxTempo, next)) * 1000) / 1000
        ownTempo = tempo
        anchor(at)
    }
    // Bends ahead (direction > 0) or back until `letGo`, or for `ms` only;
    // paused, it is a plain step of a second.
    function nudge(direction, ms) {
        if (!playing) {
            seek(now() + (direction > 0 ? 1 : -1))
            return
        }
        bendTo(direction > 0 ? bendUp : bendDown)
        if (ms > 0) {
            bendTimer.interval = ms
            bendTimer.restart()
        } else {
            bendTimer.stop()
        }
    }
    // The key of `direction` let go (0: whichever): back at `tempo`.
    function letGo(direction) {
        if (bend !== 0 && (!direction || (direction > 0) === (bend > 0)))
            bendTo(0)
    }
    function bendTo(next) {
        const at = now()
        bend = next
        anchor(at)
        if (next === 0)
            bendTimer.stop()
    }
    function unbend() {
        bendTimer.stop()
        bend = 0
    }
    property Timer bendTimer: Timer {
        onTriggered: transport.bendTo(0)
    }
    // Going on by itself at an entry's end (the next one, or the first again
    // when looping) is a cut, never a dissolve: many videos are made to loop,
    // their last frame leading straight into their first. The picture reads
    // this while it takes the new place.
    property bool cutting: false
    function cut() {
        cutting = true
        cutTimer.restart()
    }
    property Timer cutTimer: Timer {
        interval: 500
        onTriggered: transport.cutting = false
    }
}
