#version 440
// One picture effect a pass, `kind` being its place in Live.effects, at
// `amount` (0 to 1). Stage chains a pass for each effect that is on, in that
// fixed order (layout, then shape, then texture, then colour, the flashes
// last), each reading the picture the one before made. All sizes are
// fractions of the picture, so the small preview looks like the projection.
// Every effect is this one pass and reads only the picture in front of it:
// none keeps an earlier frame.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;   // seconds
    float aspect; // width / height
    float kind;
    float amount;
};
layout(binding = 1) uniform sampler2D source;

float hash(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// smoothstep that may also fall (from 1 at e0 to 0 at e1 when e0 > e1):
// smoothstep itself is undefined that way round, and some GPUs give NaN.
float ease(float e0, float e1, float x)
{
    return e0 < e1 ? smoothstep(e0, e1, x) : 1.0 - smoothstep(e1, e0, x);
}

// How deep a drop is at r (its radius 1): 1 in the middle, 0 at the rim and
// flat there.
float dome(float r)
{
    float d = max(0.0, 1.0 - r * r);
    return d * d;
}
// The larger of a and b, rounded where they are within k of each other.
float smax(float a, float b, float k)
{
    float h = max(k - abs(a - b), 0.0) / k;
    return max(a, b) + h * h * k * 0.25;
}

vec3 split(vec2 uv, vec2 offset)
{
    if (offset == vec2(0.0))
        return texture(source, uv).rgb;
    return vec3(texture(source, uv + offset).r, texture(source, uv).g, texture(source, uv - offset).b);
}

float luma(vec3 c)
{
    return dot(c, vec3(0.299, 0.587, 0.114));
}

// Smooth value noise in [0, 1], and four octaves of it.
float noise(vec2 p)
{
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p)
{
    float sum = 0.0, weight = 0.5;
    for (int i = 0; i < 4; ++i) {
        sum += weight * noise(p);
        p = p * 2.03 + vec2(1.7, 9.2);
        weight *= 0.5;
    }
    return sum;
}

// Rain on glass, as BigWings' "Heartfelt" (Shadertoy, 2017; explained in
// his videos) builds it, written anew from that explanation, no code taken:
// every drop, trail and droplet adds to one field of how much water there
// is, the field is cut at a level so that drops, trails and droplets close
// to each other run together into one smooth shape, and the picture is
// bent by the field's slope. Coordinates here have y up.

// A running drop and its trail in one cell of a layer: the cells are tall
// and thin, each column shifted by its own amount; in each cell a drop
// slides down in fits and starts (slowly, then a quick slip), its own size,
// speed and sway, while the trail above it widens towards it and leaves
// droplets that stay on the glass. Gives the water (x) and how much trail
// clears the mist (y).
vec2 runningDrops(vec2 v, float t, float density)
{
    vec2 glass = v;
    vec2 cells = vec2(12.0, 2.0);
    float shift = t * 0.7 + hash(vec2(floor(v.x * cells.x), 3.1));
    v.y += shift;
    vec2 id = floor(v * cells);
    vec2 st = fract(v * cells) - vec2(0.5, 0.0);
    float h1 = hash(id + 0.7), h2 = hash(id + 1.9), h3 = hash(id + 3.3), h4 = hash(id + 5.1);
    if (h4 > density)
        return vec2(0.0);
    // Down the cell slowly, then a slip: the slope of a soft saw.
    float phase = fract(t * (0.8 + 0.5 * h2) + h3);
    float saw = smoothstep(0.0, 0.85, phase) * ease(1.0, 0.85, phase);
    float y = (saw - 0.5) * 0.9 + 0.5;
    // Its line down, swaying as it goes, less near the cell's sides: the
    // drop where its own middle has got to, its streak row by row.
    float k = 14.0 + 10.0 * h2;
    float swayHere = glass.y * k;
    float swayDrop = ((id.y + y) / cells.y - shift) * k;
    float reachX = (0.5 - abs(h1 - 0.5)) * (h3 - 0.5);
    float x = ((h1 - 0.5) + sin(swayDrop + sin(swayDrop)) * reachX) * 0.7;
    float xPath = ((h1 - 0.5) + sin(swayHere + sin(swayHere)) * reachX) * 0.7;
    // Its own size, and kept whole inside its cell.
    float size = 0.16 + 0.2 * h4 * h4 / max(density, 0.05);
    size = min(size, 0.36);
    x = clamp(x, size - 0.48, 0.48 - size);
    xPath = clamp(xPath, size - 0.48, 0.48 - size);
    vec2 to = (st - vec2(x, y)) * vec2(1.0, cells.x / cells.y);
    float d = length(to);
    // A dome, flat at its rim (so where it lies over another the two run
    // together without a crease): its slope, not just its rim, bends the
    // picture.
    float drop = dome(d / size);
    // A neck above it that runs into it: a short upright stroke from the
    // drop's middle, thinner as it goes up but never to a point, its end
    // round (a capsule), fading into the trail. Cut at one level with the
    // drop, one tear: round and full below, tapering softly to a round tip.
    float neckLength = size * (1.3 + 0.9 * h2);
    float along = clamp(to.y, 0.0, neckLength);
    float neckWidth = size * (0.62 - 0.3 * along / neckLength);
    float neck = dome(length(vec2(to.x, to.y - along)) / neckWidth) * 0.85;
    // The trail: nothing at the cell's top, widening down to the drop.
    float widen = sqrt(ease(1.0, y, st.y));
    float off = abs(st.x - xPath);
    float behind = smoothstep(-0.02, 0.02, st.y - y);
    float trail = ease(0.22 * widen + 1e-4, 0.14 * widen * widen, off) * behind * widen * widen;
    // Droplets left on the glass along it, a row of them, some missing.
    float rows = 8.0 + 6.0 * h1;
    float rowId = floor(glass.y * rows);
    // How far from the middle of its row, in the cell's height, then in its width.
    float fromRow = (0.5 - fract(glass.y * rows)) * cells.y / rows;
    float dsize = 0.06 + 0.12 * hash(vec2(id.x, rowId));
    float dr = length(vec2(st.x - xPath, fromRow * cells.x / cells.y)) / dsize;
    float droplet = dome(dr) * step(0.3, hash(vec2(id.x + 0.5, rowId)));
    // The trail itself holds a little water, too little to show alone,
    // enough for the neck to fade into.
    return vec2(drop + neck + droplet * widen * behind + trail * 0.07, trail);
}

// Still drops: one in each of a fine grid's cells, anywhere in it, most
// tiny and a few large, each coming and going at its own time.
float stillDrops(vec2 v, float t, float density)
{
    v *= 40.0;
    vec2 id = floor(v);
    vec2 st = fract(v) - 0.5;
    float h1 = hash(id + 2.2), h2 = hash(id + 4.4), h3 = hash(id + 6.6);
    float size = 0.05 + 0.33 * h3 * h3 * h3;
    // Anywhere in the cell, but whole inside it.
    vec2 at = (vec2(h1, h2) - 0.5) * 2.0 * (0.46 - size * 1.15);
    float life = fract(t * (0.15 + 0.2 * h1) + h2);
    float fade = smoothstep(0.0, 0.05, life) * ease(1.0, 0.4, life);
    return dome(length((st - at) * vec2(1.0, 1.0 + 0.3 * h1)) / size) * fade * step(h3 * 0.8, density);
}

// The water at v: still drops and two layers of running ones (the second
// smaller by a ratio that is no whole number, and shifted), in one field:
// where it passes a level is water, so what lies close together runs
// together into one smooth shape, and the sum's slope bends the picture.
// x: how deep, y: trail.
vec2 rainField(vec2 v, float t, float a)
{
    float stillOnes = stillDrops(v, t, a) * (0.4 + 1.2 * a);
    vec2 one = runningDrops(v, t, 0.15 + 0.85 * smoothstep(0.0, 0.6, a));
    vec2 two = runningDrops(v * 1.83 + vec2(7.3, 2.9), t * 1.1, smoothstep(0.25, 1.0, a));
    // The layers in one field, run together where they meet (a smooth
    // maximum: one larger body of water, one rim, one glint).
    return vec2(smax(smax(stillOnes, one.x, 0.35), two.x, 0.35), max(one.y, two.y));
}

// Picture coordinates about the centre with square units, and back.
vec2 toSquare(vec2 uv)
{
    return (uv - 0.5) * vec2(aspect, 1.0);
}
vec2 fromSquare(vec2 c)
{
    return c / vec2(aspect, 1.0) + 0.5;
}

void main()
{
    vec2 uv = qt_TexCoord0;
    int k = int(kind + 0.5);
    float a = amount;
    vec3 color;

    if (k == 0) {
        // Mirror: the left half again on the right, then (past half way)
        // the top half again below too.
        uv.x = uv.x < 0.5 ? uv.x : 1.0 - uv.x;
        if (a > 0.5)
            uv.y = uv.y < 0.5 ? uv.y : 1.0 - uv.y;
        color = texture(source, uv).rgb;
    } else if (k == 1) {
        // A wall of screens: 2×2 from the first step up to 6×6, with thin bezels.
        float n = 1.0 + ceil(a * 5.0);
        vec2 cell = fract(uv * n);
        vec2 bezel = vec2(0.0025 / aspect, 0.0025) * n;
        bool seam = any(lessThan(cell, bezel)) || any(greaterThan(cell, 1.0 - bezel));
        color = seam ? vec3(0.0) : texture(source, cell).rgb;
    } else if (k == 2) {
        // A lens bulging from the centre.
        vec2 c = toSquare(uv);
        float r = length(c) / 0.8;
        c *= r < 1.0 ? 1.0 - a * 0.62 * (1.0 - r * r) : 1.0;
        color = texture(source, fromSquare(c)).rgb;
    } else if (k == 3) {
        // Twirl: turned about the centre, most in the middle.
        vec2 c = toSquare(uv);
        float turn = a * 5.0 * (1.0 - smoothstep(0.0, 0.75, length(c)));
        float s = sin(turn), co = cos(turn);
        c = vec2(c.x * co - c.y * s, c.x * s + c.y * co);
        color = texture(source, fromSquare(c)).rgb;
    } else if (k == 4) {
        // Punch: the picture pushed in, up to two thirds again as large.
        color = texture(source, (uv - 0.5) * (1.0 - a * 0.4) + 0.5).rgb;
    } else if (k == 5) {
        // Shake: thrown about, a new place thirty times a second.
        float slot = floor(time * 30.0);
        vec2 jolt = vec2(hash(vec2(slot, 1.0)), hash(vec2(slot, 2.0))) - 0.5;
        float s = 1.0 - a * 0.06; // a little larger, so no edge shows
        color = texture(source, (uv - 0.5) * s + 0.5 + jolt * a * 0.05).rgb;
    } else if (k == 6) {
        // Zoom blur: smeared outwards from the centre.
        color = vec3(0.0);
        for (int i = 0; i < 12; ++i) {
            float s = 1.0 - a * 0.2 * float(i) / 11.0;
            color += texture(source, (uv - 0.5) * s + 0.5).rgb;
        }
        color /= 12.0;
    } else if (k == 7) {
        // Out of body: soft, brightened, slightly larger copies leaving the
        // picture and fading, three at a time a third of the way apart, each
        // a little blurred as it grows, laid on with a screen so they glow.
        vec3 base = texture(source, uv).rgb;
        color = base;
        for (int i = 0; i < 3; ++i) {
            float t = fract(time * 0.7 + float(i) / 3.0);
            float s = 1.0 + t * (0.1 + 0.35 * a);
            vec2 p = (uv - 0.5) / s + 0.5;
            vec2 spread = (p - 0.5) * (0.01 + 0.03 * t);
            vec3 ghost = (texture(source, p).rgb + texture(source, p + spread).rgb + texture(source, p - spread).rgb) / 3.0;
            ghost = min(vec3(1.0), ghost * 1.15 + 0.03);
            float fade = (1.0 - t) * (1.0 - t) * smoothstep(0.0, 0.08, t) * (0.3 + 0.35 * a);
            color = 1.0 - (1.0 - color) * (1.0 - ghost * fade);
        }
    } else if (k == 8) {
        // Mosaic.
        float across = mix(150.0, 10.0, pow(a, 0.6));
        vec2 grid = vec2(across, across / aspect);
        color = texture(source, (floor(uv * grid) + 0.5) / grid).rgb;
    } else if (k == 9) {
        // Bands torn sideways, a new tear about twelve times a second; torn
        // bands split their colours.
        float tear = 0.0;
        float slot = floor(time * 12.0);
        float band = floor(uv.y * 22.0);
        if (hash(vec2(band, slot)) < a * 0.55) {
            tear = hash(vec2(band, slot + 7.0)) - 0.5;
            uv.x += tear * 0.16 * a;
        }
        color = split(uv, vec2(abs(tear) * 0.03 * a, 0.0));
    } else if (k == 10) {
        // RGB split, jittering a little while it is on.
        color = split(uv, vec2(a * 0.018 * (1.0 + 0.3 * sin(time * 7.0)), 0.0));
    } else if (k == 11) {
        // Halftone: a dot per cell, as large as the cell is bright.
        color = texture(source, uv).rgb;
        float across = mix(180.0, 45.0, a);
        vec2 grid = vec2(across, across / aspect);
        vec2 cell = uv * grid;
        vec3 ink = texture(source, (floor(cell) + 0.5) / grid).rgb;
        float d = length(fract(cell) - 0.5);
        float radius = sqrt(luma(ink)) * 0.62;
        float spot = 1.0 - smoothstep(radius - 0.08, radius + 0.08, d);
        color = mix(color, ink * spot * 1.15, smoothstep(0.0, 0.25, a));
    } else if (k == 12) {
        // Scan lines with a rolling bar and a little noise.
        color = texture(source, uv).rgb;
        float line = 0.5 + 0.5 * sin(uv.y * 240.0 * 6.2832);
        float roll = smoothstep(0.0, 0.08, fract(uv.y - time * 0.12)) * (1.0 - smoothstep(0.08, 0.18, fract(uv.y - time * 0.12)));
        color *= 1.0 - a * 0.55 * line;
        color += a * (0.07 * roll + 0.06 * (hash(uv * 512.0 + fract(time) * 37.0) - 0.5));
    } else if (k == 13) {
        // A worn tape: lines shifted a little, a tracking band rolling up,
        // colours bleeding sideways, washed out, with grain.
        float row = floor(uv.y * 240.0);
        float slot = floor(time * 30.0);
        uv.x += (hash(vec2(row, slot)) - 0.5) * 0.004 * a;
        float band = fract(uv.y + time * 0.18);
        float tracking = smoothstep(0.0, 0.03, band) * (1.0 - smoothstep(0.03, 0.08, band));
        uv.x += tracking * 0.03 * a * (hash(vec2(row, slot + 3.0)) - 0.3);
        float bleed = 0.006 * a;
        color = vec3(texture(source, uv + vec2(bleed, 0.0)).r, texture(source, uv).g, texture(source, uv - vec2(bleed, 0.0)).b);
        color = mix(color, vec3(luma(color)), 0.25 * a) * (1.0 + 0.06 * a) + vec3(0.03, 0.0, 0.04) * a;
        color += a * (0.1 * tracking + 0.07 * (hash(uv * 640.0 + slot) - 0.5));
    } else if (k == 14) {
        // Neon outline: only the edges, glowing in the picture's colours.
        vec2 px = vec2(0.0015 / aspect, 0.0015);
        float tl = luma(texture(source, uv + px * vec2(-1.0, -1.0)).rgb);
        float tc = luma(texture(source, uv + px * vec2(0.0, -1.0)).rgb);
        float tr = luma(texture(source, uv + px * vec2(1.0, -1.0)).rgb);
        float ml = luma(texture(source, uv + px * vec2(-1.0, 0.0)).rgb);
        float mr = luma(texture(source, uv + px * vec2(1.0, 0.0)).rgb);
        float bl = luma(texture(source, uv + px * vec2(-1.0, 1.0)).rgb);
        float bc = luma(texture(source, uv + px * vec2(0.0, 1.0)).rgb);
        float br = luma(texture(source, uv + px * vec2(1.0, 1.0)).rgb);
        float gx = tr + 2.0 * mr + br - tl - 2.0 * ml - bl;
        float gy = bl + 2.0 * bc + br - tl - 2.0 * tc - tr;
        float edge = smoothstep(0.08, 0.5, length(vec2(gx, gy)));
        vec3 base = texture(source, uv).rgb;
        vec3 glow = normalize(base + 0.05) * 1.6 * edge;
        color = mix(base, glow, a);
    } else if (k == 15) {
        // Rain on the glass (rainField): the more strength, the more drops.
        // The glass mists a little except where water is or a drop has just
        // run; through the water the picture is clear and bent by the
        // water's slope, its colours parting a little, a glint where the
        // slope faces the light, and all of it a faint blue, never more.
        vec2 v = vec2(uv.x * aspect, 1.0 - uv.y) * 0.9;
        vec2 here = rainField(v, time * 0.25, a);
        float e = 0.0012;
        float dx = rainField(v + vec2(e, 0.0), time * 0.25, a).x - here.x;
        float dy = rainField(v + vec2(0.0, e), time * 0.25, a).x - here.x;
        vec2 slope = vec2(dx, -dy);
        float water = smoothstep(0.1, 0.22, here.x);
        float clear = max(water, here.y);
        float mist = (0.002 + 0.004 * a) * (1.0 - clear);
        vec2 m = vec2(mist / aspect, mist);
        vec3 misted = (texture(source, uv).rgb + texture(source, uv + m).rgb + texture(source, uv - m).rgb
                       + texture(source, uv + vec2(m.x, -m.y)).rgb + texture(source, uv + vec2(-m.x, m.y)).rgb) / 5.0;
        vec2 bend = slope * water * vec2(1.0 / aspect, 1.0) * 0.35;
        vec3 through = vec3(texture(source, uv + bend * 1.1).r, texture(source, uv + bend).g, texture(source, uv + bend * 0.9).b);
        color = mix(misted, through, smoothstep(0.0, 0.25, clear));
        float glint = pow(max(dot(normalize(vec3(slope * 60.0, 1.0)), normalize(vec3(-0.5, 0.7, 0.6))), 0.0), 24.0);
        color += glint * water * 0.5;
        // A darker rim where the water ends.
        color *= 1.0 - 0.25 * smoothstep(0.08, 0.16, here.x) * (1.0 - smoothstep(0.16, 0.3, here.x));
        color = mix(color, color * vec3(0.9, 0.96, 1.08) + vec3(0.0, 0.01, 0.03), 0.18 + 0.12 * a);
    } else if (k == 16) {
        // Rotate the hue in YIQ, up to most of the way round.
        color = texture(source, uv).rgb;
        float turn = a * 5.5;
        mat3 toYiq = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
        mat3 toRgb = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);
        vec3 yiq = toYiq * color;
        float c = cos(turn);
        float s = sin(turn);
        yiq.yz = vec2(yiq.y * c - yiq.z * s, yiq.y * s + yiq.z * c);
        color = toRgb * yiq;
    } else if (k == 17) {
        // Duotone, as a heat camera sees: dark blue through purple and red
        // to yellow and white.
        vec3 base = texture(source, uv).rgb;
        float l = luma(base);
        vec3 heat = l < 0.25 ? mix(vec3(0.02, 0.0, 0.15), vec3(0.45, 0.0, 0.6), l / 0.25)
                  : l < 0.5 ? mix(vec3(0.45, 0.0, 0.6), vec3(0.95, 0.15, 0.1), (l - 0.25) / 0.25)
                  : l < 0.75 ? mix(vec3(0.95, 0.15, 0.1), vec3(1.0, 0.85, 0.1), (l - 0.5) / 0.25)
                  : mix(vec3(1.0, 0.85, 0.1), vec3(1.0), (l - 0.75) / 0.25);
        color = mix(base, heat, a);
    } else if (k == 18) {
        // Black and white.
        color = texture(source, uv).rgb;
        color = mix(color, vec3(smoothstep(0.02, 0.98, luma(color))), a);
    } else if (k == 19) {
        // Pure black and white, nothing between.
        color = texture(source, uv).rgb;
        color = mix(color, vec3(smoothstep(0.47, 0.53, luma(color))), a);
    } else if (k == 20) {
        // A negative.
        color = texture(source, uv).rgb;
        color = mix(color, 1.0 - color, a);
    } else if (k == 21) {
        // Fire all round the picture's edge. Each edge burns on its own:
        // flames from four octaves of noise warped by more of it, tongues of
        // all heights, brightest and thickest at the edge, thinning inwards.
        // Fire rises: the foot's flames climb highest and fastest, the
        // sides' lean upwards as they go, the top's curl in only a little.
        // Embers drift up from it, and the picture near it shimmers in the
        // heat. White and yellow at the heart, through orange and red to dark
        // red. Strength: how high and fierce. Only near the edge is it worked
        // out.
        vec2 q = toSquare(uv);
        vec2 room = vec2(aspect, 1.0) * 0.5 - abs(q);
        float high = 0.06 + 0.24 * a;
        float d = min(room.x, room.y);
        float near = exp(-d / (high * 1.2));
        // Heat haze.
        vec2 haze = (vec2(noise(uv * 40.0 + vec2(0.0, time * 4.0)), noise(uv * 40.0 + vec2(7.0, time * 4.0))) - 0.5) * 0.008 * near * (0.4 + 0.6 * a);
        color = texture(source, uv + haze).rgb;
        if (d < high * 2.2) {
            float heat = 0.0;
            for (int e = 0; e < 2; ++e) {
                float inward = e == 0 ? room.x : room.y;
                // The foot burns highest, the top lowest.
                float reach = e == 0 ? high * 1.05 : (q.y > 0.0 ? high * 1.5 : high * 0.6);
                if (inward > reach * 1.6)
                    continue;
                float along = e == 0 ? q.y + 10.0 * sign(q.x) : q.x + 20.0 * sign(q.y);
                // Rising: up the sides, inwards (up) from the foot, slowly
                // inwards from the top.
                float rise = e == 0 ? 0.0 : (q.y > 0.0 ? 3.2 : 1.2);
                vec2 f = vec2(along * 8.0 + (e == 0 ? time * 2.2 : 0.0), inward * 4.5 / (reach / high) - time * (rise + 1.0));
                vec2 warp = vec2(fbm(f * 0.7 + vec2(0.0, time * 0.5)), fbm(f * 0.7 + vec2(5.2, -time * 0.4)));
                float flame = fbm(f + warp * 1.7);
                // Tongues of all heights along the edge.
                float tall = 0.35 + 1.1 * noise(vec2(along * 2.5 + time * 0.4, float(e) * 3.0));
                float h = flame * 1.8 - inward / (reach * tall) * 1.25 + exp(-inward / 0.012) * 0.3 * noise(vec2(along * 6.0 - time, 4.0));
                heat = max(heat, clamp(h, 0.0, 1.0) * (0.65 + 0.45 * noise(vec2(along * 3.0 - time * 0.6, 1.0 + float(e)))));
            }
            heat = clamp(heat, 0.0, 1.0);
            vec3 fire = heat < 0.3 ? mix(vec3(0.0), vec3(0.5, 0.03, 0.0), heat / 0.3)
                      : heat < 0.55 ? mix(vec3(0.5, 0.03, 0.0), vec3(1.0, 0.3, 0.02), (heat - 0.3) / 0.25)
                      : heat < 0.8 ? mix(vec3(1.0, 0.3, 0.02), vec3(1.0, 0.8, 0.15), (heat - 0.55) / 0.25)
                      : mix(vec3(1.0, 0.8, 0.15), vec3(1.0, 0.95, 0.6), (heat - 0.8) / 0.2);
            float body = smoothstep(0.08, 0.4, heat);
            color = mix(color, fire, body) + vec3(1.0, 0.35, 0.05) * near * 0.22 * (0.4 + 0.6 * a);
            // Embers: sparks drifting up and away, flickering.
            vec2 e = q * 32.0 + vec2(0.0, time * 6.0);
            vec2 eid = floor(e);
            vec2 est = fract(e) - 0.5 - (vec2(hash(eid + 1.3), hash(eid + 2.9)) - 0.5) * 0.6;
            float spark = step(hash(eid), 0.06 + 0.1 * a) * ease(0.2, 0.02, length(est))
                        * (0.5 + 0.5 * sin(time * 20.0 + hash(eid) * 50.0)) * ease(high * 2.2, high * 0.3, d);
            color += vec3(1.0, 0.6, 0.15) * spark * 1.4;
        }
    } else if (k == 22) {
        // Flash to black (Live lowers `amount` as it fades).
        color = texture(source, uv).rgb * (1.0 - a);
    } else if (k == 23 || k == 24) {
        // Flash to white, and the strobe's flashes (Live sets `amount`).
        color = mix(texture(source, uv).rgb, vec3(1.0), a);
    } else {
        color = texture(source, uv).rgb;
    }

    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0) * qt_Opacity;
}
