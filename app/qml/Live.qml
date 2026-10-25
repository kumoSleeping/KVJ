pragma Singleton
import QtQuick

// What goes on the screen over the picture, sent by the operator and, later, by
// the room. The projection and the operator's preview each draw it (Stage), so
// everything here carries what both need to draw the same thing: its birth on
// one clock and any randomness already rolled.
//
// Danmaku from elsewhere (an audience page, a chat bridge) comes in through
// say(text, from) like the operator's own words; nothing else needs to change.
QtObject {
    id: live

    // Times are Date.now() milliseconds; the effects run on seconds from here.
    readonly property real epoch: Date.now()

    // Events: each drawing spawns its own copy and lets it go.
    signal bullet(var item)    // { text, from, lane, born }
    signal reaction(var item)  // { emoji, x, seed, born }

    // State: drawn for as long as it is set.
    property var caption: null // { text, born, hold } in the middle of the screen
    property var stickers: []  // [{ id, kind: "image" | "text", source, text, x, y, size }]

    // The reactions on offer: Noto's animated emoji, as Google Meet shows them.
    // `still` is the frame that stands for one while it is not playing.
    readonly property var emoji: [
        { glyph: "🎉", file: "1f389", still: 13 }, { glyph: "👏", file: "1f44f", still: 6 }, { glyph: "💖", file: "1f496" },
        { glyph: "🔥", file: "1f525" }, { glyph: "😂", file: "1f602" }, { glyph: "😮", file: "1f62e" },
        { glyph: "🙌", file: "1f64c", still: 8 }, { glyph: "🥳", file: "1f973" }, { glyph: "😍", file: "1f60d" },
        { glyph: "🤘", file: "1f918" }, { glyph: "✨", file: "2728" }, { glyph: "🪩", file: "1faa9" }
    ]

    property int lane: 0
    property int serial: 0
    property var recent: []

    function say(text, from) {
        const words = (text || "").trim()
        if (!words.length)
            return
        lane = (lane + 1) % 9
        bullet({ text: words, from: from || "", lane: lane, born: Date.now() })
    }
    // Reactions rise up the sides, clear of whoever stands in the middle. The
    // fourth of one emoji within a second and a half, and every one after, bursts.
    function react(glyph) {
        const now = Date.now()
        recent = recent.filter(r => now - r.born < 1500).concat([{ emoji: glyph, born: now }])
        const burst = recent.filter(r => r.emoji === glyph).length >= 4
        const x = Math.random() < 0.5 ? 0.05 + Math.random() * 0.25 : 0.70 + Math.random() * 0.25
        reaction({ emoji: glyph, x: x, seed: Math.random(), burst: burst, born: now })
    }
    function showCaption(text) {
        const words = (text || "").trim()
        if (!words.length)
            return
        caption = { text: words, born: Date.now(), hold: Math.min(10000, 3000 + words.length * 150) }
    }
    function clearCaption() {
        caption = null
    }
    function post(sticker) {
        serial += 1
        stickers = stickers.concat([Object.assign({}, sticker, { id: "s" + serial })])
    }
    function unpost(id) {
        stickers = stickers.filter(s => s.id !== id)
    }
    function clearStickers() {
        stickers = []
    }

    // —— Picture effects ——
    // Every effect is on from the start and does nothing at 0; its slider brings
    // it in. Switching one off keeps its level for later.
    readonly property var effects: [
        { key: "mosaic", name: "马赛克" },
        { key: "rgb", name: "RGB 分离", moving: true },
        { key: "tiles", name: "多画面" },
        { key: "lens", name: "鱼眼透镜" },
        { key: "zoom", name: "放射模糊" },
        { key: "wave", name: "水波", moving: true },
        { key: "glitch", name: "故障", moving: true },
        { key: "scan", name: "扫描线", moving: true },
        { key: "halftone", name: "网点" },
        { key: "posterize", name: "色调分离" },
        { key: "hue", name: "色相" },
        { key: "mono", name: "黑白" },
        { key: "vignette", name: "暗角" }
    ]
    property var level: ({})
    property var off: ({})

    function setLevel(key, value) {
        const next = Object.assign({}, level)
        next[key] = Math.max(0, Math.min(1, value))
        level = next
    }
    function setOn(key, on) {
        const next = Object.assign({}, off)
        next[key] = !on
        off = next
    }
    function amount(key) {
        return off[key] ? 0 : (level[key] || 0)
    }
    function resetEffects() {
        level = {}
    }
    readonly property bool effectsOn: effects.some(e => amount(e.key) > 0)
    readonly property bool effectsMoving: effects.some(e => e.moving && amount(e.key) > 0)
}
