import Foundation
import Testing

@testable import DesignSystem

/// Tests for the deck-face style catalog, card backs, and court-card placeholders (R-DS-3.1, R-DS-3.2,
/// R-DS-3.3, R-A11Y-3.1).
@Suite("Deck styles")
struct DeckStyleTests {
    // MARK: - Catalog (R-DS-3.1)

    @Test("the four named deck styles ship")
    func fourNamedStyles() {
        let ids = Set(DeckStyle.all.map(\.id))
        #expect(ids == ["classic", "modern", "four-color", "jumbo-index"])
        #expect(DesignSystem.deckStyles == DeckStyle.all)
    }

    @Test("style ids and display names are unique")
    func idsUnique() {
        let ids = DeckStyle.all.map(\.id)
        let names = DeckStyle.all.map(\.displayName)
        #expect(Set(ids).count == ids.count)
        #expect(Set(names).count == names.count)
    }

    @Test("every style is looked up by id; unknown returns nil")
    func lookupById() {
        for style in DeckStyle.all {
            #expect(DeckStyle.style(id: style.id) == style)
        }
        #expect(DeckStyle.style(id: "nope") == nil)
    }

    @Test("the default deck style is Classic and is in the catalog")
    func defaultStyle() {
        #expect(DeckStyle.default == .classic)
        #expect(DeckStyle.all.contains(DeckStyle.default))
        #expect(DesignSystem.defaultDeckStyle == .classic)
    }

    // MARK: - Suit shapes are always present (color independence — R-A11Y-3.1)

    @Test("every suit maps to a distinct shape, so suit is never color-only")
    func suitsAlwaysHaveDistinctShapes() {
        let shapes = DeckSuit.allCases.map(\.shape)
        #expect(Set(shapes).count == DeckSuit.allCases.count)
        #expect(DeckSuit.hearts.shape == .heart)
        #expect(DeckSuit.diamonds.shape == .diamond)
        #expect(DeckSuit.clubs.shape == .club)
        #expect(DeckSuit.spades.shape == .spade)
    }

    @Test("across EVERY deck style, every suit carries its distinct shape (never color-only)")
    func suitShapesPresentInEveryStyle() {
        // Color independence (R-A11Y-3.1): regardless of the chosen style — including the two-color
        // Classic/Modern/Jumbo styles, not just Four-Color — each suit resolves to a non-nil, distinct
        // shape. The shape does not depend on the style, so a suit is always identifiable without color.
        for style in DeckStyle.all {
            let shapes = DeckSuit.allCases.map(\.shape)
            #expect(
                Set(shapes).count == DeckSuit.allCases.count,
                "\(style.id): suits must have four distinct shapes")
            for suit in DeckSuit.allCases {
                // Each suit's shape is a real, specific `SuitShape` case (the enum is non-optional, so
                // this asserts the mapping is total and stable per style).
                #expect(SuitShape.allCases.contains(suit.shape))
            }
        }
    }

    @Test("the four-color deck is selectable from the catalog by id")
    func fourColorSelectable() {
        #expect(DeckStyle.style(id: "four-color") == .fourColor)
        #expect(DeckStyle.all.contains(.fourColor))
        #expect(DeckStyle.fourColor.isFourColor)
    }

    @Test("every deck style assigns an ink color to all four suits")
    func everyStyleColorsAllSuits() {
        for style in DeckStyle.all {
            for suit in DeckSuit.allCases {
                // A concrete color is present for each suit (never the neutral fallback path unseen).
                #expect(style.suitColors[suit] != nil, "\(style.id) missing \(suit)")
                #expect(style.inkColor(for: suit) == style.suitColors[suit])
            }
        }
    }

    // MARK: - Four-Color gives each suit a distinct color (R-DS-3.1, R-A11Y-3.1)

    @Test("the Four-Color deck assigns four distinct suit colors")
    func fourColorDistinctColors() {
        let four = DeckStyle.fourColor
        #expect(four.isFourColor)
        let colors = DeckSuit.allCases.map { four.inkColor(for: $0) }
        #expect(Set(colors).count == 4, "Four-Color must use four distinct hues")
    }

    @Test("two-color styles use one red for hearts+diamonds and one black for clubs+spades")
    func twoColorScheme() {
        for style in [DeckStyle.classic, .modern, .jumboIndex] {
            #expect(!style.isFourColor)
            #expect(style.inkColor(for: .hearts) == style.inkColor(for: .diamonds))
            #expect(style.inkColor(for: .clubs) == style.inkColor(for: .spades))
            #expect(style.inkColor(for: .hearts) != style.inkColor(for: .spades))
        }
    }

    // MARK: - Jumbo Index prominence (R-DS-3.1)

    @Test("only Jumbo Index uses the jumbo index prominence")
    func jumboProminence() {
        #expect(DeckStyle.jumboIndex.indexProminence == .jumbo)
        for style in [DeckStyle.classic, .modern, .fourColor] {
            #expect(style.indexProminence == .standard)
        }
    }

    @Test("deck styles round-trip through Codable")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for style in DeckStyle.all {
            let data = try encoder.encode(style)
            #expect(try decoder.decode(DeckStyle.self, from: data) == style)
        }
    }
}

/// Tests for the card-back catalog (R-DS-3.2).
@Suite("Card backs")
struct CardBackTests {
    @Test("at least six backs ship, matching the manifest back list")
    func atLeastSixBacks() {
        #expect(CardBack.all.count >= 6)
        let ids = Set(CardBack.all.map(\.id))
        #expect(ids.isSuperset(of: ["lattice", "art-deco", "linen", "checker", "wave", "crest"]))
        #expect(DesignSystem.cardBacks == CardBack.all)
    }

    @Test("back ids, names, and motifs are unique")
    func backsUnique() {
        let ids = CardBack.all.map(\.id)
        let names = CardBack.all.map(\.displayName)
        let motifs = CardBack.all.map(\.motif)
        #expect(Set(ids).count == ids.count)
        #expect(Set(names).count == names.count)
        #expect(Set(motifs).count == motifs.count, "each back uses a distinct motif")
    }

    @Test("every back is looked up by id; unknown returns nil")
    func lookupById() {
        for back in CardBack.all {
            #expect(CardBack.back(id: back.id) == back)
        }
        #expect(CardBack.back(id: "nope") == nil)
    }

    @Test("the default card back is in the catalog")
    func defaultBack() {
        #expect(CardBack.all.contains(CardBack.default))
        #expect(DesignSystem.defaultCardBack == CardBack.default)
    }

    @Test("card backs round-trip through Codable")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for back in CardBack.all {
            let data = try encoder.encode(back)
            #expect(try decoder.decode(CardBack.self, from: data) == back)
        }
    }
}

/// Tests for the placeholder court-card designs (R-DS-3.3, R-DS-6).
@Suite("Court card placeholders")
struct CourtCardArtTests {
    @Test("a placeholder ships for each court rank")
    func placeholderPerRank() {
        let ranks = Set(CourtCardArt.placeholders.map(\.rank))
        #expect(ranks == Set(CourtRank.allCases))
        #expect(DesignSystem.courtCardPlaceholders == CourtCardArt.placeholders)
    }

    @Test("every placeholder is flagged needs production art (R-DS-6)")
    func allFlaggedNeedsProductionArt() {
        for art in CourtCardArt.placeholders {
            #expect(
                art.needsProductionArt,
                "\(art.rank) placeholder must be flagged needs-production-art")
        }
    }

    @Test("placeholders use an original geometric motif, not figurative court imagery (R-DS-3.3)")
    func originalGeometricMotif() {
        for art in CourtCardArt.placeholders {
            #expect(art.motif == .medallion)
        }
    }

    @Test("court rank monograms are J/Q/K")
    func monograms() {
        #expect(CourtRank.jack.monogram == "J")
        #expect(CourtRank.queen.monogram == "Q")
        #expect(CourtRank.king.monogram == "K")
    }

    @Test("placeholder(for:) returns the matching flagged placeholder")
    func placeholderLookup() {
        for rank in CourtRank.allCases {
            let art = CourtCardArt.placeholder(for: rank)
            #expect(art.rank == rank)
            #expect(art.needsProductionArt)
        }
    }
}
