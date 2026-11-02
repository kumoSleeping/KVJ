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
        { glyph: "🐍", file: "1f40d" }
    ]
    // The reactions in the rail's order (dragged there), kept between runs;
    // Q to P send the first ten.
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
    // shader's `kind` (shaders/effects.frag).
    readonly property var effects: [
        { key: "mosaic", name: "马赛克", preset: 0.35 },
        { key: "rgb", name: "RGB 分离", moving: true, preset: 0.4 },
        { key: "tiles", name: "多画面", steps: true, preset: 0.3 },
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
    // in the list; , and . tune the last one. Always on.
    readonly property bool keysOn: true

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
    readonly property bool effectsMoving: effects.some(e => (e.moving || rhythmOf(e.key) > 0) && amount(e.key) > 0)

    // —— Rhythm ——
    // How often an effect hits, in beats of the music; up the knob, more and
    // faster. 不跟拍 (the knob at its foot) leaves the effect as it always was.
    // With a rhythm, a still effect comes on at the start of each period and
    // goes off at its middle (按拍开关: a hard cut on the beat reads across a
    // dark room), coming on a little stronger than set and settling; a moving
    // one (RGB 分离, 水波, 故障, 扫描线) keeps its own motion and hits hard at
    // the start of each period (wider, taller, more torn), so 2 小节 already
    // moves more than 不跟拍 and 1/8 拍 most. 多画面 steps instead, a period
    // each, 1×1, 2×2 … up to the grid its strength sets and back down. A
    // period shorter than `shortest` cannot be seen on a screen (1/8 拍 at
    // 168 BPM is 45 ms, under three frames): such a rhythm goes at the next
    // slower one that can, and says so. Set with the controller's knobs
    // (below); not kept between runs.
    readonly property var rhythms: [
        { beats: 0, name: "不跟拍" },
        { beats: 8, name: "2 小节" },
        { beats: 4, name: "1 小节" },
        { beats: 2, name: "2 拍" },
        { beats: 1, name: "1 拍" },
        { beats: 0.5, name: "1/2 拍" },
        { beats: 0.25, name: "1/4 拍" },
        { beats: 0.125, name: "1/8 拍" }
    ]
    // { key: index into rhythms }
    property var rhythm: ({})
    readonly property real shortest: 0.08
    // The beats a period `beats` goes at now (slower when too short to see).
    function playedBeats(beats) {
        let d = beats
        while (d > 0 && d < 1 && d * 60 / bpm < shortest)
            d *= 2
        return d
    }
    // An effect's rhythm as words: "1/4 拍", or "1/8 拍（按 1/4 拍）".
    function rhythmName(key) {
        const i = rhythmOf(key)
        const g = grids[key]
        if (!i || !g || g.d === rhythms[i].beats)
            return rhythms[i].name
        const at = rhythms.find(r => r.beats === g.d)
        return rhythms[i].name + "（按 " + (at ? at.name : g.d + " 拍") + "）"
    }
    function rhythmOf(key) {
        return rhythm[key] || 0
    }
    // Each rhythm's grid: { beats (its rhythm's), d (beats a period now, see
    // playedBeats), from (the beat it counts from), shift, at }. A change of rhythm (or of where bars start) never
    // jumps: the period goes on from where it was, `shift` periods off the
    // new grid, and that is made up at half the pace, so the effect runs
    // between half and one and a half times as fast for up to a period and
    // is then on the beat again (`at`: the new grid's count at the change).
    property var grids: ({})
    function gridRaw(g, t) {
        return (beatAt(t) - g.from) / g.d
    }
    function gridAt(g, t) {
        const raw = gridRaw(g, t)
        const left = Math.max(0, Math.abs(g.shift) - 0.5 * (raw - g.at))
        return raw + (g.shift < 0 ? -left : left)
    }
    function regrid(key, beats) {
        const t = Date.now()
        const next = Object.assign({}, grids)
        if (!beats) {
            delete next[key]
        } else {
            const d = playedBeats(beats)
            const g = { beats: beats, d: d, from: d >= 2 ? barAt % d : 0, shift: 0, at: 0 }
            g.at = gridRaw(g, t)
            const old = grids[key]
            if (old) {
                let shift = gridAt(old, t) - g.at
                shift -= Math.round(shift)
                g.shift = shift
            }
            next[key] = g
        }
        grids = next
    }
    function setRhythm(key, i) {
        i = Math.max(0, Math.min(rhythms.length - 1, i))
        if (kind(key) < 0 || rhythmOf(key) === i)
            return
        regrid(key, rhythms[i].beats)
        const next = Object.assign({}, rhythm)
        next[key] = i
        rhythm = next
    }
    function resetRhythms() {
        grids = {}
        rhythm = {}
    }
    readonly property bool effectsSynced: active.some(k => rhythmOf(k) > 0)
    function moves(key) {
        const i = kind(key)
        return i >= 0 && !!effects[i].moving
    }

    // The beat clock: beats counted from the start, as the line beatB0 +
    // (t − beatT0) · beatRate (t in Date.now() ms), so the projection and each
    // preview, drawing on clocks of their own, agree. hearBeat() steers it to
    // the picture's video ten times a second while an effect keeps a rhythm:
    // to its beats where they are known, never by a jump (a difference is
    // made up at up to half the tempo again, half a beat in a second at 120
    // BPM), else at the last tempo heard, 120 BPM to begin with.
    property real beatT0: epoch
    property real beatB0: 0
    property real beatRate: 2
    property real bpm: 120
    // On the music's beats now.
    property bool beatLocked: false
    // The beats starting bars: barAt, barAt + 4, … (a guess over a long mix).
    property int barAt: 0
    // What the clock goes by, for the hint and the log: "画面" (the video the
    // picture plays) or "空跑" (none playing: on at the last tempo); whether
    // that file has beats there and bars; how far off its beat the clock was
    // at the last look, in beats.
    property string beatSource: "空跑"
    property bool beatHeard: false
    property bool barKnown: false
    property real beatError: 0
    function beatAt(t) {
        return beatB0 + (t - beatT0) / 1000 * beatRate
    }
    // How many of `key`'s periods have gone by at t (only its fraction and
    // its whole count's changes matter), a bar or longer starting on a bar.
    function periodsAt(key, t) {
        const g = grids[key]
        if (!g)
            return 0
        const p = gridAt(g, t)
        // Small enough for the shader's floats to keep the fraction fine, and
        // a whole number of 多画面's round trips (2, 4, 6, 8 or 10 periods).
        return p - Math.floor(p / 240) * 240
    }
    // A still effect with a rhythm shows in the first half of each period.
    function shownAt(key, t) {
        const i = kind(key)
        if (rhythmOf(key) === 0 || moves(key) || (i >= 0 && effects[i].steps))
            return true
        const p = periodsAt(key, t)
        return p - Math.floor(p) < 0.5
    }
    // `heard`: Beats.at() where the picture is (or null), `speed` how fast it
    // plays, `source` what it is (beatSource).
    function hearBeat(heard, speed, source) {
        beatSource = heard && speed > 0 ? source : "空跑"
        beatHeard = !!heard && heard.beat !== undefined && speed > 0
        barKnown = beatHeard && heard.bar >= 0
        const t = Date.now()
        const now = beatAt(t)
        if (heard && heard.bpm > 0 && speed > 0)
            bpm = Math.max(40, Math.min(300, heard.bpm * speed))
        let base = bpm / 60
        beatB0 = now
        beatT0 = t
        if (heard && heard.beat !== undefined && speed > 0) {
            // The beats' own pace just here: the section's tempo is the
            // song's, a little off where it speeds up or slows down.
            if (heard.beatsPerSecond > 0)
                base = Math.max(0.5, Math.min(5, heard.beatsPerSecond * speed))
            // To the nearest beat: which beat it is says nothing.
            let e = heard.beat - now
            e -= Math.round(e)
            beatError = e
            beatLocked = true
            beatRate = base + Math.max(-0.5 * base, Math.min(0.5 * base, e / 0.5))
            if (heard.bar >= 0) {
                const heardBeat = Math.round(heard.beat)
                const mine = Math.round(now + e - (heard.beat - heardBeat))
                const bar = ((heard.bar + mine - heardBeat) % 4 + 4) % 4
                if (bar !== barAt) {
                    barAt = bar
                    // Bars start elsewhere: the bar-long grids move there smoothly.
                    for (const k in grids)
                        if (grids[k].d >= 2)
                            regrid(k, grids[k].beats)
                }
            }
        } else {
            beatLocked = false
            beatRate = base
        }
        // The tempo moved a rhythm across what can be seen: on at the other pace, smoothly.
        for (const k in grids)
            if (playedBeats(grids[k].beats) !== grids[k].d)
                regrid(k, grids[k].beats)
    }

    // —— The controller ——
    // A Korg nanoKONTROL2 in its CC mode, as it comes (any channel). Its eight
    // strips work the first eight effects of the rail (TRACK ▶ the ninth on,
    // TRACK ◀ back): the fader the strength (at the foot: off), the knob the
    // rhythm. A fader never jumps an effect that is on: after a number key,
    // the mouse, a reorder or the other page, while it stands elsewhere, the
    // effect follows its moves scaled so that the two meet at the end of its
    // travel (and at once where they cross), then goes with it. An effect that
    // is off the fader takes at once. A knob always takes at once, turning
    // its effect to the beat: its whole travel is the rhythms from 2 小节
    // (left) to 1/8 拍 (right), never 不跟拍 (R), and a change of rhythm never
    // jumps (grids). S switches the effect as its number key does,
    // M held flips it (off while held, or on at its best strength) and R puts
    // its rhythm back to 不跟拍. Play, following and the projection are never
    // on it.
    readonly property var cc: ({ fader: 0, knob: 16, solo: 32, mute: 48, rec: 64, trackLeft: 58, trackRight: 59 })
    property int midiPage: 0
    readonly property int midiPages: Math.ceil(Math.max(1, chain.count) / 8)
    // The effect a strip works now, or "".
    function stripKey(strip) {
        const i = midiPage * 8 + strip
        return i < order.length ? order[i] : ""
    }
    // Where each strip's fader stands (0 to 1) and its knob points (an index
    // into rhythms), -1 until it is first moved: the device tells nothing more.
    // touched() tells the rail which, to show what it set for a moment.
    signal touched(string key, string control)
    property var faders: [-1, -1, -1, -1, -1, -1, -1, -1]
    property var knobs: [-1, -1, -1, -1, -1, -1, -1, -1]
    // Per strip: the effect its fader last worked, whether it has taken
    // over, what it last set, and the effect M holds flipped.
    property var strips: [0, 1, 2, 3, 4, 5, 6, 7].map(() => ({ faderKey: "", faderOn: false, faderSet: -1, held: null }))
    function moveFader(strip, v) {
        const key = stripKey(strip)
        const s = strips[strip]
        const was = faders[strip]
        faders = faders.map((f, i) => i === strip ? v : f)
        if (!key)
            return
        const now = amount(key)
        if (s.faderKey !== key || Math.abs(now - s.faderSet) > 1e-6) {
            s.faderKey = key
            s.faderOn = false
        }
        let to = v
        if (!s.faderOn) {
            if (now <= 0 || Math.abs(v - now) <= 0.03 || (was >= 0 && (was - now) * (v - now) <= 0)) {
                s.faderOn = true
            } else if (was >= 0 && v !== was) {
                // Elsewhere still: the same share of the way left, so that
                // the effect and the fader meet at the end of the travel.
                to = v > was ? now + (v - was) * (1 - now) / Math.max(1e-6, 1 - was)
                             : now - (was - v) * now / Math.max(1e-6, was)
                s.faderOn = Math.abs(v - to) <= 0.03
            } else {
                // Its first move since it was plugged in: only where it stands.
                return
            }
        }
        focused = key
        setLevel(key, to)
        s.faderSet = amount(key)
        touched(key, "fader")
    }
    // A knob's place among the rhythms, held at a border until well past it.
    // (1 to 7: 不跟拍 is never on the knob.)
    function knobRhythm(v, before) {
        const n = rhythms.length - 1
        const i = Math.min(n - 1, Math.floor(v * n / 128))
        if (before < 1 || i === before - 1)
            return i + 1
        const lo = i * 128 / n, hi = (i + 1) * 128 / n
        return (i > before - 1 && v < lo + 3) || (i < before - 1 && v > hi - 3) ? before : i + 1
    }
    function turnKnob(strip, v) {
        const key = stripKey(strip)
        const at = knobRhythm(v, knobs[strip])
        knobs = knobs.map((k, i) => i === strip ? at : k)
        if (!key)
            return
        setRhythm(key, at)
        touched(key, "knob")
    }
    function pressStrip(strip, row, ons, offs, down) {
        const key = stripKey(strip)
        const s = strips[strip]
        if (row === "solo") {
            if (key && ons % 2)
                toggleEffect(key)
        } else if (row === "rec") {
            if (key && ons > 0)
                setRhythm(key, 0)
        } else if (row === "mute") {
            // Pressed and let go between two looks: nothing to see.
            if (ons > 0 && down && !s.held && key) {
                s.held = { key: key, level: amount(key) }
                toggleEffect(key)
            } else if (offs > 0 && !down && s.held) {
                const h = s.held
                s.held = null
                if (h.level > 0)
                    setLevel(h.key, h.level)
                else
                    switchEffect(h.key, false)
            }
        }
    }
    function setMidiPage(page) {
        midiPage = Math.max(0, Math.min(midiPages - 1, page))
    }
    property Connections midiLink: Connections {
        target: Midi
        // Plugged out or in: where its faders and knobs stand is not known.
        function onDevicesChanged() {
            live.faders = live.faders.map(() => -1)
            live.knobs = live.knobs.map(() => -1)
            for (const s of live.strips)
                s.faderOn = false
        }
        function onControl(channel, number, value, ons, offs) {
            const c = live.cc
            if (number >= c.fader && number < c.fader + 8)
                live.moveFader(number - c.fader, value / 127)
            else if (number >= c.knob && number < c.knob + 8)
                live.turnKnob(number - c.knob, value)
            else if (number >= c.solo && number < c.solo + 8)
                live.pressStrip(number - c.solo, "solo", ons, offs, value > 0)
            else if (number >= c.mute && number < c.mute + 8)
                live.pressStrip(number - c.mute, "mute", ons, offs, value > 0)
            else if (number >= c.rec && number < c.rec + 8)
                live.pressStrip(number - c.rec, "rec", ons, offs, value > 0)
            else if (number === c.trackLeft && ons > 0)
                live.setMidiPage(live.midiPage - 1)
            else if (number === c.trackRight && ons > 0)
                live.setMidiPage(live.midiPage + 1)
        }
    }
    function setMidi(on) {
        store.midi = on
        Midi.enabled = on
    }

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
        // Off on Windows until turned on: there WinMM, under Windows 11's new
        // MIDI service, may bring the app down when a device is pulled out.
        property bool midi: Qt.platform.os !== "windows"
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
        const saved = store.order.split(",").filter((k, i, all) => kind(k) >= 0 && all.indexOf(k) === i)
        const keys = saved.concat(effects.map(e => e.key).filter(k => saved.indexOf(k) < 0))
        for (const k of keys)
            chain.append({ key: k, name: effects[kind(k)].name })
        chainRevision += 1
    }
}
