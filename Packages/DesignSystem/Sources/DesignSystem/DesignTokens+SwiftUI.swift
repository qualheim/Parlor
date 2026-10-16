// DesignTokens+SwiftUI — the SwiftUI bridge for the token set (UI layer).
//
// The token *values* are pure (Foundation-only) so they can be tested headless and used off the main
// actor. This file is the thin SwiftUI adapter: it maps a `TokenColor` to a SwiftUI `Color`, a `TypeToken`
// to a `Font`, and exposes the current `DesignTokens` through the SwiftUI environment so a chrome view
// asks the environment for a *semantic* role and never constructs a `Color` from raw channels itself
// (R-DS-1.2). Only DesignSystem may bridge raw channels → `Color`; consumers stay semantic-color-only.

import SwiftUI

// MARK: - Primitive bridges

extension TokenColor {
    /// The SwiftUI `Color` for this token, in the sRGB color space. DesignSystem is the ONLY place raw
    /// channels become a `Color`; everything else names a semantic role (R-DS-1.2).
    public var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension FontWeightToken {
    /// The SwiftUI weight for this semantic weight token.
    public var swiftUIWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

extension TypeToken {
    /// The SwiftUI `Font` for this type token.
    public var swiftUIFont: Font {
        Font.system(size: size, weight: weight.swiftUIWeight)
    }
}

extension MotionToken {
    /// The SwiftUI spring `Animation` for this motion token.
    public var swiftUIAnimation: Animation {
        .spring(response: response, dampingFraction: dampingFraction)
    }
}

// MARK: - Semantic color → Color

extension DesignTokens {
    /// The SwiftUI `Color` for a semantic role in this token set (R-DS-1.2).
    public func swiftUIColor(_ role: ColorRole) -> Color { color(role).swiftUIColor }
}

extension SemanticColors {
    /// The SwiftUI `Color` for a semantic role in this palette.
    public func swiftUIColor(_ role: ColorRole) -> Color { color(role).swiftUIColor }
}

// MARK: - Environment plumbing

/// The environment key carrying the current `DesignTokens`. Defaults to light chrome.
private struct DesignTokensKey: EnvironmentKey {
    static let defaultValue: DesignTokens = .light
}

extension EnvironmentValues {
    /// The current design-token set. Defaults to light chrome; the app sets it (independently of system
    /// appearance if it chooses — R-DS-2.2). Chrome views read semantic roles from here (R-DS-1.2).
    public var designTokens: DesignTokens {
        get { self[DesignTokensKey.self] }
        set { self[DesignTokensKey.self] = newValue }
    }
}

extension View {
    /// Inject a design-token set (light/dark chrome) into the environment for this subtree.
    public func designTokens(_ tokens: DesignTokens) -> some View {
        environment(\.designTokens, tokens)
    }
}
