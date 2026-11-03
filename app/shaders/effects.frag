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

// Rain on glass, one layer of it: a drop in some cells of a grid (as many as
// `density`), running down its cell fast and then slow, wavering; a tear,
// narrow above and round below, drawn out the more it runs, its outline
// stirred by noise, with a thin streak of water left above it and small
// drops along that. Gives how far to look aside through the water (xy, in
// the cell's units) and how much water there is (z). After the idea of
// BigWings' "Heartfelt" (Shadertoy); written anew.
vec3 rainLayer(vec2 p, float t, float density)
{
    vec2 cell = vec2(1.0, 2.0);
    vec2 id = floor(p / cell);
    vec2 st = fract(p / cell) - 0.5;
    float n = hash(id);
    if (n > density)
        return vec3(0.0);
    float phase = fract(t * (0.12 + 0.2 * hash(id + 3.3)) + n * 7.0);
    // Down the cell, slower as it goes, and back to the top.
    float y = -0.42 + 0.84 * (1.0 - (1.0 - phase) * (1.0 - phase));
    float speed = 2.0 * (1.0 - phase);
    float wobble = 0.06 * (1.0 - phase);
    float x = (hash(id + 7.1) - 0.5) * 0.5 + sin(phase * 13.0 + n * 40.0) * wobble;
    vec2 to = (st - vec2(x, y)) * vec2(1.0, 2.0);
    float r = 0.13 + 0.07 * hash(id + 5.9);
    // A tear: drawn out upwards (behind it) and narrowed there, the more
    // the faster it runs; its rim stirred.
    float behind = max(-to.y, 0.0);
    vec2 shape = vec2(to.x * (1.0 + behind / r * (0.5 + speed * 0.3)), to.y / (1.0 + (to.y < 0.0 ? 0.3 + speed * 0.4 : 0.0)));
    float angle = atan(shape.y, shape.x);
    float rim = r * (1.0 + 0.12 * (noise(vec2(angle * 2.0 + n * 9.0, t * 0.5 + n)) - 0.5));
    float drop = smoothstep(rim, rim * 0.6, length(shape));
    // The streak above: a thin line where it came down, wavering, fading
    // further up, with small drops of different sizes along it.
    float above = y - st.y;
    float path = x + sin(st.y * 18.0 + n * 30.0) * 0.015;
    float streak = smoothstep(0.03, 0.008, abs(st.x - path)) * step(0.0, above) * (1.0 - smoothstep(0.0, 0.45, above)) * 0.12;
    float row = floor(st.y * 9.0);
    vec2 tr = vec2(st.x - path, (fract(st.y * 9.0) - 0.5) / 9.0);
    float size = (0.012 + 0.03 * hash(vec2(row, n))) * step(0.45, hash(vec2(row, n + 2.0)));
    float bead = smoothstep(size, size * 0.4, length(tr * vec2(1.0, 1.3))) * step(0.0, above) * (1.0 - smoothstep(0.05, 0.5, above));
    float trail = max(streak, bead);
    vec2 aside = shape / r * drop + tr / max(size, 1e-3) * bead * 0.4;
    return vec3(aside, max(drop, trail));
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
        // Rain on the glass: drops (more with strength) running down and
        // still ones on the pane, the picture bent through each, its colours
        // parting a little at their rims, a glint on each, and the picture
        // a faint blue, never more.
        vec2 p = vec2(uv.x * aspect, uv.y);
        float density = 0.1 + 0.85 * a;
        vec3 big = rainLayer(p * 6.0, time, density);
        vec3 small = rainLayer(p * 12.0 + vec2(3.7, 1.1), time * 1.3, density * 0.9);
        // Still drops beading on the pane, coming and going: two in a cell,
        // not round, flattened a little, of all sizes, run together where
        // they touch.
        vec2 g = p * 24.0;
        vec2 gid = floor(g);
        vec2 gst = fract(g) - 0.5;
        vec2 c1 = (vec2(hash(gid + 1.0), hash(gid + 2.0)) - 0.5) * 0.5;
        vec2 c2 = c1 + (vec2(hash(gid + 5.0), hash(gid + 6.0)) - 0.5) * 0.45;
        float r1 = 0.06 + 0.14 * hash(gid + 3.0), r2 = 0.04 + 0.1 * hash(gid + 7.0);
        vec2 o1 = (gst - c1) * vec2(1.0, 1.2), o2 = (gst - c2) * vec2(1.0, 1.25);
        float wob = 0.25 * (noise(gst * 9.0 + gid * 3.1) - 0.5);
        float d1 = length(o1) - r1 * (1.0 + wob), d2 = length(o2) - r2 * (1.0 - wob);
        float k = 0.06;
        float h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
        float dd = mix(d2, d1, h) - k * h * (1.0 - h);
        float on = step(hash(gid), density * 0.6) * smoothstep(0.0, 0.3, sin(time * 0.6 + hash(gid + 4.0) * 6.2832));
        float bead = (1.0 - smoothstep(-0.03, 0.005, dd)) * on;
        vec2 gc = mix(c2, c1, h);
        float gr = mix(r2, r1, h);
        vec2 aside = big.xy * 0.06 + small.xy * 0.03 + (gst - gc) / gr * bead * 0.012;
        float water = max(max(big.z, small.z), bead);
        aside.x /= aspect;
        // The wet glass a little misted (five looks), clear through the water.
        float mist = (0.002 + 0.004 * a) * (1.0 - water);
        vec2 m = vec2(mist / aspect, mist);
        vec3 misted = (texture(source, uv).rgb + texture(source, uv + m).rgb + texture(source, uv - m).rgb
                       + texture(source, uv + vec2(m.x, -m.y)).rgb + texture(source, uv + vec2(-m.x, m.y)).rgb) / 5.0;
        vec3 through = vec3(texture(source, uv + aside * 1.1).r, texture(source, uv + aside).g, texture(source, uv + aside * 0.9).b);
        color = mix(misted, through, smoothstep(0.0, 0.3, water));
        // A darker rim round each drop, and a glint, the light from the upper left.
        color *= 1.0 - 0.35 * water * (1.0 - water) * 4.0;
        vec2 bend = normalize(aside + 1e-6);
        float glint = pow(max(dot(bend, vec2(0.55, 0.83)), 0.0), 4.0) * smoothstep(0.002, 0.02, length(aside));
        color += water * glint * 0.6;
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
            float spark = step(hash(eid), 0.06 + 0.1 * a) * smoothstep(0.2, 0.02, length(est))
                        * (0.5 + 0.5 * sin(time * 20.0 + hash(eid) * 50.0)) * smoothstep(high * 2.2, high * 0.3, d);
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
