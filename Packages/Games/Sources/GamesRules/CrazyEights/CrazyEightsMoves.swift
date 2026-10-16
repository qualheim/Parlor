// Crazy Eights legal-action enumeration and the `apply` dispatch (R-CE-2, R-CE-4; R-ENG-5.3/5.4).
//
// `legalActions` lists every move the seat to move may make right now — it drives legal-target
// highlighting (R-TABLE-3.6), bounds AI/search, and is the ground truth the scenario suite (task 4.6)
// checks against the rules doc. `apply` is the single transition function (in CrazyEightsApply.swift): it
// re-validates the action, produces the next state plus the ordered `GameEvent`s the move caused, or
// returns a typed `RuleViolation` whose `reason` becomes the gentle spring-back caption (R-TABLE-4.1,
// R-NFR-QUAL.1).
//
// Both are pure functions of the state; neither mutates in place (R-ENG-5.4).

import EngineCore
import Foundation

extension CrazyEights {

    // MARK: - Legal actions (R-ENG-5.3)

    /// Every legal action `seat` may take in `state` (R-ENG-5.3). Empty for any seat other than the one
    /// to move, and empty in a terminal state.
    public func legalActions(for seat: SeatID, in state: CrazyEightsState) -> [CrazyEightsAction] {
        guard seat == state.turn, !isTerminal(state) else { return [] }
        guard let hand = state.hand(of: seat) else { return [] }

        // A pending draw-two (action cards on) forces the player to either pay it by drawing, or — if
        // they hold a 2 — stack it (R-CE-4.1). No other play is legal while a draw is pending.
        if state.pendingDraw > 0 {
            var forced: [CrazyEightsAction] = [.draw]
            for card in hand.contents {
                guard let face = state.face(of: card) else { continue }
                if CrazyEightsCard.isDrawTwo(face) { forced.append(.play(card: card)) }
            }
            return forced
        }

        var actions: [CrazyEightsAction] = []
        let top = state.topDiscardFace

        // Every playable card in hand (R-CE-2.1). An 8 is wild and yields one `playEight` per suit the
        // player may name (R-CE-2.2); every other playable card yields a single `play`.
        for card in hand.contents {
            guard let face = state.face(of: card) else { continue }
            guard CrazyEightsCard.isPlayable(face, activeSuit: state.activeSuit, topFace: top)
            else {
                continue
            }
            if CrazyEightsCard.isEight(face) {
                for suit in Suit.allCases {
                    actions.append(.playEight(card: card, namedSuit: suit))
                }
            } else {
                actions.append(.play(card: card))
            }
        }

        // Drawing: legal when the stock has cards, or when the stock is empty but the discards can
        // reshuffle into a fresh stock (R-CE-2.3, R-CE-2.4).
        if Self.canDraw(state) {
            actions.append(.draw)
        } else if actions.isEmpty {
            // Stock exhausted, no reshuffle, and nothing to play: the player passes (R-CE-2.4; Q-3 — no
            // infinite draw when the stock is empty and reshuffle is off).
            actions.append(.pass)
        }

        return actions
    }

    // MARK: - Predicates

    /// Whether the current player may draw: the stock has cards, or the stock is empty but there are
    /// enough discards (more than the top card) to reshuffle into a fresh stock under
    /// `reshuffleDiscards` (R-CE-2.3, R-CE-2.4).
    static func canDraw(_ state: CrazyEightsState) -> Bool {
        if !state.stock.contents.isEmpty { return true }
        return state.options.stockOut == .reshuffleDiscards && state.discard.contents.count > 1
    }

    /// Whether the hand is stuck: no seat can play and the stock cannot yield another card (empty and no
    /// reshuffle available). Used only for the `endHand` terminal test (R-CE-2.4).
    static func handIsStuck(_ state: CrazyEightsState) -> Bool {
        // If a draw is still possible the hand is not stuck.
        if canDraw(state) { return false }
        // No draw possible: stuck iff no seat holds a playable card.
        let top = state.topDiscardFace
        for hand in state.hands {
            for card in hand.contents {
                guard let face = state.face(of: card) else { continue }
                if CrazyEightsCard.isPlayable(face, activeSuit: state.activeSuit, topFace: top) {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - apply dispatch (R-ENG-5.4)

    /// Apply `action` for `seat`, returning the next state + ordered events, or a `RuleViolation`
    /// (R-ENG-5.4). Pure: operates on a copy of `state`.
    public func apply(_ action: CrazyEightsAction, by seat: SeatID, to state: CrazyEightsState)
        -> Result<(CrazyEightsState, [GameEvent]), RuleViolation>
    {
        guard !isTerminal(state) else {
            return .failure(RuleViolation(code: "hand-over", reason: "The hand is already over."))
        }
        guard seat == state.turn else {
            return .failure(
                RuleViolation(code: "not-your-turn", reason: "It is not your turn to play."))
        }

        switch action {
        case .play(let card):
            return playCard(state, seat: seat, card: card)
        case .playEight(let card, let namedSuit):
            return playEight(state, seat: seat, card: card, namedSuit: namedSuit)
        case .draw:
            return draw(state, seat: seat)
        case .pass:
            return pass(state, seat: seat)
        }
    }
}
