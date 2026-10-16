// Test-only toy game + helpers used across the AIKit toolkit tests.
//
// AIKit is generic over a caller's `GameSimulation`; to exercise Monte Carlo and ISMCTS we need a tiny,
// fully-known game the tests can reason about. `NimSim` is a subtraction game: from a pile of `remaining`
// stones, the mover removes 1, 2, or 3; the player who takes the LAST stone LOSES (misère). It is a
// classic game with a known optimal strategy — the mover to act on a pile where `remaining % 4 == 1` is in
// a losing position, so the winning move is to leave the opponent at `remaining % 4 == 1`. That known
// optimum is what lets a test assert "the search picks the winning move".
//
// This file is compiled only into the test target.

import EngineCore
import Foundation

@testable import AIKit

// MARK: - A tiny type-erased action helper

/// A trivial `GameAction` so tests can mint `AnyGameAction` values without a real game.
struct ToyAction: GameAction, Hashable {
    let name: String
    let amount: Int
    init(name: String, amount: Int = 0) {
        self.name = name
        self.amount = amount
    }
}

extension AnyGameAction {
    /// Convenience: erase a `ToyAction` (force-tries; the encoding cannot fail for this simple type).
    static func toy(_ name: String, amount: Int = 0) -> AnyGameAction {
        try! AnyGameAction(ToyAction(name: name, amount: amount))
    }
}

// MARK: - Misère Nim simulation (a fully-known toy)

/// State of the subtraction game: how many stones remain and whose turn it is.
struct NimState: Sendable, Hashable {
    var remaining: Int
    var toMove: SimSeat
    var lastMover: SimSeat?
}

/// The two seats used in the toy.
enum ToySeats {
    static let a = SimSeat(raw: "A")
    static let b = SimSeat(raw: "B")
    static func other(_ s: SimSeat) -> SimSeat { s == a ? b : a }
}

/// Misère subtraction game as a `GameSimulation`. Remove 1–3 stones; taking the last stone loses.
struct NimSim: GameSimulation {
    typealias SimState = NimState
    typealias SimAction = Int  // stones to remove: 1, 2, or 3

    func legalActions(in state: NimState) -> [Int] {
        guard state.remaining > 0 else { return [] }
        return (1...min(3, state.remaining)).map { $0 }
    }

    func apply(_ action: Int, in state: NimState) -> NimState {
        let take = min(max(action, 1), state.remaining)
        return NimState(
            remaining: state.remaining - take,
            toMove: ToySeats.other(state.toMove),
            lastMover: state.toMove)
    }

    func isTerminal(_ state: NimState) -> Bool { state.remaining == 0 }

    func value(of state: NimState, for seat: SimSeat) -> Double {
        // Misère: whoever took the last stone (lastMover) loses. Non-terminal states are scored 0.5
        // (unknown) so heuristic cutoffs are neutral.
        guard state.remaining == 0, let loser = state.lastMover else { return 0.5 }
        return loser == seat ? 0.0 : 1.0
    }

    func currentPlayer(in state: NimState) -> SimSeat? {
        state.remaining == 0 ? nil : state.toMove
    }
}
