// EffectiveAccessibility — the pure fold of OS accessibility settings + app-level overrides into the
// effective flags the views actually consume (R-A11Y-4.1, R-A11Y-3.1).
//
// The OS exposes three accessibility switches the app must respect — Reduce Motion, Reduce Transparency,
// and Increase Contrast (R-A11Y-4.1) — read in SwiftUI via `@Environment(\.accessibilityReduceMotion)`,
// `@Environment(\.accessibilityReduceTransparency)`, and the color-scheme contrast environment. On TOP of
// those, the app offers its own explicit overrides (Persistence `AccessibilitySettings`): force reduced
// motion, high-contrast cards, and a four-color deck (R-APP-5.1).
//
// This type is the SINGLE, PURE place those two sources are folded together into the effective values the
// renderer reads. Keeping it Foundation-only (no SwiftUI, no Persistence) means every rule — "OS OR
// override" for motion, "OS OR override" for contrast, "OS only" for transparency, and the four-color
// deck selection — is unit-testable headless. The SwiftUI layer reads the `@Environment` flags and the
// app reads its stored overrides; both feed primitive `Bool`s in here, and the views consume the result.
//
// Why primitives in, not the Persistence `AccessibilitySettings` type: DesignSystem is a leaf of the UI
// layer and depends on neither Persistence nor SwiftUI (Package.swift; design.md §1). Taking plain `Bool`s
// keeps the fold at the bottom of the graph where TableKit and the App can both reach it, and keeps the
// rule table free of any framework coupling.

import Foundation

/// The effective accessibility flags the renderer consumes, folded from the OS settings and the app-level
/// overrides (R-A11Y-4.1). A pure value: given the same inputs it always yields the same effective flags.
public struct EffectiveAccessibility: Sendable, Hashable {
    /// Whether motion should be reduced: crossfades instead of slides, and no parallax/particles
    /// (R-TABLE-5.3). True when EITHER the OS Reduce Motion setting is on OR the app override forces it.
    public let reduceMotion: Bool

    /// Whether contrast should be increased: card faces use the high-contrast variant (R-A11Y-4.1). True
    /// when EITHER the OS Increase Contrast setting is on OR the app's high-contrast-cards override is on.
    public let increaseContrast: Bool

    /// Whether transparency should be reduced: translucent materials/blur fall back to opaque fills
    /// (R-A11Y-4.1). Driven by the OS setting ONLY — the app exposes no override for it.
    public let reduceTransparency: Bool

    /// Whether the four-color suit deck is selected for color independence (R-A11Y-3.1). Driven by the
    /// app override ONLY (the OS has no equivalent switch); suit SHAPES are always present regardless.
    public let fourColorDeck: Bool

    public init(
        reduceMotion: Bool,
        increaseContrast: Bool,
        reduceTransparency: Bool,
        fourColorDeck: Bool
    ) {
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        self.reduceTransparency = reduceTransparency
        self.fourColorDeck = fourColorDeck
    }

    /// The all-off default (no OS settings on, no overrides) — the plain, full-motion, translucent,
    /// standard-contrast, two-color baseline.
    public static let standard = EffectiveAccessibility(
        reduceMotion: false, increaseContrast: false, reduceTransparency: false,
        fourColorDeck: false)

    /// Fold the OS accessibility settings and the app-level overrides into the effective flags
    /// (R-A11Y-4.1, R-A11Y-3.1). This is the whole rule table, in one pure function:
    ///
    ///   • Reduce Motion       — effective when the OS setting is on OR the app forces it (`forceReduceMotion`).
    ///   • Increase Contrast   — effective when the OS setting is on OR the app's `highContrastCards` is on.
    ///   • Reduce Transparency — effective when the OS setting is on (no app override).
    ///   • Four-Color deck     — effective when the app's `fourColorDeck` override is on (no OS switch).
    ///
    /// - Parameters:
    ///   - osReduceMotion:        the OS `accessibilityReduceMotion` flag.
    ///   - osIncreaseContrast:    the OS Increase Contrast flag (SwiftUI's `colorSchemeContrast == .increased`).
    ///   - osReduceTransparency:  the OS `accessibilityReduceTransparency` flag.
    ///   - forceReduceMotion:     the app override forcing reduced motion (`AccessibilitySettings.forceReduceMotion`).
    ///   - highContrastCards:     the app override for high-contrast card faces (`AccessibilitySettings.highContrastCards`).
    ///   - fourColorDeck:         the app override selecting the four-color deck (`AccessibilitySettings.fourColorDeck`).
    public static func resolve(
        osReduceMotion: Bool,
        osIncreaseContrast: Bool,
        osReduceTransparency: Bool,
        forceReduceMotion: Bool,
        highContrastCards: Bool,
        fourColorDeck: Bool
    ) -> EffectiveAccessibility {
        EffectiveAccessibility(
            reduceMotion: osReduceMotion || forceReduceMotion,
            increaseContrast: osIncreaseContrast || highContrastCards,
            reduceTransparency: osReduceTransparency,
            fourColorDeck: fourColorDeck)
    }
}
