// Klondike card semantics — rank order and color, layered over pieces (R-ENG-2.3, R-KLON-1.2).
//
// EngineCore keeps rank order, points, and color OUT of `Card`/`CardFace` (R-ENG-1.3); each game
// supplies its own interpretation (R-ENG-2.3). Klondike's interpretation is simple and fixed:
//
//   • rank runs Ace (low) up to King, so foundations build A→2→…→K by suit (R-KLON-1.2), and tableau
//     sequences step down one rank at a time (K→Q→…→A);
//   • suits split into two colors — clubs and spades are black, hearts and diamonds are red — and the
//     tableau builds down in *alternating* colors (R-KLON-1.2).
//
// These helpers operate on `CardFace`; jokers are not part of a standard-52 Klondike deck, so the
// helpers return `nil` for a joker face rather than inventing an order for it.

import EngineCore
import Foundation

/// The two card colors Klondike alternates on the tableau (R-KLON-1.2).
enum KlondikeColor: Sendable, Equatable {
    case black
    case red
}

extension Suit {
    /// The Klondike color of this suit: clubs/spades are black, hearts/diamonds are red (R-KLON-1.2).
    var klondikeColor: KlondikeColor {
        switch self {
        case .clubs, .spades: return .black
        case .hearts, .diamonds: return .red
        }
    }
}

/// Klondike's fixed, Ace-low rank order and color reading for a card face (R-KLON-1.2).
///
/// A tiny value type rather than a `CardSemantics` conformance: Klondike needs only "what rank value is
/// this (Ace = 1 … King = 13)" and "what color is this", both of which are already expressible directly.
/// Kept as a namespace of pure functions so the rules code reads declaratively.
enum KlondikeCard {
    /// The Ace-low rank value of a standard face: Ace = 1, two = 2, …, King = 13; `nil` for a joker
    /// (R-KLON-1.2). This matches `Rank`'s raw ordinal, but naming it here states the Klondike intent.
    static func rankValue(_ face: CardFace) -> Int? {
        guard case .standard(let rank, _) = face else { return nil }
        return rank.rawValue
    }

    /// The suit of a standard face, or `nil` for a joker.
    static func suit(_ face: CardFace) -> Suit? {
        guard case .standard(_, let suit) = face else { return nil }
        return suit
    }

    /// The Klondike color of a standard face, or `nil` for a joker (R-KLON-1.2).
    static func color(_ face: CardFace) -> KlondikeColor? {
        suit(face)?.klondikeColor
    }

    /// Whether `lower` may sit directly on `upper` in a **tableau** build-down: one rank lower and the
    /// opposite color (R-KLON-1.2). Jokers never qualify.
    static func tableauFollows(_ lower: CardFace, onto upper: CardFace) -> Bool {
        guard
            let lowerRank = rankValue(lower), let upperRank = rankValue(upper),
            let lowerColor = color(lower), let upperColor = color(upper)
        else { return false }
        return lowerRank == upperRank - 1 && lowerColor != upperColor
    }

    /// Whether `next` may be placed on a **foundation** whose current top is `onto`: same suit, one rank
    /// higher (R-KLON-1.2). Passing `onto == nil` means an empty foundation, which accepts only an Ace.
    static func foundationFollows(_ next: CardFace, onto top: CardFace?) -> Bool {
        guard let nextRank = rankValue(next), let nextSuit = suit(next) else { return false }
        // An empty foundation (nil top) accepts only an Ace.
        guard let top else { return nextRank == Rank.ace.rawValue }
        guard let ontoRank = rankValue(top), let ontoSuit = suit(top) else { return false }
        return nextSuit == ontoSuit && nextRank == ontoRank + 1
    }

    /// Whether `face` is a King — the only card (or sequence lead) that may fill an empty tableau pile
    /// (R-KLON-1.4).
    static func isKing(_ face: CardFace) -> Bool {
        rankValue(face) == Rank.king.rawValue
    }
}
