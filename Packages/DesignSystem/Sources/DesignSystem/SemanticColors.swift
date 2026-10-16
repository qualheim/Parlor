// SemanticColors — the semantic color token layer for chrome (R-DS-1.1, R-DS-1.2).
//
// This is the single source of color for the app's chrome. Consumers NEVER name a raw color; they name a
// semantic *role* (`ColorRole`) — `.textPrimary`, `.accent`, `.surface`, `.focusRing`, … — and resolve it
// through a `SemanticColors` palette. That indirection is what "color comes only from semantic tokens"
// means (R-DS-1.2): swap the palette (light ↔ dark) and every surface, label, and control recolors with
// no call-site changes.
//
// Two chrome palettes ship: `.light` and `.dark` (R-DS-1.1). They are *chrome* palettes chosen so that
// every text and essential-UI role meets WCAG 2.2 AA against the surfaces it is used on (R-DS-1.2); the
// exact foreground/background pairings that must pass are declared in `ContrastRequirement.allAA` and
// proven by the contrast test (task 5.1). Chrome palettes are independent of the *table* theme, which is
// a separate procedural-shader system (task 5.2, R-DS-2.2).

import Foundation

/// A semantic color role — the only vocabulary a chrome consumer uses to ask for color (R-DS-1.2).
///
/// Roles are grouped: text/content, surfaces/backgrounds, accents/interaction, status, and separators.
/// Adding a UI color means adding a *role* here and a value in each palette — never a raw color at a
/// call site.
public enum ColorRole: String, Sendable, Hashable, CaseIterable, Codable {
    // Text & content (drawn on surfaces).
    case textPrimary
    case textSecondary
    case textOnAccent

    // Surfaces & backgrounds (the things text and controls sit on).
    case background
    case surface
    case surfaceElevated

    // Accents & interaction.
    case accent
    case accentPressed
    case focusRing

    // Status (semantic feedback).
    case success
    case warning
    case danger

    // Separators & essential non-text UI.
    case separator
    case controlBorder
}

/// A resolved palette: every `ColorRole` mapped to a concrete `TokenColor` for one chrome appearance.
///
/// A palette is a pure value; `.light` and `.dark` are the two built-in chrome palettes (R-DS-1.1). The
/// appearance is chosen explicitly by the app, not inferred from the system, keeping chrome independent
/// of system appearance where the app decides to (R-DS-2.2).
public struct SemanticColors: Sendable, Hashable {
    private let values: [ColorRole: TokenColor]

    /// Which built-in chrome appearance this palette represents.
    public let appearance: Appearance

    /// A chrome appearance.
    public enum Appearance: String, Sendable, Hashable, CaseIterable, Codable {
        case light
        case dark
    }

    /// Create a palette from a complete role→color mapping. Every `ColorRole` must be present.
    public init(appearance: Appearance, values: [ColorRole: TokenColor]) {
        precondition(
            Set(values.keys) == Set(ColorRole.allCases),
            "A SemanticColors palette must define every ColorRole exactly once."
        )
        self.appearance = appearance
        self.values = values
    }

    /// Resolve a role to its color in this palette.
    public func callAsFunction(_ role: ColorRole) -> TokenColor { values[role]! }

    /// Resolve a role to its color in this palette.
    public func color(_ role: ColorRole) -> TokenColor { values[role]! }
}

// MARK: - Built-in chrome palettes

extension SemanticColors {
    /// The light chrome palette (R-DS-1.1). Values chosen so all text/essential-UI roles meet WCAG 2.2
    /// AA on the surfaces they appear on (proven by the contrast test — see `ContrastRequirement.allAA`).
    public static let light = SemanticColors(
        appearance: .light,
        values: [
            // Text on light surfaces — near-black / dark grey for strong contrast.
            .textPrimary: TokenColor(hex: 0x1A1C1E),  // ~15.9:1 on background
            .textSecondary: TokenColor(hex: 0x44474A),  // ~8.9:1 on background
            .textOnAccent: TokenColor(hex: 0xFFFFFF),  // white on accent
            // Surfaces.
            .background: TokenColor(hex: 0xF7F8FA),
            .surface: TokenColor(hex: 0xFFFFFF),
            .surfaceElevated: TokenColor(hex: 0xFFFFFF),
            // Accent & interaction — a deep parlor green; white text sits on it.
            .accent: TokenColor(hex: 0x00695C),  // teal-green, ~5.0:1 vs white
            .accentPressed: TokenColor(hex: 0x004D40),
            .focusRing: TokenColor(hex: 0x005BBB),  // strong blue focus, ≥3:1 on light surfaces
            // Status.
            .success: TokenColor(hex: 0x1B6B33),
            .warning: TokenColor(hex: 0x8A5000),
            .danger: TokenColor(hex: 0xB3261E),
            // Separators & control borders — essential non-text UI (≥3:1 vs surface).
            .separator: TokenColor(hex: 0x6E7276),
            .controlBorder: TokenColor(hex: 0x5E6266),
        ]
    )

    /// The dark chrome palette (R-DS-1.1). Values chosen so all text/essential-UI roles meet WCAG 2.2 AA
    /// on the surfaces they appear on.
    public static let dark = SemanticColors(
        appearance: .dark,
        values: [
            // Text on dark surfaces — near-white / light grey.
            .textPrimary: TokenColor(hex: 0xE6E8EA),  // ~14:1 on background
            .textSecondary: TokenColor(hex: 0xB4B8BC),  // ~8:1 on background
            .textOnAccent: TokenColor(hex: 0x04211E),  // dark ink on the light-mint accent
            // Surfaces.
            .background: TokenColor(hex: 0x121316),
            .surface: TokenColor(hex: 0x1D1F23),
            .surfaceElevated: TokenColor(hex: 0x272A2F),
            // Accent & interaction — a light mint so text-on-accent stays legible.
            .accent: TokenColor(hex: 0x5FD3BE),  // light mint; dark ink sits on it
            .accentPressed: TokenColor(hex: 0x8AE3D2),
            .focusRing: TokenColor(hex: 0x6FB3FF),  // bright blue focus, ≥3:1 on dark surfaces
            // Status.
            .success: TokenColor(hex: 0x6ED07F),
            .warning: TokenColor(hex: 0xF2B24A),
            .danger: TokenColor(hex: 0xF2857A),
            // Separators & control borders — essential non-text UI (≥3:1 vs surface).
            .separator: TokenColor(hex: 0x9096A0),
            .controlBorder: TokenColor(hex: 0x9A9FA8),
        ]
    )

    /// Both built-in chrome palettes.
    public static let allPalettes: [SemanticColors] = [.light, .dark]
}

// MARK: - Contrast requirements (the pairings WCAG 2.2 AA must hold for)

/// One (foreground role, background role, usage) pairing that must meet WCAG 2.2 AA in every chrome
/// palette. `ContrastRequirement.allAA` is the authoritative list the contrast test enforces (task 5.1).
public struct ContrastRequirement: Sendable, Hashable {
    public let foreground: ColorRole
    public let background: ColorRole
    public let usage: ContrastUsage

    public init(_ foreground: ColorRole, on background: ColorRole, usage: ContrastUsage) {
        self.foreground = foreground
        self.background = background
        self.usage = usage
    }

    /// Whether this requirement holds in the given palette.
    public func holds(in palette: SemanticColors) -> Bool {
        palette(foreground).meetsAA(against: palette(background), usage: usage)
    }

    /// The actual ratio in the given palette (for diagnostics).
    public func ratio(in palette: SemanticColors) -> Double {
        palette(foreground).contrastRatio(against: palette(background))
    }
}

extension ContrastRequirement {
    /// Every text and essential-UI contrast pairing that must meet WCAG 2.2 AA in both chrome palettes
    /// (R-DS-1.2). Text roles are checked at the normal-text threshold (4.5:1, the stricter bar);
    /// separators, control borders, and focus rings are essential non-text UI at 3:1 (SC 1.4.11).
    public static let allAA: [ContrastRequirement] = [
        // Primary/secondary text on each surface.
        .init(.textPrimary, on: .background, usage: .normalText),
        .init(.textPrimary, on: .surface, usage: .normalText),
        .init(.textPrimary, on: .surfaceElevated, usage: .normalText),
        .init(.textSecondary, on: .background, usage: .normalText),
        .init(.textSecondary, on: .surface, usage: .normalText),
        .init(.textSecondary, on: .surfaceElevated, usage: .normalText),
        // Text on the accent fill (e.g. a primary button label).
        .init(.textOnAccent, on: .accent, usage: .normalText),
        .init(.textOnAccent, on: .accentPressed, usage: .normalText),
        // Essential non-text UI: separators, control borders, focus rings on the surfaces they touch.
        .init(.separator, on: .background, usage: .essentialUI),
        .init(.separator, on: .surface, usage: .essentialUI),
        .init(.controlBorder, on: .surface, usage: .essentialUI),
        .init(.controlBorder, on: .surfaceElevated, usage: .essentialUI),
        .init(.focusRing, on: .background, usage: .essentialUI),
        .init(.focusRing, on: .surface, usage: .essentialUI),
        // Status colors used as text on surfaces.
        .init(.danger, on: .surface, usage: .normalText),
        .init(.success, on: .surface, usage: .normalText),
        .init(.warning, on: .surface, usage: .normalText),
    ]
}
