// ISMCTS — Information Set Monte Carlo Tree Search, the Hard-tier technique (R-AI-2.2, R-AI-3.1).
//
// ISMCTS extends UCT tree search to games of imperfect information. Instead of searching one true state
// (which the strategy cannot see — the info barrier, R-AI-1.1), each iteration samples a fresh
// *determinization* (a plausible full state consistent with what the strategy observed) and descends the
// SAME shared tree through the moves that are legal in that determinization. Because different iterations
// sample different worlds, the tree's statistics average over the information set rather than committing
// to one guess — which is exactly the Hard-tier requirement (R-AI-2.2; design.md §5).
//
// GENERICITY & BARRIER. Search runs over the caller's `GameSimulation` seam (Simulation.swift). Each
// iteration's root state is produced by a caller-supplied `determinize` closure — the caller builds it
// from a `DeterminizationSampler` sample of the strategy's own `PlayerView` (Determinization.swift), so
// ISMCTS only ever reasons over determinizations of observable information, never authoritative state
// (R-AI-1.1). The closure takes the injected RNG so sampling is reproducible (R-AI-3.2).
//
// BUDGET + CANCELLATION (R-AI-3.1). Iterations check `shouldStopSearch(deadline:)` between passes and stop
// with the best root move found so far; a cancelled `Task` unwinds promptly. REPRODUCIBILITY (R-AI-3.2):
// determinization, tree selection tie-breaks, and rollouts all draw from the injected `SeededRNG`.
//
// ALGORITHM (one iteration): determinize → SELECT down the tree by UCB1 among moves legal in this world,
// creating children lazily → EXPAND one untried legal move → SIMULATE a random playout to a terminal →
// BACKPROP the terminal value up the visited path, crediting the mover at each node. The chosen move is
// the root child with the most visits (the robust-child criterion).

import Foundation
import EngineCore

// MARK: - ISMCTS configuration (R-AI-2.2)

/// Tuning knobs for an ISMCTS search (R-AI-2.2).
///
/// `explorationC` is the UCB1 exploration constant (√2 is the textbook default). `maxIterations` caps the
/// number of determinization/descent passes so the search is bounded even with a generous deadline;
/// `maxPlyPerRollout` caps a single playout's length. All defaults are reasonable for the small hands
/// these AIs face; a game may tune them per tier.
public struct ISMCTSConfig: Sendable, Hashable {
    /// UCB1 exploration constant — higher explores more, lower exploits more.
    public let explorationC: Double
    /// Hard cap on determinization/descent iterations (also bounded by the deadline).
    public let maxIterations: Int
    /// Cap on a single rollout's ply, guarding against a non-terminating state.
    public let maxPlyPerRollout: Int

    public init(
        explorationC: Double = 1.414_213_562_373_095,
        maxIterations: Int = 10_000,
        maxPlyPerRollout: Int = 512
    ) {
        self.explorationC = explorationC
        self.maxIterations = max(1, maxIterations)
        self.maxPlyPerRollout = max(1, maxPlyPerRollout)
    }
}

// MARK: - ISMCTS (R-AI-2.2, R-AI-3.1, R-AI-3.2)

/// A generic, budget-aware ISMCTS over a `GameSimulation` seam and a caller-supplied determinizer
/// (R-AI-2.2).
///
/// Keeps the info barrier: the caller's `determinize` builds each iteration's root from a determinization
/// of the strategy's `PlayerView`, so the search never touches authoritative state (R-AI-1.1). Honors the
/// deadline and cancellation (R-AI-3.1) and draws all randomness from the injected RNG (R-AI-3.2).
public struct ISMCTS<Simulation: GameSimulation>: Sendable {
    /// The caller's simulation seam.
    public let simulation: Simulation
    /// Tuning knobs.
    public let config: ISMCTSConfig

    public init(simulation: Simulation, config: ISMCTSConfig = ISMCTSConfig()) {
        self.simulation = simulation
        self.config = config
    }

    // A search-tree node. Reference type so the shared tree is updated in place across iterations.
    private final class Node {
        let action: Simulation.SimAction?  // the move that led here (nil at root)
        let mover: SimSeat?  // whose move it was AT the parent when `action` was taken
        var visits: Int = 0
        var totalValue: Double = 0  // reward accrued for `mover`
        var children: [Node] = []
        // The set of actions already expanded from this node (so we expand each once).
        var expanded: Set<Simulation.SimAction> = []

        init(action: Simulation.SimAction?, mover: SimSeat?) {
            self.action = action
            self.mover = mover
        }
    }

    /// Run ISMCTS from the strategy's information set and return the best root action for `seat`, or
    /// `nil` if there are no legal actions (R-AI-2.2, R-AI-3.1).
    ///
    /// - Parameters:
    ///   - rootActions: the legal actions at the real decision point (the strategy's `legalActions`).
    ///   - seat: the deciding seat (rewards are from its perspective at the root).
    ///   - determinize: builds a plausible full root state from the injected RNG — the caller samples it
    ///     from the strategy's `PlayerView` (Determinization.swift), preserving the barrier (R-AI-1.1).
    ///   - deadline: the compute budget (R-AI-3.1).
    ///   - rng: the injected generator threaded through determinization, selection, and rollouts
    ///     (R-AI-3.2).
    public func search(
        rootActions: [Simulation.SimAction],
        for seat: SimSeat,
        determinize: (inout SeededRNG) -> Simulation.SimState,
        deadline: Deadline,
        rng: inout SeededRNG,
        now: @Sendable () -> Date = { Date() }
    ) -> Simulation.SimAction? {
        guard !rootActions.isEmpty else { return nil }
        if rootActions.count == 1 { return rootActions[0] }

        let root = Node(action: nil, mover: nil)
        var iterations = 0
        var didAny = false

        while iterations < config.maxIterations {
            if didAny, shouldStopSearch(deadline: deadline, now: now()) { break }

            // 1) Determinize: sample a plausible world for this iteration (barrier-preserving).
            let world = determinize(&rng)

            // Descend the shared tree, restricted to the moves legal in THIS world.
            runIteration(root: root, world: world, for: seat, rng: &rng)

            didAny = true
            iterations += 1
        }

        // Robust child: the root move tried most often. Ties broken by mean value, then RNG.
        return bestRootAction(root: root, rng: &rng)
    }

    /// One selection → expansion → simulation → backprop pass over the shared tree for a given world.
    private func runIteration(
        root: Node,
        world: Simulation.SimState,
        for seat: SimSeat,
        rng: inout SeededRNG
    ) {
        var node = root
        var state = world
        var path: [Node] = [root]

        // SELECT + EXPAND.
        while !simulation.isTerminal(state) {
            let legal = simulation.legalActions(in: state)
            guard !legal.isEmpty else { break }
            let mover = simulation.currentPlayer(in: state)

            // Actions legal in THIS world that we have not expanded yet from `node`.
            let untried = legal.filter { !node.expanded.contains($0) }

            if !untried.isEmpty {
                // EXPAND one untried move (chosen via RNG for reproducible variety).
                let pick = untried[Int(rng.next() % UInt64(untried.count))]
                node.expanded.insert(pick)
                let child = Node(action: pick, mover: mover)
                node.children.append(child)
                state = simulation.apply(pick, in: state)
                node = child
                path.append(child)
                break  // proceed to simulation from the newly expanded node
            }

            // SELECT the best child among those legal in this world by UCB1.
            let candidates = node.children.filter { child in
                guard let a = child.action else { return false }
                return legal.contains(a)
            }
            guard let selected = selectUCB(from: candidates, parentVisits: node.visits, rng: &rng),
                let action = selected.action
            else { break }
            state = simulation.apply(action, in: state)
            node = selected
            path.append(selected)
        }

        // SIMULATE a random playout from the current state.
        let value = rollout(from: state, for: seat, rng: &rng)

        // BACKPROP: credit each node with the value from its mover's perspective.
        for visited in path {
            visited.visits += 1
            if let mover = visited.mover {
                // Reward from the mover's perspective; two-outcome games use value / (1 - value).
                visited.totalValue += (mover == seat) ? value : (1.0 - value)
            } else {
                visited.totalValue += value
            }
        }
    }

    /// UCB1 child selection, breaking exact ties with the injected RNG (R-AI-3.2).
    private func selectUCB(from children: [Node], parentVisits: Int, rng: inout SeededRNG) -> Node?
    {
        guard !children.isEmpty else { return nil }
        let logParent = log(Double(max(parentVisits, 1)))
        var best = -Double.infinity
        var leaders: [Node] = []
        for child in children {
            let score: Double
            if child.visits == 0 {
                score = .infinity  // always try an unvisited child first
            } else {
                let exploit = child.totalValue / Double(child.visits)
                let explore = config.explorationC * (logParent / Double(child.visits)).squareRoot()
                score = exploit + explore
            }
            if score > best {
                best = score
                leaders = [child]
            } else if score == best {
                leaders.append(child)
            }
        }
        if leaders.count == 1 { return leaders[0] }
        return leaders[Int(rng.next() % UInt64(leaders.count))]
    }

    /// A uniform-random playout to a terminal state (or the ply cap), returning its value for `seat`.
    private func rollout(from state: Simulation.SimState, for seat: SimSeat, rng: inout SeededRNG)
        -> Double
    {
        var current = state
        var ply = 0
        while ply < config.maxPlyPerRollout, !simulation.isTerminal(current) {
            let legal = simulation.legalActions(in: current)
            guard !legal.isEmpty else { break }
            let choice = legal[Int(rng.next() % UInt64(legal.count))]
            current = simulation.apply(choice, in: current)
            ply += 1
        }
        return simulation.value(of: current, for: seat)
    }

    /// The most-visited root action (robust child), ties broken by mean value then RNG (R-AI-3.2).
    private func bestRootAction(root: Node, rng: inout SeededRNG) -> Simulation.SimAction? {
        guard !root.children.isEmpty else { return nil }
        var bestVisits = -1
        for child in root.children where child.visits > bestVisits { bestVisits = child.visits }
        let mostVisited = root.children.filter { $0.visits == bestVisits }
        if mostVisited.count == 1 { return mostVisited[0].action }
        // Break by mean value, then uniformly by RNG.
        let best = Evaluator.argMax(
            mostVisited,
            score: { $0.visits > 0 ? $0.totalValue / Double($0.visits) : 0 },
            using: &rng)
        return best?.action
    }
}
