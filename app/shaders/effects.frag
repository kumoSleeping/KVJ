#version 440
// One picture effect a pass, `kind` being its place in Live.effects, at
// `amount` (0 to 1). Stage chains a pass for each effect that is on, in the
// order the desk lists them, each reading the picture the one before made, so
// the order changes the look (a mosaic of a wall of screens, or a wall of
// mosaics). All sizes are fractions of the picture, so the small preview looks
// like the projection.

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

void main()
{
    vec2 uv = qt_TexCoord0;
    int k = int(kind + 0.5);
    vec3 color;

    if (k == 0) {
        // Mosaic.
        float across = mix(150.0, 10.0, pow(amount, 0.6));
        vec2 grid = vec2(across, across / aspect);
        color = texture(source, (floor(uv * grid) + 0.5) / grid).rgb;
    } else if (k == 1) {
        // RGB split, jittering a little while it is on.
        color = split(uv, vec2(amount * 0.018 * (1.0 + 0.3 * sin(time * 7.0)), 0.0));
    } else if (k == 2) {
        // A wall of screens: 2×2 from the first step up to 6×6, with thin bezels.
        float n = 1.0 + ceil(amount * 5.0);
        vec2 cell = fract(uv * n);
        vec2 bezel = vec2(0.0025 / aspect, 0.0025) * n;
        bool seam = any(lessThan(cell, bezel)) || any(greaterThan(cell, 1.0 - bezel));
        color = seam ? vec3(0.0) : texture(source, cell).rgb;
    } else if (k == 3) {
        // A lens bulging from the centre.
        vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
        float r = length(c) / 0.8;
        c *= r < 1.0 ? 1.0 - amount * 0.62 * (1.0 - r * r) : 1.0;
        color = texture(source, c / vec2(aspect, 1.0) + 0.5).rgb;
    } else if (k == 4) {
        // Zoom blur: smeared outwards from the centre.
        color = vec3(0.0);
        for (int i = 0; i < 12; ++i) {
            float s = 1.0 - amount * 0.2 * float(i) / 11.0;
            color += texture(source, (uv - 0.5) * s + 0.5).rgb;
        }
        color /= 12.0;
    } else if (k == 5) {
        // Water.
        uv.x += sin(uv.y * 11.0 + time * 2.2) * 0.018 * amount;
        uv.y += sin(uv.x * 8.0 + time * 1.7) * 0.012 * amount;
        color = texture(source, uv).rgb;
    } else if (k == 6) {
        // Bands torn sideways, a new tear about twelve times a second; torn
        // bands split their colours.
        float tear = 0.0;
        float slot = floor(time * 12.0);
        float band = floor(uv.y * 22.0);
        if (hash(vec2(band, slot)) < amount * 0.55) {
            tear = hash(vec2(band, slot + 7.0)) - 0.5;
            uv.x += tear * 0.16 * amount;
        }
        color = split(uv, vec2(abs(tear) * 0.03 * amount, 0.0));
    } else if (k == 7) {
        // Scan lines with a rolling bar and a little noise.
        color = texture(source, uv).rgb;
        float line = 0.5 + 0.5 * sin(uv.y * 240.0 * 6.2832);
        float roll = smoothstep(0.0, 0.08, fract(uv.y - time * 0.12)) * (1.0 - smoothstep(0.08, 0.18, fract(uv.y - time * 0.12)));
        color *= 1.0 - amount * 0.55 * line;
        color += amount * (0.07 * roll + 0.06 * (hash(uv * 512.0 + fract(time) * 37.0) - 0.5));
    } else if (k == 8) {
        // Halftone: a dot per cell, as large as the cell is bright.
        color = texture(source, uv).rgb;
        float across = mix(180.0, 45.0, amount);
        vec2 grid = vec2(across, across / aspect);
        vec2 cell = uv * grid;
        vec3 ink = texture(source, (floor(cell) + 0.5) / grid).rgb;
        float light = dot(ink, vec3(0.299, 0.587, 0.114));
        float d = length(fract(cell) - 0.5);
        float radius = sqrt(light) * 0.62;
        float spot = 1.0 - smoothstep(radius - 0.08, radius + 0.08, d);
        color = mix(color, ink * spot * 1.15, smoothstep(0.0, 0.25, amount));
    } else if (k == 9) {
        // Posterize.
        color = texture(source, uv).rgb;
        float levels = mix(12.0, 2.5, amount);
        color = mix(color, floor(color * levels + 0.5) / levels, smoothstep(0.0, 0.15, amount));
    } else if (k == 10) {
        // Rotate the hue in YIQ, up to most of the way round.
        color = texture(source, uv).rgb;
        float a = amount * 5.5;
        mat3 toYiq = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
        mat3 toRgb = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);
        vec3 yiq = toYiq * color;
        float c = cos(a);
        float s = sin(a);
        yiq.yz = vec2(yiq.y * c - yiq.z * s, yiq.y * s + yiq.z * c);
        color = toRgb * yiq;
    } else if (k == 11) {
        // Black and white.
        color = texture(source, uv).rgb;
        float light = dot(color, vec3(0.299, 0.587, 0.114));
        color = mix(color, vec3(smoothstep(0.02, 0.98, light)), amount);
    } else if (k == 12) {
        // Vignette.
        color = texture(source, uv).rgb;
        float d = length((uv - 0.5) * vec2(aspect, 1.0)) / length(vec2(aspect, 1.0) * 0.5);
        color *= 1.0 - amount * 0.95 * smoothstep(0.35, 1.0, d);
    } else {
        color = texture(source, uv).rgb;
    }

    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0) * qt_Opacity;
}
