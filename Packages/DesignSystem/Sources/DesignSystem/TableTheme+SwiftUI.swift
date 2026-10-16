// TableTheme+SwiftUI — the SwiftUI/Metal bridge that renders a procedural table surface (R-DS-2.1).
//
// The theme *values* are pure (see `TableTheme.swift`); this file is the UI-only adapter that turns a
// theme into a rendered playing surface. Per ADR 0001 §3 and design.md §6, table materials — felt
// fiber/vignette, wood grain, sheen — are drawn by Metal shaders through SwiftUI's shader APIs, NOT by
// large bitmaps (R-DS-2.1). The `.metal` source ships with DesignSystem (`Shaders/TableMaterials.metal`)
// and is compiled into the host app's default Metal library; `ShaderLibrary.default` resolves the
// stitchable functions there.
//
// GRACEFUL FALLBACK: when a compiled shader library is unavailable (SwiftUI previews, a headless build,
// or a platform without the app's default library), the surface still renders — as a *procedural*
// SwiftUI gradient + vignette derived from the same `MaterialParameters`. So a theme always paints,
// never a blank rectangle, and the fallback is itself procedural (no bitmaps), honoring R-DS-2.1.
//
// APPEARANCE INDEPENDENCE: every color here comes from the theme's own `MaterialParameters` /
// `shadowInk`, never from the environment color scheme, so the surface looks identical under the system
// light/dark setting (R-DS-2.2). The bridge exposes no `@Environment(\.colorScheme)` at all.

import SwiftUI

// MARK: - Material → shader name

extension TableMaterial {
    /// The stitchable shader function name in `TableMaterials.metal` for this material family.
    public var shaderFunctionName: String {
        switch self {
        case .felt: return "parlorFelt"
        case .wood: return "parlorWood"
        case .matte: return "parlorMatte"
        }
    }
}

// MARK: - The table surface view

/// A procedural table surface for a `TableTheme` (R-DS-2.1, R-DS-2.2).
///
/// Renders the theme's material via its Metal shader when available, otherwise a procedural gradient
/// fallback built from the same parameters. Always fills the space it is given; place it full-bleed
/// behind the table. Independent of system appearance (R-DS-2.2).
public struct TableSurface: View {
    private let theme: TableTheme
    /// Whether to attempt the Metal shader. Tests / previews can force the fallback.
    private let useShader: Bool

    public init(theme: TableTheme, useShader: Bool = true) {
        self.theme = theme
        self.useShader = useShader
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            fallbackSurface(size: size)
                .modifier(
                    MaterialShaderModifier(
                        theme: theme,
                        size: size,
                        enabled: useShader
                    )
                )
        }
        // The surface owns its own colors; never inherit the system light/dark scheme (R-DS-2.2).
        .drawingGroup(opaque: true)
    }

    /// The procedural (shader-free) surface: a diagonal gradient between base and a fiber-shifted accent,
    /// with a radial vignette. Used as the base layer and as the standalone fallback (R-DS-2.1).
    @ViewBuilder
    private func fallbackSurface(size: CGSize) -> some View {
        let p = theme.parameters
        ZStack {
            LinearGradient(
                colors: [
                    p.base.swiftUIColor,
                    p.base.blended(toward: p.accent, amount: p.grainStrength * 0.5).swiftUIColor,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Vignette toward the rail.
            RadialGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(p.vignette),
                ],
                center: .center,
                startRadius: min(size.width, size.height) * 0.25,
                endRadius: max(size.width, size.height) * 0.75
            )
        }
    }
}

/// Applies the material's Metal `colorEffect` shader on top of the fallback surface, when enabled.
///
/// A separate `ViewModifier` keeps the shader-argument plumbing in one place. When `enabled` is false the
/// modifier is a no-op, so the procedural fallback shows through.
private struct MaterialShaderModifier: ViewModifier {
    let theme: TableTheme
    let size: CGSize
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            let p = theme.parameters
            let shader = MaterialShaderModifier.library[
                dynamicMember: theme.material.shaderFunctionName](
                    .float2(Float(size.width), Float(size.height)),
                    .color(p.base.swiftUIColor),
                    .color(p.accent.swiftUIColor),
                    .float(Float(p.grainScale)),
                    .float(Float(p.grainStrength)),
                    .float(Float(p.sheenStrength)),
                    .float(Float(p.vignette))
                )
            content.colorEffect(shader)
        } else {
            content
        }
    }

    /// The Metal library holding the stitchable table-material functions.
    ///
    /// `ShaderLibrary.default` resolves against the *running app's* default Metal library, into which the
    /// host app compiles `Shaders/TableMaterials.metal` (shipped as source in DesignSystem's resource
    /// bundle; ADR 0001 §3). If a compiled `.metallib` is ever bundled with DesignSystem itself, switch
    /// this to `ShaderLibrary(bundle: .module)`. When neither resolves the named function (e.g. a
    /// headless preview), `TableSurface`'s procedural gradient fallback shows through unchanged.
    static let library: ShaderLibrary = .default
}

// MARK: - Height-scaled shadow application

extension View {
    /// Cast a height-scaled table shadow for a card lifted `lift` points off the surface, tinted with the
    /// theme's `shadowInk` (R-TABLE-1.3; ux-guidelines). At rest the shadow is tight; as the card lifts,
    /// it blurs wider, drops further, and reads more strongly — the cue that the card is off the table.
    public func liftShadow(
        _ lift: Double,
        theme: TableTheme,
        scale: LiftShadow = .table
    ) -> some View {
        let token = scale.shadow(atLift: lift)
        return shadow(
            color: theme.shadowInk.swiftUIColor.opacity(token.opacity),
            radius: token.radius,
            x: token.offsetX,
            y: token.offsetY
        )
    }
}

// MARK: - Environment plumbing

/// The environment key carrying the current table theme. Defaults to Classic Felt, independent of the
/// system appearance (R-DS-2.2).
private struct TableThemeKey: EnvironmentKey {
    static let defaultValue: TableTheme = .default
}

extension EnvironmentValues {
    /// The current table theme. The app sets this explicitly; it never derives from the system light/dark
    /// setting (R-DS-2.2). The renderer reads it to paint the surface and tint height-scaled shadows.
    public var tableTheme: TableTheme {
        get { self[TableThemeKey.self] }
        set { self[TableThemeKey.self] = newValue }
    }
}

extension View {
    /// Inject a table theme into the environment for this subtree (runtime-switchable — task 5.4).
    public func tableTheme(_ theme: TableTheme) -> some View {
        environment(\.tableTheme, theme)
    }
}
