#version 440
// Every picture effect in one pass, each a no-op at 0. Where it reads the
// picture is bent first (wall, lens, wave, glitch, mosaic), then it is sampled
// (RGB split, zoom blur), then its colours are changed. All sizes are fractions
// of the picture, so the small preview looks like the projection.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;   // seconds
    float aspect; // width / height
    float mosaic;
    float rgb;
    float tiles;
    float lens;
    float zoom;
    float wave;
    float glitch;
    float scan;
    float halftone;
    float posterize;
    float hue;
    float mono;
    float vignette;
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

void main()
{
    vec2 uv = qt_TexCoord0;
    bool seam = false;

    // A wall of screens: 2×2 from the first step up to 6×6, with thin bezels.
    if (tiles > 0.0) {
        float n = 1.0 + ceil(tiles * 5.0);
        vec2 cell = fract(uv * n);
        vec2 bezel = vec2(0.0025 / aspect, 0.0025) * n;
        seam = any(lessThan(cell, bezel)) || any(greaterThan(cell, 1.0 - bezel));
        uv = cell;
    }

    // A lens bulging from the centre.
    if (lens > 0.0) {
        vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
        float r = length(c) / 0.8;
        float k = lens * 0.62;
        c *= r < 1.0 ? 1.0 - k * (1.0 - r * r) : 1.0;
        uv = c / vec2(aspect, 1.0) + 0.5;
    }

    if (wave > 0.0) {
        uv.x += sin(uv.y * 11.0 + time * 2.2) * 0.018 * wave;
        uv.y += sin(uv.x * 8.0 + time * 1.7) * 0.012 * wave;
    }

    // Bands torn sideways, a new tear about twelve times a second.
    float tear = 0.0;
    if (glitch > 0.0) {
        float slot = floor(time * 12.0);
        float band = floor(uv.y * 22.0);
        if (hash(vec2(band, slot)) < glitch * 0.55) {
            tear = hash(vec2(band, slot + 7.0)) - 0.5;
            uv.x += tear * 0.16 * glitch;
        }
    }

    if (mosaic > 0.0) {
        float across = mix(150.0, 10.0, pow(mosaic, 0.6));
        vec2 grid = vec2(across, across / aspect);
        uv = (floor(uv * grid) + 0.5) / grid;
    }

    // RGB split, jittering a little while it is on; torn bands split further.
    vec2 offset = vec2(rgb * 0.018 * (1.0 + 0.3 * sin(time * 7.0)) + abs(tear) * 0.03 * glitch, 0.0);
    vec3 color;
    if (zoom > 0.0) {
        // Zoom blur: smeared outwards from the centre.
        color = vec3(0.0);
        for (int i = 0; i < 12; ++i) {
            float s = 1.0 - zoom * 0.2 * float(i) / 11.0;
            color += split((uv - 0.5) * s + 0.5, offset);
        }
        color /= 12.0;
    } else {
        color = split(uv, offset);
    }

    // Halftone: a dot per cell, as large as the cell is bright.
    if (halftone > 0.0) {
        float across = mix(180.0, 45.0, halftone);
        vec2 grid = vec2(across, across / aspect);
        vec2 cell = uv * grid;
        vec3 ink = texture(source, (floor(cell) + 0.5) / grid).rgb;
        float light = dot(ink, vec3(0.299, 0.587, 0.114));
        float d = length(fract(cell) - 0.5);
        float radius = sqrt(light) * 0.62;
        float spot = 1.0 - smoothstep(radius - 0.08, radius + 0.08, d);
        color = mix(color, ink * spot * 1.15, smoothstep(0.0, 0.25, halftone));
    }

    if (posterize > 0.0) {
        float levels = mix(12.0, 2.5, posterize);
        color = mix(color, floor(color * levels + 0.5) / levels, smoothstep(0.0, 0.15, posterize));
    }

    if (hue > 0.0) {
        // Rotate the hue in YIQ, up to most of the way round.
        float a = hue * 5.5;
        mat3 toYiq = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
        mat3 toRgb = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);
        vec3 yiq = toYiq * color;
        float c = cos(a);
        float s = sin(a);
        yiq.yz = vec2(yiq.y * c - yiq.z * s, yiq.y * s + yiq.z * c);
        color = toRgb * yiq;
    }

    if (mono > 0.0) {
        float light = dot(color, vec3(0.299, 0.587, 0.114));
        color = mix(color, vec3(smoothstep(0.02, 0.98, light)), mono);
    }

    if (scan > 0.0) {
        float line = 0.5 + 0.5 * sin(qt_TexCoord0.y * 240.0 * 6.2832);
        float roll = smoothstep(0.0, 0.08, fract(qt_TexCoord0.y - time * 0.12)) * (1.0 - smoothstep(0.08, 0.18, fract(qt_TexCoord0.y - time * 0.12)));
        color *= 1.0 - scan * 0.55 * line;
        color += scan * (0.07 * roll + 0.06 * (hash(qt_TexCoord0 * 512.0 + fract(time) * 37.0) - 0.5));
    }

    if (vignette > 0.0) {
        float d = length((qt_TexCoord0 - 0.5) * vec2(aspect, 1.0)) / length(vec2(aspect, 1.0) * 0.5);
        color *= 1.0 - vignette * 0.95 * smoothstep(0.35, 1.0, d);
    }

    if (seam)
        color = vec3(0.0);
    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0) * qt_Opacity;
}
