#version 440
// One slot of a composition (Compositor.qml): `source`, a picture, cropped or
// fitted into the slot by the uv transform and cut to the slot's mask. Every
// length is a share of the slot's shorter side, so a small monitor and the
// projection cut the same shape.
//
// shape: 0 rectangle, 1 rounded rectangle (`radius`), 2 the ellipse fitted to
// the slot, 3 a drawn curve (`maskSource`'s alpha). `feather` softens the edge
// inwards; at 0 the edge is only antialiased.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float shape;
    float radius;   // share of min(w, h)
    float feather;  // share of min(w, h)
    float aspect;   // the slot's width / height, in pixels
    vec2 uvScale;   // the picture's uv = (slot uv - 0.5) * uvScale + 0.5
};
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D maskSource;

float roundedBox(vec2 p, vec2 half_, float r)
{
    vec2 q = abs(p) - half_ + vec2(r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// An approximate distance to an ellipse (Inigo Quilez's first-order one):
// right at the edge, which is all the feather needs.
float ellipse(vec2 p, vec2 half_)
{
    float k0 = length(p / half_);
    float k1 = length(p / (half_ * half_));
    return k1 > 0.0 ? k0 * (k0 - 1.0) / k1 : -min(half_.x, half_.y);
}

// The drawn curve's coverage, blurred over a disc `r` (in slot uv) wide: taps
// on two rings, read a few mipmap levels down (the mask is about the slot's
// size on screen), where its texels are about as far apart as the taps, so
// they blend into one smooth falloff. (A bias, not an explicit level: GLSL ES
// 100 has neither textureSize nor textureLod.)
float curve(vec2 uv, vec2 r)
{
    vec2 pixel = max(fwidth(uv), vec2(1e-5));
    float bias = max(0.0, log2(max(r.x / pixel.x, r.y / pixel.y) * 0.5));
    float sum = texture(maskSource, uv, bias).a;
    for (int i = 0; i < 8; ++i) {
        float a = float(i) * 0.785398;
        sum += texture(maskSource, uv + vec2(cos(a), sin(a)) * r * 0.5, bias).a;
    }
    for (int i = 0; i < 12; ++i) {
        float a = float(i) * 0.523599 + 0.261799;
        sum += texture(maskSource, uv + vec2(cos(a), sin(a)) * r, bias).a;
    }
    return sum / 21.0;
}

void main()
{
    vec2 uv = qt_TexCoord0;
    // The slot in units of its shorter side, centred.
    vec2 size = aspect >= 1.0 ? vec2(aspect, 1.0) : vec2(1.0, 1.0 / max(aspect, 0.0001));
    vec2 p = (uv - 0.5) * size;
    vec2 half_ = size * 0.5;

    float alpha;
    if (shape > 2.5) {
        if (feather > 0.0) {
            // The blur crosses the edge at one half: keep its inner half,
            // so the softening runs inwards like the other shapes'.
            float c = curve(uv, vec2(2.0 * feather) / size);
            alpha = smoothstep(0.5, 1.0, c);
        } else {
            alpha = texture(maskSource, uv).a;
        }
    } else {
        float d;
        if (shape > 1.5)
            d = ellipse(p, half_);
        else if (shape > 0.5)
            d = roundedBox(p, half_, clamp(radius, 0.0, min(half_.x, half_.y)));
        else
            d = roundedBox(p, half_, 0.0);
        float edge = max(feather, fwidth(d));
        alpha = 1.0 - smoothstep(-edge, 0.0, d);
    }

    vec2 suv = (uv - 0.5) * uvScale + 0.5;
    // Outside the picture (a fitted one's bands): nothing.
    vec2 inside = step(vec2(0.0), suv) * step(suv, vec2(1.0));
    fragColor = texture(source, suv) * (alpha * inside.x * inside.y * qt_Opacity);
}
