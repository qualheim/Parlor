// AccessibilityWiring — maps the stored `AppSettings` groups onto the runtime accessibility values the
// packages consume (R-A11Y-4.1, R-A11Y-3.1, R-TABLE-5.1).
//
// NOTE ON BUILD: like all of App/Sources, this file is compiled by the XcodeGen-generated Xcode project,
// NOT by SwiftPM (design.md §1). It bridges Persistence's framework-independent settings enums to the
// DesignSystem / TableKit runtime types, which Persistence itself cannot import (dependency direction —
// R-BUILD-1.3). Every mapping the packages expect lives here in one place.
//
// The heart of the accessibility story is the FOLD: the OS exposes Reduce Motion / Reduce Transparency /
// Increase Contrast, read in SwiftUI via `@Environment`; the app adds its own overrides in
// `AppSettings.accessibility`. `EffectiveAccessibility.resolve(...)` (a pure DesignSystem function) folds
// the two into the effective flags the views actually consume. The SwiftUI shell reads the environment
// flags and calls `AppSettings.effectiveAccessibility(...)` below, then hands the result to the render
// model, the card appearance, the deck-style selection, and the reduce-transparency environment.

import DesignSystem
import Persistence
import SwiftUI
import TableKit

// MARK: - Animation speed (Persistence → TableKit)

extension AnimationSpeedSetting {
    /// The TableKit animation speed this stored setting maps onto (R-TABLE-5.1). One-to-one by case.
    var tableKitSpeed: AnimationSpeed {
        switch self {
        case .relaxed: return .relaxed
        case .normal: return .normal
        case .fast: return .fast
        case .instant: return .instant
        }
    }
}

// MARK: - Card size (Persistence → DesignSystem)

extension CardSize {
    /// The DesignSystem card-size scale this stored setting maps onto (R-A11Y-4.1). Raw values match
    /// (`S`/`M`/`L`/`XL`), so the mapping is a total, order-preserving 1:1 by case.
    var scale: CardSizeScale {
        switch self {
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .extraLarge: return .extraLarge
        }
    }
}

// MARK: - The effective accessibility fold (OS + overrides → effective flags)

extension AppSettings {
    /// Fold the OS accessibility environment flags together with this app's stored overrides into the
    /// effective flags the views consume (R-A11Y-4.1, R-A11Y-3.1). The SwiftUI shell supplies the OS
    /// flags from `@Environment`; the overrides come from `accessibility`.
    ///
    /// - Parameters:
    ///   - osReduceMotion:       `@Environment(\.accessibilityReduceMotion)`.
    ///   - osReduceTransparency: `@Environment(\.accessibilityReduceTransparency)`.
    ///   - osIncreaseContrast:   `@Environment(\.colorSchemeContrast) == .increased`.
    func effectiveAccessibility(
        osReduceMotion: Bool,
        osReduceTransparency: Bool,
        osIncreaseContrast: Bool
    ) -> EffectiveAccessibility {
        EffectiveAccessibility.resolve(
            osReduceMotion: osReduceMotion,
            osIncreaseContrast: osIncreaseContrast,
            osReduceTransparency: osReduceTransparency,
            forceReduceMotion: accessibility.forceReduceMotion,
            highContrastCards: accessibility.highContrastCards,
            fourColorDeck: accessibility.fourColorDeck)
    }
}

// MARK: - Effective → runtime selections

extension EffectiveAccessibility {
    /// The card appearance to draw faces in: high-contrast when contrast is increased, else standard
    /// (R-A11Y-4.1). Feeds `CardView`'s `.cardAppearance` environment (a distinct cached face).
    var cardAppearance: CardAppearance {
        increaseContrast ? .highContrast : .standard
    }

    /// The deck style to select given the four-color override, falling back to the user's chosen style
    /// otherwise (R-A11Y-3.1). Suit SHAPES are always present regardless of the style.
    func deckStyle(preferred: DeckStyle) -> DeckStyle {
        fourColorDeck ? .fourColor : preferred
    }
}
