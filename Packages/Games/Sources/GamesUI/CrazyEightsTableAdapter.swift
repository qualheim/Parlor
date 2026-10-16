// CrazyEightsTableAdapter — maps Crazy Eights legal actions onto the generic TableKit interaction seam
// (R-CE-2, R-TABLE-3, R-A11Y-2).
//
// Crazy Eights remains a pure rules module. This adapter is the only bridge that knows both the rules and
// TableKit: it turns a local player's legal card plays into highlighted discard targets and exposes draw /
// pass as keyboard-activatable stock actions. The generic renderer still owns gestures, focus, animation,
// and accessibility plumbing.

import Foundation
import GamesRules
import TableKit

/// The Crazy Eights → TableKit interaction adapter. It is stateless and derives every answer from the
/// current authoritative shadow state supplied by the table controller.
public enum CrazyEightsTableAdapter {
    /// Stable ids for non-drag actions. A draw or pass is attached to the stock so keyboard users can reach
    /// it without needing a card to drag.
    public enum ZoneActionID {
        public static let draw = "crazy-eights.draw"
        public static let pass = "crazy-eights.pass"
    }

    /// Every legal play becomes a target on the public discard zone. An eight has one target per named suit;
    /// duplicate visual targets are harmless and keep the choice-specific action available to the controller.
    public static func legalTargets(
        for game: CrazyEights, in state: CrazyEightsState, seat: SeatID
    ) -> [MoveTarget] {
        game.legalActions(for: seat, in: state).compactMap { action in
            switch action {
            case .play(let card), .playEight(let card, _):
                return MoveTarget(piece: .known(card), destination: CrazyEightsZone.discardID)
            case .draw, .pass:
                return nil
            }
        }
    }

    /// The concrete action represented by a card move. For a wild eight, the first legal suit (clubs) is
    /// selected deterministically; the visible action strip supplies every suit-specific alternative for
    /// players who want to name a different suit.
    public static func action(
        for move: TableMove, in state: CrazyEightsState, seat: SeatID
    ) -> CrazyEightsAction? {
        guard case .known(let movingID) = move.piece,
            move.destination == CrazyEightsZone.discardID
        else { return nil }
        return stateAction(for: movingID, in: state, seat: seat)
    }

    /// The local hand action for a concrete card, preferring a regular play and then the deterministic first
    /// named-suit choice for an eight.
    public static func stateAction(
        for card: PieceID, in state: CrazyEightsState, seat: SeatID
    ) -> CrazyEightsAction? {
        let actions = CrazyEights().legalActions(for: seat, in: state)
        return actions.first { action in
            switch action {
            case .play(let candidate), .playEight(let candidate, _): return candidate == card
            case .draw, .pass: return false
            }
        }
    }

    /// Non-drag actions available on the stock for the current turn.
    public static func zoneActions(
        for game: CrazyEights, in state: CrazyEightsState, seat: SeatID
    ) -> [ZoneAction] {
        game.legalActions(for: seat, in: state).compactMap { action in
            switch action {
            case .draw:
                return ZoneAction(
                    zone: CrazyEightsZone.stockID, id: ZoneActionID.draw, title: "Draw")
            case .pass:
                return ZoneAction(
                    zone: CrazyEightsZone.stockID, id: ZoneActionID.pass, title: "Pass")
            case .play, .playEight:
                return nil
            }
        }
    }

    /// Resolve an opaque zone-action id back into its game action.
    public static func zoneAction(forID id: String) -> CrazyEightsAction? {
        switch id {
        case ZoneActionID.draw: return .draw
        case ZoneActionID.pass: return .pass
        default: return nil
        }
    }

    /// Assemble the generic interaction input for a Crazy Eights frame.
    public static func interactionInput(
        for game: CrazyEights,
        in state: CrazyEightsState,
        seat: SeatID,
        resolve: @escaping @Sendable (TableMove) -> MoveResult,
        performAction: @escaping @Sendable (CrazyEightsAction) -> MoveResult
    ) -> TableInteractionInput {
        let targets = legalTargets(for: game, in: state, seat: seat)
        let dryRun: @Sendable (TableMove) -> MoveResult = { move in
            if action(for: move, in: state, seat: seat) != nil { return .success(()) }
            return .failure(
                RuleViolation(
                    code: "no-such-move",
                    reason: "That card cannot be played on the current discard."))
        }
        return TableInteractionInput(
            legalTargets: targets,
            resolve: resolve,
            dryRunResolve: dryRun,
            zoneActions: zoneActions(for: game, in: state, seat: seat),
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
}
