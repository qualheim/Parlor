// Crazy Eights simulation seam — lets AIKit search play out a determinized hand (R-AI-2.2, R-CE-5.3).
//
// AIKit's Monte Carlo (and ISMCTS) are generic over a `GameSimulation` (Simulation.swift): the caller
// supplies how to enumerate legal moves, apply one, detect a terminal, and score it — by wrapping its own
// `GameDefinition`. This is that wrapper for Crazy Eights. The `SimState` is a FULL `CrazyEightsState`
// that the Hard tier built from a determinization of the strategy's own `PlayerView` (see
// CrazyEightsDeterminizer) — never the host's authoritative state — so the information barrier holds
// (R-AI-1.1).
//
// The wrapper is a thin adapter over `CrazyEights`' existing pure functions: `legalActions`, `apply`,
// `isTerminal`, `outcome`. `value(of:for:)` normalizes the per-hand outcome to 0…1 from the deciding
// seat's perspective (win = 1, loss = 0), which is what the rollouts average. `currentPlayer` mirrors the
// state's `turn`.

import AIKit
import EngineCore
import Foundation

/// A `GameSimulation` over `CrazyEightsState`, wrapping the game's pure rules so AIKit can play out a
/// determinized hand (R-AI-2.2, R-CE-5.3).
struct CrazyEightsSimulation: GameSimulation {
    typealias SimState = CrazyEightsState
    typealias SimAction = CrazyEightsAction

    /// The rules definition whose pure functions drive the playout.
    let game = CrazyEights()

    func legalActions(in state: CrazyEightsState) -> [CrazyEightsAction] {
        game.legalActions(for: state.turn, in: state)
    }

    func apply(_ action: CrazyEightsAction, in state: CrazyEightsState) -> CrazyEightsState {
        switch game.apply(action, by: state.turn, to: state) {
        case .success(let (next, _)): return next
        case .failure: return state  // illegal (shouldn't happen from legalActions): no progress
        }
    }

    func isTerminal(_ state: CrazyEightsState) -> Bool {
        game.isTerminal(state)
    }

    /// Value of a state for `seat`: 1 if `seat` is a winner of the (terminal) hand, else 0. For a
    /// non-terminal cutoff we fall back to a light heuristic — fewer cards in hand is better — normalized
    /// to (0, 1) so it never outweighs a real win/loss.
    func value(of state: CrazyEightsState, for seat: SimSeat) -> Double {
        let seatID = SeatID(raw: seat.raw)
        if isTerminal(state) {
            let outcome = game.outcome(state)
            return outcome.winners.contains(seatID) ? 1.0 : 0.0
        }
        // Heuristic midgame value: shed cards → closer to going out. Map hand size to (0, 0.5).
        let myCount = state.hand(of: seatID)?.contents.count ?? 0
        let maxHand = max(1, state.hands.map { $0.contents.count }.max() ?? 1)
        let progress = 1.0 - Double(myCount) / Double(maxHand)  // 0…1
        return 0.25 + 0.25 * progress
    }

    func currentPlayer(in state: CrazyEightsState) -> SimSeat? {
        if isTerminal(state) { return nil }
        return SimSeat(raw: state.turn.raw)
    }
}
