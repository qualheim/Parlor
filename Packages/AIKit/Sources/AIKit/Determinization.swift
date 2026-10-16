// Determinization sampler — sample a plausible hidden state consistent with everything observed
// (R-AI-2.2, R-AI-3.2).
//
// A strategy sees only its own pieces plus public zones plus tokenized hidden piles (a `PlayerView`); it
// does not know *which* unseen piece is *where*. To reason with Monte Carlo / ISMCTS it must first invent
// a concrete, *plausible* full assignment of the unseen pieces to the hidden slots — a "determinization".
// Doing this well means respecting everything observed:
//
//   • the KNOWN pieces stay fixed (they are not re-dealt);
//   • each hidden ZONE's count is honored (a zone with N hidden slots gets exactly N pieces); and
//   • CONSTRAINTS inferred from the public log are obeyed — most importantly *voids*: a seat that failed
//     to follow suit is known not to hold that suit, so that seat's hidden slots must never be filled
//     with an excluded category (R-AI-2.2).
//
// GENERICITY. AIKit cannot know a specific game's pieces, so the sampler is generic over an opaque
// `Item` (`Hashable & Sendable`) and an opaque `Category` (`Hashable & Sendable`). A game supplies:
//   • the multiset of `unseen` items (the pieces the viewer cannot see but that must be somewhere),
//   • the hidden `slots` grouped by an opaque `Slot` key (usually a hidden zone / a seat's hand), each
//     with a required count, and
//   • a `category(of:)` function mapping an item to the category a void is expressed over (e.g. a card's
//     suit). A game with no void concept passes categories it never excludes.
// The constraints are pure DATA (`DeterminizationConstraints`): "slot S excludes category C". This keeps
// the sampler game-agnostic while still enforcing inferred voids.
//
// REPRODUCIBILITY. All randomness flows through an injected `SeededRNG` (R-AI-3.2): the same seed and
// inputs always produce the same sample. The sampler uses the engine's own unbiased shuffle
// (`EngineCore.Shuffle`) so it never touches `Int.random`/`SystemRandomNumberGenerator` (forbidden,
// R-ENG-4.2).
//
// ALGORITHM. Constraint-satisfaction by constrained random assignment with backtracking: slots are filled
// most-constrained-first, each from a shuffled pool of the items still legal for it; if a dead end is hit
// (a slot cannot be satisfied), it backtracks. For the small hands these AIs face this is fast and, given a
// feasible instance, always finds an assignment; infeasible instances return `nil` rather than looping.

import Foundation
import EngineCore

// MARK: - Determinization constraints (R-AI-2.2)

/// Constraints inferred from the public log that a sampled hidden state must respect — chiefly inferred
/// voids (R-AI-2.2).
///
/// Modeled as pure data so a game can build it from the `PublicLog` (e.g. "seat-2 discarded off-suit, so
/// seat-2 is void in hearts") without the sampler knowing any game rules. `Slot` keys a hidden group
/// (typically an opponent's hand / a hidden zone), `Category` is whatever a void is expressed over (a
/// card's suit, a tile's color). Generic over both so it stays game-agnostic; both are `Hashable`.
public struct DeterminizationConstraints<Slot: Hashable & Sendable, Category: Hashable & Sendable>:
    Sendable
{
    /// For each slot, the set of categories it may NOT contain — the inferred voids (R-AI-2.2). A slot
    /// absent from this map has no void.
    public private(set) var voids: [Slot: Set<Category>]

    public init(voids: [Slot: Set<Category>] = [:]) {
        self.voids = voids
    }

    /// Record that `slot` is void in `category` — it can hold no item of that category (R-AI-2.2).
    ///
    /// Idempotent and additive: adding the same void twice is a no-op; a slot may accumulate several
    /// voids. This is the mutation a game calls as it reads voids out of the public log.
    public mutating func addVoid(slot: Slot, category: Category) {
        voids[slot, default: []].insert(category)
    }

    /// Whether `slot` is known void in `category` (may not hold an item of that category).
    public func isVoid(slot: Slot, category: Category) -> Bool {
        voids[slot]?.contains(category) ?? false
    }
}

// MARK: - Hidden slot group (R-AI-2.2)

/// A group of hidden slots that must be filled with a given count of unseen items — typically one
/// opponent's hidden hand or a hidden zone (R-AI-2.2).
///
/// The sampler assigns exactly `count` unseen items to this group, none of them in a category the
/// constraints mark this `key` void in. `key` is the same opaque `Slot` the constraints use, so voids
/// line up with groups.
public struct HiddenGroup<Slot: Hashable & Sendable>: Sendable, Hashable {
    /// The slot key this group fills — matches the constraints' `Slot` (R-AI-2.2).
    public let key: Slot
    /// How many unseen items this group must receive (its hidden count, honored exactly).
    public let count: Int

    public init(key: Slot, count: Int) {
        self.key = key
        self.count = count
    }
}

// MARK: - Sample (R-AI-2.2)

/// A sampled determinization: which unseen items landed in each hidden slot group (R-AI-2.2).
///
/// The `assignment` maps each group's `Slot` key to the concrete items placed there. Together with the
/// (unchanged) known pieces the caller already holds, this is a plausible *full* hidden state a rollout /
/// ISMCTS can play out. Every group's count is honored and no void is violated (guaranteed by the
/// sampler).
public struct Determinization<Slot: Hashable & Sendable, Item: Hashable & Sendable>: Sendable {
    /// The items assigned to each hidden group, keyed by the group's `Slot` (R-AI-2.2).
    public let assignment: [Slot: [Item]]

    public init(assignment: [Slot: [Item]]) {
        self.assignment = assignment
    }
}

// MARK: - DeterminizationSampler (R-AI-2.2, R-AI-3.2)

/// A generic sampler that assigns unseen items to hidden slot groups, honoring counts and inferred voids,
/// using an injected `SeededRNG` (R-AI-2.2, R-AI-3.2).
///
/// Game-agnostic: a game provides the unseen items, the hidden groups (with counts), the void
/// constraints, and a `category(of:)` mapping; the sampler returns a plausible assignment consistent with
/// all of them, or `nil` if the instance is infeasible. Sampling is deterministic for a given `rng`
/// state, so `sample` with the same seed yields the same result (R-AI-3.2). Draws only through
/// `EngineCore.Shuffle` (no forbidden RNG APIs, R-ENG-4.2).
public enum DeterminizationSampler {
    /// Sample one plausible assignment of `unseen` items to `groups`, obeying `constraints` (inferred
    /// voids) and each group's count (R-AI-2.2).
    ///
    /// - Parameters:
    ///   - unseen: the multiset of items the viewer cannot see but that must be placed somewhere.
    ///   - groups: the hidden slot groups to fill, each with its required count.
    ///   - constraints: inferred voids per slot (R-AI-2.2).
    ///   - category: maps an item to the category a void is expressed over (e.g. a card's suit).
    ///   - rng: the injected generator; the same state yields the same sample (R-AI-3.2).
    /// - Returns: a `Determinization` honoring all counts and voids, or `nil` if no assignment exists
    ///   (e.g. the counts do not add up, or voids make a group unfillable).
    public static func sample<Slot, Item, Category>(
        unseen: [Item],
        groups: [HiddenGroup<Slot>],
        constraints: DeterminizationConstraints<Slot, Category>,
        category: (Item) -> Category,
        using rng: inout SeededRNG
    ) -> Determinization<Slot, Item>? {
        let totalNeeded = groups.reduce(0) { $0 + $1.count }
        guard totalNeeded == unseen.count else { return nil }
        if groups.isEmpty { return Determinization(assignment: [:]) }

        // Shuffle the pool once with the injected RNG so the assignment is randomized yet reproducible.
        var pool = unseen
        Shuffle.fisherYates(&pool, using: &rng)

        // Fill most-constrained groups first (fewer legal items per required slot) to cut backtracking.
        // A group's legal items are those whose category is not void for its slot.
        let ordered = groups.sorted { lhs, rhs in
            let l = legalCount(for: lhs, in: pool, constraints: constraints, category: category)
            let r = legalCount(for: rhs, in: pool, constraints: constraints, category: category)
            // Fewer legal items relative to the count needed is "more constrained".
            return (l - lhs.count) < (r - rhs.count)
        }

        var remaining = pool
        var assignment: [Slot: [Item]] = [:]
        guard
            assign(
                groups: ordered,
                index: 0,
                remaining: &remaining,
                assignment: &assignment,
                constraints: constraints,
                category: category)
        else { return nil }

        return Determinization(assignment: assignment)
    }

    /// How many items in `pool` are legal for `group` (category not void for its slot).
    private static func legalCount<Slot, Item, Category>(
        for group: HiddenGroup<Slot>,
        in pool: [Item],
        constraints: DeterminizationConstraints<Slot, Category>,
        category: (Item) -> Category
    ) -> Int {
        pool.reduce(0) { count, item in
            constraints.isVoid(slot: group.key, category: category(item)) ? count : count + 1
        }
    }

    /// Recursively fill `groups[index...]` from `remaining`, backtracking on dead ends.
    ///
    /// For the current group, it takes the first `count` legal items from `remaining` (which is already
    /// shuffled, so this is a random-but-reproducible choice), records them, and recurses. If the recursion
    /// fails it restores `remaining`/`assignment` and tries a different legal subset by rotating the pool;
    /// once every rotation is exhausted it reports failure so an outer group can rechoose. For the small
    /// hands these AIs face the search is shallow and fast.
    private static func assign<Slot, Item, Category>(
        groups: [HiddenGroup<Slot>],
        index: Int,
        remaining: inout [Item],
        assignment: inout [Slot: [Item]],
        constraints: DeterminizationConstraints<Slot, Category>,
        category: (Item) -> Category
    ) -> Bool {
        if index == groups.count {
            return remaining.isEmpty
        }
        let group = groups[index]

        // Partition `remaining` into items legal for this group and the rest, preserving the shuffled
        // order so choices stay reproducible.
        let legalIndices = remaining.indices.filter { i in
            !constraints.isVoid(slot: group.key, category: category(remaining[i]))
        }
        guard legalIndices.count >= group.count else { return false }

        // Try successive windows of `count` legal items (rotating start) so backtracking explores distinct
        // subsets deterministically without an RNG re-draw.
        let windowCount = legalIndices.count - group.count + 1
        for start in 0..<windowCount {
            let chosenPositions = Array(legalIndices[start..<(start + group.count)])
            let chosenSet = Set(chosenPositions)
            let chosen = chosenPositions.map { remaining[$0] }
            let rest = remaining.indices.filter { !chosenSet.contains($0) }.map { remaining[$0] }

            let savedRemaining = remaining
            remaining = rest
            assignment[group.key] = chosen

            if assign(
                groups: groups,
                index: index + 1,
                remaining: &remaining,
                assignment: &assignment,
                constraints: constraints,
                category: category)
            {
                return true
            }

            // Backtrack.
            remaining = savedRemaining
            assignment[group.key] = nil
        }
        return false
    }
}
