// Klondike move helpers — the per-action state transitions used by `apply` (R-KLON-1, R-ENG-5.4).
//
// Each helper validates its own move (so `apply` stays a dispatch table and a hand-crafted action can't
// bypass a check), mutates a copy of the state, applies the scoring delta for the chosen scheme, and
// returns the ordered events the move produced. Scoring lives in one place per scheme:
//
//   • Vegas — +5 for every card that reaches a foundation, −? for a foundation→tableau retreat is not
//     specified for Vegas (Vegas scores money per foundation card only), so only foundation gains apply;
//   • Standard — reads the named constants in `KlondikeStandardScoring` (Q-1 NEEDS REVIEW);
//   • None — no score delta ever.
//
// A move that exposes a face-down tableau top turns it face-up (a rule, not the auto-flip *toggle* which
// is task 3.5) and emits `pieceFlipped`; Standard awards the flip its documented value. When the last
// card lands home, `handEnded` is emitted with the win outcome.

import EngineCore
import Foundation

extension Klondike {

    // MARK: - Scoring

    /// The score delta for one card reaching a foundation, under the active scheme.
    fileprivate static func foundationGain(_ options: KlondikeOptions) -> Int {
        switch options.scoring {
        case .vegas: return 5
        case .standard: return KlondikeStandardScoring.foundationDelta
        case .none: return 0
        }
    }

    /// The score delta for a card retreating from a foundation to the tableau (R-KLON-1.5).
    fileprivate static func foundationRetreat(_ options: KlondikeOptions) -> Int {
        switch options.scoring {
        case .standard: return KlondikeStandardScoring.foundationToTableau
        // Vegas scores only cards *sent* to a foundation; retreating does not refund. None: no score.
        case .vegas, .none: return 0
        }
    }

    /// The score delta for turning a waste card onto the tableau, under the active scheme.
    fileprivate static func wasteToTableauGain(_ options: KlondikeOptions) -> Int {
        options.scoring == .standard ? KlondikeStandardScoring.wasteToTableau : 0
    }

    /// The score delta for turning a face-down tableau card face-up, under the active scheme.
    fileprivate static func flipGain(_ options: KlondikeOptions) -> Int {
        options.scoring == .standard ? KlondikeStandardScoring.tableauCardFlipped : 0
    }

    /// The score delta for recycling the waste, under the active scheme (a penalty in Standard).
    fileprivate static func recycleDelta(_ options: KlondikeOptions) -> Int {
        options.scoring == .standard ? KlondikeStandardScoring.wasteRecyclePenalty : 0
    }

    /// Apply a score `delta` to `state`, appending a `scoreChanged` event when it is non-zero.
    fileprivate func score(_ delta: Int, into state: inout KlondikeState, events: inout [GameEvent])
    {
        guard delta != 0 else { return }
        state.score += delta
        events.append(.scoreChanged(seat: klondikeSeat, delta: delta, total: state.score))
    }

    /// If the top card of tableau pile `index` is face-down, turn it face-up: emit `pieceFlipped`, apply
    /// the flip score, and record it (the exposed-top rule; the auto-flip *toggle* is task 3.5).
    fileprivate func flipExposedTop(
        pileIndex index: Int, in state: inout KlondikeState, events: inout [GameEvent]
    ) {
        guard let top = state.tableau[index].contents.last, !state.tableau[index].isFaceUp(top)
        else { return }
        state.tableau[index].faceUp.insert(top)
        events.append(.pieceFlipped(top, faceUp: true))
        score(Self.flipGain(state.options), into: &state, events: &events)
    }

    /// Append `handEnded` if the move completed the game.
    fileprivate func appendTerminalIfWon(_ state: KlondikeState, events: inout [GameEvent]) {
        if isTerminal(state) { events.append(.handEnded(outcome(state))) }
    }

    // MARK: - Stock

    func drawFromStock(_ state: KlondikeState)
        -> Result<(KlondikeState, [GameEvent]), RuleViolation>
    {
        guard !state.stock.contents.isEmpty else {
            return .failure(
                RuleViolation(
                    code: "stock-empty", reason: "The stock is empty — recycle the waste."))
        }
        var new = state
        var events: [GameEvent] = []
        let drawCount = min(state.options.drawCount.rawValue, new.stock.contents.count)
        // Draw from the top of the stock (last element) to the top of the waste, preserving order.
        for _ in 0..<drawCount {
            let card = new.stock.contents.removeLast()
            new.stock.faceUp.remove(card)
            new.waste.contents.append(card)
            let idx = new.waste.contents.count - 1
            events.append(
                .pieceMoved(
                    PieceMoveDescriptor(
                        piece: card, from: KlondikeZone.stockID, to: KlondikeZone.wasteID,
                        toIndex: idx, faceUp: true)))
        }
        return .success((new, events))
    }

    func recycleWaste(_ state: KlondikeState)
        -> Result<(KlondikeState, [GameEvent]), RuleViolation>
    {
        guard state.stock.contents.isEmpty else {
            return .failure(
                RuleViolation(code: "stock-not-empty", reason: "Draw the stock before recycling."))
        }
        guard !state.waste.contents.isEmpty else {
            return .failure(
                RuleViolation(code: "waste-empty", reason: "There is nothing to recycle."))
        }
        guard Self.canRecycle(state) else {
            return .failure(
                RuleViolation(code: "no-passes-left", reason: "No more passes through the stock."))
        }
        var new = state
        var events: [GameEvent] = []
        // Waste returns to the stock in reverse, so the next draw re-turns them in the original order.
        let returning = Array(new.waste.contents.reversed())
        new.waste.contents.removeAll()
        for (offset, card) in returning.enumerated() {
            new.stock.contents.append(card)
            events.append(
                .pieceMoved(
                    PieceMoveDescriptor(
                        piece: card, from: KlondikeZone.wasteID, to: KlondikeZone.stockID,
                        toIndex: offset, faceUp: false)))
        }
        new.passes += 1
        score(Self.recycleDelta(new.options), into: &new, events: &events)
        return .success((new, events))
    }

    // MARK: - Waste moves

    func moveWasteToTableau(_ state: KlondikeState, toPile: Int)
        -> Result<(KlondikeState, [GameEvent]), RuleViolation>
    {
        guard state.tableau.indices.contains(toPile) else {
            return .failure(
                RuleViolation(code: "no-such-pile", reason: "That pile does not exist."))
        }
        guard let card = state.waste.contents.last, let face = state.face(of: card) else {
            return .failure(RuleViolation(code: "waste-empty", reason: "The waste is empty."))
        }
        guard Self.canPlaceOnTableau(face, pileIndex: toPile, in: state) else {
            return .failure(Self.tableauViolation(face: face, pileIndex: toPile, in: state))
        }
        var new = state
        var events: [GameEvent] = []
        new.waste.contents.removeLast()
        new.tableau[toPile].contents.append(card)
        new.tableau[toPile].faceUp.insert(card)
        events.append(
            .pieceMoved(
                PieceMoveDescriptor(
                    piece: card, from: KlondikeZone.wasteID, to: KlondikeZone.tableau(toPile),
                    toIndex: new.tableau[toPile].contents.count - 1, faceUp: true)))
        score(Self.wasteToTableauGain(new.options), into: &new, events: &events)
        return .success((new, events))
    }

    func moveWasteToFoundation(_ state: KlondikeState, toFoundation: Int)
        -> Result<(KlondikeState, [GameEvent]), RuleViolation>
    {
        guard state.foundations.indices.contains(toFoundation) else {
            return .failure(
                RuleViolation(code: "no-such-foundation", reason: "That foundation does not exist.")
            )
        }
        guard let card = state.waste.contents.last, let face = state.face(of: card) else {
            return .failure(RuleViolation(code: "waste-empty", reason: "The waste is empty."))
        }
        guard
            KlondikeCard.foundationFollows(
                face, onto: Self.topFace(of: state.foundations[toFoundation], in: state))
        else {
            return .failure(Self.foundationViolation)
        }
        var new = state
        var events: [GameEvent] = []
        new.waste.contents.removeLast()
        new.foundations[toFoundation].contents.append(card)
        events.append(
            .pieceMoved(
                PieceMoveDescriptor(
                    piece: card, from: KlondikeZone.wasteID,
                    to: KlondikeZone.foundation(toFoundation),
                    toIndex: new.foundations[toFoundation].contents.count - 1, faceUp: true)))
        score(Self.foundationGain(new.options), into: &new, events: &events)
        appendTerminalIfWon(new, events: &events)
        return .success((new, events))
    }

    // MARK: - Tableau moves

    func moveTableauToTableau(_ state: KlondikeState, fromPile: Int, card: PieceID, toPile: Int)
        -> Result<(KlondikeState, [GameEvent]), RuleViolation>
    {
        guard state.tableau.indices.contains(fromPile), state.tableau.indices.contains(toPile)
        else {
            return .failure(
                RuleViolation(code: "no-such-pile", reason: "That pile does not exist."))
        }
        guard fromPile != toPile else {
            return .failure(RuleViolation(code: "same-pile", reason: "That is the same pile."))
        }
        let source = state.tableau[fromPile]
        guard let startIdx = source.contents.firstIndex(of: card), source.isFaceUp(card) else {
            return .failure(
                RuleViolation(code: "not-face-up", reason: "You can only move a face-up card."))
        }
        // The run is everything from `card` to the top of the source pile; it must be a valid sequence.
        let run = Array(source.contents[startIdx...])
        guard Self.isValidRun(run, in: state) else {
            return .failure(
                RuleViolation(code: "not-a-sequence", reason: "That is not a movable sequence."))
        }
        guard let leadFace = state.face(of: card) else {
            return .failure(RuleViolation(code: "unknown-card", reason: "Unknown card."))
        }
        guard Self.canPlaceOnTableau(leadFace, pileIndex: toPile, in: state) else {
            return .failure(Self.tableauViolation(face: leadFace, pileIndex: toPile, in: state))
        }
        var new = state
        var events: [GameEvent] = []
        new.tableau[fromPile].contents.removeSubrange(startIdx...)
        for id in run { new.tableau[fromPile].faceUp.remove(id) }
        for id in run {
            new.tableau[toPile].contents.append(id)
            new.tableau[toPile].faceUp.insert(id)
            events.append(
                .pieceMoved(
                    PieceMoveDescriptor(
                        piece: id, from: KlondikeZone.tableau(fromPile),
                        to: KlondikeZone.tableau(toPile),
                        toIndex: new.tableau[toPile].contents.count - 1, faceUp: true)))
        }
        flipExposedTop(pileIndex: fromPile, in: &new, events: &events)
        return .success((new, events))
    }

    func moveTableauToFoundation(_ state: KlondikeState, fromPile: Int, toFoundation: Int)
        -> Result<(KlondikeState, [GameEvent]), RuleViolation>
    {
        guard state.tableau.indices.contains(fromPile) else {
            return .failure(
                RuleViolation(code: "no-such-pile", reason: "That pile does not exist."))
        }
        guard state.foundations.indices.contains(toFoundation) else {
            return .failure(
                RuleViolation(code: "no-such-foundation", reason: "That foundation does not exist.")
            )
        }
        guard let card = state.tableau[fromPile].contents.last,
            state.tableau[fromPile].isFaceUp(card), let face = state.face(of: card)
        else {
            return .failure(RuleViolation(code: "empty-pile", reason: "There is no card to move."))
        }
        guard
            KlondikeCard.foundationFollows(
                face, onto: Self.topFace(of: state.foundations[toFoundation], in: state))
        else {
            return .failure(Self.foundationViolation)
        }
        var new = state
        var events: [GameEvent] = []
        new.tableau[fromPile].contents.removeLast()
        new.tableau[fromPile].faceUp.remove(card)
        new.foundations[toFoundation].contents.append(card)
        events.append(
            .pieceMoved(
                PieceMoveDescriptor(
                    piece: card, from: KlondikeZone.tableau(fromPile),
                    to: KlondikeZone.foundation(toFoundation),
                    toIndex: new.foundations[toFoundation].contents.count - 1, faceUp: true)))
        score(Self.foundationGain(new.options), into: &new, events: &events)
        flipExposedTop(pileIndex: fromPile, in: &new, events: &events)
        appendTerminalIfWon(new, events: &events)
        return .success((new, events))
    }

    func moveFoundationToTableau(_ state: KlondikeState, fromFoundation: Int, toPile: Int)
        -> Result<(KlondikeState, [GameEvent]), RuleViolation>
    {
        guard state.foundations.indices.contains(fromFoundation) else {
            return .failure(
                RuleViolation(code: "no-such-foundation", reason: "That foundation does not exist.")
            )
        }
        guard state.tableau.indices.contains(toPile) else {
            return .failure(
                RuleViolation(code: "no-such-pile", reason: "That pile does not exist."))
        }
        guard let card = state.foundations[fromFoundation].contents.last,
            let face = state.face(of: card)
        else {
            return .failure(
                RuleViolation(code: "foundation-empty", reason: "That foundation is empty."))
        }
        guard Self.canPlaceOnTableau(face, pileIndex: toPile, in: state) else {
            return .failure(Self.tableauViolation(face: face, pileIndex: toPile, in: state))
        }
        var new = state
        var events: [GameEvent] = []
        new.foundations[fromFoundation].contents.removeLast()
        new.tableau[toPile].contents.append(card)
        new.tableau[toPile].faceUp.insert(card)
        events.append(
            .pieceMoved(
                PieceMoveDescriptor(
                    piece: card, from: KlondikeZone.foundation(fromFoundation),
                    to: KlondikeZone.tableau(toPile),
                    toIndex: new.tableau[toPile].contents.count - 1, faceUp: true)))
        score(Self.foundationRetreat(new.options), into: &new, events: &events)
        return .success((new, events))
    }

    // MARK: - Validation helpers

    /// Whether `run` (in pile order, lead first) is a proper descending, alternating-color sequence
    /// (R-KLON-1.3). A single card is a valid run.
    static func isValidRun(_ run: [PieceID], in state: KlondikeState) -> Bool {
        guard run.count > 1 else { return run.count == 1 }
        for i in 0..<(run.count - 1) {
            guard
                let upper = state.face(of: run[i]), let lower = state.face(of: run[i + 1]),
                KlondikeCard.tableauFollows(lower, onto: upper)
            else { return false }
        }
        return true
    }

    /// A tailored violation for an illegal tableau placement: empty piles want a King (R-KLON-1.4),
    /// otherwise the card must build down in alternating color (R-KLON-1.2).
    static func tableauViolation(face: CardFace, pileIndex: Int, in state: KlondikeState)
        -> RuleViolation
    {
        if topFace(of: state.tableau[pileIndex], in: state) == nil {
            return RuleViolation(
                code: "empty-needs-king", reason: "Only a King can start an empty pile.")
        }
        return RuleViolation(
            code: "wrong-tableau-build",
            reason: "Build down in alternating colors.")
    }

    /// The violation for an illegal foundation placement (R-KLON-1.2).
    static let foundationViolation = RuleViolation(
        code: "wrong-foundation-build",
        reason: "Foundations build up by suit from Ace to King.")
}
