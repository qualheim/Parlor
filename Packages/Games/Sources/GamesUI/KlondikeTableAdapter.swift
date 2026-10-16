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

    // MARK: - Non-drag stock zone actions (R-KLON-2.1, R-KLON-2.3; R-A11Y-2.1)

    /// The opaque ids TableKit carries for Klondike's two non-drag stock actions. Stable strings so the
    /// view (mouse tap / keyboard activation) and `performZoneAction` agree without importing rules.
    public enum ZoneActionID {
        /// Turn cards from the stock onto the waste (R-KLON-2.1).
        public static let draw = "klondike.draw"
        /// Recycle the waste back under the stock when the stock is empty (R-KLON-2.3).
        public static let recycle = "klondike.recycle"
    }

    /// The non-drag actions offered on the STOCK zone for the current state (R-A11Y-2.1).
    ///
    /// The stock draw and recycle are not moves a player can drag — no single piece travels to a
    /// destination — so, exactly like `legalTargets` feeds draggable moves, these feed the tap/keyboard
    /// path for the stock. At most one is legal at a time (draw when the stock has cards; recycle when it
    /// is empty and the option permits another pass), so the returned array holds zero or one action.
    /// Both are attached to the stock zone; a click/tap on the stock or space/return on the focused stock
    /// invokes the first (and only) one present.
    public static func zoneActions(for game: Klondike, in state: KlondikeState) -> [ZoneAction] {
        var actions: [ZoneAction] = []
        let legal = game.legalActions(for: klondikeSeat, in: state)
        if legal.contains(.drawFromStock) {
            actions.append(
                ZoneAction(
                    zone: KlondikeZone.stockID, id: ZoneActionID.draw, title: "Draw from stock"))
        }
        if legal.contains(.recycleWaste) {
            actions.append(
                ZoneAction(
                    zone: KlondikeZone.stockID, id: ZoneActionID.recycle, title: "Recycle waste"))
        }
        return actions
    }

    /// The Klondike action a non-drag zone-action `id` maps to, or `nil` for an unknown id (R-A11Y-2.1).
    /// Pure inverse of `zoneActions`' id assignment; the caller submits the returned action.
    public static func zoneAction(forID id: String) -> KlondikeAction? {
        switch id {
        case ZoneActionID.draw: return .drawFromStock
        case ZoneActionID.recycle: return .recycleWaste
        default: return nil
        }
    }

    /// Assemble the full `TableInteractionInput` for the current frame (R-TABLE-3): legal targets +
    /// smart-target closure, the stock's non-drag zone actions, plus the host closures that submit a chosen
    /// move (`resolve`) or a chosen non-drag action (`performAction`).
    ///
    /// `resolve`/`performAction` are supplied by the caller (the screen/host that owns the `GameHost`),
    /// because submitting is a session-layer effect, not a pure mapping. The smart-target closure captures
    /// a snapshot of `state`, matching TableKit's per-frame model (the input is rebuilt when the view
    /// refreshes). `zoneActions` wires the stock draw/recycle so the core Klondike loop is reachable by
    /// mouse AND keyboard (R-KLON-2.1, R-KLON-2.3; R-A11Y-2.1) — previously omitted, which left the stock
    /// non-interactive.
    public static func interactionInput(
        for game: Klondike,
        in state: KlondikeState,
        resolve: @escaping @Sendable (TableMove) -> MoveResult,
        performAction: @escaping @Sendable (KlondikeAction) -> MoveResult = { _ in
            .failure(RuleViolation(code: "no-action", reason: "No action available."))
        }
    ) -> TableInteractionInput {
        // The READ-ONLY move verdict for the "why can't I play this?" explainer: validate the move against
        // THIS frame's state purely (does it map to a legal action?) and return the verdict WITHOUT
        // submitting anything. Captured over the same `state` snapshot as `legalTargets`/`smartTarget`, so
        // it is a pure function of the frame — never a committing host round-trip (that is `resolve`, which
        // only a discrete user gesture may call). This is what stops the context-menu explainer from
        // driving an infinite self-resubmit loop.
        let dryRun: @Sendable (TableMove) -> MoveResult = { move in
            if action(for: move, in: state) != nil {
                return .success(())
            }
            return .failure(
                RuleViolation(code: "no-such-move", reason: "That move isn't available."))
        }
        return TableInteractionInput(
            legalTargets: legalTargets(for: game, in: state),
            resolve: resolve,
            dryRunResolve: dryRun,
            smartTarget: { key in smartTarget(for: game, piece: key, in: state) },
            zoneActions: zoneActions(for: game, in: state),
            performZoneAction: { id in
                guard let action = zoneAction(forID: id) else {
                    return .failure(
                        RuleViolation(
                            code: "no-such-action", reason: "That action isn't available."))
                }
                return performAction(action)
            }
        )
    }

    /// The Klondike action a generic `TableMove` corresponds to in `state`, or `nil` if the move maps to
    /// no legal Klondike action (R-TABLE-3). This is the inverse of `pieceAndDestination`: the table hands
    /// back the piece's `RenderKey`, source, and destination zone the player expressed, and this finds the
    /// single legal action that moves that concrete piece to that destination.
    ///
    /// Legality is delegated to `legalActions` — only an action already enumerated as legal can match — so
    /// a move onto an illegal target yields `nil` (the caller surfaces the gentle rejection, R-TABLE-4.1).
    /// A hidden token has no known identity to move, so it never maps to an action.
    public static func action(for move: TableMove, in state: KlondikeState) -> KlondikeAction? {
        guard case .known(let movingID) = move.piece else { return nil }
        // The one legal action whose (piece, destination) matches what the table expressed.
        for action in Klondike().legalActions(for: klondikeSeat, in: state) {
            guard let (piece, destination) = pieceAndDestination(of: action, in: state) else {
                continue
            }
            if piece == movingID && destination == move.destination {
                return action
            }
        }
        return nil
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
