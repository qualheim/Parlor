// Per-game card semantics — the extension point, not the values (R-ENG-2.3).
//
// A `DeckDefinition` says which faces are in a pack; it deliberately says nothing about how they rank,
// what they score, or which is trump (R-ENG-2.1). Those meanings differ per game: ace can be high or
// low, Euchre promotes the jacks (the "bowers"), Sheepshead pulls all queens and jacks plus the diamond
// suit into one trump run, Pinochle scores ten and ace above king. EngineCore therefore provides the
// *extension point* — the `CardSemantics` protocol and a minimal `TrumpContext` — and each game supplies
// the actual mapping (R-ENG-2.3). No concrete conformance lives here; that belongs to the rules targets.

import Foundation

// MARK: - Trump context

/// The minimal context a game needs to interpret a face during a trick: what suit is trump (if any) and
/// what suit was led (if any).
///
/// This is enough to express the tricky "effective suit" cases the requirements call out — the Euchre
/// left bower counts as the trump suit rather than its printed suit, and following-suit checks compare a
/// card's effective suit against `leadSuit`. Both fields are optional because not every game or moment
/// has trump or a lead (e.g. no-trump contracts, or the first card of a trick). Games that need richer
/// context (bid level, partnerships) layer it in their own state; this stays deliberately small so it can
/// live in the pure engine (R-ENG-2.3).
public struct TrumpContext: Codable, Sendable, Hashable {
    /// The trump suit for the current hand, or `nil` if the game/round has no trump.
    public let trump: Suit?

    /// The suit led to the current trick, or `nil` if no card has been led yet.
    public let leadSuit: Suit?

    public init(trump: Suit? = nil, leadSuit: Suit? = nil) {
        self.trump = trump
        self.leadSuit = leadSuit
    }
}

// MARK: - Card semantics extension point

/// Per-game interpretation of card faces, layered over pieces and never baked into `Card`/`Tile`
/// (R-ENG-1.3, R-ENG-2.3).
///
/// EngineCore defines this protocol; each game provides a conforming type in its rules target that
/// encodes that game's rank order, point values, and effective-suit mapping. Keeping these as a supplied
/// semantics object (rather than methods on the piece) is what lets one `DeckDefinition` serve many games
/// with contradictory rules.
public protocol CardSemantics: Sendable {
    /// A comparable ordering key for `face` — higher means stronger — given the current `context`.
    ///
    /// The value is only meaningful relative to other faces under the same semantics and context; it is
    /// not a global rank. `context` carries trump/lead so games can, e.g., rank the bowers above the ace
    /// in Euchre or float the whole trump run in Sheepshead.
    func rankOrder(_ face: CardFace, context: TrumpContext?) -> Int

    /// The point value of `face` for scoring (0 when the game assigns none to it).
    func points(_ face: CardFace) -> Int

    /// The suit `face` counts as for following-suit and trick logic under `context`, or `nil` if it has
    /// none (e.g. a joker, or a card with no relevant suit in this game).
    ///
    /// This is where the Euchre left bower reports the trump suit instead of its printed suit, and where
    /// Sheepshead maps every queen, jack, and diamond to trump.
    func effectiveSuit(_ face: CardFace, context: TrumpContext?) -> Suit?
}
