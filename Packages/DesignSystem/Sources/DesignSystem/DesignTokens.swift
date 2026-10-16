// DesignTokens — the single entry point to the whole token set (R-DS-1.1, R-DS-1.2).
//
// A `DesignTokens` bundles one chrome color palette with the (appearance-independent) type, spacing,
// radius, shadow, and motion scales. The app holds one of these in its environment and every chrome view
// reads color/metrics through it — so nothing names a raw color or magic number (R-DS-1.2). Switching
// `.light` ↔ `.dark` swaps only the color palette; the metric scales are shared.
//
// The color palette is chosen explicitly (not inferred from the system), so chrome — like table themes —
// can be pinned independently of the system light/dark setting (R-DS-2.2).

import Foundation

/// The complete design-token set for one chrome appearance (R-DS-1.1).
public struct DesignTokens: Sendable {
    /// Semantic chrome colors (the only source of color — R-DS-1.2).
    public let colors: SemanticColors

    public init(colors: SemanticColors) {
        self.colors = colors
    }

    /// The light-chrome token set.
    public static let light = DesignTokens(colors: .light)
    /// The dark-chrome token set.
    public static let dark = DesignTokens(colors: .dark)

    /// Resolve a semantic color role in this token set's palette.
    public func color(_ role: ColorRole) -> TokenColor { colors(role) }
}
