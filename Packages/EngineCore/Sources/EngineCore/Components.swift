// Components and identity — the physical pieces of the pure engine (R-ENG-1).
//
// A "piece" is a physical object on the table: a playing card or a rummy tile. Every piece has two
// independent parts:
//
//   • an *identity* (`PieceID`) — a stable, opaque handle that stays with the physical object for its
//     whole life, and
//   • a *face* (`CardFace` / `TileFace`) — the printed value on it.
//
// These are deliberately separate. In a double deck the two "queen of spades" cards share a face but are
// still two distinct objects; giving each its own `PieceID` lets rules, zones, logs, and animations track
// exactly which physical piece moved even when faces collide (R-ENG-1.2).
//
// What faces intentionally do NOT carry: rank order, point values, or an effective (trump-adjusted) suit.
// Those are per-game semantics supplied elsewhere (the `CardSemantics` extension point in task 2.2), never
// baked into the piece (R-ENG-1.3). A `Rank`'s raw `Int` is an enum ordinal for `Codable`/`CaseIterable`
// convenience, not a claim about which rank beats which — Euchre, Sheepshead, and Pinochle all reorder it.

import Foundation

// MARK: - Identity

/// A stable, opaque identity for a physical piece, distinct from its face value.
///
/// Two pieces with the *same* face (e.g. both queens of spades in a double deck) still have *different*
/// `PieceID`s, so they remain individually addressable throughout a match (R-ENG-1.2). The `raw` value is
/// an opaque handle; callers should treat it as a token, not derive meaning from its numeric value.
public struct PieceID: Hashable, Codable, Sendable {
    /// Opaque underlying handle. Uniqueness across a deal is the responsibility of whoever mints IDs
    /// (deck construction in task 2.2); `PieceID` itself only guarantees value equality on `raw`.
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }
}

// MARK: - Card faces

/// The four suits of a standard French-suited deck.
///
/// This enum names the suits only; it says nothing about their order or whether any is trump — that is
/// per-game semantics (R-ENG-1.3).
public enum Suit: String, Codable, Sendable, CaseIterable {
    case clubs
    case diamonds
    case hearts
    case spades
}

/// The thirteen ranks of a standard deck.
///
/// The raw `Int` (ace = 1 … king = 13) is a stable ordinal for `Codable` and `CaseIterable`, *not* a
/// ranking. Games define their own rank order via `CardSemantics` (R-ENG-1.3); for example ace can be
/// high or low, and Euchre promotes the jacks.
public enum Rank: Int, Codable, Sendable, CaseIterable {
    case ace = 1
    case two
    case three
    case four
    case five
    case six
    case seven
    case eight
    case nine
    case ten
    case jack
    case queen
    case king
}

/// The printed value on a card: either a standard rank+suit, or one of the jokers.
///
/// `joker(index:)` distinguishes the (typically two) jokers in a pack so they are separately identifiable
/// as faces; physical identity is still carried by `PieceID` on `Card` (R-ENG-1.1, R-ENG-1.2).
public enum CardFace: Codable, Sendable, Hashable {
    case standard(Rank, Suit)
    case joker(index: Int)
}

// MARK: - Tile faces

/// The colors used by rummy tile sets.
public enum TileColor: String, Codable, Sendable, CaseIterable {
    case red
    case blue
    case black
    case orange
}

/// The printed value on a rummy tile: either a numbered color tile (1…13), or a joker.
///
/// The numeric range is a set-composition concern owned by `DeckDefinition` (task 2.2); the face type does
/// not clamp or interpret the number, keeping game semantics out of the piece (R-ENG-1.1, R-ENG-1.3).
public enum TileFace: Codable, Sendable, Hashable {
    case numbered(Int, TileColor)
    case joker(index: Int)
}

// MARK: - Pieces

/// A playing card: a unique physical piece (`id`) bearing a printed `face` (R-ENG-1.1).
///
/// `Identifiable` identity is the `PieceID`, not the face, so two cards with identical faces are distinct
/// (R-ENG-1.2). Value equality (`Hashable`) compares both `id` and `face`; to compare only what is printed,
/// compare `face` directly.
public struct Card: Identifiable, Codable, Sendable, Hashable {
    public let id: PieceID
    public let face: CardFace

    public init(id: PieceID, face: CardFace) {
        self.id = id
        self.face = face
    }
}

/// A rummy tile: a unique physical piece (`id`) bearing a printed `face` (R-ENG-1.1).
///
/// As with `Card`, identity is the `PieceID` and is independent of the printed `face` (R-ENG-1.2).
public struct Tile: Identifiable, Codable, Sendable, Hashable {
    public let id: PieceID
    public let face: TileFace

    public init(id: PieceID, face: TileFace) {
        self.id = id
        self.face = face
    }
}
