// The simulation seam — how a game lets AIKit play out moves without AIKit knowing the game (R-AI-2.2).
//
// AIKit is pure and generic: it must run Monte Carlo rollouts and ISMCTS, but it cannot apply a specific
// game's rules directly, because that lives in the game's `GameDefinition` (EngineCore) — and AIKit does
// not know any concrete game (design.md §1). The clean seam is a small protocol the CALLER supplies by
// wrapping its `GameDefinition`:
//
//   • `SimState`  — the search's working state. For a determinized search this is a *full* hidden state
//     the caller built from a `Determinization` (Determinization.swift) — NOT the redacted `PlayerView`.
//     The caller owns the type; AIKit treats it opaquely, so the info barrier is preserved (AIKit only
//     ever receives states the caller derived from a determinization of the strategy's own `PlayerView`).
//   • `SimAction` — a move in the search (usually the game's `Action` or `AnyGameAction`).
//   • `legalActions(in:)` — the moves available in a state.
//   • `apply(_:in:)` — advance a state by an action (the caller wraps `GameDefinition.apply`).
//   • `isTerminal(_:)` / `value(of:for:)` — detect the end and score it from the deciding seat's view.
//   • `currentPlayer(in:)` — whose move it is (so ISMCTS can attribute rewards).
//
// The caller wraps its `GameDefinition` once (task 4.6 for Crazy Eights) and every AIKit search runs
// against it. Because the seam takes closures/associated types the game fills in, AIKit stays generic and
// the game supplies the rules — with no dependency from AIKit onto any concrete game.

import Foundation

// MARK: - GameSimulation (R-AI-2.2)

/// The caller-supplied bridge that lets AIKit's searches play out a specific game generically (R-AI-2.2).
///
/// A game wraps its `GameDefinition` in a conformer: `SimState` is a full (determinized) state the search
/// walks, `SimAction` is a move. AIKit's Monte Carlo and ISMCTS drive a game only through these members,
/// so they never need to know the game's rules. `Sendable` so a search runs off the main actor (R-AI-3.1).
///
/// **Barrier note.** The `SimState` AIKit receives is always one the caller *constructed from a
/// determinization of the strategy's own `PlayerView`* — the search invents plausible hidden state and
/// reasons over it; it is never handed the host's authoritative state. The seam thus keeps the info
/// barrier intact (R-AI-1.1).
public protocol GameSimulation: Sendable {
    /// The full working state the search walks (a determinized state the caller built). Opaque to AIKit.
    associatedtype SimState: Sendable
    /// A move in the search. Opaque to AIKit; usually the game's action or `AnyGameAction`.
    associatedtype SimAction: Sendable & Hashable

    /// The legal moves in `state` — empty when the state is terminal or the mover has no move.
    func legalActions(in state: SimState) -> [SimAction]

    /// Advance `state` by `action`, returning the resulting state. Pure: never mutates `state`.
    ///
    /// If the action is somehow illegal in `state` (should not happen when fed from `legalActions`), the
    /// caller should return `state` unchanged; the search then treats it as a no-progress move.
    func apply(_ action: SimAction, in state: SimState) -> SimState

    /// Whether `state` is terminal — the playout has reached a scored end.
    func isTerminal(_ state: SimState) -> Bool

    /// The scalar value of a terminal (or heuristically evaluated) `state` from `seat`'s perspective,
    /// where higher is better for `seat`.
    ///
    /// Conventionally normalized to `0...1` (loss…win) or `-1...1`; AIKit only compares/averages it, so
    /// any consistent scale works. Called at the end of a rollout and for heuristic cutoffs.
    func value(of state: SimState, for seat: SimSeat) -> Double

    /// Whose move it is in `state` — used to attribute rewards during search. Returns `nil` in a
    /// terminal state.
    func currentPlayer(in state: SimState) -> SimSeat?
}

// MARK: - SimSeat

/// A lightweight seat identifier used inside a search, decoupled from EngineCore's `SeatID` so the
/// simulation seam has no engine-type dependency in its value positions.
///
/// A thin wrapper over a stable string; the caller maps its `SeatID.raw` straight onto this. Kept tiny
/// and `Hashable` so ISMCTS can key per-seat statistics on it.
public struct SimSeat: Hashable, Sendable {
    /// Opaque, stable seat token (e.g. mirrors `SeatID.raw`).
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

// MARK: - Rollout policy (R-AI-2.2)

/// How a rollout picks moves during a playout (R-AI-2.2).
///
/// `.randomLegal` is the standard uniform playout (fast, unbiased) driven by the injected RNG. `.guided`
/// lets the caller inject a light policy (e.g. "prefer following suit") to make short rollouts stronger
/// for a Medium tier; the closure returns an index into the supplied legal actions. The closure is
/// `@Sendable` so the policy crosses to an off-main-actor search.
public enum RolloutPolicy<Simulation: GameSimulation>: Sendable {
    /// Play uniformly at random among legal moves, using the injected RNG.
    case randomLegal
    /// Play the move the policy chooses: given the state and its legal actions, return the chosen index.
    case guided(@Sendable (Simulation.SimState, [Simulation.SimAction]) -> Int)
}
