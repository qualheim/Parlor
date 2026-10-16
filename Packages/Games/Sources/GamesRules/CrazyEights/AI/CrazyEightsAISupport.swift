// Crazy Eights AI support — read the redacted view + public log through the information barrier
// (R-AI-1.1, R-CE-5.1, R-CE-5.2, R-CE-5.3).
//
// The AI tiers (Easy/Medium/Hard, in sibling files) all reason from the SAME inputs a human in that seat
// sees: the seat's redacted `PlayerView`, the `PublicLog`, and the legal actions AIKit hands them in a
// `DecisionContext` (Strategy.swift). None of them ever touches authoritative `CrazyEightsState` — the
// barrier is structural (R-AI-1.1). This file is the shared reading layer the tiers compose:
//
//   • decode `AnyGameAction`s back into the concrete `CrazyEightsAction`s a tier compares/scores;
//   • read the seat's own hand faces out of its `ownerOnly` hand zone in the view (visible to it);
//   • read the public top-discard face + the active/named suit (the suit rides in `phase`, R-CE-2.2);
//   • classify actions (is this playing an 8? a draw? a pass?) so a tier can hoard or dump 8s; and
//   • infer opponent suit voids from the public log (a seat that drew instead of playing an available
//     suit is void in it) — the observation the Medium tier tracks (R-CE-5.2) and the Hard determinizer
//     feeds `DeterminizationConstraints` (R-AI-2.2).
//
// Everything here is a pure function of the inputs a strategy legitimately holds. Kept internal to the
// module; the tiers are the public surface.

import AIKit
import EngineCore
import Foundation

// MARK: - Decoded legal actions

/// A legal action paired with its decoded `CrazyEightsAction`, so a tier can inspect and score it while
/// still returning the original `AnyGameAction` the host expects (R-AI-1.1).
struct DecodedCrazyEightsAction {
    /// The type-erased action to return to the host if chosen.
    let erased: AnyGameAction
    /// The concrete action, decoded for inspection/scoring.
    let action: CrazyEightsAction
}

/// Shared readers over the redacted view + public log the Crazy Eights tiers compose (R-AI-1.1).
enum CrazyEightsAI {

    // MARK: - Legal action decoding

    /// Decode a context's legal actions into inspectable `CrazyEightsAction`s, dropping any that do not
    /// decode (there should be none in practice). Preserves order so RNG tie-breaks stay reproducible.
    static func decodedActions(_ legal: [AnyGameAction]) -> [DecodedCrazyEightsAction] {
        legal.compactMap { erased in
            guard let action = try? erased.decode(as: CrazyEightsAction.self) else { return nil }
            return DecodedCrazyEightsAction(erased: erased, action: action)
        }
    }

    // MARK: - Action classification

    /// Whether a decoded action plays an 8 (wild) — the move Easy dumps early and Medium hoards
    /// (R-CE-5.1, R-CE-5.2).
    static func playsEight(_ action: CrazyEightsAction) -> Bool {
        if case .playEight = action { return true }
        return false
    }

    /// Whether a decoded action plays a non-8 card from hand.
    static func playsCard(_ action: CrazyEightsAction) -> Bool {
        if case .play = action { return true }
        return false
    }

    /// Whether a decoded action is a draw.
    static func isDraw(_ action: CrazyEightsAction) -> Bool {
        if case .draw = action { return true }
        return false
    }

    /// The `PieceID` a decoded action plays, if it plays a card (an 8 via `playEight` or a non-8 via
    /// `play`); `nil` for draw/pass.
    static func playedCard(_ action: CrazyEightsAction) -> PieceID? {
        switch action {
        case .play(let card): return card
        case .playEight(let card, _): return card
        case .draw, .pass: return nil
        }
    }

    // MARK: - Reading the seat's own hand (visible in its ownerOnly zone)

    /// The faces of the cards in `seat`'s own hand, read from the redacted view (the seat may see its own
    /// hand, so those pieces are `.known`) (R-CE-1.2). Order matches the view.
    static func handFaces(in view: PlayerView, seat: SeatID) -> [CardFace] {
        handCards(in: view, seat: seat).map(\.face)
    }

    /// The `Card`s (identity + face) in `seat`'s own hand, read from the redacted view (R-CE-1.2).
    static func handCards(in view: PlayerView, seat: SeatID) -> [Card] {
        let handName = CrazyEightsZone.hand
        guard
            let zone = view.zones.first(where: { $0.id.name == handName && $0.id.owner == seat })
        else { return [] }
        return zone.pieces.compactMap { piece in
            guard case .known(.card(let card)) = piece else { return nil }
            return card
        }
    }

    /// A `PieceID → CardFace` table for `seat`'s own hand, so a tier can score a play (which names a
    /// `PieceID`) by the card's real face (R-CE-3.1). Built from the view's visible hand.
    static func handFaceTable(in view: PlayerView, seat: SeatID) -> [PieceID: CardFace] {
        var table: [PieceID: CardFace] = [:]
        for card in handCards(in: view, seat: seat) { table[card.id] = card.face }
        return table
    }

    // MARK: - Reading the public discard + active suit

    /// The public top discard face, read from the `topCardOnly` discard zone in the view (its top card is
    /// `.known` to everyone) (R-CE-2.1). `nil` if the discard is empty or tokenized.
    static func topDiscardFace(in view: PlayerView) -> CardFace? {
        guard let zone = view.zones.first(where: { $0.id.name == CrazyEightsZone.discard })
        else { return nil }
        guard case .known(.card(let card)) = zone.pieces.last else { return nil }
        return card.face
    }

    /// The active/named suit that must be matched right now — public information carried in the view's
    /// `phase` as `"play:<suit>"` (R-CE-2.2). Falls back to the top discard's own suit, then clubs.
    static func activeSuit(in view: PlayerView) -> Suit {
        let raw = view.phase.rawValue
        if let colon = raw.firstIndex(of: ":") {
            let suitRaw = String(raw[raw.index(after: colon)...])
            if let suit = Suit(rawValue: suitRaw) { return suit }
        }
        if let top = topDiscardFace(in: view), case .standard(_, let suit) = top { return suit }
        return .clubs
    }

    // MARK: - Suit counting (name-the-longest-suit, R-CE-5.2)

    /// A histogram of the suits held in `faces`, ignoring 8s (an 8 is wild and belongs to no suit for
    /// the purpose of choosing which suit to commit to) and jokers.
    static func suitCounts(of faces: [CardFace]) -> [Suit: Int] {
        var counts: [Suit: Int] = [:]
        for face in faces {
            guard case .standard(let rank, let suit) = face, rank != .eight else { continue }
            counts[suit, default: 0] += 1
        }
        return counts
    }

    /// The suit the hand is longest in, ignoring 8s — the suit a Medium AI names when it must play an 8
    /// so its remaining cards are most likely playable next turn (R-CE-5.2). Ties broken by the injected
    /// RNG so the choice is varied yet reproducible (R-AI-3.2). Falls back to the current active suit
    /// when the hand holds only 8s (nothing to prefer).
    static func longestSuit(in faces: [CardFace], fallback: Suit, using rng: inout SeededRNG)
        -> Suit
    {
        let counts = suitCounts(of: faces)
        guard !counts.isEmpty else { return fallback }
        let maxCount = counts.values.max() ?? 0
        let leaders = counts.filter { $0.value == maxCount }.map(\.key).sorted {
            $0.rawValue < $1.rawValue
        }
        if leaders.count == 1 { return leaders[0] }
        let index = Int(rng.next() % UInt64(leaders.count))
        return leaders[index]
    }

    // MARK: - Opponent void inference from the public log (R-CE-5.2, R-AI-2.2)

    /// Suits each seat is inferred VOID in, read from the public log (R-CE-5.2).
    ///
    /// A seat that DREW is telling us it could not (or chose not to) play the active suit at that moment —
    /// under the honest "play if you can" model a drawing seat is void in the suit that was active when it
    /// drew. We reconstruct the active suit as the log replays (it changes when an 8 names a suit), and on
    /// every `draw` by a seat, record that seat void in the then-active suit. This is exactly the
    /// observation `DeterminizationConstraints` consumes (R-AI-2.2); the Medium tier reads it to avoid
    /// naming a suit an opponent is known to hold none of.
    static func inferredVoids(from log: PublicLog, startingSuit: Suit) -> [SeatID: Set<Suit>] {
        var voids: [SeatID: Set<Suit>] = [:]
        var active = startingSuit
        for entry in log.actions {
            guard let action = try? entry.action.decode(as: CrazyEightsAction.self) else {
                continue
            }
            switch action {
            case .draw, .pass:
                voids[entry.seat, default: []].insert(active)
            case .play(let card):
                // A non-8 play sets the active suit to its own — but the log's public action carries the
                // piece id, not the face, so we cannot always know the new suit from the log alone. The
                // named suit after an 8 is what matters for voids, and that arrives via `playEight`.
                _ = card
            case .playEight(_, let named):
                active = named
            }
        }
        return voids
    }
}
