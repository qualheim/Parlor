// TokenColor — the color primitive underlying every semantic color token (R-DS-1.1, R-DS-1.2).
//
// A `TokenColor` is a plain, `Sendable` sRGB value with an alpha channel. It is deliberately NOT a
// SwiftUI `Color`: keeping the primitive a pure value type means the whole token system (palettes,
// contrast math, tests) is expressible and verifiable without importing SwiftUI, and the WCAG contrast
// proof (task 5.1) runs headless in `swift test`. A SwiftUI bridge (`swiftUIColor`) is provided for the
// UI layer; consumers of the design system only ever name a *semantic* token — never a raw color — which
// is what "color comes only from semantic tokens" means in practice (R-DS-1.2).
//
// Channel values are stored in the 0...1 range in the sRGB color space. Contrast is computed per the
// WCAG 2.x definition (relative luminance with the sRGB→linear transfer function), which WCAG 2.2 carries
// forward unchanged for the AA text/non-text contrast success criteria (1.4.3, 1.4.11).

import Foundation

/// A pure, `Sendable` sRGB color with alpha — the primitive behind every semantic token (R-DS-1.1).
///
/// This type is appearance-agnostic: light/dark chrome is expressed by choosing *which* `TokenColor` a
/// semantic token resolves to (see `SemanticColors`), not by any system-appearance lookup, so table
/// themes and chrome stay independent of the system light/dark setting (R-DS-2.2).
public struct TokenColor: Sendable, Hashable, Codable {
    /// Red channel, 0...1 in the sRGB color space.
    public let red: Double
    /// Green channel, 0...1 in the sRGB color space.
    public let green: Double
    /// Blue channel, 0...1 in the sRGB color space.
    public let blue: Double
    /// Alpha, 0...1 (1 = opaque).
    public let alpha: Double

    /// Create a color from sRGB channel values in 0...1. Values are clamped to the valid range.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = TokenColor.clamp(red)
        self.green = TokenColor.clamp(green)
        self.blue = TokenColor.clamp(blue)
        self.alpha = TokenColor.clamp(alpha)
    }

    /// Create a color from an 8-bit-per-channel hex value, e.g. `0x1B5E20`. Alpha defaults to opaque.
    public init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

// MARK: - Blending

extension TokenColor {
    /// A linear (per-channel) blend of this color toward `other` by `amount` (0 = self, 1 = `other`).
    ///
    /// `amount` is clamped to 0...1. Used by procedural material rendering to derive a fiber/grain
    /// highlight color from a theme's base + accent without introducing a new named token. Pure.
    public func blended(toward other: TokenColor, amount: Double) -> TokenColor {
        let t = TokenColor.clamp(amount)
        return TokenColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }
}

// MARK: - WCAG contrast (SC 1.4.3 text, SC 1.4.11 non-text — carried forward unchanged in WCAG 2.2)

extension TokenColor {
    /// The WCAG relative luminance of this color (0 = black, 1 = white).
    ///
    /// Uses the sRGB→linear transfer function and the Rec. 709 luma weights defined by WCAG. Alpha is
    /// ignored here; contrast between two tokens is computed on their opaque colors (chrome tokens used
    /// for text/essential UI are opaque by construction — see `SemanticColors`).
    public var relativeLuminance: Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let r = linearize(red)
        let g = linearize(green)
        let b = linearize(blue)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// The WCAG contrast ratio between this color and another, in the range 1...21.
    ///
    /// Defined as (L1 + 0.05) / (L2 + 0.05) with L1 the lighter luminance. Symmetric in its arguments.
    public func contrastRatio(against other: TokenColor) -> Double {
        let l1 = relativeLuminance
        let l2 = other.relativeLuminance
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// The kind of foreground being placed on a background, which sets the WCAG 2.2 AA threshold.
public enum ContrastUsage: Sendable, Hashable {
    /// Body / normal-weight text below the large-text size: AA requires ≥ 4.5:1 (SC 1.4.3).
    case normalText
    /// Large text (≥ 18 pt, or ≥ 14 pt bold): AA requires ≥ 3:1 (SC 1.4.3).
    case largeText
    /// Essential non-text UI (control boundaries, focus rings, icons): AA requires ≥ 3:1 (SC 1.4.11).
    case essentialUI

    /// The minimum WCAG 2.2 AA contrast ratio for this usage.
    public var minimumRatio: Double {
        switch self {
        case .normalText: return 4.5
        case .largeText, .essentialUI: return 3.0
        }
    }
}

extension TokenColor {
    /// Whether this color, used as `usage` against `background`, meets the WCAG 2.2 AA threshold.
    public func meetsAA(against background: TokenColor, usage: ContrastUsage) -> Bool {
        contrastRatio(against: background) >= usage.minimumRatio
    }
}
