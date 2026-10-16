// Crazy Eights — Hard AI: determinized Monte Carlo via the shared AIKit toolkit (R-CE-5.3).
//
// The Hard tier is the strongest opponent: it uses determinized Monte Carlo search (Docs/Rules/
// crazy-eights.md → AI opponents; design.md §5). Each candidate legal move is scored by averaging many
// random playouts from a plausible full hand — a DETERMINIZATION the strategy builds from its own
// redacted `PlayerView` plus the public log and options (CrazyEightsDeterminizer), never from
// authoritative state, so the information barrier holds (R-AI-1.1). The playouts run over the game's own
// rules through the `CrazyEightsSimulation` seam, and every draw comes from the injected `SeededRNG`, so
// an AI-vs-AI run is reproducible (R-AI-3.2). The search honors the compute deadline and cancellation and
// returns its best-so-far pick on timeout (R-AI-3.1, R-AI-3.3).
//
// APPROACH. For robustness against a single unlucky world, the tier draws SEVERAL determinizations and
// sums each candidate's Monte Carlo value across them (a light determinized-Monte-Carlo ensemble); the
// candidate with the best total is chosen, RNG-tie-broken. If determinization ever fails (an infeasible
// view), it falls back to the Medium heuristic so it always returns a legal move.

import AIKit
import EngineCore
import Foundation

/// The Hard Crazy Eights strategy: determinized Monte Carlo over the shared AIKit toolkit (R-CE-5.3).
public struct CrazyEightsHardStrategy: AIStrategy {
    /// The public options the hand runs under, used to build plausible full states (R-AI-1.1: options are
    /// public setup config, not hidden state).
    private let options: CrazyEightsOptions
    /// How many determinizations to average over per decision (the ensemble width).
    private let worlds: Int
    /// Rollouts per candidate per world — the DETERMINISTIC work bound. Fixing the number of rollouts
    /// (rather than relying on wall-clock alone) is what makes an AI-vs-AI run reproducible from its seed
    /// (R-AI-3.2): the same inputs draw the same rollouts. The real deadline still caps it as an upper
    /// bound under time pressure (R-AI-3.3).
    private let rolloutsPerCandidate: Int

    /// How long before the caller's deadline the search stops, leaving time to wrap up the in-flight
    /// rollout and pick the move so the decision as a whole stays within its budget (R-AI-3.3).
    static let deadlineHeadroomSeconds: TimeInterval = 0.05

    /// Create a Hard strategy for a hand dealt under `options` (R-CE-5.3). `worlds` is the number of
    /// determinizations averaged per move; `rolloutsPerCandidate` fixes the per-world work so the
    /// decision is reproducible from the injected seed (R-AI-3.2).
    public init(options: CrazyEightsOptions, worlds: Int = 8, rolloutsPerCandidate: Int = 48) {
        self.options = options
        self.worlds = max(1, worlds)
        self.rolloutsPerCandidate = max(1, rolloutsPerCandidate)
    }

    public func decide(_ context: DecisionContext) async -> AnyGameAction? {
        var rng = context.rng
        return search(context, rng: &rng)
    }

    public func hint(_ context: DecisionContext) async -> Hint? {
        var rng = context.rng
        guard let action = search(context, rng: &rng) else { return nil }
        let decoded = try? action.decode(as: CrazyEightsAction.self)
        let explanation: String
        switch decoded {
        case .playEight:
            explanation = "Simulations favor playing the eight here and steering the suit your way."
        case .play:
            explanation = "Playouts show this match keeps the most options open."
        case .draw:
            explanation = "Every simulated line stalls — drawing is the best available move."
        case .pass, .none:
            explanation = "No move improves the position, so pass."
        }
        return Hint(action: action, explanation: explanation)
    }

    // MARK: - Search (R-CE-5.3)

    /// Run determinized Monte Carlo and return the best legal action, or a heuristic fallback if a full
    /// state cannot be reconstructed (R-CE-5.3, R-AI-3.1).
    private func search(_ context: DecisionContext, rng: inout SeededRNG) -> AnyGameAction? {
        let decoded = CrazyEightsAI.decodedActions(context.legalActions)
        guard !decoded.isEmpty else { return nil }
        if decoded.count == 1 { return decoded[0].erased }

        let determinizer = CrazyEightsDeterminizer(options: options)
        let simulation = CrazyEightsSimulation()
        let seat = SimSeat(raw: context.seat.raw)
        let candidates = decoded.map(\.action)

        // The real compute deadline is the upper bound (R-AI-3.3); the fixed rollout count is what makes
        // the search REPRODUCIBLE (R-AI-3.2). We drive `evaluateActions` with a SYNTHETIC clock that
        // "expires" after exactly `rolloutsPerCandidate` rollouts per candidate, so the number of
        // rollouts — and therefore the choice — depends only on the seed, not on wall-clock timing. The
        // real deadline is still checked so a superseded/over-budget decision stops early.
        // Stop searching a little BEFORE the caller's deadline: finishing the in-flight rollout, scoring
        // and the argMax run after the stop check, so aiming at the deadline itself overshoots it by a
        // few milliseconds. The headroom keeps the whole decision inside the budget (R-AI-3.3).
        let searchDeadline = Deadline(
            at: context.deadline.at.addingTimeInterval(-Self.deadlineHeadroomSeconds))
        var totals = [Double](repeating: 0, count: candidates.count)
        var counted = false

        for _ in 0..<worlds {
            if counted, searchDeadline.isReached() { break }
            guard
                let root = determinizer.makeState(
                    view: context.view, seat: context.seat, log: context.publicLog, rng: &rng)
            else { continue }

            // Synthetic monotonic clock: each `now()` call ticks one unit forward, independent of wall
            // time, so the number of rollouts depends ONLY on the seed (reproducible, R-AI-3.2). A
            // reference counter satisfies the `@Sendable` `now` closure. When the REAL deadline has
            // passed the clock jumps past the synthetic deadline so an over-budget decision stops early
            // (budget-safe, R-AI-3.3).
            let realDeadline = searchDeadline
            let totalRollouts = rolloutsPerCandidate * candidates.count
            let syntheticEpoch = Date(timeIntervalSince1970: 0)
            let syntheticDeadlineAt = Double(totalRollouts) + 0.5
            let counter = TickCounter()
            let clock: @Sendable () -> Date = {
                if realDeadline.isReached() {
                    return syntheticEpoch.addingTimeInterval(syntheticDeadlineAt + 1)
                }
                return syntheticEpoch.addingTimeInterval(Double(counter.next()))
            }
            let worldDeadline = Deadline(at: syntheticEpoch.addingTimeInterval(syntheticDeadlineAt))
            let mc = MonteCarlo(simulation: simulation)
            let values = mc.evaluateActions(
                from: root, candidates: candidates, for: seat, deadline: worldDeadline, rng: &rng,
                now: clock)
            for value in values {
                if let idx = candidates.firstIndex(of: value.action) {
                    totals[idx] += value.mean
                }
            }
            counted = true
        }

        guard counted else {
            // Determinization never succeeded — fall back to the Medium heuristic (always legal).
            return fallback(context, rng: &rng)
        }

        // Pick the candidate with the highest summed value, RNG tie-broken (R-AI-3.2).
        let indices = Array(candidates.indices)
        let bestIndex = Evaluator.argMax(indices, score: { totals[$0] }, using: &rng)
        guard let bestIndex else { return decoded[0].erased }
        return decoded[bestIndex].erased
    }

    /// A monotonic tick counter backing the synthetic clock. `MonteCarlo.evaluateActions` runs
    /// synchronously on a single task, so the counter is only ever touched from one thread within a
    /// decision; a serial lock keeps it correct and lets it satisfy the `@Sendable` `now` closure.
    private final class TickCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        /// The current tick, then advance by one.
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }

    /// The Medium heuristic as a safety net when a full state cannot be built (R-AI-3.1: always return a
    /// legal move).
    private func fallback(_ context: DecisionContext, rng: inout SeededRNG) -> AnyGameAction? {
        let decoded = CrazyEightsAI.decodedActions(context.legalActions)
        // Prefer a non-8 play, else an 8, else draw/pass — a compact echo of the Medium order.
        if let nonEight = decoded.first(where: { CrazyEightsAI.playsCard($0.action) }) {
            return nonEight.erased
        }
        if let eight = decoded.first(where: { CrazyEightsAI.playsEight($0.action) }) {
            return eight.erased
        }
        return decoded.first?.erased
    }
}
