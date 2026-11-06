pragma Singleton
import QtCore
import QtQuick

// What goes on the screen over the picture, sent by the operator and, later, by
// the room. The projection and the operator's preview each draw it (Stage), so
// everything here carries what both need to draw the same thing: its birth on
// one clock and any randomness already rolled.
//
// Danmaku from elsewhere (an audience page, a chat bridge) comes in through
// say(text, from, options) like the operator's own words; nothing else needs
// to change.
QtObject {
    id: live

    // Times are Date.now() milliseconds; the effects run on seconds from here.
    readonly property real epoch: Date.now()

    // Events: each drawing spawns its own copy and lets it go.
    // A bullet: { text, from, mode: "scroll" | "top" | "bottom", lane, y (top of
    // its line, as a share of the screen's height), size (its font, the same
    // share), born, and duration (scroll: across the screen) or hold and fade
    // (top, bottom: shown, then fading) in ms }.
    signal bullet(var item)
    signal reaction(var item)  // { emoji, x, seed, born }
    // A reaction key was used (its place in the rail): the rail answers with a bounce.
    signal reactionPressed(int index)

    // State: drawn for as long as it is set.
    property var caption: null // { text, born, hold } in the middle of the screen
    // Stickers, changed in place so a moved one is not drawn anew: { sid,
    // kind: "image" | "text", source, text, name, px, py (its centre, as shares
    // of the screen), size (share of the screen's height), angle (degrees) }.
    // `staged` are the ones on the mixer's preview, where they are posted,
    // moved and taken down; `stickers` the ones on the air, a copy of them as
    // they were last put there (Switcher.apply(), or at once while following).
    property ListModel stickers: ListModel {}
    property ListModel staged: ListModel {}
    // The one posted last, and a count of changes for bindings that read the models.
    property string lastSid: ""
    property int revision: 0
    property int airRevision: 0
    readonly property var fields: ["sid", "kind", "source", "text", "name", "px", "py", "size", "angle"]
    function rows(model) {
        const out = []
        for (let i = 0; i < model.count; ++i) {
            const o = model.get(i)
            out.push(fields.map(f => o[f]))
        }
        return out
    }
    // The preview's stickers differ from those on the air.
    readonly property bool stickersPending: {
        revision
        airRevision
        return JSON.stringify(rows(staged)) !== JSON.stringify(rows(stickers))
    }
    // `to` made like `from`, row by row: a row of the same sid changed in
    // place (so it does not pop in anew), the rest added or taken out.
    function copyInto(from, to) {
        const want = rows(from)
        for (let i = to.count - 1; i >= 0; --i)
            if (!want.some(r => r[0] === to.get(i).sid))
                to.remove(i)
        for (let i = 0; i < want.length; ++i) {
            const sid = want[i][0]
            let at = -1
            for (let j = i; j < to.count && at < 0; ++j)
                if (to.get(j).sid === sid)
                    at = j
            if (at < 0) {
                const o = {}
                fields.forEach((f, k) => o[f] = want[i][k])
                to.insert(i, o)
                continue
            }
            if (at !== i)
                to.move(at, i, 1)
            const o = to.get(i)
            fields.forEach((f, k) => {
                if (o[f] !== want[i][k])
                    to.setProperty(i, f, want[i][k])
            })
        }
    }
    // The preview's stickers on the air.
    function goLive() {
        copyInto(staged, stickers)
        airRevision += 1
    }
    // The preview's stickers back to those on the air.
    function restage() {
        copyInto(stickers, staged)
        revision += 1
    }
    function changed() {
        revision += 1
        if (Switcher.follow)
            goLive()
    }

    // The reactions on offer: Noto's animated emoji, as Google Meet shows them.
    // `still` is the frame that stands for one while it is not playing.
    readonly property var emoji: [
        { glyph: "🎉", file: "1f389", still: 13 }, { glyph: "👏", file: "1f44f", still: 6 }, { glyph: "💖", file: "1f496" },
        { glyph: "🔥", file: "1f525" }, { glyph: "😂", file: "1f602" }, { glyph: "😮", file: "1f62e" },
        { glyph: "🙌", file: "1f64c", still: 8 }, { glyph: "🥳", file: "1f973" }, { glyph: "😍", file: "1f60d" },
        { glyph: "🤘", file: "1f918" }, { glyph: "✨", file: "2728" }, { glyph: "🪩", file: "1faa9" },
        { glyph: "🐍", file: "1f40d" }, { glyph: "💥", file: "1f4a5" }, { glyph: "⚡", file: "26a1" },
        { glyph: "💯", file: "1f4af" }, { glyph: "🤯", file: "1f92f" }, { glyph: "💃", file: "1f483" },
        { glyph: "🎶", file: "1f3b6" }, { glyph: "😎", file: "1f60e" }, { glyph: "🤩", file: "1f929" },
        { glyph: "🥁", file: "1f941" }, { glyph: "🎸", file: "1f3b8" }, { glyph: "🚀", file: "1f680" },
        { glyph: "🌈", file: "1f308" }, { glyph: "🎆", file: "1f386" }, { glyph: "🎊", file: "1f38a" },
        { glyph: "🍾", file: "1f37e" }, { glyph: "🍻", file: "1f37b" }, { glyph: "🫶", file: "1faf6" },
        { glyph: "🤟", file: "1f91f" }, { glyph: "👋", file: "1f44b" }, { glyph: "💪", file: "1f4aa" },
        { glyph: "🥵", file: "1f975" }, { glyph: "👀", file: "1f440" }
    ]
    // The reactions in the rail's order (dragged there), kept between runs;
    // Q to P send the first ten, the controller's buttons all of them
    // (reactionButtons).
    property var reactionOrder: []
    readonly property var reactions: {
        const kept = reactionOrder.map(f => emoji.find(e => e.file === f)).filter(e => !!e)
        return kept.concat(emoji.filter(e => kept.indexOf(e) < 0))
    }
    readonly property var reactionKeys: ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"]
    function moveReaction(from, to) {
        const list = reactions.map(e => e.file)
        if (from === to || from < 0 || to < 0 || from >= list.length || to >= list.length)
            return
        list.splice(to, 0, list.splice(from, 1)[0])
        reactionOrder = list
        reactionStore.order = list.join(",")
    }
    function resetReactions() {
        reactionOrder = []
        reactionStore.order = ""
    }
    property Settings reactionStore: Settings {
        category: "reactions"
        property string order: ""
    }

    property int serial: 0
    property var recent: []

    // —— Danmaku, as on Bilibili ——
    // Font sizes on offer (小, 中, 大), as shares of the screen's height.
    readonly property var sizes: [1 / 26, 1 / 20, 1 / 15]
    // The projection's width over its height, for telling how far a line
    // reaches across it.
    property real aspect: 16 / 9
    // Every scrolling line takes as long to cross, so a longer one moves faster.
    readonly property int crossing: 7000
    readonly property int hold: 4500
    readonly property int fade: 300
    // A line's height, in font sizes.
    readonly property real lineSpan: 1.25
    // The lines still up, by mode: { y, h, born, end, width, speed } in shares
    // of the screen and ms.
    property var flying: ({ scroll: [], top: [], bottom: [] })

    // How wide `text` is in font sizes: CJK and full-width forms (and emoji)
    // about one each, anything else about half.
    function ems(text) {
        let n = 0
        for (const ch of text) {
            const c = ch.codePointAt(0)
            n += c >= 0x1100 && !(c >= 0x2000 && c < 0x2e80) && !(c >= 0xff61 && c <= 0xffdc) ? 1 : 0.55
        }
        return n
    }
    // The first lane between `top` and `bottom` (from the bottom up when
    // `upward`) that no line still up holds at `now`; failing that, the one
    // that frees soonest. `freeAt(other)` is when `other` stops holding a lane.
    function place(list, line, top, bottom, upward, now, freeAt) {
        const lanes = Math.max(1, Math.floor((bottom - top) / line + 1e-6))
        const at = k => upward ? bottom - (k + 1) * line : top + k * line
        let best = 0
        let soonest = Infinity
        for (let k = 0; k < lanes; ++k) {
            const y = at(k)
            let free = now
            for (const other of list)
                if (other.y < y + line - 1e-6 && y < other.y + other.h - 1e-6)
                    free = Math.max(free, freeAt(other))
            if (free <= now)
                return { lane: k, y: y }
            if (free < soonest) {
                soonest = free
                best = k
            }
        }
        return { lane: best, y: at(best) }
    }
    // `options`: { mode: "scroll" (the default) | "top" | "bottom", size (a
    // share of the screen's height; 中 by default) }. Scrolling lines take the
    // top three quarters of the screen, the topmost lane where the one before
    // has come fully in and will be gone off the left before this one catches
    // it; top and bottom lines stack, centred, down from the top or up from
    // the foot.
    function say(text, from, options) {
        const words = (text || "").trim()
        if (!words.length)
            return
        const opts = options || {}
        const mode = ["scroll", "top", "bottom"].indexOf(opts.mode) >= 0 ? opts.mode : "scroll"
        const size = typeof opts.size === "number" && opts.size > 0 ? opts.size : sizes[1]
        const name = from || ""
        const now = Date.now()
        const line = size * lineSpan
        const list = flying[mode].filter(o => o.end > now)
        let spot
        let entry
        if (mode === "scroll") {
            // Shares of the screen's width, and of it a millisecond.
            const width = ems(name ? name + "：" + words : words) * size / Math.max(0.1, aspect)
            const gap = size / Math.max(0.1, aspect)
            const speed = (1 + width) / crossing
            spot = place(list, line, 0.02, 0.75, false, now, other => Math.max(
                other.born + (other.width + gap) / other.speed,
                other.born + crossing - (1 - gap) / speed))
            entry = { width: width, speed: speed, end: now + crossing }
        } else {
            spot = mode === "top" ? place(list, line, 0.02, 0.5, false, now, other => other.end)
                                  : place(list, line, 0.5, 0.97, true, now, other => other.end)
            entry = { end: now + hold + fade }
        }
        list.push(Object.assign(entry, { y: spot.y, h: line, born: now }))
        flying[mode] = list
        bullet({
            text: words, from: name, mode: mode, lane: spot.lane, y: spot.y, size: size, born: now,
            duration: crossing, hold: hold, fade: fade
        })
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
    // Stickers are posted, moved and taken down on the preview (`staged`).
    function post(sticker) {
        serial += 1
        const sid = "s" + serial
        staged.append({
            sid: sid, kind: sticker.kind, source: sticker.source || "", text: sticker.text || "",
            name: sticker.name || "", px: sticker.px, py: sticker.py, size: sticker.size, angle: sticker.angle || 0
        })
        lastSid = sid
        changed()
        return sid
    }
    function find(sid) {
        for (let i = 0; i < staged.count; ++i)
            if (staged.get(i).sid === sid)
                return i
        return -1
    }
    function sticker(sid) {
        const i = find(sid)
        return i >= 0 ? staged.get(i) : null
    }
    // Moves, sizes or turns one: `changes` holds any of px, py, size, angle.
    function update(sid, changes) {
        const i = find(sid)
        if (i < 0)
            return
        for (const key in changes)
            staged.setProperty(i, key, changes[key])
        changed()
    }
    function unpost(sid) {
        const i = find(sid)
        if (i >= 0)
            staged.remove(i)
        changed()
    }
    function clearStickers() {
        staged.clear()
        changed()
    }

    // —— Picture effects ——
    // An effect at 0 is off; its key turns it on at `preset`, the strength it
    // looks best at, and its slider fine-tunes it. Their place here is the
    // order they apply in, whatever key or control they are on (layout, then
    // shape, then texture, then colour, the flashes last so that a flash is
    // pure white or black), and the shader's `kind` (shaders/effects.frag).
    // `moving`: it changes by itself. `rate`: a flash (闪黑, 闪白, 频闪), its
    // strength how fast it flashes (flashSteps).
    readonly property var effects: [
        { key: "mirror", name: "镜像", preset: 0.3 },
        { key: "tiles", name: "多画面", preset: 0.3 },
        { key: "lens", name: "鱼眼透镜", preset: 0.5 },
        { key: "twirl", name: "漩涡", preset: 0.4 },
        { key: "punch", name: "缩放冲击", preset: 0.4 },
        { key: "shake", name: "抖动", moving: true, preset: 0.4 },
        { key: "zoom", name: "放射模糊", preset: 0.35 },
        { key: "ghost", name: "灵魂出窍", moving: true, preset: 0.5 },
        { key: "mosaic", name: "马赛克", preset: 0.35 },
        { key: "glitch", name: "故障", moving: true, preset: 0.35 },
        { key: "rgb", name: "RGB 分离", moving: true, preset: 0.4 },
        { key: "halftone", name: "网点", preset: 0.45 },
        { key: "scan", name: "扫描线", moving: true, preset: 0.45 },
        { key: "vhs", name: "VHS", moving: true, preset: 0.6 },
        { key: "edge", name: "描边", preset: 0.8 },
        { key: "rain", name: "雨打玻璃", moving: true, preset: 0.5 },
        { key: "hue", name: "色相", preset: 0.3 },
        { key: "duotone", name: "双色调", preset: 1 },
        { key: "mono", name: "黑白", preset: 1 },
        { key: "threshold", name: "高对比黑白", preset: 1 },
        { key: "invert", name: "反色", preset: 1 },
        { key: "fire", name: "火焰", moving: true, preset: 0.5 },
        { key: "flashBlack", name: "闪黑", rate: true, moving: true, preset: 0.4 },
        { key: "flash", name: "闪白", rate: true, moving: true, preset: 0.4 },
        { key: "strobe", name: "频闪", rate: true, moving: true, preset: 0.4 }
    ]
    property var level: ({})
    // Strengths the operator kept in place of a preset: { key: 0..1 }.
    property var custom: ({})
    // The effect last switched or tuned: what , and . adjust.
    property string focused: ""
    // Effects tuned with , or . since they were switched on: switched off, they
    // keep that strength as their own preset.
    property var tuned: ({})
    // The number keys 1–8 (the number pad too) switch the effects in the
    // rail's right column (the faders' places), with Shift those in the left
    // (the knobs'); , and . tune the last one. Always on.
    readonly property bool keysOn: true

    function setLevel(key, value) {
        value = Math.max(0, Math.min(1, value))
        const i = kind(key)
        if (i >= 0 && effects[i].rate)
            stepTo(key, value)
        const next = Object.assign({}, level)
        next[key] = value
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

    // —— Flashes ——
    // 闪白, 闪黑 and 频闪 flash on and on, their strength how fast: six
    // steps (`flashRates`, flashes a second), the strength's range cut in six
    // and held at a border until well past it, so a fader resting there does
    // not flicker between two; at the foot, off. 闪白 and 闪黑 breathe, coming
    // up over the first fifth of each flash and fading over the rest (so
    // quicker at the faster steps); 频闪 is a hard flash of white
    // `strobeFlash` seconds long. Never more than `fastestFlash` a second:
    // faster reads as flicker rather than flashes, and fast flashing can
    // bring on seizures in people prone to them. A change of step goes on
    // from where the flash was, so nothing jumps.
    readonly property real fastestFlash: 8
    readonly property var flashRates: [1, 1.5, 2.5, 4, 6, fastestFlash]
    readonly property real strobeFlash: 0.035
    // { key: step (0–5) }, and each one's clock: { key: { b0 (flashes gone
    // by at t0), t0 (Date.now()), rate } }.
    property var steps: ({})
    property var flashClocks: ({})
    function stepOf(key, v) {
        if (v <= 0)
            return -1
        const n = flashRates.length
        const i = Math.min(n - 1, Math.floor(v * n))
        const was = steps[key] !== undefined ? steps[key] : -1
        if (was < 0 || i === was)
            return i
        const lo = i / n, hi = (i + 1) / n
        return (i > was && v < lo + 0.02) || (i < was && v > hi - 0.02) ? was : i
    }
    function stepTo(key, v) {
        const step = stepOf(key, v)
        const was = steps[key] !== undefined ? steps[key] : -1
        if (step === was)
            return
        const t = Date.now()
        const clocks = Object.assign({}, flashClocks)
        clocks[key] = { b0: flashesAt(key, t), t0: t, rate: step >= 0 ? flashRates[step] : 0 }
        flashClocks = clocks
        const next = Object.assign({}, steps)
        next[key] = step
        steps = next
    }
    function flashesAt(key, t) {
        const c = flashClocks[key]
        return c ? c.b0 + (t - c.t0) / 1000 * c.rate : 0
    }
    // An effect's step as words, for the hint: "第 3 档（2.5 次/秒）".
    function stepName(key) {
        const step = steps[key] !== undefined ? steps[key] : -1
        return step < 0 ? "关" : "第 " + (step + 1) + " 档（" + flashRates[step] + " 次/秒）"
    }
    // What a pass draws `key` at, at t (Stage): a flash as far as it is lit
    // (闪白 and 闪黑 breathing, 频闪 hard), else the strength.
    function drawnAt(key, t) {
        const i = kind(key)
        if (i < 0)
            return 0
        if (!effects[i].rate)
            return amount(key)
        const step = steps[key] !== undefined ? steps[key] : -1
        if (step < 0)
            return 0
        const n = flashesAt(key, t)
        const f = n - Math.floor(n)
        if (key === "strobe")
            return f < strobeFlash * flashRates[step] ? 1 : 0
        if (f < 0.2) {
            const x = f / 0.2
            return x * x * (3 - 2 * x)
        }
        return Math.exp(-(f - 0.2) * 4.5)
    }

    // —— Where each effect is ——
    // The rail is two columns: row by row, the left key is the controller's
    // knob of that strip and the right one its fader (the first eight rows,
    // its 16 places), the rest of the effects below in the same two columns.
    // `layout` lists them so, left then right, row by row; swapping two (the
    // rail's 调整顺序) is all that changes it. Kept between runs.
    readonly property var defaultLayout: [
        "vhs", "fire",
        "invert", "rain",
        "hue", "threshold",
        "duotone", "lens",
        "rgb", "mosaic",
        "mono", "tiles",
        "glitch", "ghost",
        "edge", "shake",
        "scan", "zoom",
        "mirror", "halftone",
        "twirl", "flashBlack",
        "flash", "punch",
        "strobe"
    ]
    property var layout: defaultLayout
    readonly property int places: 16
    function knobKey(strip) {
        return layout[strip * 2] || ""
    }
    function faderKey(strip) {
        return layout[strip * 2 + 1] || ""
    }
    function swapPlaces(a, b) {
        if (a === b || a < 0 || b < 0 || a >= layout.length || b >= layout.length)
            return
        const next = layout.slice()
        const keep = next[a]
        next[a] = next[b]
        next[b] = keep
        layout = next
        store.layout = layout.join(",")
    }
    // A kept layout made whole: an effect no longer there (or there twice)
    // leaves its place to one missing from it, or, with none missing, to the
    // first of the rest when it was one of the 16 (so no knob or fader is
    // left empty and nothing else moves); missing ones go at the end.
    function keptLayout(saved) {
        const keys = effects.map(e => e.key)
        const list = saved.map((k, i) => keys.indexOf(k) >= 0 && saved.indexOf(k) === i ? k : null)
        const missing = defaultLayout.filter(k => list.indexOf(k) < 0)
        for (let i = 0; i < list.length; ++i) {
            if (list[i] !== null)
                continue
            if (missing.length) {
                list[i] = missing.shift()
            } else if (i < places) {
                const from = list.findIndex((k, j) => j >= places && k !== null)
                if (from >= 0) {
                    list[i] = list[from]
                    list[from] = null
                }
            }
        }
        return list.filter(k => k !== null).concat(missing)
    }
    function resetLayout() {
        layout = defaultLayout
        store.layout = ""
    }
    readonly property bool laidOutOwn: layout.join(",") !== defaultLayout.join(",")

    // —— The controller ——
    // A Korg nanoKONTROL2 in its CC mode, as it comes (any channel). Strip N's
    // knob and fader set the strength of the effects in the rail's row N, left
    // and right (layout). Neither ever jumps an effect that is on: after a
    // key, the mouse or a swap, while one stands elsewhere, the effect follows
    // its moves scaled so that the two meet at the end of its travel (and at
    // once where they cross), then goes with it; an effect that is off it
    // takes at once. Knobs and faders work the effects and nothing else does:
    // every button sends a reaction, in the reactions rail's order
    // (`reactionButtons`). Play, following and the projection are never on it.
    readonly property var cc: ({ fader: 0, knob: 16 })
    // The buttons, each sending the reaction of its place: S1–S8, M1–M8,
    // R1–R8, then TRACK ◀ ▶, CYCLE, MARKER SET ◀ ▶ and ◀◀ ▶▶ ■ ▶ ●, left to
    // right as they sit.
    readonly property var reactionButtons: [32, 33, 34, 35, 36, 37, 38, 39, 48, 49, 50, 51, 52, 53, 54, 55,
                                            64, 65, 66, 67, 68, 69, 70, 71, 58, 59, 46, 60, 61, 62, 43, 44, 42, 41, 45]
    // Where each strip's knob and fader stand (0 to 1), -1 until first moved:
    // the device tells nothing more. touched() tells the rail, to show what
    // one set for a moment.
    signal touched(string key, string control)
    property var faders: [-1, -1, -1, -1, -1, -1, -1, -1]
    property var knobs: [-1, -1, -1, -1, -1, -1, -1, -1]
    // Per control ("k0".."k7", "f0".."f7"): the effect it last worked,
    // whether it has taken over, what it last set.
    property var controls: ({})
    function moveControl(fader, strip, v) {
        const key = fader ? faderKey(strip) : knobKey(strip)
        const id = (fader ? "f" : "k") + strip
        const s = controls[id] || (controls[id] = { key: "", on: false, set: -1 })
        const was = fader ? faders[strip] : knobs[strip]
        if (fader)
            faders = faders.map((f, i) => i === strip ? v : f)
        else
            knobs = knobs.map((k, i) => i === strip ? v : k)
        if (!key)
            return
        const now = amount(key)
        if (s.key !== key || Math.abs(now - s.set) > 1e-6) {
            s.key = key
            s.on = false
        }
        let to = v
        if (!s.on) {
            if (now <= 0 || Math.abs(v - now) <= 0.03 || (was >= 0 && (was - now) * (v - now) <= 0)) {
                s.on = true
            } else if (was >= 0 && v !== was) {
                // Elsewhere still: the same share of the way left, so that
                // the effect and the control meet at the end of the travel.
                to = v > was ? now + (v - was) * (1 - now) / Math.max(1e-6, 1 - was)
                             : now - (was - v) * now / Math.max(1e-6, was)
                s.on = Math.abs(v - to) <= 0.03
            } else {
                // Its first move since it was plugged in: only where it stands.
                return
            }
        }
        focused = key
        setLevel(key, to)
        s.set = amount(key)
        touched(key, fader ? "fader" : "knob")
    }
    function sendReaction(place) {
        if (place < 0 || place >= reactions.length)
            return
        react(reactions[place].glyph)
        reactionPressed(place)
    }
    property Connections midiLink: Connections {
        target: Midi
        // Plugged out or in: where its knobs and faders stand is not known.
        function onDevicesChanged() {
            live.faders = live.faders.map(() => -1)
            live.knobs = live.knobs.map(() => -1)
            for (const id in live.controls)
                live.controls[id].on = false
        }
        function onControl(channel, number, value, ons, offs) {
            const c = live.cc
            if (number >= c.fader && number < c.fader + 8)
                live.moveControl(true, number - c.fader, value / 127)
            else if (number >= c.knob && number < c.knob + 8)
                live.moveControl(false, number - c.knob, value / 127)
            else if (live.reactionButtons.indexOf(number) >= 0) {
                for (let n = 0; n < ons; ++n)
                    live.sendReaction(live.reactionButtons.indexOf(number))
            }
        }
    }
    function setMidi(on) {
        store.midi = on
        Midi.enabled = on
    }

    // The order they apply in: the list's, whatever key they are on.
    readonly property var order: effects.map(e => e.key)
    // The effects that are on, in that order: one pass each.
    readonly property var active: order.filter(k => amount(k) > 0)
    property Settings store: Settings {
        category: "effects"
        property string layout: ""
        property string presets: "{}"
        // Off on Windows until turned on: there WinMM, under Windows 11's new
        // MIDI service, may bring the app down when a device is pulled out.
        property bool midi: Qt.platform.os !== "windows"
    }

    function kind(key) {
        return effects.findIndex(e => e.key === key)
    }
    Component.onCompleted: {
        Midi.enabled = store.midi
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
        reactionOrder = reactionStore.order ? reactionStore.order.split(",") : []
        layout = store.layout ? keptLayout(store.layout.split(",")) : defaultLayout
    }
}
