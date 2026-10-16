// CardSizeScale — the pure S / M / L / XL card-size scale the renderer multiplies card dimensions by
// (R-A11Y-4.1, R-APP-5.1).
//
// The app offers a card-size setting of Small / Medium / Large / Extra Large (R-A11Y-4.1), stored in
// Persistence as `AppearanceSettings.cardSize`. That setting has to turn into a CONCRETE size the renderer
// uses: this type is that mapping. Each case carries a scale multiplier applied to the base card size the
// `LayoutResolver` derives from the table size, so choosing a larger size enlarges every card uniformly
// (and keeps the spread proportional) with no per-game code.
//
// The multipliers are MONOTONIC — `small < medium < large < extraLarge` — with Medium at 1.0 (the base
// size), so the resolver's existing proportions are unchanged at the default. Kept as a pure, Foundation-
// only value in DesignSystem (a leaf of the UI layer, no Persistence dependency — design.md §1): the App
// maps its stored `CardSize` case onto this by matching raw values, so the mapping is testable headless
// and lives at the bottom of the graph where TableKit can reach it.

import CoreGraphics
import Foundation

/// The card-size accessibility scale — S / M / L / XL — as a multiplier on the base card dimensions
/// (R-A11Y-4.1). Pure and monotonic; Medium is the 1.0 baseline the `LayoutResolver` already produces.
public enum CardSizeScale: String, Sendable, Hashable, CaseIterable, Codable {
    case small = "S"
    case medium = "M"
    case large = "L"
    case extraLarge = "XL"

    /// The scale multiplier applied to the base card size. Monotonically increasing across the cases so a
    /// larger setting always yields a larger card; Medium is the 1.0 baseline (unchanged default layout).
    public var multiplier: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        case .large: return 1.2
        case .extraLarge: return 1.45
        }
    }

    /// The default card size — Medium (the 1.0 baseline).
    public static let `default`: CardSizeScale = .medium
}
