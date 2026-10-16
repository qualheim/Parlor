import Testing

@testable import DesignSystem

/// The WCAG 2.2 AA contrast proof for the chrome palettes plus semantic-color-only structural checks
/// (R-DS-1.1, R-DS-1.2).
@Suite("Semantic colors & WCAG 2.2 AA chrome")
struct SemanticColorsTests {
    @Test("both light and dark chrome palettes ship")
    func palettesExist() {
        #expect(SemanticColors.allPalettes.count == 2)
        #expect(SemanticColors.light.appearance == .light)
        #expect(SemanticColors.dark.appearance == .dark)
    }

    @Test("every color role resolves in every palette")
    func everyRoleResolves() {
        for palette in SemanticColors.allPalettes {
            for role in ColorRole.allCases {
                // Opaque chrome color for text/essential UI.
                #expect(palette(role).alpha == 1, "\(palette.appearance) \(role) must be opaque")
            }
        }
    }

    /// The core WCAG 2.2 AA proof: every declared text/essential-UI pairing meets its threshold in BOTH
    /// chrome palettes (R-DS-1.2). Failure prints the offending role pair, palette, threshold, and actual
    /// ratio so the palette can be corrected.
    @Test(
        "all declared contrast pairings meet WCAG 2.2 AA in both palettes",
        arguments: SemanticColors.allPalettes
    )
    func contrastMeetsAA(palette: SemanticColors) {
        for requirement in ContrastRequirement.allAA {
            let ratio = requirement.ratio(in: palette)
            #expect(
                requirement.holds(in: palette),
                """
                WCAG 2.2 AA failure in \(palette.appearance) chrome: \
                \(requirement.foreground) on \(requirement.background) \
                needs ≥ \(requirement.usage.minimumRatio):1 but is \
                \(String(format: "%.2f", ratio)):1
                """
            )
        }
    }

    @Test("primary text clears AA comfortably on the base background")
    func primaryTextStrong() {
        for palette in SemanticColors.allPalettes {
            let ratio = palette(.textPrimary).contrastRatio(against: palette(.background))
            // Primary body text should exceed the 4.5 bar with headroom.
            #expect(ratio >= 7, "\(palette.appearance) primary text ratio \(ratio) too low")
        }
    }

    @Test("light and dark chrome differ (independent palettes)")
    func palettesDiffer() {
        #expect(SemanticColors.light(.background) != SemanticColors.dark(.background))
        #expect(SemanticColors.light(.textPrimary) != SemanticColors.dark(.textPrimary))
    }

    @Test("DesignTokens resolves the same color as its palette")
    func tokensResolve() {
        #expect(DesignTokens.light.color(.accent) == SemanticColors.light(.accent))
        #expect(DesignTokens.dark.color(.accent) == SemanticColors.dark(.accent))
    }
}
