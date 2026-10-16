import Foundation
import Testing

@testable import DesignSystem

/// Tests for the procedural table themes and their appearance independence (R-DS-2.1, R-DS-2.2).
@Suite("Table themes")
struct TableThemeTests {
    // MARK: - Catalog (R-DS-2.1)

    @Test("at least four themes ship, including the four named ones")
    func atLeastFourThemes() {
        #expect(TableTheme.all.count >= 4)
        let ids = Set(TableTheme.all.map(\.id))
        #expect(ids.isSuperset(of: ["classic-felt", "midnight", "walnut-parlor", "minimal"]))
    }

    @Test("theme ids and display names are unique")
    func idsAndNamesUnique() {
        let ids = TableTheme.all.map(\.id)
        let names = TableTheme.all.map(\.displayName)
        #expect(Set(ids).count == ids.count)
        #expect(Set(names).count == names.count)
    }

    @Test("every theme is looked up by id")
    func lookupById() {
        for theme in TableTheme.all {
            #expect(TableTheme.theme(id: theme.id) == theme)
        }
        #expect(TableTheme.theme(id: "does-not-exist") == nil)
    }

    @Test("the default theme is a member of the catalog")
    func defaultIsInCatalog() {
        #expect(TableTheme.all.contains(TableTheme.default))
        #expect(DesignSystem.defaultTableTheme == TableTheme.default)
        #expect(DesignSystem.tableThemes == TableTheme.all)
    }

    // MARK: - Procedural, not bitmaps (R-DS-2.1)

    @Test("every theme carries well-formed procedural material parameters")
    func materialParametersWellFormed() {
        for theme in TableTheme.all {
            let p = theme.parameters
            // Normalized inputs stay in range (the shader relies on this).
            #expect(p.grainScale > 0, "\(theme.id) grainScale must be positive")
            #expect((0...1).contains(p.grainStrength), "\(theme.id) grainStrength out of range")
            #expect((0...1).contains(p.sheenStrength), "\(theme.id) sheenStrength out of range")
            #expect((0...1).contains(p.vignette), "\(theme.id) vignette out of range")
        }
    }

    @Test("material parameters clamp normalized inputs into range")
    func materialParametersClamp() {
        let p = MaterialParameters(
            base: TokenColor(hex: 0x000000),
            accent: TokenColor(hex: 0xFFFFFF),
            grainScale: -5,
            grainStrength: 2,
            sheenStrength: -1,
            vignette: 9
        )
        #expect(p.grainScale == 0)
        #expect(p.grainStrength == 1)
        #expect(p.sheenStrength == 0)
        #expect(p.vignette == 1)
    }

    @Test("each material maps to a distinct stitchable shader function name")
    func materialShaderNames() {
        #expect(TableMaterial.felt.shaderFunctionName == "parlorFelt")
        #expect(TableMaterial.wood.shaderFunctionName == "parlorWood")
        #expect(TableMaterial.matte.shaderFunctionName == "parlorMatte")
        let names = Set(TableMaterial.allCases.map(\.shaderFunctionName))
        #expect(names.count == TableMaterial.allCases.count)
    }

    @Test("the named themes use their intended materials")
    func namedThemeMaterials() {
        #expect(TableTheme.classicFelt.material == .felt)
        #expect(TableTheme.midnight.material == .felt)
        #expect(TableTheme.walnutParlor.material == .wood)
        #expect(TableTheme.minimal.material == .matte)
    }

    // MARK: - Appearance independence (R-DS-2.2)

    @Test("a theme is a fixed value — identical regardless of any surrounding appearance")
    func themesAreAppearanceIndependent() {
        // A theme names its own colors; there is no light/dark variant. Re-fetching the catalog under any
        // notional appearance yields the same values (the model has no appearance input at all).
        let first = TableTheme.all
        let second = TableTheme.all
        #expect(first == second)
        for theme in TableTheme.all {
            // Colors are concrete tokens, not appearance-resolved roles.
            #expect(theme.parameters.base.alpha == 1)
            #expect(theme.shadowInk.alpha == 1)
        }
    }

    @Test("themes round-trip through Codable unchanged (stable, appearance-free values)")
    func themesCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for theme in TableTheme.all {
            let data = try encoder.encode(theme)
            let restored = try decoder.decode(TableTheme.self, from: data)
            #expect(restored == theme)
        }
    }
}

/// Tests for `TokenColor.blended`, used by procedural material rendering.
@Suite("TokenColor blending")
struct TokenColorBlendTests {
    @Test("blend endpoints and midpoint")
    func blendEndpoints() {
        let black = TokenColor(hex: 0x000000)
        let white = TokenColor(hex: 0xFFFFFF)
        #expect(black.blended(toward: white, amount: 0) == black)
        #expect(black.blended(toward: white, amount: 1) == white)
        let mid = black.blended(toward: white, amount: 0.5)
        #expect(abs(mid.red - 0.5) < 1e-9)
        #expect(abs(mid.green - 0.5) < 1e-9)
        #expect(abs(mid.blue - 0.5) < 1e-9)
    }

    @Test("blend amount clamps to 0...1")
    func blendClamps() {
        let a = TokenColor(hex: 0x102030)
        let b = TokenColor(hex: 0x405060)
        #expect(a.blended(toward: b, amount: -1) == a)
        #expect(a.blended(toward: b, amount: 2) == b)
    }
}
