pragma Singleton
import QtCore
import QtQuick

// The vision mixer: what the audience sees (`program`, PGM) and what the
// operator is putting together next (`preview`, PVW). Both are layouts:
//
//   { name, slots: [ { source, x, y, w, h, z, fit, mask } ] }
//
// `source` a picture source id ("track:0".."track:3", "camera:<id>"), x y w h
// the slot in shares of the projected picture (it may reach past its edges),
// z the order (higher on top), fit "cover" (fill, cropped) or "contain" (all
// of it, banded), mask { shape: "rect" | "round" | "circle" | "path", radius,
// feather (shares of the slot's shorter side), points: [[x, y], …] (the
// closed curve through them, in shares of the slot) }.
//
// apply() puts the preview on the air: at once, or dissolving over `fadeMs`.
// The projection and the operator's PGM monitor both draw `program` (and,
// while it lasts, `transition`) with Program.qml, so they show the same.
QtObject {
    id: switcher

    readonly property var shapes: ["rect", "round", "circle", "path"]

    // A layout made sound: every field there and in range.
    function normalize(layout) {
        const l = layout && typeof layout === "object" ? layout : {}
        const slots = Array.isArray(l.slots) ? l.slots : []
        return { name: typeof l.name === "string" ? l.name : "", slots: slots.map((s, i) => slot(s, i)) }
    }
    function slot(s, i) {
        const o = s && typeof s === "object" ? s : {}
        const num = (v, d) => typeof v === "number" && isFinite(v) ? v : d
        const m = o.mask && typeof o.mask === "object" ? o.mask : {}
        const points = Array.isArray(m.points)
            ? m.points.filter(p => Array.isArray(p) && p.length >= 2 && isFinite(p[0]) && isFinite(p[1])).map(p => [+p[0], +p[1]])
            : []
        return {
            source: typeof o.source === "string" ? o.source : "",
            x: num(o.x, 0), y: num(o.y, 0),
            w: Math.max(0.01, num(o.w, 1)), h: Math.max(0.01, num(o.h, 1)),
            z: num(o.z, i || 0),
            fit: o.fit === "cover" ? "cover" : "contain",
            mask: {
                shape: shapes.indexOf(m.shape) >= 0 ? m.shape : "rect",
                radius: Math.max(0, Math.min(0.5, num(m.radius, 0.08))),
                feather: Math.max(0, Math.min(0.5, num(m.feather, 0))),
                points: points
            }
        }
    }
    function copy(layout) {
        return normalize(JSON.parse(JSON.stringify(layout || {})))
    }
    // The source ids a layout draws, each once.
    function sourcesOf(layout) {
        const ids = []
        if (layout && layout.slots)
            for (const s of layout.slots)
                if (s.source && ids.indexOf(s.source) < 0)
                    ids.push(s.source)
        return ids
    }

    // The closed Catmull-Rom curve through `points` ([[x, y], …]), as
    // `steps` straight pieces between each two: [[x, y], …], closed.
    function curve(points, steps) {
        const n = points ? points.length : 0
        if (n < 3)
            return []
        const k = steps || 12
        const out = []
        for (let i = 0; i < n; ++i) {
            const p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            for (let j = 0; j < k; ++j) {
                const t = j / k, t2 = t * t, t3 = t2 * t
                const at = c => 0.5 * (2 * p1[c] + (p2[c] - p0[c]) * t
                                       + (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t2
                                       + (3 * p1[c] - p0[c] - 3 * p2[c] + p3[c]) * t3)
                out.push([at(0), at(1)])
            }
        }
        out.push(out[0])
        return out
    }

    // —— Presets ——
    // `count`: how many sources it takes. 画中画 has a corner: "tl", "tr",
    // "bl", "br" (the inset's), bottom right unless told.
    readonly property var presets: [
        { key: "single", name: "单画面", count: 1 },
        { key: "pip", name: "画中画", count: 2 },
        { key: "split", name: "左右", count: 2 },
        { key: "stack", name: "上下", count: 2 },
        { key: "quad", name: "2×2", count: 4 },
        { key: "onetwo", name: "1 大 + 2 小", count: 3 }
    ]
    readonly property var corners: [
        { key: "tl", name: "左上" }, { key: "tr", name: "右上" },
        { key: "bl", name: "左下" }, { key: "br", name: "右下" }
    ]
    // The preset's key from its key or name; "pip-tl" or "画中画 · 左上" carry
    // the corner too: { key, corner }.
    function presetKey(name) {
        const text = String(name || "")
        for (const c of corners)
            if (text === "pip-" + c.key || text === "画中画 · " + c.name || text === "画中画·" + c.name || text === "画中画" + c.name)
                return { key: "pip", corner: c.key }
        const p = presets.find(p => p.key === text || p.name === text)
        return p ? { key: p.key, corner: "" } : null
    }
    // A layout for `sources` (ids, the first ones used in order; a missing
    // one leaves its slot empty to be chosen).
    function preset(name, sources, corner) {
        const found = presetKey(name)
        if (!found)
            return null
        const ids = sources || []
        const id = i => ids[i] || ""
        const box = (i, x, y, w, h, fit, mask) => slot({ source: id(i), x: x, y: y, w: w, h: h, z: i, fit: fit || "cover", mask: mask || {} }, i)
        const key = found.key
        if (key === "single")
            return { name: "单画面", slots: [box(0, 0, 0, 1, 1, "contain")] }
        if (key === "pip") {
            const c = corners.find(c => c.key === (corner || found.corner)) || corners[3]
            const w = 0.32, h = 0.32, mx = 0.03, my = 0.04
            const x = c.key[1] === "l" ? mx : 1 - mx - w
            const y = c.key[0] === "t" ? my : 1 - my - h
            return { name: "画中画 · " + c.name, slots: [
                box(0, 0, 0, 1, 1, "contain"),
                box(1, x, y, w, h, "cover", { shape: "round", radius: 0.08 })
            ] }
        }
        if (key === "split")
            return { name: "左右", slots: [box(0, 0, 0, 0.5, 1), box(1, 0.5, 0, 0.5, 1)] }
        if (key === "stack")
            return { name: "上下", slots: [box(0, 0, 0, 1, 0.5), box(1, 0, 0.5, 1, 0.5)] }
        if (key === "quad")
            return { name: "2×2", slots: [box(0, 0, 0, 0.5, 0.5), box(1, 0.5, 0, 0.5, 0.5), box(2, 0, 0.5, 0.5, 0.5), box(3, 0.5, 0.5, 0.5, 0.5)] }
        if (key === "onetwo")
            return { name: "1 大 + 2 小", slots: [box(0, 0, 0, 2 / 3, 1), box(1, 2 / 3, 0, 1 / 3, 0.5), box(2, 2 / 3, 0.5, 1 / 3, 0.5)] }
        return null
    }
    function setPreviewPreset(name, sources, corner) {
        const made = preset(name, sources, corner)
        if (made)
            preview = made
    }

    // —— The two layouts ——
    // One picture, the main track, in full: the projection as it was before
    // there was a mixer.
    readonly property var plain: ({ name: "单画面", slots: [slot({ source: "track:0", x: 0, y: 0, w: 1, h: 1, z: 0, fit: "contain" }, 0)] })
    property var program: copy(plain)
    property var preview: copy(plain)
    // The preview differs from what is on the air.
    readonly property bool pending: JSON.stringify(preview) !== JSON.stringify(program)

    // Changes slot `i` of the preview: any of source, x, y, w, h, z, fit, mask
    // (a mask given whole; setMask() changes parts of it).
    function updateSlot(i, changes) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const next = copy(preview)
        next.slots[i] = slot(Object.assign({}, next.slots[i], changes), i)
        preview = next
    }
    function setMask(i, mask) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const m = Object.assign({}, preview.slots[i].mask, mask)
        // A curve to start from: six points round the middle.
        if (m.shape === "path" && (!m.points || m.points.length < 3))
            m.points = [[0.5, 0.06], [0.92, 0.28], [0.92, 0.72], [0.5, 0.94], [0.08, 0.72], [0.08, 0.28]]
        updateSlot(i, { mask: m })
    }
    // A new slot on top, a third of the picture in the middle; its index.
    function addSlot(source) {
        const next = copy(preview)
        const z = next.slots.reduce((top, s) => Math.max(top, s.z + 1), 0)
        next.slots.push(slot({ source: source || "", x: 1 / 3, y: 1 / 3, w: 1 / 3, h: 1 / 3, z: z, fit: "cover" }, z))
        preview = next
        return next.slots.length - 1
    }
    function removeSlot(i) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const next = copy(preview)
        next.slots.splice(i, 1)
        preview = next
    }
    // Slot `i` above every other.
    function raiseSlot(i) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const top = preview.slots.reduce((t, s, k) => k === i ? t : Math.max(t, s.z + 1), 0)
        updateSlot(i, { z: top })
    }

    // —— Putting the preview on the air ——
    // 0 cuts; else a dissolve this long. `fadeLength` is the length the
    // dissolve takes when it is switched on again.
    property int fadeMs: 600
    property int fadeLength: 600
    // While dissolving: { from, to (layouts), born (Date.now() ms), ms }.
    // Drawing stops at born + ms on its own (Program.qml); this is cleared
    // a moment after.
    property var transition: null
    readonly property bool fading: transition !== null

    function apply() {
        const next = copy(preview)
        if (fadeMs > 0) {
            transition = { from: copy(program), to: next, born: Date.now(), ms: fadeMs }
            done.interval = fadeMs + 50
            done.restart()
        } else {
            done.stop()
            transition = null
        }
        program = next
    }
    // The preview back to what is on the air.
    function revert() {
        preview = copy(program)
    }
    property Timer done: Timer {
        onTriggered: switcher.transition = null
    }

    // Kept between runs: the two layouts and the dissolve.
    property bool loaded: false
    property Settings store: Settings {
        category: "switcher"
        property string program: ""
        property string preview: ""
        property int fadeMs: 600
        property int fadeLength: 600
    }
    onProgramChanged: if (loaded) store.program = JSON.stringify(program)
    onPreviewChanged: if (loaded) store.preview = JSON.stringify(preview)
    onFadeMsChanged: {
        if (fadeMs > 0)
            fadeLength = fadeMs
        if (loaded)
            store.fadeMs = fadeMs
    }
    onFadeLengthChanged: if (loaded) store.fadeLength = fadeLength
    function restore(text) {
        try {
            return normalize(JSON.parse(text))
        } catch (error) {
            return copy(plain)
        }
    }
    Component.onCompleted: {
        program = store.program ? restore(store.program) : copy(plain)
        preview = store.preview ? restore(store.preview) : copy(program)
        fadeLength = Math.max(1, store.fadeLength)
        fadeMs = Math.max(0, store.fadeMs)
        loaded = true
    }
}
