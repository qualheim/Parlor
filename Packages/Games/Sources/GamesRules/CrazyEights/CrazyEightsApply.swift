// Crazy Eights move helpers — the per-action state transitions used by `apply` (R-CE-2, R-CE-4;
// R-ENG-5.4).
//
// Each helper validates its own move (so `apply` stays a dispatch table and a hand-crafted action can't
// bypass a check), mutates a copy of the state, applies any action-card effect, advances the turn, and
// returns the ordered events the move produced. When a player empties their hand the hand ends and a
// `handEnded` event carries the outcome (R-CE-3.1).
//
// TURN ADVANCEMENT + ACTION CARDS (R-CE-4.1, option). With action cards OFF the turn simply passes to
// the next seat in the current direction and nothing else changes. With action cards ON:
//
//   • a 2 sets `pendingDraw += 2` and passes to the next seat, who must pay the draw or stack their own
//     2 (R-CE-4.1); 2s therefore stack;
//   • a Jack skips the next seat — the turn passes two seats along (R-CE-4.1). See Q-4: in a 2-player
//     game a skip returns the turn to the player who played it (they play again);
//   • an Ace reverses `direction` before advancing (R-CE-4.1). See Q-4: in a 2-player game a reverse
//     also returns the turn to the player who played it, matching the skip behavior.
//
// The starter card's own action effect never applies to the first player (Q-5): `initialState` sets no
// pending draw and clockwise direction regardless of the starter's rank.

import EngineCore
import Foundation

extension CrazyEights {

    // MARK: - Play a non-8 card (R-CE-2.1)

    func playCard(_ state: CrazyEightsState, seat: SeatID, card: PieceID)
        -> Result<(CrazyEightsState, [GameEvent]), RuleViolation>
    {
        guard let hand = state.hand(of: seat), hand.contents.contains(card),
            let face = state.face(of: card)
        else {
            return .failure(
                RuleViolation(code: "not-in-hand", reason: "That card is not in your hand."))
        }
        // An 8 must be played via `playEight` so a suit is named (R-CE-2.2).
        guard !CrazyEightsCard.isEight(face) else {
            return .failure(
                RuleViolation(
                    code: "eight-needs-suit", reason: "An 8 is wild — name a suit when you play it."
                ))
        }

        // A pending draw-two (action cards on) restricts play to stacking another 2 (R-CE-4.1).
        if state.pendingDraw > 0 {
            guard CrazyEightsCard.isDrawTwo(face) else {
                return .failure(
                    RuleViolation(
                        code: "must-cover-draw",
                        reason: "You must draw \(state.pendingDraw) or stack a 2."))
            }
        } else {
            guard
                CrazyEightsCard.isPlayable(
                    face, activeSuit: state.activeSuit, topFace: state.topDiscardFace)
            else {
                return .failure(Self.matchViolation(activeSuit: state.activeSuit))
            }
        }

        var new = state
        var events: [GameEvent] = []
        Self.moveToDiscard(card, from: seat, in: &new, events: &events)
        // A non-8 sets the active suit to its own suit (R-CE-2.1).
        new.activeSuit = CrazyEightsCard.suit(face) ?? new.activeSuit

        // If this empties the hand, the player goes out — end the hand (R-CE-3.1).
        if Self.handEmpty(seat, in: new) {
            events.append(.handEnded(outcome(new)))
            return .success((new, events))
        }

        applyActionAndAdvance(face: face, seat: seat, in: &new, events: &events)
        return .success((new, events))
    }

    // MARK: - Play a wild 8 (R-CE-2.2)

    func playEight(_ state: CrazyEightsState, seat: SeatID, card: PieceID, namedSuit: Suit)
        -> Result<(CrazyEightsState, [GameEvent]), RuleViolation>
    {
        guard let hand = state.hand(of: seat), hand.contents.contains(card),
            let face = state.face(of: card)
        else {
            return .failure(
                RuleViolation(code: "not-in-hand", reason: "That card is not in your hand."))
        }
        guard CrazyEightsCard.isEight(face) else {
            return .failure(
                RuleViolation(code: "not-an-eight", reason: "Only an 8 may name a suit."))
        }
        // An 8 cannot be played to cover a pending draw-two (only a 2 stacks) (R-CE-4.1).
        guard state.pendingDraw == 0 else {
            return .failure(
                RuleViolation(
                    code: "must-cover-draw",
                    reason: "You must draw \(state.pendingDraw) or stack a 2."))
        }

        var new = state
        var events: [GameEvent] = []
        Self.moveToDiscard(card, from: seat, in: &new, events: &events)
        // The 8 names the suit to follow — this is the whole point of the wild 8 (R-CE-2.2).
        new.activeSuit = namedSuit
        events.append(.suitNamed(namedSuit, by: seat))

        if Self.handEmpty(seat, in: new) {
            events.append(.handEnded(outcome(new)))
            return .success((new, events))
        }

        // An 8 is not itself an action card (Q-4: an 8 is only ever wild) — advance normally.
        Self.advanceTurn(in: &new, from: seat, skip: false, events: &events)
        return .success((new, events))
    }

    // MARK: - Draw (R-CE-2.3, R-CE-2.4, R-CE-4.1)

    func draw(_ state: CrazyEightsState, seat: SeatID)
        -> Result<(CrazyEightsState, [GameEvent]), RuleViolation>
    {
        var new = state
        var events: [GameEvent] = []

        // Paying a pending draw-two (action cards on): draw exactly that many, then pass (R-CE-4.1).
        if new.pendingDraw > 0 {
            let owed = new.pendingDraw
            for _ in 0..<owed {
                guard Self.drawOne(seat: seat, in: &new, events: &events) != nil else { break }
            }
            new.pendingDraw = 0
            Self.advanceTurn(in: &new, from: seat, skip: false, events: &events)
            return .success((new, events))
        }

        guard Self.canDraw(new) else {
            return .failure(
                RuleViolation(
                    code: "cannot-draw", reason: "The stock is empty and cannot be refilled."))
        }

        switch new.options.drawMode {
        case .drawOneThenPass:
            // Draw exactly one and pass, whether or not it is playable (R-CE-2.3).
            _ = Self.drawOne(seat: seat, in: &new, events: &events)
            Self.advanceTurn(in: &new, from: seat, skip: false, events: &events)
            return .success((new, events))

        case .drawUntilCanPlay:
            // Keep drawing until a playable card appears; that draw ends the turn (the player may then
            // play on a later turn — modeled as: draw stops at the first playable card, turn passes).
            // Q-3: when the stock empties and reshuffle is off, drawing simply stops — no infinite draw.
            while Self.canDraw(new) {
                guard let drawn = Self.drawOne(seat: seat, in: &new, events: &events) else { break }
                if let face = new.face(of: drawn),
                    CrazyEightsCard.isPlayable(
                        face, activeSuit: new.activeSuit, topFace: new.topDiscardFace)
                {
                    break
                }
            }
            Self.advanceTurn(in: &new, from: seat, skip: false, events: &events)
            return .success((new, events))
        }
    }

    // MARK: - Pass (R-CE-2.4, Q-3)

    func pass(_ state: CrazyEightsState, seat: SeatID)
        -> Result<(CrazyEightsState, [GameEvent]), RuleViolation>
    {
        // A pass is legal only when the player genuinely cannot draw or play (Q-3: empty stock, no
        // reshuffle, nothing playable).
        guard !Self.canDraw(state), state.pendingDraw == 0 else {
            return .failure(
                RuleViolation(
                    code: "must-act", reason: "You still have a legal move — you cannot pass."))
        }
        let top = state.topDiscardFace
        if let hand = state.hand(of: seat),
            hand.contents.contains(where: {
                guard let f = state.face(of: $0) else { return false }
                return CrazyEightsCard.isPlayable(f, activeSuit: state.activeSuit, topFace: top)
            })
        {
            return .failure(
                RuleViolation(
                    code: "must-play", reason: "You have a playable card — you cannot pass."))
        }
        var new = state
        var events: [GameEvent] = []
        Self.advanceTurn(in: &new, from: seat, skip: false, events: &events)
        return .success((new, events))
    }

    // MARK: - Shared transitions

    /// Move `card` from `seat`'s hand to the top of the discard, emitting a `pieceMoved`.
    fileprivate static func moveToDiscard(
        _ card: PieceID, from seat: SeatID, in state: inout CrazyEightsState,
        events: inout [GameEvent]
    ) {
        guard let handIdx = state.seatIndex(of: seat) else { return }
        state.hands[handIdx].contents.removeAll { $0 == card }
        state.discard.contents.append(card)
        state.discard.faceUp = [card]  // only the new top is exposed by the topCardOnly policy
        events.append(
            .pieceMoved(
                PieceMoveDescriptor(
                    piece: card, from: CrazyEightsZone.hand(handIdx), to: CrazyEightsZone.discardID,
                    toIndex: state.discard.contents.count - 1, faceUp: true)))
    }

    /// Draw the top card of the stock into `seat`'s hand, reshuffling the discards (except the top) into
    /// a fresh stock first if the stock is empty and `reshuffleDiscards` is on (R-CE-2.4). Returns the
    /// drawn `PieceID`, or `nil` if no card could be drawn.
    @discardableResult
    fileprivate static func drawOne(
        seat: SeatID, in state: inout CrazyEightsState, events: inout [GameEvent]
    ) -> PieceID? {
        if state.stock.contents.isEmpty {
            guard state.options.stockOut == .reshuffleDiscards, state.discard.contents.count > 1
            else { return nil }
            reshuffleDiscards(in: &state, events: &events)
        }
        guard let card = state.stock.contents.popLast(), let handIdx = state.seatIndex(of: seat)
        else { return nil }
        state.hands[handIdx].contents.append(card)
        events.append(
            .pieceMoved(
                PieceMoveDescriptor(
                    piece: card, from: CrazyEightsZone.stockID, to: CrazyEightsZone.hand(handIdx),
                    toIndex: state.hands[handIdx].contents.count - 1, faceUp: false)))
        return card
    }

    /// Reshuffle the discard pile — every card except the current top — back into a fresh stock
    /// (R-CE-2.4). The active suit and top discard are unchanged. Deterministic ordering: the recycled
    /// cards keep their pre-reshuffle order (a stable rebuild, not a re-randomization — replay stays
    /// exact without a fresh seed, which the hand does not carry).
    fileprivate static func reshuffleDiscards(
        in state: inout CrazyEightsState, events: inout [GameEvent]
    ) {
        guard let top = state.discard.contents.last, state.discard.contents.count > 1 else {
            return
        }
        let recycled = Array(state.discard.contents.dropLast())
        state.discard.contents = [top]
        state.discard.faceUp = [top]
        // The recycled cards become the new stock beneath (front of the array = bottom).
        state.stock.contents = recycled + state.stock.contents
        for card in recycled {
            events.append(
                .pieceMoved(
                    PieceMoveDescriptor(
                        piece: card, from: CrazyEightsZone.discardID, to: CrazyEightsZone.stockID,
                        toIndex: 0, faceUp: false)))
        }
    }

    /// Apply the just-played `face`'s action-card effect (if the option is on) and advance the turn
    /// accordingly (R-CE-4.1). With action cards off, this simply advances to the next seat.
    fileprivate func applyActionAndAdvance(
        face: CardFace, seat: SeatID, in state: inout CrazyEightsState, events: inout [GameEvent]
    ) {
        guard state.options.actionCards else {
            Self.advanceTurn(in: &state, from: seat, skip: false, events: &events)
            return
        }
        if CrazyEightsCard.isReverse(face) {
            // Ace reverses direction, then the turn passes in the new direction (R-CE-4.1).
            state.direction = state.direction.reversed
            Self.advanceTurn(in: &state, from: seat, skip: false, events: &events)
        } else if CrazyEightsCard.isSkip(face) {
            // Jack skips the next seat (R-CE-4.1).
            Self.advanceTurn(in: &state, from: seat, skip: true, events: &events)
        } else if CrazyEightsCard.isDrawTwo(face) {
            // 2 makes the next seat owe two more cards (2s stack) and passes to them (R-CE-4.1).
            state.pendingDraw += 2
            Self.advanceTurn(in: &state, from: seat, skip: false, events: &events)
        } else {
            Self.advanceTurn(in: &state, from: seat, skip: false, events: &events)
        }
    }

    /// Advance the turn from `seat` in the current direction, skipping one extra seat when `skip` is true
    /// (a Jack) (R-CE-4.1). Emits `turnChanged`.
    fileprivate static func advanceTurn(
        in state: inout CrazyEightsState, from seat: SeatID, skip: Bool, events: inout [GameEvent]
    ) {
        let steps = skip ? 2 : 1
        let next = state.seat(after: seat, steps: steps)
        state.turn = next
        events.append(.turnChanged(to: next))
    }

    /// Whether `seat`'s hand is empty in `state` — the player has gone out (R-CE-3.1).
    fileprivate static func handEmpty(_ seat: SeatID, in state: CrazyEightsState) -> Bool {
        state.hand(of: seat)?.contents.isEmpty ?? false
    }

    // MARK: - Violations

    /// The violation for a card that matches neither the active suit nor the top discard's rank
    /// (R-CE-2.1).
    static func matchViolation(activeSuit: Suit) -> RuleViolation {
        RuleViolation(
            code: "no-match",
            reason: "Play a card matching the \(activeSuit.rawValue) suit or the top card's rank.")
    }
}
