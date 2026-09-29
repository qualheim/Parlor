// Zones and visibility — where pieces live and who may see them (R-ENG-3).
//
// A "zone" is a named place on the table that holds an ordered pile of pieces: a player's hand, the
// stock, a discard pile, a foundation, a tableau column, the talon. Two things about a zone drive the
// rest of the engine:
//
//   • ownership + order — a zone belongs to a seat or to no one (a shared/table zone), and its contents
//     are an *ordered* list, because "top of the stock" and "bottom of the pile" are meaningful
//     (R-ENG-3.1); and
//   • a visibility policy — a declarative rule for who may see the identities of the pieces inside
//     (R-ENG-3.2). Redaction (task 2.6, R-ENG-8) reads this policy plus the per-piece face state to
//     decide what each viewer's `PlayerView` reveals; it is not computed ad hoc per game (R-ENG-3.3).
//
// `Zone` deliberately stores only what redaction needs: the policy, the ordered `PieceID`s, and a
// `faceUp` set. It does not resolve visibility itself — that derivation lives with views in task 2.6 so
// the policy has a single interpreter. Keeping the face state *here* (rather than on the piece) is what
// lets the same physical piece be face-up in one zone context and hidden in another (R-ENG-3.3).

import Foundation

// MARK: - Visibility policy

/// How the identities of the pieces in a `Zone` are revealed to viewers (R-ENG-3.2).
///
/// This is a *policy*, not the redaction result: task 2.6 (R-ENG-8) derives each viewer's view from this
/// policy together with the zone's owner and its `faceUp` set (R-ENG-3.3). The cases below are the
/// minimum the requirements call out; games pick one per zone.
public enum Visibility: Codable, Sendable, Hashable {
    /// No one sees the contents' identities — e.g. the stock/deck (R-ENG-3.2).
    case hidden

    /// Only the owning seat sees identities — e.g. a player's private hand. A zone with no owner and
    /// this policy is effectively hidden to everyone (R-ENG-3.2).
    case ownerOnly

    /// Everyone sees every identity — e.g. a discard pile spread face-up, or a Klondike foundation
    /// (R-ENG-3.2). Named `publicAll` because `public` is a Swift keyword.
    case publicAll

    /// Only the identity of the top piece (last in `contents`) is public; the rest are hidden — e.g. a
    /// discard pile where only the top card matters (R-ENG-3.2).
    case topCardOnly

    /// Each piece is revealed according to its own face state: a piece in `faceUp` is public, otherwise
    /// hidden — e.g. a Klondike tableau column with some cards flipped up (R-ENG-3.2, R-ENG-3.3).
    case perPieceFaceState
}

// MARK: - Zone identity

/// A stable identity for a zone: its `name` plus the seat that owns it (or `nil` for a shared/table
/// zone).
///
/// Two hands named `"hand"` owned by different seats are *different* zones; a single shared `"stock"`
/// with `owner == nil` is one zone. Equality and hashing are therefore keyed on both `name` and `owner`
/// (R-ENG-3.1), which lets the engine address "seat-0's hand" distinctly from "seat-1's hand".
public struct ZoneID: Hashable, Codable, Sendable {
    /// The zone's role name, e.g. `"hand"`, `"stock"`, `"discard"`, `"foundation"`, `"tableau"`.
    public let name: String

    /// The owning seat, or `nil` for a shared/table zone with no single owner (R-ENG-3.1).
    public let owner: SeatID?

    public init(name: String, owner: SeatID? = nil) {
        self.name = name
        self.owner = owner
    }
}

// MARK: - Zone

/// A named, ordered pile of pieces with an owner and a visibility policy (R-ENG-3.1, R-ENG-3.2).
///
/// `contents` is ordered so that positional concepts (top/bottom of a stock, next card off the talon)
/// are well-defined; the convention used across the engine is that the *last* element is the "top" of
/// the pile. `faceUp` records which pieces are currently face-up and is consulted by the
/// `perPieceFaceState` policy (and, for the single top piece, `topCardOnly`) during redaction
/// (R-ENG-3.3). `visibility` is `var` because a policy can change over a hand (a hand revealed at
/// show-down), and `contents`/`faceUp` are `var` because pieces move and flip; `id` is fixed for the
/// zone's life.
public struct Zone: Codable, Sendable {
    /// Stable identity (name + owner) of this zone.
    public let id: ZoneID

    /// The current visibility policy governing who sees the pieces' identities.
    public var visibility: Visibility

    /// The pieces in this zone, in order. By convention the last element is the top of the pile.
    public var contents: [PieceID]

    /// The subset of `contents` currently face-up. Consulted by `perPieceFaceState` (and `topCardOnly`
    /// for the top piece) when deriving views (R-ENG-3.3). Pieces not present here are face-down.
    public var faceUp: Set<PieceID>

    public init(
        id: ZoneID,
        visibility: Visibility,
        contents: [PieceID] = [],
        faceUp: Set<PieceID> = []
    ) {
        self.id = id
        self.visibility = visibility
        self.contents = contents
        self.faceUp = faceUp
    }
}

// MARK: - Convenience accessors

extension Zone {
    /// The zone's owning seat, or `nil` if it is a shared/table zone (R-ENG-3.1).
    public var owner: SeatID? { id.owner }

    /// The top piece of the pile (last in `contents`), or `nil` if the zone is empty. This is the piece
    /// the `topCardOnly` policy exposes.
    public var top: PieceID? { contents.last }

    /// Whether a given piece is currently face-up in this zone (R-ENG-3.3).
    public func isFaceUp(_ piece: PieceID) -> Bool { faceUp.contains(piece) }
}
