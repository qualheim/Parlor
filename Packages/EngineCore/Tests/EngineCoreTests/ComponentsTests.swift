import Foundation
import Testing

@testable import EngineCore

// Tests for the pieces + identity layer (task 2.1; R-ENG-1.1, R-ENG-1.2, R-ENG-1.3).

@Suite("Piece identity vs. face (R-ENG-1.2)")
struct PieceIdentityTests {
    @Test("Two cards with identical faces but different IDs are unequal as pieces, equal by face")
    func doubleDeckQueensOfSpadesAreDistinguishable() {
        let face = CardFace.standard(.queen, .spades)
        let first = Card(id: PieceID(raw: 1), face: face)
        let second = Card(id: PieceID(raw: 2), face: face)

        // Distinct physical pieces: unequal as whole values and by identity.
        #expect(first != second)
        #expect(first.id != second.id)

        // …yet they share exactly the printed face.
        #expect(first.face == second.face)
    }

    @Test("Two tiles with identical faces but different IDs are distinguishable")
    func doubleTileSetIsDistinguishable() {
        let face = TileFace.numbered(7, .red)
        let first = Tile(id: PieceID(raw: 10), face: face)
        let second = Tile(id: PieceID(raw: 11), face: face)

        #expect(first != second)
        #expect(first.id != second.id)
        #expect(first.face == second.face)
    }

    @Test("A piece's Identifiable id is its PieceID, not its face")
    func identifiableIdentityIsPieceID() {
        let card = Card(id: PieceID(raw: 42), face: .standard(.ace, .clubs))
        #expect(card.id == PieceID(raw: 42))
    }

    @Test("Pieces with the same id and face are equal and hash together")
    func sameIdAndFaceAreEqual() {
        let a = Card(id: PieceID(raw: 5), face: .standard(.king, .hearts))
        let b = Card(id: PieceID(raw: 5), face: .standard(.king, .hearts))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)

        // Distinct faces at the same id are still unequal pieces.
        let c = Card(id: PieceID(raw: 5), face: .standard(.queen, .hearts))
        #expect(a != c)
    }
}

@Suite("Codable round-trips (R-ENG-1.1)")
struct PieceCodableTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("PieceID round-trips")
    func pieceIDRoundTrips() throws {
        let id = PieceID(raw: 0xDEAD_BEEF_0000_0001)
        #expect(try roundTrip(id) == id)
    }

    @Test("Standard and joker card faces round-trip")
    func cardFaceRoundTrips() throws {
        #expect(try roundTrip(CardFace.standard(.ten, .diamonds)) == .standard(.ten, .diamonds))
        #expect(try roundTrip(CardFace.joker(index: 1)) == .joker(index: 1))
    }

    @Test("Numbered and joker tile faces round-trip")
    func tileFaceRoundTrips() throws {
        #expect(try roundTrip(TileFace.numbered(13, .orange)) == .numbered(13, .orange))
        #expect(try roundTrip(TileFace.joker(index: 0)) == .joker(index: 0))
    }

    @Test("A full Card round-trips preserving id and face")
    func cardRoundTrips() throws {
        let card = Card(id: PieceID(raw: 99), face: .standard(.jack, .spades))
        #expect(try roundTrip(card) == card)
    }

    @Test("A full Tile round-trips preserving id and face")
    func tileRoundTrips() throws {
        let tile = Tile(id: PieceID(raw: 100), face: .numbered(1, .blue))
        #expect(try roundTrip(tile) == tile)
    }
}

@Suite("Faces cover the intended value spaces (R-ENG-1.1)")
struct FaceValueSpaceTests {
    @Test("There are exactly four suits")
    func suitCoverage() {
        #expect(Suit.allCases.count == 4)
        #expect(Set(Suit.allCases) == [.clubs, .diamonds, .hearts, .spades])
    }

    @Test("There are exactly thirteen ranks, ace low through king high as ordinals")
    func rankCoverage() {
        #expect(Rank.allCases.count == 13)
        #expect(Rank.ace.rawValue == 1)
        #expect(Rank.king.rawValue == 13)
        // Ordinals are contiguous 1...13 with no gaps.
        #expect(Rank.allCases.map(\.rawValue) == Array(1...13))
    }

    @Test("There are exactly four tile colors")
    func tileColorCoverage() {
        #expect(TileColor.allCases.count == 4)
        #expect(Set(TileColor.allCases) == [.red, .blue, .black, .orange])
    }

    @Test("A standard-52 face set spans every rank in every suit uniquely")
    func standardFaceSetSpansAllRankSuitPairs() {
        var faces: Set<CardFace> = []
        for suit in Suit.allCases {
            for rank in Rank.allCases {
                faces.insert(.standard(rank, suit))
            }
        }
        #expect(faces.count == 52)
    }

    @Test("Jokers are distinguished by index")
    func jokersAreDistinctByIndex() {
        #expect(CardFace.joker(index: 0) != CardFace.joker(index: 1))
        #expect(TileFace.joker(index: 0) != TileFace.joker(index: 1))
    }
}
