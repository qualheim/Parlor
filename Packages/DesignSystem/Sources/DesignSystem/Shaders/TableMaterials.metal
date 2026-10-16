// TableMaterials.metal — procedural table-surface shaders for the DesignSystem themes (R-DS-2.1).
//
// These are Metal `[[ stitchable ]]` color effects consumed through SwiftUI's shader APIs
// (`ShaderLibrary` / `View.colorEffect`), per ADR 0001 §3 and design.md §6/§7: felt fiber + vignette,
// wood grain + sheen, and a flat matte — all *procedural*, no bitmap textures. Each function takes the
// pixel `position`, the layer `color` SwiftUI provides, the surface `size`, the theme's `base`/`accent`
// colors, and the normalized material parameters (grain scale/strength, sheen, vignette) that come
// straight from `MaterialParameters` (`TableTheme.swift`). The Swift/SwiftUI bridge in
// `TableTheme+SwiftUI.swift` binds these arguments and falls back to a procedural SwiftUI gradient when a
// compiled shader library is unavailable (e.g. headless previews), so the themes always render.
//
// NOTE ON BUILD: this file is shipped as a *source resource* (copied, not compiled by SwiftPM, which
// cannot reliably build .metal files headless). The host app compiles it into its default Metal library;
// `ShaderLibrary.default` then resolves these functions by name. See `TableTheme+SwiftUI.swift`.

#include <metal_stdlib>
using namespace metal;

namespace parlor {

// A cheap 2D hash → [0,1). Used to seed value noise; deterministic per position.
static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

// Value noise in [0,1], bilinearly interpolated from hashed lattice corners.
static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);  // smoothstep weights
    float a = hash21(i + float2(0.0, 0.0));
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Two-octave fractal noise for a woven-fiber / grain feel.
static inline float fbm(float2 p) {
    float n = valueNoise(p) * 0.65;
    n += valueNoise(p * 2.03 + 11.7) * 0.35;
    return n;
}

// Radial vignette factor in [0,1]: 1 at center, darkening toward the edges by `depth`.
static inline float vignetteFactor(float2 position, float2 size, float depth) {
    float2 uv = position / max(size, float2(1.0));
    float2 c = uv - 0.5;
    float d = length(c) * 1.41421356;  // 0 at center, ~1 at corners
    return 1.0 - depth * smoothstep(0.2, 1.0, d);
}

} // namespace parlor

// MARK: - Felt: woven fiber + vignette (Classic Felt, Midnight)

[[ stitchable ]]
half4 parlorFelt(float2 position,
                 half4 color,
                 float2 size,
                 half4 base,
                 half4 accent,
                 float grainScale,
                 float grainStrength,
                 float sheenStrength,
                 float vignette) {
    float2 uv = position / max(size, float2(1.0));
    // Fine crosshatched fiber: blend two anisotropic noise samples.
    float warp = parlor::fbm(uv * grainScale);
    float weft = parlor::fbm(uv.yx * grainScale * 1.13 + 7.0);
    float fiber = (warp + weft) * 0.5;
    half3 rgb = mix(base.rgb, accent.rgb, half(fiber * grainStrength));
    // A soft directional sheen across the felt.
    float sheen = sheenStrength * smoothstep(0.0, 1.0, uv.x + uv.y) * 0.5;
    rgb += half3(sheen);
    // Vignette toward the rail.
    float v = parlor::vignetteFactor(position, size, vignette);
    rgb *= half(v);
    return half4(rgb, color.a) * color.a;
}

// MARK: - Wood: procedural grain + directional sheen (Walnut Parlor)

[[ stitchable ]]
half4 parlorWood(float2 position,
                 half4 color,
                 float2 size,
                 half4 base,
                 half4 accent,
                 float grainScale,
                 float grainStrength,
                 float sheenStrength,
                 float vignette) {
    float2 uv = position / max(size, float2(1.0));
    // Wood rings: low-frequency ripple along one axis, perturbed by noise for organic grain lines.
    float ripple = uv.y * grainScale + parlor::fbm(uv * (grainScale * 0.25)) * 6.0;
    float grain = 0.5 + 0.5 * sin(ripple);
    grain = pow(grain, 2.2);  // sharpen into distinct grain lines
    half3 rgb = mix(base.rgb, accent.rgb, half(grain * grainStrength));
    // Polished sheen: a bright band that sweeps across the surface.
    float band = smoothstep(0.35, 0.5, uv.x) * (1.0 - smoothstep(0.5, 0.65, uv.x));
    rgb += half3(half(band * sheenStrength));
    float v = parlor::vignetteFactor(position, size, vignette);
    rgb *= half(v);
    return half4(rgb, color.a) * color.a;
}

// MARK: - Matte: near-flat surface, whisper of fiber (Minimal)

[[ stitchable ]]
half4 parlorMatte(float2 position,
                  half4 color,
                  float2 size,
                  half4 base,
                  half4 accent,
                  float grainScale,
                  float grainStrength,
                  float sheenStrength,
                  float vignette) {
    float2 uv = position / max(size, float2(1.0));
    float n = parlor::valueNoise(uv * grainScale);
    half3 rgb = mix(base.rgb, accent.rgb, half(n * grainStrength));
    float v = parlor::vignetteFactor(position, size, vignette);
    rgb *= half(v);
    return half4(rgb, color.a) * color.a;
}
