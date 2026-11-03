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
        // Splash: the picture smaller in the middle, its outline a liquid one
        // that keeps moving (a rounded shape wobbling like water), and from
        // all round it white water thrown out on black: curved streams that
        // grow and fall back, each ending in a drop, and drops flung off
        // further. Strength: how much smaller, and how far the water goes.
        float s = 1.0 - (0.12 + 0.33 * a);
        vec2 c = toSquare(uv);
        float r = length(c);
        vec2 d = c / max(r, 1e-5);
        float theta = atan(d.y, d.x);
        // A rounded rectangle (|x/w|^4 + |y/h|^4 = 1) as large as the smaller
        // picture, its edge rippling.
        vec2 half_ = vec2(aspect, 1.0) * 0.5 * s;
        vec2 q = abs(d) / half_;
        float edge = pow(pow(q.x, 4.0) + pow(q.y, 4.0), -0.25);
        edge += s * (0.022 * sin(5.0 * theta + time * 2.3) + 0.016 * sin(9.0 * theta - time * 3.1)
                     + 0.010 * sin(15.0 * theta + time * 4.7));
        float aa = 0.0025;
        float inside = 1.0 - smoothstep(edge - aa, edge + aa, r);
        vec3 picture = texture(source, fromSquare(c / s)).rgb;
        // A bright rim where the water meets the picture.
        float rim = exp(-abs(r - edge) / 0.004);
        float water = 0.0;
        float glow = 0.0;
        float beyond = r - edge;
        if (beyond > -aa) {
            float n = floor(26.0 + 30.0 * a);
            float around = (theta / 6.2832 + 0.5) * n;
            float reachAll = 0.04 + 0.36 * a;
            for (int j = -1; j <= 1; ++j) {
                float stream = floor(around) + float(j);
                float seed = mod(stream, n);
                float h1 = hash(vec2(seed, 1.3)), h2 = hash(vec2(seed, 2.7)), h3 = hash(vec2(seed, 4.1));
                // Each stream grows and falls back at its own pace.
                float reach = reachAll * (0.35 + 0.65 * h1) * (0.55 + 0.45 * sin(time * (3.0 + 4.0 * h2) + h3 * 6.2832));
                float t = clamp(beyond / max(reach, 1e-3), 0.0, 1.0);
                // Its line bends as it goes out.
                float line = stream + 0.5 + (h2 - 0.5) * 0.4 + (h3 - 0.5) * 1.6 * t * t;
                float across = (around - line) / n * 6.2832 * r;
                float width = (0.007 + 0.016 * h1) * sqrt(1.0 - 0.85 * t);
                float body = beyond < reach ? 1.0 - smoothstep(width - aa, width + aa, abs(across)) : 0.0;
                // The drop at its end.
                vec2 tip = vec2(across, beyond - reach);
                float bulb = 0.008 + 0.014 * h1;
                float drop = 1.0 - smoothstep(bulb - aa, bulb + aa, length(tip));
                float here = max(body, drop);
                // And drops flung further, going out and shrinking.
                for (int f = 0; f < 2; ++f) {
                    float flight = fract(time * (0.7 + 0.8 * h2) + h1 + float(f) * 0.5);
                    vec2 far = vec2(across - (h3 - 0.5) * 0.03 * (1.0 + float(f)), beyond - reach - flight * (0.06 + 0.28 * a));
                    float size = bulb * (0.9 - 0.3 * float(f)) * (1.0 - 0.7 * flight);
                    here = max(here, (1.0 - smoothstep(size - aa, size + aa, length(far))) * (1.0 - flight * flight));
                }
                water = max(water, here);
                glow += exp(-max(abs(across) - width, 0.0) / 0.01) * (beyond < reach * 1.1 ? 0.25 : 0.0);
            }
        }
        // Spray hanging round the edge.
        float mist = beyond > 0.0 ? exp(-beyond / (0.015 + 0.03 * a)) * 0.35 : 0.0;
        vec3 outside = vec3(min(1.0, water + glow * 0.35 + mist));
        color = mix(outside, picture, inside) + vec3(rim * 0.6 * (0.6 + 0.4 * a));
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
