// KlondikeTableAdapter — the thin GamesUI wiring that connects Klondike's pure rules/features to the
// generic TableKit interaction seam (R-TABLE-3.3, R-TABLE-3.6; R-KLON-3.3).
//
// TableKit is game-agnostic and must not import GamesRules (R-SESS-1.2): legality, smart destinations,
// and rejections all arrive as DATA/CLOSURES the host supplies (see TableInteraction.swift). Klondike's
// rules live in the pure `GamesRules` module and cannot import TableKit (dependency direction). GamesUI
// is the one module that imports BOTH, so the adapter mapping between them belongs here — nothing in this
// file is a rule; it only translates.
//
// It provides:
//   • `legalTargets(for:in:)` — maps Klondike's `legalActions` for the seat into TableKit `[MoveTarget]`
//     (piece render key → destination zone), for legal-target highlighting (R-TABLE-3.6).
//   • `smartTarget(for:in:)` — maps a `RenderKey` to Klondike's `smartDestination` for double-click
//     smart move (R-TABLE-3.3, R-KLON-3.3).
//   • `interactionInput(for:in:resolve:)` — assembles a `TableInteractionInput` from the above plus a
//     host-provided `resolve` closure that submits the chosen move.
//
// All mapping is pure over `(KlondikeState)`; the smart-move computation itself is `Klondike`'s pure
// `smartDestination(for: PieceID:)`, so this layer only converts `RenderKey ↔ PieceID` and action →
// `MoveTarget`.

import Foundation
import GamesRules
import TableKit

/// The Klondike → TableKit interaction adapter (R-TABLE-3.3, R-TABLE-3.6; R-KLON-3.3). Stateless: every
/// method is a pure function of the current authoritative `KlondikeState`.
public enum KlondikeTableAdapter {

    /// The legal (piece → destination) move targets for the Klondike seat in `state` (R-TABLE-3.6).
    ///
    /// Each of Klondike's `legalActions` that "moves a concrete piece to a concrete zone" becomes one
    /// `MoveTarget` keyed by that piece's `RenderKey`. Stock draw/recycle have no moving *piece* the
    /// player drags, so they are not targets (they are driven by tapping the stock, not by a drag/drop).
    /// A tableau run is represented by its lead piece (TableKit resolves the run from the lead).
    public static func legalTargets(for game: Klondike, in state: KlondikeState) -> [MoveTarget] {
        var targets: [MoveTarget] = []
        for action in game.legalActions(for: klondikeSeat, in: state) {
            guard let (piece, destination) = pieceAndDestination(of: action, in: state) else {
                continue
            }
            targets.append(MoveTarget(piece: .known(piece), destination: destination))
        }
        return targets
    }

    /// The smart double-click destination zone for `piece` in `state`, or `nil` (R-TABLE-3.3, R-KLON-3.3).
    ///
    /// Maps the TableKit `RenderKey` to the real `PieceID` (a hidden token has no known identity to move,
    /// so it yields `nil`) and defers to Klondike's pure `smartDestination`.
    public static func smartTarget(for game: Klondike, piece: RenderKey, in state: KlondikeState)
        -> ZoneID?
    {
        guard case .known(let id) = piece else { return nil }
        return game.smartDestination(for: id, in: state)
    }

    /// Assemble the full `TableInteractionInput` for the current frame (R-TABLE-3): legal targets +
    /// smart-target closure, plus the host's `resolve` closure that actually submits a chosen move.
    ///
    /// `resolve` is supplied by the caller (the screen/host that owns the `GameHost`), because submitting a
    /// move is a session-layer effect, not a pure mapping. The smart-target closure captures a snapshot of
    /// `state`, matching TableKit's per-frame model (the input is rebuilt when the view refreshes).
    public static func interactionInput(
        for game: Klondike,
        in state: KlondikeState,
        resolve: @escaping @Sendable (TableMove) -> MoveResult
    ) -> TableInteractionInput {
        TableInteractionInput(
            legalTargets: legalTargets(for: game, in: state),
            resolve: resolve,
            smartTarget: { key in smartTarget(for: game, piece: key, in: state) }
        )
    }

    // MARK: - Action → (piece, destination) mapping

    /// The moving piece and its destination zone for a Klondike action, or `nil` for actions with no
    /// dragged piece (stock draw/recycle).
    static func pieceAndDestination(of action: KlondikeAction, in state: KlondikeState)
        -> (PieceID, ZoneID)?
    {
        switch action {
        case .drawFromStock, .recycleWaste:
            return nil
        case .wasteToTableau(let toPile):
            guard let piece = state.waste.contents.last else { return nil }
            return (piece, KlondikeZone.tableau(toPile))
        case .wasteToFoundation(let toFoundation):
            guard let piece = state.waste.contents.last else { return nil }
            return (piece, KlondikeZone.foundation(toFoundation))
        case .tableauToTableau(_, let card, let toPile):
            return (card, KlondikeZone.tableau(toPile))
        case .tableauToFoundation(let fromPile, let toFoundation):
            guard let piece = state.tableau[fromPile].contents.last else { return nil }
            return (piece, KlondikeZone.foundation(toFoundation))
        case .foundationToTableau(let fromFoundation, let toPile):
            guard let piece = state.foundations[fromFoundation].contents.last else { return nil }
            return (piece, KlondikeZone.tableau(toPile))
        }
    }
}
