// Klondike legal-action enumeration and the `apply` transition (R-KLON-1, R-ENG-5.3/5.4).
//
// `legalActions` lists every move the seat may make right now — it drives legal-target highlighting
// (R-TABLE-3.6), bounds AI/search, and is the ground truth the scenario suite (task 3.2) checks against
// the rules doc. `apply` is the single transition function: it re-validates the action (so a stale or
// hand-crafted action can't slip through), produces the next state plus the ordered `GameEvent`s the
// move caused, or returns a typed `RuleViolation` whose `reason` becomes the gentle spring-back caption
// (R-TABLE-4.1, R-NFR-QUAL.1).
//
// Both are pure functions of the state; neither mutates in place (R-ENG-5.4). The move helpers below do
// the piece-shuffling on a copied state and thread the score/event side effects through a small result.

import EngineCore
import Foundation

extension Klondike {

    // MARK: - Legal actions (R-ENG-5.3)

    /// Every legal action the seat may take in `state` (R-ENG-5.3). Empty for any seat other than the
    /// single Klondike seat.
    public func legalActions(for seat: SeatID, in state: KlondikeState) -> [KlondikeAction] {
        guard seat == klondikeSeat, !isTerminal(state) else { return [] }
        var actions: [KlondikeAction] = []

        // Stock: draw if it has cards; otherwise recycle the waste if passes remain and waste is
        // non-empty (R-KLON-2.1, R-KLON-2.3).
        if !state.stock.contents.isEmpty {
            actions.append(.drawFromStock)
        } else if !state.waste.contents.isEmpty, Self.canRecycle(state) {
            actions.append(.recycleWaste)
        }

        // Waste top → foundation / tableau.
        if let wasteTop = state.waste.contents.last, let face = state.face(of: wasteTop) {
            for (fi, foundation) in state.foundations.enumerated()
            where KlondikeCard.foundationFollows(
                face, onto: Self.topFace(of: foundation, in: state))
            {
                actions.append(.wasteToFoundation(toFoundation: fi))
            }
            for ti in state.tableau.indices
            where Self.canPlaceOnTableau(face, pileIndex: ti, in: state) {
                actions.append(.wasteToTableau(toPile: ti))
            }
        }

        // Tableau top → foundation.
        for (ti, pile) in state.tableau.enumerated() {
            guard let top = pile.contents.last, pile.isFaceUp(top), let face = state.face(of: top)
            else { continue }
            for (fi, foundation) in state.foundations.enumerated()
            where KlondikeCard.foundationFollows(
                face, onto: Self.topFace(of: foundation, in: state))
            {
                actions.append(.tableauToFoundation(fromPile: ti, toFoundation: fi))
            }
        }

        // Tableau face-up run → another tableau pile (movable sequence, R-KLON-1.3/1.4).
        for (fromPile, pile) in state.tableau.enumerated() {
            for card in Self.faceUpRunLeads(of: pile, in: state) {
                guard let leadFace = state.face(of: card) else { continue }
                for toPile in state.tableau.indices
                where toPile != fromPile
                    && Self.canPlaceOnTableau(leadFace, pileIndex: toPile, in: state)
                {
                    actions.append(
                        .tableauToTableau(fromPile: fromPile, card: card, toPile: toPile))
                }
            }
        }

        // Foundation top → tableau (R-KLON-1.5).
        for (fi, foundation) in state.foundations.enumerated() {
            guard let top = foundation.contents.last, let face = state.face(of: top) else {
                continue
            }
            for toPile in state.tableau.indices
            where Self.canPlaceOnTableau(face, pileIndex: toPile, in: state) {
                actions.append(.foundationToTableau(fromFoundation: fi, toPile: toPile))
            }
        }

        return actions
    }

    // MARK: - Placement predicates

    /// The face of a zone's top piece, or `nil` if empty/unknown.
    static func topFace(of zone: Zone, in state: KlondikeState) -> CardFace? {
        guard let top = zone.contents.last else { return nil }
        return state.face(of: top)
    }

    /// Whether `face` (a single card or the lead of a run) may be placed on tableau pile `pileIndex`:
    /// onto an empty pile only if it is a King (R-KLON-1.4); otherwise it must build down in alternating
    /// color on the current top (R-KLON-1.2).
    static func canPlaceOnTableau(_ face: CardFace, pileIndex: Int, in state: KlondikeState) -> Bool
    {
        let pile = state.tableau[pileIndex]
        guard let topFace = topFace(of: pile, in: state) else {
            return KlondikeCard.isKing(face)  // empty pile: only a King (or King-led run)
        }
        return KlondikeCard.tableauFollows(face, onto: topFace)
    }

    /// The lead cards of every *valid* face-up run in `pile` — each face-up card from which the run down
    /// to the pile's top is a proper descending, alternating-color sequence (R-KLON-1.3). Moving from
    /// such a lead carries the whole run as a unit.
    static func faceUpRunLeads(of pile: Zone, in state: KlondikeState) -> [PieceID] {
        // Face-up cards, in pile order (bottom→top of the face-up region).
        let faceUp = pile.contents.filter { pile.isFaceUp($0) }
        guard !faceUp.isEmpty else { return [] }
        var leads: [PieceID] = []
        // A lead at position k is valid if faceUp[k], faceUp[k+1], … form a descending alt-color run.
        for start in faceUp.indices {
            var valid = true
            var i = start
            while i < faceUp.count - 1 {
                guard
                    let upper = state.face(of: faceUp[i]),
                    let lower = state.face(of: faceUp[i + 1]),
                    KlondikeCard.tableauFollows(lower, onto: upper)
                else {
                    valid = false
                    break
                }
                i += 1
            }
            if valid { leads.append(faceUp[start]) }
        }
        return leads
    }

    /// Whether the waste may currently be recycled into the stock: passes limit not yet reached
    /// (R-KLON-2.3). The effective limit accounts for Vegas's pass overrides.
    static func canRecycle(_ state: KlondikeState) -> Bool {
        guard let maxPasses = state.options.effectiveStockPasses.maxPasses else { return true }
        return state.passes < maxPasses
    }

    // MARK: - apply (R-ENG-5.4)

    /// Apply `action` for `seat`, returning the next state + ordered events, or a `RuleViolation`
    /// (R-ENG-5.4). Pure: operates on a copy of `state`.
    public func apply(_ action: KlondikeAction, by seat: SeatID, to state: KlondikeState)
        -> Result<(KlondikeState, [GameEvent]), RuleViolation>
    {
        guard seat == klondikeSeat else {
            return .failure(
                RuleViolation(code: "not-your-seat", reason: "Only the player may move."))
        }
        guard !isTerminal(state) else {
            return .failure(RuleViolation(code: "game-over", reason: "The game is already won."))
        }

        switch action {
        case .drawFromStock:
            return drawFromStock(state)
        case .recycleWaste:
            return recycleWaste(state)
        case .wasteToTableau(let toPile):
            return moveWasteToTableau(state, toPile: toPile)
        case .wasteToFoundation(let toFoundation):
            return moveWasteToFoundation(state, toFoundation: toFoundation)
        case .tableauToTableau(let fromPile, let card, let toPile):
            return moveTableauToTableau(state, fromPile: fromPile, card: card, toPile: toPile)
        case .tableauToFoundation(let fromPile, let toFoundation):
            return moveTableauToFoundation(state, fromPile: fromPile, toFoundation: toFoundation)
        case .foundationToTableau(let fromFoundation, let toPile):
            return moveFoundationToTableau(state, fromFoundation: fromFoundation, toPile: toPile)
        }
    }
}
