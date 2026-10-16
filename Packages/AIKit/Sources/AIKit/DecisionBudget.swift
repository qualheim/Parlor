// Decision budget and deadline — the time contract an AI decision runs under (R-AI-3.1, R-AI-3.3).
//
// R-AI-3.1 requires AI decisions to be *time-budgeted* and *cancellable* and to *run off the main actor*.
// R-AI-3.3 fixes the Hard-tier p95 budget (≤ 1.0 s per move; ≤ 1.5 s for poker and Tile Rummy),
// EXCLUDING cosmetic pacing delay (that lives in `AIPacing`, Pacing.swift — kept entirely separate).
//
// This file models the *compute* budget only, as data:
//
//   • `DecisionBudget` — a duration a decision may spend thinking. It does not name a game; a game/persona
//     supplies the concrete number (Hard defaults are provided as named constants matching tech.md).
//   • `Deadline` — a wall-clock instant the decision must finish by, derived from a budget at the moment
//     the decision starts. The toolkit's rollout/ISMCTS loops check the deadline between iterations and
//     return the best-so-far result when it passes, so a decision always respects its budget.
//
// CANCELLATION. Separate from the deadline: a decision also unwinds promptly when its enclosing `Task` is
// cancelled (a superseded turn, a quit) — the loops check `Task.isCancelled`. `Deadline.isReached` and the
// cancellation check together are what `shouldStop()` folds into one call the loops use.
//
// OFF THE MAIN ACTOR. Nothing here is `@MainActor`; every type is `Sendable` and the strategy's `decide`
// is a plain `async` method (Strategy.swift). The host/`AIController` runs it off the main actor — this
// module never touches the main actor, which is how "off the main actor" is honored (documented on
// `AIStrategy`).

import Foundation

// MARK: - DecisionBudget (R-AI-3.1, R-AI-3.3)

/// How long an AI decision may spend computing, as a duration — the compute budget, excluding cosmetic
/// pacing (R-AI-3.1, R-AI-3.3).
///
/// A budget is pure data measured in seconds; a game or persona picks the number. The `Deadline` a
/// decision actually runs against is derived from a budget at decision start (`deadline(from:)`). Named
/// constants mirror the tech.md p95 Hard budgets so games do not hardcode a magic number — but the type
/// itself is game-agnostic (R-AI-3.3). `Sendable` so it rides in a `DecisionContext` across the
/// concurrency boundary.
public struct DecisionBudget: Sendable, Hashable, Codable {
    /// The compute budget in seconds. Always `>= 0`; a zero budget means "make an immediate best-effort
    /// choice" (the loops run at least one cheap pass and return promptly).
    public let seconds: Double

    /// Create a budget from a duration in seconds, clamped to be non-negative.
    public init(seconds: Double) {
        self.seconds = max(0, seconds)
    }

    /// The standard Hard-tier per-move budget: 1.0 s p95 (R-AI-3.3, R-NFR-PERF.4).
    public static let hardDefault = DecisionBudget(seconds: 1.0)

    /// The relaxed Hard-tier budget for poker and Tile Rummy: 1.5 s p95 (R-AI-3.3, R-NFR-PERF.4).
    public static let hardPokerOrTileRummy = DecisionBudget(seconds: 1.5)

    /// A short budget suitable for a Medium tier's bounded rollouts.
    public static let mediumDefault = DecisionBudget(seconds: 0.25)

    /// A near-instant budget suitable for an Easy tier's shallow/heuristic choice.
    public static let easyDefault = DecisionBudget(seconds: 0.02)

    /// Derive the `Deadline` this budget imposes, starting from `now` (default: the current instant).
    ///
    /// Injecting `now` keeps the derivation testable and lets a caller align several decisions to one
    /// clock read. A decision started at `now` must finish by `now + seconds`.
    public func deadline(from now: Date = Date()) -> Deadline {
        Deadline(at: now.addingTimeInterval(seconds))
    }
}

// MARK: - Deadline (R-AI-3.1)

/// A wall-clock instant an AI decision must finish by (R-AI-3.1).
///
/// Derived from a `DecisionBudget` at decision start. The toolkit's iterative searches check `isReached`
/// between iterations and stop with their best-so-far result once it passes, so the decision always
/// respects its budget. `Sendable` and cheap to copy; it carries only the target `Date`.
public struct Deadline: Sendable, Hashable, Codable {
    /// The instant the decision must finish by.
    public let at: Date

    public init(at: Date) {
        self.at = at
    }

    /// A deadline that is already in the past — the loops will stop immediately and return best-so-far.
    /// Useful for "just make one quick pass" and for tests.
    public static let immediate = Deadline(at: .distantPast)

    /// A deadline effectively never reached — for tests that want an unbounded search bounded only by
    /// iteration count or cancellation.
    public static let never = Deadline(at: .distantFuture)

    /// Whether the deadline has passed as of `now` (default: the current instant).
    public func isReached(now: Date = Date()) -> Bool {
        now >= at
    }

    /// Seconds remaining until the deadline as of `now`, never negative.
    public func remaining(now: Date = Date()) -> Double {
        max(0, at.timeIntervalSince(now))
    }
}

// MARK: - Stop condition (R-AI-3.1)

/// Fold the two reasons an iterative search must stop — the deadline passing or the `Task` being
/// cancelled — into one check the rollout/ISMCTS loops call between iterations (R-AI-3.1).
///
/// Returns `true` when the search should stop and return its best-so-far result. Kept as a free function
/// (not a method) so the loops read plainly and it is trivially testable with a synthetic `deadline`.
/// Reads `Task.isCancelled` (never throws) so a partially-completed search still yields its best answer
/// rather than discarding work on cancellation.
public func shouldStopSearch(deadline: Deadline, now: Date = Date()) -> Bool {
    Task.isCancelled || deadline.isReached(now: now)
}
