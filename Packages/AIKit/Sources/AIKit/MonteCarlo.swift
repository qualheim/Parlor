// Monte Carlo rollouts — estimate an action's value by averaging random playouts (R-AI-2.2, R-AI-3.1).
//
// Given a determinized full state (built by the caller from `DeterminizationSampler`) and a `GameSimulation`
// seam (Simulation.swift), the rollout engine estimates the value of each candidate action by playing many
// random-legal (or policy-guided) games to a terminal/scored state and averaging the results from the
// deciding seat's perspective. The action with the highest mean value is the pick.
//
// This is the Medium-tier workhorse and the core of determinized Monte Carlo (Crazy Eights Hard falls back
// to this; design.md §5). It is generic over the caller's `GameSimulation`, so AIKit never applies a
// specific game's rules directly.
//
// BUDGET + CANCELLATION (R-AI-3.1). The loop checks `shouldStopSearch(deadline:)` (DecisionBudget.swift)
// between rollouts, so it always returns its best-so-far estimate on timeout or `Task` cancellation, having
// run at least one rollout per candidate where possible. REPRODUCIBILITY (R-AI-3.2): every playout draws
// from the injected `SeededRNG`, so the same seed + inputs yield the same estimates and the same choice.

import Foundation
import EngineCore

// MARK: - Action value (R-AI-2.2)

/// The Monte Carlo estimate for one candidate action: its mean rollout value and how many rollouts backed
/// it (R-AI-2.2).
///
/// `mean` is the average terminal value from the deciding seat's perspective (higher is better);
/// `rollouts` is the sample size behind it (more rollouts ⇒ more confidence). Generic over the action so
/// the caller gets its own action type back.
public struct ActionValue<Action: Sendable>: Sendable {
    /// The candidate action this value is for.
    public let action: Action
    /// Mean terminal value over the rollouts, from the deciding seat's perspective (higher is better).
    public let mean: Double
    /// Number of rollouts averaged into `mean`.
    public let rollouts: Int

    public init(action: Action, mean: Double, rollouts: Int) {
        self.action = action
        self.mean = mean
        self.rollouts = rollouts
    }
}

// MARK: - MonteCarlo (R-AI-2.2, R-AI-3.1, R-AI-3.2)

/// A generic Monte Carlo rollout engine over a `GameSimulation` seam (R-AI-2.2).
///
/// Estimates each candidate action's value by averaging random/guided playouts, respecting a compute
/// deadline and cancellation (R-AI-3.1) and drawing all randomness from an injected RNG (R-AI-3.2).
public struct MonteCarlo<Simulation: GameSimulation>: Sendable {
    /// The caller's simulation seam (wraps its `GameDefinition`).
    public let simulation: Simulation
    /// How playouts choose moves (uniform random or a light guided policy).
    public let policy: RolloutPolicy<Simulation>
    /// A safety cap on playout length so a non-terminating game state cannot loop forever.
    public let maxPlyPerRollout: Int

    public init(
        simulation: Simulation,
        policy: RolloutPolicy<Simulation> = .randomLegal,
        maxPlyPerRollout: Int = 512
    ) {
        self.simulation = simulation
        self.policy = policy
        self.maxPlyPerRollout = max(1, maxPlyPerRollout)
    }

    /// Estimate the value of every candidate action from `root`, for `seat`, within the `deadline`
    /// (R-AI-2.2, R-AI-3.1).
    ///
    /// Rollouts are spread round-robin across the candidates so each accrues a comparable sample even if
    /// the deadline cuts the search short. Each rollout applies the candidate once, then plays out to a
    /// terminal (or the ply cap) via `policy`, and records `value(of:for:)` from `seat`'s perspective. The
    /// injected `rng` threads through every draw (R-AI-3.2). Returns one `ActionValue` per candidate;
    /// empty if there are no candidates.
    public func evaluateActions(
        from root: Simulation.SimState,
        candidates: [Simulation.SimAction],
        for seat: SimSeat,
        deadline: Deadline,
        rng: inout SeededRNG,
        now: @Sendable () -> Date = { Date() }
    ) -> [ActionValue<Simulation.SimAction>] {
        guard !candidates.isEmpty else { return [] }

        var totals = [Double](repeating: 0, count: candidates.count)
        var counts = [Int](repeating: 0, count: candidates.count)

        // Round-robin so a short budget still samples every candidate roughly equally.
        var i = 0
        var didAnyRollout = false
        while !shouldStopSearch(deadline: deadline, now: now()) || !didAnyRollout {
            let index = i % candidates.count
            let afterAction = simulation.apply(candidates[index], in: root)
            let value = playout(from: afterAction, for: seat, rng: &rng)
            totals[index] += value
            counts[index] += 1
            didAnyRollout = true
            i += 1
            // After guaranteeing at least one full round, honor the stop condition promptly.
            if didAnyRollout, i % candidates.count == 0,
                shouldStopSearch(deadline: deadline, now: now())
            {
                break
            }
        }

        return candidates.enumerated().map { idx, action in
            let n = counts[idx]
            return ActionValue(
                action: action, mean: n > 0 ? totals[idx] / Double(n) : 0, rollouts: n)
        }
    }

    /// Choose the best action from `root` for `seat` by Monte Carlo, breaking ties with the injected RNG
    /// (R-AI-2.2, R-AI-3.2).
    ///
    /// Convenience over `evaluateActions` + `Evaluator.argMax`. Returns `nil` only when there are no
    /// candidates.
    public func bestAction(
        from root: Simulation.SimState,
        candidates: [Simulation.SimAction],
        for seat: SimSeat,
        deadline: Deadline,
        rng: inout SeededRNG,
        now: @Sendable () -> Date = { Date() }
    ) -> Simulation.SimAction? {
        let values = evaluateActions(
            from: root, candidates: candidates, for: seat, deadline: deadline, rng: &rng, now: now)
        guard !values.isEmpty else { return nil }
        let best = Evaluator.argMax(values, score: { $0.mean }, using: &rng)
        return best?.action
    }

    /// Play one game out from `state` to a terminal state (or the ply cap) and return its value for
    /// `seat`.
    ///
    /// Moves are chosen by `policy`: uniform random via the injected RNG, or the guided closure. A cap of
    /// `maxPlyPerRollout` guards against a game that never reports terminal. Drawing through `rng` keeps
    /// playouts reproducible (R-AI-3.2).
    private func playout(
        from state: Simulation.SimState,
        for seat: SimSeat,
        rng: inout SeededRNG
    ) -> Double {
        var current = state
        var ply = 0
        while ply < maxPlyPerRollout, !simulation.isTerminal(current) {
            let legal = simulation.legalActions(in: current)
            guard !legal.isEmpty else { break }
            let choiceIndex: Int
            switch policy {
            case .randomLegal:
                choiceIndex = Int(rng.next() % UInt64(legal.count))
            case .guided(let choose):
                let raw = choose(current, legal)
                choiceIndex = min(max(raw, 0), legal.count - 1)
            }
            current = simulation.apply(legal[choiceIndex], in: current)
            ply += 1
        }
        return simulation.value(of: current, for: seat)
    }
}
