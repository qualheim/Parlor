// ReduceTransparency — the Reduce-Transparency fallback plumbing for translucent HUD chrome (R-A11Y-4.1).
//
// R-A11Y-4.1 requires the app to respect the OS Reduce Transparency setting. The HUD and menus use
// translucency in a few places — seat plates and the scoreboard sit on a `surfaceElevated` fill at 0.94
// opacity, the history drawer on a `surface` fill at 0.96, the toolbar on a translucent capsule, and the
// App's pause menu uses `.regularMaterial` (a blurred material). When Reduce Transparency is on, those
// translucent/blurred backdrops should fall back to OPAQUE fills so nothing shows through.
//
// This file provides two small pieces:
//   • an `@Environment(\.reduceTransparency)` flag the SwiftUI shell sets from the effective accessibility
//     fold (`EffectiveAccessibility.reduceTransparency`, itself read from the OS setting), so any view in
//     the subtree can key its backdrop off it; and
//   • an `opaqueWhenReducingTransparency(_:opaque:)` helper that returns a fully-opaque color when the flag
//     is on and the translucent color otherwise, plus a `View.reduceTransparency(_:)` injector.
//
// The DECISION ("should this backdrop be opaque?") is a plain boolean read from the effective fold, so it
// is testable headless via `EffectiveAccessibility`; this file is only the SwiftUI environment seam and
// the tiny color-selection helper the HUD views call.

import SwiftUI

// MARK: - Environment flag

private struct ReduceTransparencyKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Whether translucency/materials should fall back to opaque fills (Reduce Transparency — R-A11Y-4.1).
    ///
    /// Set by the app shell from `EffectiveAccessibility.reduceTransparency` (the OS setting). HUD chrome
    /// reads it to pick an opaque backdrop instead of a translucent one. Defaults to `false` (translucent).
    public var reduceTransparency: Bool {
        get { self[ReduceTransparencyKey.self] }
        set { self[ReduceTransparencyKey.self] = newValue }
    }
}

extension View {
    /// Inject the effective Reduce-Transparency flag for this subtree so HUD chrome can fall back to
    /// opaque fills (R-A11Y-4.1). The app derives the value from the effective accessibility fold.
    public func reduceTransparency(_ reduce: Bool) -> some View {
        environment(\.reduceTransparency, reduce)
    }
}

// MARK: - Opacity selection helper

/// Pick a backdrop opacity that respects Reduce Transparency: a full `1.0` (opaque) when transparency is
/// reduced, otherwise the requested translucent `opacity` (R-A11Y-4.1). Pure — the HUD views multiply a
/// fill color by this so a translucent plate becomes a solid one under Reduce Transparency.
///
/// - Parameters:
///   - reduce: the effective Reduce-Transparency flag.
///   - opacity: the translucent opacity to use when transparency is NOT reduced.
/// - Returns: `1.0` when `reduce` is true, else `opacity`.
public func backdropOpacity(reduceTransparency reduce: Bool, translucent opacity: Double) -> Double
{
    reduce ? 1.0 : opacity
}
