// Crazy Eights card semantics — matching, the wild 8, action-card roles, and scoring values.
//
// EngineCore keeps rank order, points, and suit meaning OUT of `Card`/`CardFace` (R-ENG-1.3); each game
// supplies its own interpretation (R-ENG-2.3). Crazy Eights' interpretation:
//
//   • matching (R-CE-2.1): a card is playable if it shares the ACTIVE suit (which an 8 may have renamed,
//     R-CE-2.2) or the top discard's RANK;
//   • the wild 8 (R-CE-2.2): an 8 is always playable and, when played, names the suit to follow;
//   • action-card roles (R-CE-4.1, option): 2 → next draws two (and stacks), Jack → skip, Ace →
//     reverse; and
//   • scoring (R-CE-3.1): an 8 counts 50, K/Q/J count 10, an Ace counts 1, and every other card counts
//     its pip/face value (2…10 count 2…10 per assumption A-5). The rules doc is authoritative.
//
// These helpers operate on `CardFace`; jokers are not part of a standard-52 Crazy Eights deck, so they
// return `nil`/`false` rather than inventing behavior for a joker.

import EngineCore
import Foundation

/// Crazy Eights' reading of a card face: matching, the wild 8, action roles, and points (R-CE-2, R-CE-3,
/// R-CE-4). A namespace of pure functions so the rules code reads declaratively.
enum CrazyEightsCard {
    /// The suit of a standard face, or `nil` for a joker.
    static func suit(_ face: CardFace) -> Suit? {
        guard case .standard(_, let suit) = face else { return nil }
        return suit
    }

    /// The rank of a standard face, or `nil` for a joker.
    static func rank(_ face: CardFace) -> Rank? {
        guard case .standard(let rank, _) = face else { return nil }
        return rank
    }

    /// Whether `face` is an 8 — wild; always playable and names a suit (R-CE-2.2).
    static func isEight(_ face: CardFace) -> Bool {
        rank(face) == .eight
    }

    /// Whether `face` may be played given the current `activeSuit` and the top discard `topFace`
    /// (R-CE-2.1, R-CE-2.2).
    ///
    /// An 8 is always playable (wild, R-CE-2.2). Any other card is playable if it shares the active suit
    /// (which an earlier 8 may have named, R-CE-2.2) or the top discard's rank (R-CE-2.1). A joker is
    /// never playable in standard Crazy Eights.
    static func isPlayable(_ face: CardFace, activeSuit: Suit, topFace: CardFace?) -> Bool {
        if isEight(face) { return true }
        guard let cardSuit = suit(face), let cardRank = rank(face) else { return false }
        if cardSuit == activeSuit { return true }
        if let topRank = rank(topFace ?? face), topRank == cardRank { return true }
        return false
    }

    // MARK: - Action-card roles (R-CE-4.1, option)

    /// Whether `face` is a 2 — under the action-card option, forces the next player to draw two, and 2s
    /// stack (R-CE-4.1).
    static func isDrawTwo(_ face: CardFace) -> Bool { rank(face) == .two }

    /// Whether `face` is a Jack — under the action-card option, skips the next player (R-CE-4.1).
    static func isSkip(_ face: CardFace) -> Bool { rank(face) == .jack }

    /// Whether `face` is an Ace — under the action-card option, reverses the direction of play
    /// (R-CE-4.1).
    static func isReverse(_ face: CardFace) -> Bool { rank(face) == .ace }

    // MARK: - Scoring (R-CE-3.1, A-5)

    /// The going-out score for a card left in a loser's hand (R-CE-3.1):
    ///
    ///   • an 8 = 50;
    ///   • a King, Queen, or Jack = 10;
    ///   • an Ace = 1; and
    ///   • every other card = its pip/face value (2…10 count 2…10, per assumption A-5).
    ///
    /// A joker (not part of a standard deck) counts 0. The rules doc is authoritative for these values.
    static func points(_ face: CardFace) -> Int {
        guard let rank = rank(face) else { return 0 }
        switch rank {
        case .eight: return 50
        case .king, .queen, .jack: return 10
        case .ace: return 1
        default: return rank.rawValue  // 2…10 count their pip value (A-5)
        }
    }
}
