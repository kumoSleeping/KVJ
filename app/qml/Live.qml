pragma Singleton
import QtCore
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
    // Reactions rise from anywhere along the foot of the screen. The fourth of
    // one emoji within a second and a half, and every one after, bursts.
    function react(glyph) {
        const now = Date.now()
        recent = recent.filter(r => now - r.born < 1500).concat([{ emoji: glyph, born: now }])
        const burst = recent.filter(r => r.emoji === glyph).length >= 4
        const x = 0.04 + Math.random() * 0.92
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
    // An effect at 0 is off; its key turns it on at `preset`, the strength it
    // looks best at, and its slider fine-tunes it. Their place here is the
    // shader's `kind` (shaders/effects.frag).
    readonly property var effects: [
        { key: "mosaic", name: "马赛克", preset: 0.35 },
        { key: "rgb", name: "RGB 分离", moving: true, preset: 0.4 },
        { key: "tiles", name: "多画面", preset: 0.3 },
        { key: "lens", name: "鱼眼透镜", preset: 0.5 },
        { key: "zoom", name: "放射模糊", preset: 0.35 },
        { key: "wave", name: "水波", moving: true, preset: 0.5 },
        { key: "glitch", name: "故障", moving: true, preset: 0.35 },
        { key: "scan", name: "扫描线", moving: true, preset: 0.45 },
        { key: "halftone", name: "网点", preset: 0.45 },
        { key: "posterize", name: "色调分离", preset: 0.5 },
        { key: "hue", name: "色相", preset: 0.3 },
        { key: "mono", name: "黑白", preset: 1 }
    ]
    property var level: ({})
    // Strengths the operator kept in place of a preset: { key: 0..1 }.
    property var custom: ({})
    // The effect last switched or tuned: what , and . adjust.
    property string focused: ""
    // Effects tuned with , or . since they were switched on: switched off, they
    // keep that strength as their own preset.
    property var tuned: ({})
    // The number keys (1–0, the number pad too) switch the first ten effects
    // in the list; , and . tune the last one. On unless turned off.
    property bool keysOn: true

    function setLevel(key, value) {
        const next = Object.assign({}, level)
        next[key] = Math.max(0, Math.min(1, value))
        level = next
    }
    function presetOf(key) {
        const i = kind(key)
        return custom[key] !== undefined ? custom[key] : i >= 0 ? effects[i].preset : 0
    }
    // On at its preset (one that is on already keeps its strength), or off.
    function switchEffect(key, on) {
        const i = kind(key)
        if (i < 0)
            return
        focused = key
        if (on === amount(key) > 0)
            return
        if (!on && tuned[key]) {
            const kept = Object.assign({}, custom)
            kept[key] = Math.round(amount(key) * 100) / 100
            custom = kept
            store.presets = JSON.stringify(custom)
        }
        if (tuned[key]) {
            const next = Object.assign({}, tuned)
            delete next[key]
            tuned = next
        }
        setLevel(key, on ? presetOf(key) : 0)
    }
    function toggleEffect(key) {
        switchEffect(key, !(amount(key) > 0))
    }
    // , and . : the last effect switched or tuned (or the first one on) a
    // step weaker or stronger; a step up from off switches it on there.
    function tune(delta) {
        const key = focused && kind(focused) >= 0 ? focused : active.length ? active[0] : ""
        if (!key)
            return
        focused = key
        setLevel(key, Math.round((amount(key) + delta) * 100) / 100)
        const next = Object.assign({}, tuned)
        next[key] = true
        tuned = next
    }
    // Every effect back at the strength it came with.
    function resetPresets() {
        custom = {}
        tuned = {}
        store.presets = "{}"
    }
    readonly property bool customized: Object.keys(custom).length > 0
    function amount(key) {
        return level[key] || 0
    }
    function resetEffects() {
        level = {}
    }
    readonly property bool effectsOn: effects.some(e => amount(e.key) > 0)
    readonly property bool effectsMoving: effects.some(e => e.moving && amount(e.key) > 0)

    // The order they are applied in, first at the top, as the desk lists them:
    // { key, name }. A model, so that a row dragged elsewhere is moved, not
    // made anew. Kept between runs.
    property ListModel chain: ListModel {}
    property int chainRevision: 0
    readonly property var order: {
        chainRevision
        const keys = []
        for (let i = 0; i < chain.count; ++i)
            keys.push(chain.get(i).key)
        return keys
    }
    // The effects that are on, in that order: one pass each.
    readonly property var active: order.filter(k => amount(k) > 0)
    property Settings store: Settings {
        category: "effects"
        property string order: ""
        property string presets: "{}"
        property alias keys: live.keysOn
    }

    function kind(key) {
        return effects.findIndex(e => e.key === key)
    }
    function moveEffect(from, to) {
        if (from === to || from < 0 || to < 0 || from >= chain.count || to >= chain.count)
            return
        chain.move(from, to, 1)
        chainRevision += 1
        store.order = order.join(",")
    }
    Component.onCompleted: {
        try {
            const kept = JSON.parse(store.presets)
            const valid = {}
            for (const k in kept)
                if (kind(k) >= 0 && typeof kept[k] === "number" && kept[k] > 0 && kept[k] <= 1)
                    valid[k] = kept[k]
            custom = valid
        } catch (error) {
            custom = {}
        }
        const saved = store.order.split(",").filter((k, i, all) => kind(k) >= 0 && all.indexOf(k) === i)
        const keys = saved.concat(effects.map(e => e.key).filter(k => saved.indexOf(k) < 0))
        for (const k of keys)
            chain.append({ key: k, name: effects[kind(k)].name })
        chainRevision += 1
    }
}
