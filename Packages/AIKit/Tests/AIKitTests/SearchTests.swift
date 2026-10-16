// Monte Carlo + ISMCTS search tests (R-AI-2.2, R-AI-3.1, R-AI-3.2).

import EngineCore
import Foundation
import Testing

@testable import AIKit

@Suite("Monte Carlo + ISMCTS")
struct SearchTests {

    // On misère Nim from remaining == 4, taking 3 leaves 1 stone, forcing the opponent to take the last
    // one and lose — a forced win regardless of how the (random-rollout) opponent plays. Monte Carlo with
    // uniform playouts therefore cleanly values it highest, so `bestAction` picks it.
    @Test("Monte Carlo prefers the known winning move")
    func monteCarloFindsWin() {
        let sim = NimSim()
        let root = NimState(remaining: 4, toMove: ToySeats.a, lastMover: nil)
        let mc = MonteCarlo(simulation: sim)
        var rng = SeededRNG(seed: 3)
        let values = mc.evaluateActions(
            from: root,
            candidates: sim.legalActions(in: root),
            for: ToySeats.a,
            deadline: .never,
            rng: &rng,
            now: fixedNow(iterationsBeforeDeadline: 4000))
        // Taking 3 is a forced win (mean 1.0); it must be strictly the best.
        let takeThree = values.first { $0.action == 3 }
        #expect(takeThree?.mean == 1.0)
        let best = values.max { $0.mean < $1.mean }
        #expect(best?.action == 3)
    }

    // ISMCTS on the same position (perfect information here, so determinize is identity) also finds the
    // winning move — and does measurably better than random (it should not pick a losing move).
    @Test("ISMCTS prefers the known winning move")
    func ismctsFindsWin() {
        let sim = NimSim()
        let root = NimState(remaining: 12, toMove: ToySeats.a, lastMover: nil)
        let search = ISMCTS(simulation: sim, config: ISMCTSConfig(maxIterations: 4000))
        var rng = SeededRNG(seed: 11)
        let best = search.search(
            rootActions: sim.legalActions(in: root),
            for: ToySeats.a,
            determinize: { _ in root },  // perfect info: the world is the known root
            deadline: .never,
            rng: &rng,
            now: fixedNow(iterationsBeforeDeadline: 4000))
        #expect(best == 3)
    }

    // Reproducibility (R-AI-3.2): same seed → same ISMCTS choice.
    @Test("ISMCTS is reproducible for a fixed seed")
    func ismctsReproducible() {
        let sim = NimSim()
        let root = NimState(remaining: 10, toMove: ToySeats.a, lastMover: nil)
        func run() -> Int? {
            let search = ISMCTS(simulation: sim, config: ISMCTSConfig(maxIterations: 1500))
            var rng = SeededRNG(seed: 77)
            return search.search(
                rootActions: sim.legalActions(in: root),
                for: ToySeats.a,
                determinize: { _ in root },
                deadline: .never,
                rng: &rng,
                now: fixedNow(iterationsBeforeDeadline: 1500))
        }
        #expect(run() == run())
    }

    // Monte Carlo reproducibility (R-AI-3.2).
    @Test("Monte Carlo is reproducible for a fixed seed")
    func monteCarloReproducible() {
        let sim = NimSim()
        let root = NimState(remaining: 9, toMove: ToySeats.a, lastMover: nil)
        func run() -> Int? {
            let mc = MonteCarlo(simulation: sim)
            var rng = SeededRNG(seed: 5)
            return mc.bestAction(
                from: root,
                candidates: sim.legalActions(in: root),
                for: ToySeats.a,
                deadline: .never,
                rng: &rng,
                now: fixedNow(iterationsBeforeDeadline: 2000))
        }
        #expect(run() == run())
    }

    // Cancellation (R-AI-3.1): a cancelled Task stops the search promptly, still returning best-so-far
    // (a legal action), not nil.
    @Test("cancelled search returns promptly with a legal action")
    func cancellationReturnsBestSoFar() async {
        let sim = NimSim()
        let root = NimState(remaining: 12, toMove: ToySeats.a, lastMover: nil)
        let legal = sim.legalActions(in: root)
        let result: Int? = await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                // Cancel this task immediately, then run: the search should stop after one iteration.
                withUnsafeCurrentTask { $0?.cancel() }
                let search = ISMCTS(simulation: sim, config: ISMCTSConfig(maxIterations: 1_000_000))
                var rng = SeededRNG(seed: 1)
                return search.search(
                    rootActions: legal,
                    for: ToySeats.a,
                    determinize: { _ in root },
                    deadline: .never,
                    rng: &rng)
            }
            return await group.next() ?? nil
        }
        // A cancelled search that ran at least one iteration returns a legal action (best-so-far).
        #expect(result != nil)
        #expect(result.map { legal.contains($0) } == true)
    }

    // A deadline already in the past stops after a single guaranteed pass, still returning a legal move.
    @Test("expired deadline returns a legal best-so-far move")
    func expiredDeadline() {
        let sim = NimSim()
        let root = NimState(remaining: 7, toMove: ToySeats.a, lastMover: nil)
        let legal = sim.legalActions(in: root)
        let mc = MonteCarlo(simulation: sim)
        var rng = SeededRNG(seed: 2)
        let best = mc.bestAction(
            from: root, candidates: legal, for: ToySeats.a, deadline: .immediate, rng: &rng)
        #expect(best != nil)
        #expect(best.map { legal.contains($0) } == true)
    }

    // A single legal action is returned without searching.
    @Test("single candidate short-circuits")
    func singleCandidate() {
        let sim = NimSim()
        let root = NimState(remaining: 1, toMove: ToySeats.a, lastMover: nil)  // only "take 1"
        let search = ISMCTS(simulation: sim)
        var rng = SeededRNG(seed: 1)
        let best = search.search(
            rootActions: sim.legalActions(in: root),
            for: ToySeats.a,
            determinize: { _ in root },
            deadline: .never,
            rng: &rng)
        #expect(best == 1)
    }
}

// A `now` closure that returns a time in the past until `iterationsBeforeDeadline` calls have elapsed,
// then jumps far into the future — a deterministic way to bound iteration count without wall-clock time.
private func fixedNow(iterationsBeforeDeadline: Int) -> @Sendable () -> Date {
    let counter = Counter()
    return {
        counter.increment() <= iterationsBeforeDeadline ? .distantPast : .distantFuture
    }
}

// A tiny thread-safe counter (the `now` closure is @Sendable and may be called from a search task).
private final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
