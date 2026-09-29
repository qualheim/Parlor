// Deck and set definitions as data, plus per-game semantics extension points (R-ENG-2).
//
// A `DeckDefinition` is *pure data*: an ordered list of the faces that make up a pack, with no rank
// order, point values, or trump rules baked in (R-ENG-2.1). Composition is what a definition describes;
// interpretation is a per-game concern layered on top via `CardSemantics` (R-ENG-2.3).
//
// Card packs and tile sets both need to be describable, but their faces are different types
// (`CardFace` vs `TileFace`). Rather than force one into the other, a definition carries a `PieceFace`
// — a small tagged union of "this slot holds a card face" or "this slot holds a tile face". A single
// `DeckDefinition` type therefore covers French-suited packs (standard-52, Euchre-24, …), double decks
// (Spider-104), and rummy tile sets (tile-rummy-106) without special-casing (R-ENG-2.2).
//
// Duplicates are first-class: Spider is two full 52-card decks and Pinochle has two copies of each
// high card, so the same face legitimately appears more than once in `faces`. Identity is *not* the
// face — it is minted when a definition is materialized into concrete pieces (`makeCards` /
// `makeTiles`), where each slot gets its own fresh `PieceID`. This keeps "two queens of spades" as two
// distinct physical objects (R-ENG-1.2) while the definition stays a plain description.

import Foundation

// MARK: - Face variant

/// One slot in a `DeckDefinition`: either a playing-card face or a rummy-tile face.
///
/// This lets a single deck-definition type describe both French-suited packs and tile sets as data,
/// without baking either piece type's assumptions into the other (R-ENG-2.1).
public enum PieceFace: Codable, Sendable, Hashable {
    case card(CardFace)
    case tile(TileFace)
}

// MARK: - Deck definition

/// A deck or set described purely as data: an ordered multiset of faces with a stable `id`.
///
/// The definition says *what faces are in the pack and how many*, nothing about how they rank, score, or
/// which is trump — those are supplied per game through `CardSemantics` (R-ENG-2.3). Duplicate faces are
/// expected (double decks, Pinochle); physical uniqueness is minted later by `makeCards`/`makeTiles`.
public struct DeckDefinition: Codable, Sendable, Hashable {
    /// Stable identifier, e.g. `"standard-52"`, `"spider-104"`, `"tile-rummy-106"`.
    public let id: String

    /// The faces that make up the pack, in a canonical build order. Order is not a ranking (R-ENG-2.1).
    public let faces: [PieceFace]

    /// Total number of pieces in the pack.
    public var count: Int { faces.count }

    public init(id: String, faces: [PieceFace]) {
        self.id = id
        self.faces = faces
    }
}

// MARK: - Materialization

extension DeckDefinition {
    /// Materialize the card faces in this definition into concrete `Card`s with unique, stable IDs.
    ///
    /// Each slot gets its own `PieceID` derived from `firstID` by position, so duplicate faces (e.g. the
    /// two queens of spades in a double deck) become distinct physical pieces (R-ENG-1.2). Any tile faces
    /// in the definition are ignored — use ``makeTiles(startingAt:)`` for tile sets. IDs are assigned to
    /// card slots in definition order starting at `firstID`, so calling this twice with the same
    /// `firstID` yields identical IDs (stable for later shuffle/deal and save/replay).
    public func makeCards(startingAt firstID: UInt64 = 0) -> [Card] {
        var next = firstID
        var cards: [Card] = []
        cards.reserveCapacity(faces.count)
        for face in faces {
            guard case let .card(cardFace) = face else { continue }
            cards.append(Card(id: PieceID(raw: next), face: cardFace))
            next &+= 1
        }
        return cards
    }

    /// Materialize the tile faces in this definition into concrete `Tile`s with unique, stable IDs.
    ///
    /// Mirrors ``makeCards(startingAt:)`` for tile sets: duplicate faces become distinct pieces via a
    /// fresh `PieceID` per slot, assigned in definition order from `firstID` (R-ENG-1.2). Any card faces
    /// are ignored.
    public func makeTiles(startingAt firstID: UInt64 = 0) -> [Tile] {
        var next = firstID
        var tiles: [Tile] = []
        tiles.reserveCapacity(faces.count)
        for face in faces {
            guard case let .tile(tileFace) = face else { continue }
            tiles.append(Tile(id: PieceID(raw: next), face: tileFace))
            next &+= 1
        }
        return tiles
    }
}

// MARK: - Standard catalogue (R-ENG-2.2)

extension DeckDefinition {
    /// Suits in a fixed build order. Not a ranking — see `CardSemantics` (R-ENG-2.3).
    private static let buildSuits: [Suit] = [.clubs, .diamonds, .hearts, .spades]

    /// Build one card face per suit for each rank in `ranks`, iterating rank-major then suit.
    private static func cardFaces(ranks: [Rank]) -> [PieceFace] {
        ranks.flatMap { rank in buildSuits.map { .card(.standard(rank, $0)) } }
    }

    /// Standard French-suited 52: 13 ranks × 4 suits (R-ENG-2.2).
    public static let standard52 = DeckDefinition(
        id: "standard-52",
        faces: cardFaces(ranks: Rank.allCases)
    )

    /// Standard 52 plus two jokers = 54 (R-ENG-2.2).
    public static let standard52PlusJokers = DeckDefinition(
        id: "standard-52-plus-jokers",
        faces: cardFaces(ranks: Rank.allCases) + [.card(.joker(index: 0)), .card(.joker(index: 1))]
    )

    /// Euchre 24: ranks 9–A (nine, ten, jack, queen, king, ace) × 4 suits (R-ENG-2.2).
    public static let euchre24 = DeckDefinition(
        id: "euchre-24",
        faces: cardFaces(ranks: [.nine, .ten, .jack, .queen, .king, .ace])
    )

    /// Sheepshead 32: ranks 7–A (seven, eight, nine, ten, jack, queen, king, ace) × 4 suits (R-ENG-2.2).
    public static let sheepshead32 = DeckDefinition(
        id: "sheepshead-32",
        faces: cardFaces(ranks: [.seven, .eight, .nine, .ten, .jack, .queen, .king, .ace])
    )

    /// Spider double deck 104: two full standard-52 packs (R-ENG-2.2). Duplicate faces are distinguished
    /// by `PieceID` when materialized (R-ENG-1.2).
    public static let spider104 = DeckDefinition(
        id: "spider-104",
        faces: cardFaces(ranks: Rank.allCases) + cardFaces(ranks: Rank.allCases)
    )

    /// Pinochle 48: two copies each of ranks 9, 10, J, Q, K, A × 4 suits (R-ENG-2.2).
    public static let pinochle48: DeckDefinition = {
        let single = cardFaces(ranks: [.nine, .ten, .jack, .queen, .king, .ace])
        return DeckDefinition(id: "pinochle-48", faces: single + single)
    }()

    /// Tile Rummy 106: numbers 1–13 in 4 colors, two of each (13 × 4 × 2 = 104), plus 2 jokers
    /// (R-ENG-2.2). The number range lives here in the definition, not in `TileFace` (R-ENG-1.3).
    public static let tileRummy106: DeckDefinition = {
        var faces: [PieceFace] = []
        for _ in 0..<2 {
            for color in TileColor.allCases {
                for number in 1...13 {
                    faces.append(.tile(.numbered(number, color)))
                }
            }
        }
        faces.append(.tile(.joker(index: 0)))
        faces.append(.tile(.joker(index: 1)))
        return DeckDefinition(id: "tile-rummy-106", faces: faces)
    }()

    /// Every standard definition EngineCore ships, for catalogue lookups and exhaustive tests.
    public static let all: [DeckDefinition] = [
        standard52, standard52PlusJokers, euchre24, sheepshead32, spider104, pinochle48,
        tileRummy106,
    ]
}
