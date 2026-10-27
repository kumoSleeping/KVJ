pragma Singleton
import QtCore
import QtQuick

// The vision mixer: what the audience sees (`program`, PGM) and what the
// operator is putting together next (`preview`, PVW). Both are layouts:
//
//   { slots: [ { source, x, y, w, h, z, fit, mask } ] }
//
// `source` a picture source id ("track:0".."track:3", "camera:<id>"), x y w h
// the slot in shares of the projected picture (it may lie past its edges, on
// the stage around it, where the audience does not see it), z the order
// (higher on top), fit "cover" (fill, cropped) or "contain" (all of it,
// banded), mask { shape: "rect" | "round" | "circle", radius, feather (shares
// of the slot's shorter side), blend (how wide the split lines' soft band is,
// the same share), lines }.
//
// A split line hides the picture on one side of it: { points: [[x, y, sharp],
// …] (in shares of the slot; `sharp` 1 where the line runs straight into and
// out of the point, else it curves through it), closed (the points make a
// shape: the picture shows inside it), flip (the other side hidden) }. An open
// line goes on straight past its ends; by default the side above it, as it
// runs from its first point to its last, is hidden.
//
// Every picture source is in the preview, once: one newly there is stacked on
// the stage at the picture's right (stack()), to be brought in by the
// operator. apply() puts the preview, and the stickers waiting on it, on the
// air: at once, or dissolving over `fadeMs`. Following (`follow`), every
// change to the preview is on the air as it is made. The projection and the
// operator's PGM monitor both draw `program` (and, while it lasts,
// `transition`) with Program.qml, so they show the same.
QtObject {
    id: switcher

    readonly property var shapes: ["rect", "round", "circle"]

    // A layout made sound: every field there and in range. Slots without a
    // source (left by the presets of before) are dropped.
    function normalize(layout) {
        const l = layout && typeof layout === "object" ? layout : {}
        const slots = Array.isArray(l.slots) ? l.slots : []
        return { slots: slots.map((s, i) => slot(s, i)).filter(s => s.source) }
    }
    function line(l) {
        const o = l && typeof l === "object" ? l : {}
        const points = Array.isArray(o.points)
            ? o.points.filter(p => Array.isArray(p) && p.length >= 2 && isFinite(p[0]) && isFinite(p[1]))
                      .map(p => [+p[0], +p[1], p[2] ? 1 : 0])
            : []
        const closed = o.closed === true && points.length >= 3
        return { points: points, closed: closed, flip: o.flip === true }
    }
    function slot(s, i) {
        const o = s && typeof s === "object" ? s : {}
        const num = (v, d) => typeof v === "number" && isFinite(v) ? v : d
        const m = o.mask && typeof o.mask === "object" ? o.mask : {}
        const lines = Array.isArray(m.lines) ? m.lines.map(line).filter(l => l.points.length >= 2) : []
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
                blend: Math.max(0, Math.min(0.5, num(m.blend, 0.12))),
                lines: lines
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
    // A slot reaches into the picture (not all of it on the stage around).
    function inPicture(s) {
        return s.x < 1 && s.x + s.w > 0 && s.y < 1 && s.y + s.h > 0
    }
    // The source ids of the slots the audience can see.
    function shownSourcesOf(layout) {
        const ids = []
        if (layout && layout.slots)
            for (const s of layout.slots)
                if (s.source && inPicture(s) && ids.indexOf(s.source) < 0)
                    ids.push(s.source)
        return ids
    }

    // —— Split lines ——
    // A line's course, `steps` straight pieces between each two points:
    // [[x, y], …] (closed: back to the first). Between two points it is a
    // cubic through both; at a smooth point it leaves along the line between
    // its neighbours (Catmull-Rom), at a sharp one straight for the other end
    // of the piece, so a piece between two sharp points is straight.
    function course(l, steps) {
        const pts = l ? l.points : []
        const n = pts.length
        if (n < 2)
            return []
        const k = steps || 16
        const closed = !!l.closed && n >= 3
        const at = i => closed ? pts[(i + n) % n] : pts[Math.max(0, Math.min(n - 1, i))]
        const out = []
        const pieces = closed ? n : n - 1
        for (let i = 0; i < pieces; ++i) {
            const a = at(i), b = at(i + 1)
            const chord = [b[0] - a[0], b[1] - a[1]]
            const tangent = (j, p) => {
                if (p[2])
                    return chord
                const before = at(j - 1), after = at(j + 1)
                return [(after[0] - before[0]) / 2, (after[1] - before[1]) / 2]
            }
            const ta = tangent(i, a), tb = tangent(i + 1, b)
            for (let j = 0; j < k; ++j) {
                const t = j / k, t2 = t * t, t3 = t2 * t
                const h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
                out.push([h00 * a[0] + h10 * ta[0] + h01 * b[0] + h11 * tb[0],
                          h00 * a[1] + h10 * ta[1] + h01 * b[1] + h11 * tb[1]])
            }
        }
        const last = closed ? at(0) : at(n - 1)
        out.push([last[0], last[1]])
        return out
    }
    function area(poly) {
        let a = 0
        for (let i = 0; i < poly.length; ++i) {
            const p = poly[i], q = poly[(i + 1) % poly.length]
            a += p[0] * q[1] - q[0] * p[1]
        }
        return a / 2
    }
    function wound(poly, positive) {
        return (area(poly) >= 0) === positive ? poly : poly.slice().reverse()
    }
    // What a line hides, as closed outlines in shares of the slot: filled by
    // the nonzero rule (shapes wound one way, holes the other), so the
    // outlines of every line of a slot together fill what they all hide.
    function hidden(l) {
        const c = course(l, 16)
        if (c.length < 2)
            return []
        const far = 6
        if (l.closed) {
            if (l.flip)
                return [wound(c, true)]
            const box = [[-far, -far], [1 + far, -far], [1 + far, 1 + far], [-far, 1 + far]]
            return [wound(box, true), wound(c, false)]
        }
        const unit = (dx, dy) => {
            const len = Math.hypot(dx, dy)
            return len > 1e-9 ? [dx / len, dy / len] : [1, 0]
        }
        const n = c.length
        const t0 = unit(c[1][0] - c[0][0], c[1][1] - c[0][1])
        const t1 = unit(c[n - 1][0] - c[n - 2][0], c[n - 1][1] - c[n - 2][1])
        const s = [c[0][0] - t0[0] * far, c[0][1] - t0[1] * far]
        const e = [c[n - 1][0] + t1[0] * far, c[n - 1][1] + t1[1] * far]
        // Above the line from its start to its end (screen y grows down).
        const d = unit(e[0] - s[0], e[1] - s[1])
        const side = l.flip ? -1 : 1
        const nx = d[1] * side * far * 2, ny = -d[0] * side * far * 2
        return [wound([s].concat(c, [e, [e[0] + nx, e[1] + ny], [s[0] + nx, s[1] + ny]]), true)]
    }

    // —— The preview's slots ——
    // Changes slot `i` of the preview: any of x, y, w, h, z, fit, mask (a mask
    // given whole; setMask() changes parts of it).
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
        updateSlot(i, { mask: Object.assign({}, preview.slots[i].mask, mask) })
    }
    // A split line across the middle of slot `i`, the half above hidden; its
    // index among the slot's lines. Its ends sit a little inside the slot, off
    // the slot's own handles; the line goes on past them.
    function addLine(i) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return -1
        const lines = preview.slots[i].mask.lines.concat([{ points: [[0.12, 0.5, 0], [0.88, 0.5, 0]], closed: false, flip: false }])
        setMask(i, { lines: lines })
        return lines.length - 1
    }
    function setLine(i, k, changes) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const lines = preview.slots[i].mask.lines.slice()
        if (k < 0 || k >= lines.length)
            return
        lines[k] = line(Object.assign({}, lines[k], changes))
        setMask(i, { lines: lines })
    }
    function removeLine(i, k) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const lines = preview.slots[i].mask.lines.slice()
        lines.splice(k, 1)
        setMask(i, { lines: lines })
    }
    // Slot `i` above every other, or under them all.
    function raiseSlot(i) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const top = preview.slots.reduce((t, s, k) => k === i ? t : Math.max(t, s.z + 1), 0)
        updateSlot(i, { z: top })
    }
    function lowerSlot(i) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const bottom = preview.slots.reduce((b, s, k) => k === i ? b : Math.min(b, s.z - 1), 0)
        updateSlot(i, { z: bottom })
    }
    // Where the next source waits: down the stage at the picture's right, a
    // column at a time. `ratio`: its picture's width / height; `aspect`: the
    // projection's.
    function parking(layout, ratio, aspect) {
        const w = 0.3
        const h = w * aspect / Math.max(0.1, ratio)
        const taken = (layout ? layout.slots : []).filter(s => s.x >= 1)
        for (let col = 0; col < 4; ++col) {
            const x = 1.06 + col * (w + 0.04)
            for (let y = -0.3; y + h <= 1.3; y += h + 0.05)
                if (!taken.some(s => s.x < x + w && x < s.x + s.w && s.y < y + h && y < s.y + s.h))
                    return { x: x, y: y, w: w, h: h }
        }
        return { x: 1.06, y: -0.3, w: w, h: h }
    }
    // Every source of `ids` not yet in the preview, stacked at its right
    // (`ratio(id)`: its picture's shape). Off the picture it changes nothing
    // the audience sees, so it goes on the air's layout too (there parked on
    // its own stack), and is not waiting to be put there. Nothing is taken
    // out: a source that is gone for a moment (a track still loading) keeps
    // its place.
    function stack(ids, ratio, aspect) {
        const add = (layout, id) => {
            const z = layout.slots.reduce((top, s) => Math.max(top, s.z + 1), 0)
            layout.slots.push(slot(Object.assign({ source: id, z: z, fit: "contain" }, parking(layout, ratio(id), aspect)), z))
        }
        const next = copy(preview)
        const air = copy(program)
        let changed = false
        for (const id of ids) {
            if (!next.slots.some(s => s.source === id)) {
                add(next, id)
                changed = true
            }
            if (!air.slots.some(s => s.source === id)) {
                add(air, id)
                changed = true
            }
        }
        if (!changed)
            return
        program = air
        preview = next
    }
    // Slot `i` back on the stack at the picture's right.
    function park(i, ratio, aspect) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const rest = copy(preview)
        rest.slots.splice(i, 1)
        updateSlot(i, parking(rest, ratio, aspect))
    }
    function removeSlot(i) {
        if (!preview || i < 0 || i >= preview.slots.length)
            return
        const next = copy(preview)
        next.slots.splice(i, 1)
        preview = next
    }

    // —— The two layouts ——
    // One picture, the main track, in full: the projection as it was before
    // there was a mixer.
    readonly property var plain: ({ slots: [slot({ source: "track:0", x: 0, y: 0, w: 1, h: 1, z: 0, fit: "contain" }, 0)] })
    property var program: copy(plain)
    property var preview: copy(plain)
    // The preview, or the stickers on it, differ from what is on the air.
    readonly property bool pending: JSON.stringify(preview) !== JSON.stringify(program) || Live.stickersPending

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

    // Following: what is made on the preview is on the air at once, cut.
    property bool follow: false

    function apply() {
        Live.goLive()
        const next = copy(preview)
        if (fadeMs > 0 && JSON.stringify(next) !== JSON.stringify(program)) {
            transition = { from: copy(program), to: next, born: Date.now(), ms: fadeMs }
            done.interval = fadeMs + 50
            done.restart()
        } else {
            done.stop()
            transition = null
        }
        program = next
    }
    // The preview back to what is on the air, its stickers too.
    function revert() {
        Live.restage()
        preview = copy(program)
    }
    onFollowChanged: {
        if (loaded)
            store.follow = follow
        if (follow && loaded)
            apply()
    }
    property Timer done: Timer {
        onTriggered: switcher.transition = null
    }

    // Kept between runs: the two layouts, the dissolve and following.
    property bool loaded: false
    property Settings store: Settings {
        category: "switcher"
        property string program: ""
        property string preview: ""
        property int fadeMs: 600
        property int fadeLength: 600
        property bool follow: false
    }
    // Written a moment after the last change, not on every step of a drag.
    property Timer saving: Timer {
        interval: 400
        onTriggered: {
            switcher.store.program = JSON.stringify(switcher.program)
            switcher.store.preview = JSON.stringify(switcher.preview)
        }
    }
    onProgramChanged: if (loaded) saving.restart()
    onPreviewChanged: {
        if (!loaded)
            return
        saving.restart()
        if (follow) {
            done.stop()
            transition = null
            program = copy(preview)
        }
    }
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
        follow = store.follow
        loaded = true
    }
}
