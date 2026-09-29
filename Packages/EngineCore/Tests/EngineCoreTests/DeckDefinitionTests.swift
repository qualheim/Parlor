import Foundation
import Testing

@testable import EngineCore

/// Composition tests for the standard deck/set definitions (R-ENG-2.2). Each test asserts the exact
/// multiset a pack must contain — not just the count — so a wrong rank range or a missing joker fails
/// loudly. Materialization is checked for unique `PieceID`s so double decks stay individually addressable
/// (R-ENG-1.2).
@Suite("DeckDefinition composition")
struct DeckDefinitionCompositionTests {

    // MARK: - Helpers

    /// Count each card face in a definition, ignoring any tile faces.
    private func cardHistogram(_ deck: DeckDefinition) -> [CardFace: Int] {
        var histogram: [CardFace: Int] = [:]
        for face in deck.faces {
            if case let .card(cardFace) = face {
                histogram[cardFace, default: 0] += 1
            }
        }
        return histogram
    }

    /// Count each tile face in a definition, ignoring any card faces.
    private func tileHistogram(_ deck: DeckDefinition) -> [TileFace: Int] {
        var histogram: [TileFace: Int] = [:]
        for face in deck.faces {
            if case let .tile(tileFace) = face {
                histogram[tileFace, default: 0] += 1
            }
        }
        return histogram
    }

    /// The 4 suits × the given ranks, each expected exactly `copies` times.
    private func expectedCardFaces(ranks: [Rank], copies: Int = 1) -> [CardFace: Int] {
        var expected: [CardFace: Int] = [:]
        for rank in ranks {
            for suit in Suit.allCases {
                expected[.standard(rank, suit)] = copies
            }
        }
        return expected
    }

    // MARK: - standard-52

    @Test("standard-52 is 13 ranks × 4 suits, one of each")
    func standard52Composition() {
        let deck = DeckDefinition.standard52
        #expect(deck.id == "standard-52")
        #expect(deck.count == 52)
        #expect(cardHistogram(deck) == expectedCardFaces(ranks: Rank.allCases))
    }

    // MARK: - 52 + jokers

    @Test("52 + jokers is the standard 52 plus exactly two distinct jokers")
    func standard52PlusJokersComposition() {
        let deck = DeckDefinition.standard52PlusJokers
        #expect(deck.count == 54)

        var expected = expectedCardFaces(ranks: Rank.allCases)
        expected[.joker(index: 0)] = 1
        expected[.joker(index: 1)] = 1
        #expect(cardHistogram(deck) == expected)
    }

    // MARK: - Euchre 24

    @Test("Euchre-24 is ranks 9–A × 4 suits")
    func euchre24Composition() {
        let deck = DeckDefinition.euchre24
        #expect(deck.count == 24)
        let ranks: [Rank] = [.nine, .ten, .jack, .queen, .king, .ace]
        #expect(cardHistogram(deck) == expectedCardFaces(ranks: ranks))
    }

    // MARK: - Sheepshead 32

    @Test("Sheepshead-32 is ranks 7–A × 4 suits")
    func sheepshead32Composition() {
        let deck = DeckDefinition.sheepshead32
        #expect(deck.count == 32)
        let ranks: [Rank] = [.seven, .eight, .nine, .ten, .jack, .queen, .king, .ace]
        #expect(cardHistogram(deck) == expectedCardFaces(ranks: ranks))
    }

    // MARK: - Spider 104

    @Test("Spider-104 is two full standard decks (each face exactly twice)")
    func spider104Composition() {
        let deck = DeckDefinition.spider104
        #expect(deck.count == 104)
        #expect(cardHistogram(deck) == expectedCardFaces(ranks: Rank.allCases, copies: 2))
    }

    // MARK: - Pinochle 48

    @Test("Pinochle-48 is two copies each of 9,10,J,Q,K,A × 4 suits")
    func pinochle48Composition() {
        let deck = DeckDefinition.pinochle48
        #expect(deck.count == 48)
        let ranks: [Rank] = [.nine, .ten, .jack, .queen, .king, .ace]
        #expect(cardHistogram(deck) == expectedCardFaces(ranks: ranks, copies: 2))
    }

    // MARK: - Tile Rummy 106

    @Test("Tile-Rummy-106 is 1–13 in 4 colors twice, plus two distinct jokers")
    func tileRummy106Composition() {
        let deck = DeckDefinition.tileRummy106
        #expect(deck.count == 106)

        var expected: [TileFace: Int] = [:]
        for color in TileColor.allCases {
            for number in 1...13 {
                expected[.numbered(number, color)] = 2
            }
        }
        expected[.joker(index: 0)] = 1
        expected[.joker(index: 1)] = 1
        #expect(tileHistogram(deck) == expected)

        // Tile sets carry no card faces.
        #expect(cardHistogram(deck).isEmpty)
    }
}

/// Tests for turning a data definition into concrete pieces with unique identity (R-ENG-1.2, R-ENG-2.1).
@Suite("DeckDefinition materialization")
struct DeckDefinitionMaterializationTests {

    @Test("card decks materialize one Card per card face, preserving the face multiset")
    func materializesCards() {
        let deck = DeckDefinition.standard52
        let cards = deck.makeCards()
        #expect(cards.count == 52)
        #expect(Set(cards.map(\.face)).count == 52)
    }

    @Test("duplicate faces materialize as distinct pieces with unique PieceIDs")
    func duplicateFacesGetUniqueIDs() {
        let cards = DeckDefinition.spider104.makeCards()
        #expect(cards.count == 104)

        // Every physical piece has a unique identity even though faces repeat (R-ENG-1.2).
        #expect(Set(cards.map(\.id)).count == 104)

        // The two copies of a given face are two distinct pieces.
        let queenOfSpades = cards.filter { $0.face == .standard(.queen, .spades) }
        #expect(queenOfSpades.count == 2)
        #expect(queenOfSpades[0].id != queenOfSpades[1].id)
    }

    @Test("materialization is stable for a given starting ID")
    func materializationIsStable() {
        let a = DeckDefinition.euchre24.makeCards(startingAt: 100)
        let b = DeckDefinition.euchre24.makeCards(startingAt: 100)
        #expect(a == b)
    }

    @Test("tile sets materialize one Tile per tile face with unique IDs")
    func materializesTiles() {
        let tiles = DeckDefinition.tileRummy106.makeTiles()
        #expect(tiles.count == 106)
        #expect(Set(tiles.map(\.id)).count == 106)

        // Two of each numbered tile means duplicate faces, distinct pieces.
        let redOnes = tiles.filter { $0.face == .numbered(1, .red) }
        #expect(redOnes.count == 2)
        #expect(redOnes[0].id != redOnes[1].id)
    }

    @Test("makeCards ignores tile faces and makeTiles ignores card faces")
    func materializationRespectsFaceKind() {
        #expect(DeckDefinition.tileRummy106.makeCards().isEmpty)
        #expect(DeckDefinition.standard52.makeTiles().isEmpty)
    }
}
