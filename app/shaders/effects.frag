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
        // Out of body: a faint larger copy leaving the picture over and over.
        color = texture(source, uv).rgb;
        for (int i = 0; i < 2; ++i) {
            float t = fract(time * 0.9 + float(i) * 0.5);
            float s = 1.0 + t * (0.15 + 0.45 * a);
            vec3 ghost = texture(source, (uv - 0.5) / s + 0.5).rgb;
            color = mix(color, max(color, ghost), (1.0 - t) * 0.6 * a);
        }
    } else if (k == 8) {
        // Splash: the picture drawn smaller in the middle, and from all round
        // its edge rays of the edge's own colours thrown outwards like water
        // from a stone, a new throw twenty times a second.
        float s = 1.0 - (0.12 + 0.3 * a);
        vec2 c = toSquare(uv);
        vec2 half_ = vec2(aspect, 1.0) * 0.5 * s;
        if (abs(c.x) <= half_.x && abs(c.y) <= half_.y) {
            color = texture(source, fromSquare(c / s)).rgb;
        } else {
            // Where the line from the centre meets the smaller picture's edge.
            vec2 d = c / max(length(c), 1e-5);
            float toEdge = min(half_.x / max(abs(d.x), 1e-5), half_.y / max(abs(d.y), 1e-5));
            vec2 edge = d * toEdge;
            float beyond = length(c) - toEdge;
            vec3 ink = texture(source, fromSquare(edge * 0.985 / s)).rgb;
            float slot = floor(time * 20.0);
            float angle = atan(d.y, d.x) / 6.2832 + 0.5;
            color = ink * 0.12 * (1.0 - smoothstep(0.0, 0.25, beyond));
            for (int layer = 0; layer < 2; ++layer) {
                float n = floor(70.0 + 90.0 * a) + float(layer) * 37.0;
                float ray = floor(angle * n);
                float within = fract(angle * n);
                vec2 seed = vec2(ray + float(layer) * 101.0, slot);
                float reach = (0.08 + 0.55 * a) * (0.25 + 0.75 * hash(seed));
                float width = 0.15 + 0.5 * hash(seed + 3.1);
                float body = step(abs(within - 0.5), width * 0.5 * (1.0 - beyond / max(reach, 1e-3)));
                // A drop flung off the end of every other ray.
                float drop = hash(seed + 5.7) < 0.5 ? 0.0
                           : step(length(vec2((within - 0.5) / n * 6.2832 * length(c), beyond - reach * 1.08)), 0.006 * (0.5 + a));
                // The edge's colour at its brightest, its hue kept.
                vec3 bright = mix(ink, ink / max(max(ink.r, ink.g), max(ink.b, 0.05)), 0.8);
                color = max(color, bright * (beyond < reach ? body * (1.0 - 0.5 * beyond / max(reach, 1e-3)) : 0.0));
                color = max(color, bright * drop);
            }
        }
    } else if (k == 9) {
        // Mosaic.
        float across = mix(150.0, 10.0, pow(a, 0.6));
        vec2 grid = vec2(across, across / aspect);
        color = texture(source, (floor(uv * grid) + 0.5) / grid).rgb;
    } else if (k == 10) {
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
    } else if (k == 11) {
        // RGB split, jittering a little while it is on.
        color = split(uv, vec2(a * 0.018 * (1.0 + 0.3 * sin(time * 7.0)), 0.0));
    } else if (k == 12) {
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
    } else if (k == 13) {
        // Scan lines with a rolling bar and a little noise.
        color = texture(source, uv).rgb;
        float line = 0.5 + 0.5 * sin(uv.y * 240.0 * 6.2832);
        float roll = smoothstep(0.0, 0.08, fract(uv.y - time * 0.12)) * (1.0 - smoothstep(0.08, 0.18, fract(uv.y - time * 0.12)));
        color *= 1.0 - a * 0.55 * line;
        color += a * (0.07 * roll + 0.06 * (hash(uv * 512.0 + fract(time) * 37.0) - 0.5));
    } else if (k == 14) {
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
    } else if (k == 15) {
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
        // Flash to black (Live lowers `amount` as it fades).
        color = texture(source, uv).rgb * (1.0 - a);
    } else if (k == 22 || k == 23) {
        // Flash to white, and the strobe's flashes (Live sets `amount`).
        color = mix(texture(source, uv).rgb, vec3(1.0), a);
    } else {
        color = texture(source, uv).rgb;
    }

    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0) * qt_Opacity;
}
