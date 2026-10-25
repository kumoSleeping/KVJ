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
    // Posted stickers, changed in place so a moved one is not drawn anew:
    // { sid, kind: "image" | "text", source, text, name, px, py (its centre, as
    // shares of the screen), size (share of the screen's height), angle (degrees) }.
    property ListModel stickers: ListModel {}
    // The one posted last, and a count of changes for bindings that read the model.
    property string lastSid: ""
    property int revision: 0

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
        const sid = "s" + serial
        stickers.append({
            sid: sid, kind: sticker.kind, source: sticker.source || "", text: sticker.text || "",
            name: sticker.name || "", px: sticker.px, py: sticker.py, size: sticker.size, angle: sticker.angle || 0
        })
        lastSid = sid
        revision += 1
        return sid
    }
    function find(sid) {
        for (let i = 0; i < stickers.count; ++i)
            if (stickers.get(i).sid === sid)
                return i
        return -1
    }
    function sticker(sid) {
        const i = find(sid)
        return i >= 0 ? stickers.get(i) : null
    }
    // Moves, sizes or turns one: `changes` holds any of px, py, size, angle.
    function update(sid, changes) {
        const i = find(sid)
        if (i < 0)
            return
        for (const key in changes)
            stickers.setProperty(i, key, changes[key])
        revision += 1
    }
    function unpost(sid) {
        const i = find(sid)
        if (i >= 0)
            stickers.remove(i)
        revision += 1
    }
    function clearStickers() {
        stickers.clear()
        revision += 1
    }

    // —— Picture effects ——
    // An effect at 0 is off; its slider brings it in.
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

    function setLevel(key, value) {
        const next = Object.assign({}, level)
        next[key] = Math.max(0, Math.min(1, value))
        level = next
    }
    function amount(key) {
        return level[key] || 0
    }
    function resetEffects() {
        level = {}
    }
    readonly property bool effectsOn: effects.some(e => amount(e.key) > 0)
    readonly property bool effectsMoving: effects.some(e => e.moving && amount(e.key) > 0)
}
