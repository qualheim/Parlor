// Tokens — type, spacing, radius, shadow, and motion design tokens (R-DS-1.1).
//
// These are the non-color halves of the design-system token set. Like the color layer, every value is a
// named *semantic* token, not a magic number sprinkled at call sites: a view asks for `Spacing.md` or
// `Typography.title`, never a bare `16`. All tokens are pure, `Sendable` values so they are usable off the
// main actor and directly in tests. SwiftUI bridges (Font, ShapeStyle-friendly numbers) live in
// `DesignTokens+SwiftUI.swift`.
//
// Motion tokens honor the ux-guidelines timing (default table motion is 150–350 ms springs; task 5.5
// wires the animation queue). Reduce-Motion substitution is a queue concern; these tokens just name the
// canonical durations/springs so the queue and any ad-hoc animation share one source of truth.

import Foundation

// MARK: - Typography

/// A semantic type token: a size, weight, and whether it counts as "large text" for WCAG contrast.
///
/// `isLargeText` follows the WCAG definition (≥ 18 pt, or ≥ 14 pt bold) and lets a caller pick the right
/// `ContrastUsage` automatically when validating a text/background pairing.
public struct TypeToken: Sendable, Hashable {
    public let size: Double
    public let weight: FontWeightToken
    public let lineHeightMultiple: Double

    public init(size: Double, weight: FontWeightToken, lineHeightMultiple: Double = 1.2) {
        self.size = size
        self.weight = weight
        self.lineHeightMultiple = lineHeightMultiple
    }

    /// True when this token qualifies as WCAG "large text" (≥ 18 pt, or ≥ 14 pt bold).
    public var isLargeText: Bool {
        size >= 18 || (size >= 14 && weight.isBoldOrHeavier)
    }

    /// The contrast usage implied by this text token's size/weight.
    public var contrastUsage: ContrastUsage { isLargeText ? .largeText : .normalText }
}

/// Semantic font weights (mapped to SwiftUI `Font.Weight` in the SwiftUI bridge).
public enum FontWeightToken: String, Sendable, Hashable, CaseIterable, Codable {
    case regular
    case medium
    case semibold
    case bold

    var isBoldOrHeavier: Bool { self == .bold }
}

/// The type ramp — named roles from large titles down to captions (R-DS-1.1).
public enum Typography {
    public static let largeTitle = TypeToken(size: 34, weight: .bold, lineHeightMultiple: 1.15)
    public static let title = TypeToken(size: 28, weight: .semibold, lineHeightMultiple: 1.15)
    public static let title2 = TypeToken(size: 22, weight: .semibold, lineHeightMultiple: 1.2)
    public static let headline = TypeToken(size: 17, weight: .semibold, lineHeightMultiple: 1.2)
    public static let body = TypeToken(size: 15, weight: .regular, lineHeightMultiple: 1.3)
    public static let callout = TypeToken(size: 14, weight: .regular, lineHeightMultiple: 1.3)
    public static let caption = TypeToken(size: 12, weight: .regular, lineHeightMultiple: 1.25)

    /// All type tokens (for iteration / snapshotting).
    public static let all: [TypeToken] = [
        largeTitle, title, title2, headline, body, callout, caption,
    ]
}

// MARK: - Spacing

/// The spacing scale — a small geometric-ish ramp in points (R-DS-1.1). Views use these instead of raw
/// numbers so padding/gaps stay consistent and tunable in one place.
public enum Spacing {
    /// 2 pt — hairline gaps.
    public static let xxs: Double = 2
    /// 4 pt.
    public static let xs: Double = 4
    /// 8 pt.
    public static let sm: Double = 8
    /// 12 pt.
    public static let md: Double = 12
    /// 16 pt.
    public static let lg: Double = 16
    /// 24 pt.
    public static let xl: Double = 24
    /// 32 pt.
    public static let xxl: Double = 32
    /// 48 pt — section-level separation.
    public static let xxxl: Double = 48

    /// The full ramp in ascending order.
    public static let ramp: [Double] = [xxs, xs, sm, md, lg, xl, xxl, xxxl]
}

// MARK: - Radius

/// The corner-radius scale in points (R-DS-1.1).
public enum Radius {
    /// 0 pt — square.
    public static let none: Double = 0
    /// 4 pt — small controls.
    public static let sm: Double = 4
    /// 8 pt — default control/card radius.
    public static let md: Double = 8
    /// 12 pt.
    public static let lg: Double = 12
    /// 20 pt — large surfaces / sheets.
    public static let xl: Double = 20
    /// A very large radius standing in for "fully rounded" (pill/capsule).
    public static let pill: Double = 999

    public static let ramp: [Double] = [none, sm, md, lg, xl]
}

// MARK: - Shadow

/// A semantic elevation shadow: color-agnostic geometry plus an opacity (R-DS-1.1). The color a shadow is
/// tinted with still comes from a semantic token at the call site; the shadow token only carries blur,
/// offset, and opacity so elevation reads consistently.
public struct ShadowToken: Sendable, Hashable {
    public let radius: Double
    public let offsetX: Double
    public let offsetY: Double
    public let opacity: Double

    public init(radius: Double, offsetX: Double = 0, offsetY: Double, opacity: Double) {
        self.radius = radius
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.opacity = opacity
    }
}

/// Named elevation levels (R-DS-1.1).
public enum Elevation {
    /// No shadow.
    public static let none = ShadowToken(radius: 0, offsetY: 0, opacity: 0)
    /// A resting card/control.
    public static let low = ShadowToken(radius: 3, offsetY: 1, opacity: 0.18)
    /// A raised surface (popover, elevated card).
    public static let medium = ShadowToken(radius: 8, offsetY: 3, opacity: 0.22)
    /// A floating surface (sheet, dragged piece).
    public static let high = ShadowToken(radius: 18, offsetY: 8, opacity: 0.28)

    public static let all: [ShadowToken] = [none, low, medium, high]
}

// MARK: - Motion

/// A motion token: a duration plus a spring description, used by ad-hoc animation and the animation queue
/// (task 5.5). Durations sit in the ux-guidelines 150–350 ms band for table motion (R-DS-1.1).
public struct MotionToken: Sendable, Hashable {
    /// Duration in seconds.
    public let duration: Double
    /// Spring response (seconds); mirrors SwiftUI's `Spring(response:dampingFraction:)`.
    public let response: Double
    /// Spring damping fraction, 0...1.
    public let dampingFraction: Double

    public init(duration: Double, response: Double, dampingFraction: Double) {
        self.duration = duration
        self.response = response
        self.dampingFraction = dampingFraction
    }
}

/// Named motion tokens (R-DS-1.1). The default table durations live in the 150–350 ms band; `instant` is
/// the Reduce-Motion / "Instant" speed setting's near-zero duration (the queue swaps to crossfades then —
/// task 5.5).
public enum Motion {
    /// Near-instant (used by the "Instant" speed setting and Reduce Motion crossfades).
    public static let instant = MotionToken(duration: 0.001, response: 0.001, dampingFraction: 1)
    /// A quick UI transition (~150 ms).
    public static let quick = MotionToken(duration: 0.15, response: 0.22, dampingFraction: 0.9)
    /// The standard table move/flip (~250 ms).
    public static let standard = MotionToken(duration: 0.25, response: 0.32, dampingFraction: 0.82)
    /// A relaxed, followable motion (~350 ms).
    public static let relaxed = MotionToken(duration: 0.35, response: 0.45, dampingFraction: 0.8)

    public static let all: [MotionToken] = [instant, quick, standard, relaxed]

    /// The inclusive default-duration band for table motion, in seconds (ux-guidelines; R-TABLE-5.3).
    public static let defaultBand: ClosedRange<Double> = 0.15...0.35
}
