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
    readonly property real rate: playing ? tempo : 0
    readonly property real duration: entry ? entry.duration : 0

    readonly property real minTempo: 0.5
    readonly property real maxTempo: 1.5

    function clamp(at) {
        return Math.max(0, duration > 0 ? Math.min(at, duration) : at)
    }
    // Where the picture is now; a function, since the clock is not a property.
    function now() {
        return clamp(position + (playing ? (Engine.clockMs() - clockAtMs) / 1000 * tempo : 0))
    }
    function anchor(at) {
        position = clamp(at)
        clockAtMs = Engine.clockMs()
    }
    function load(next, at, play) {
        entry = next
        anchor(at || 0)
        playing = play && !!next
    }
    function seek(at) {
        anchor(at)
    }
    function setPlaying(on) {
        const at = now()
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
        anchor(at)
    }
}
