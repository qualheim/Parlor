// The AI strategy API and the information barrier (R-AI-1.1, R-AI-3.1, R-AI-3.2, R-AI-6.1).
//
// This is the seam every AI plays through, and the place the AI information barrier is made structural.
//
// THE BARRIER (R-AI-1.1). A strategy is handed a single value — `DecisionContext` — and that value exposes
// ONLY:
//     • `view`         — the seat's redacted `PlayerView` (hidden pieces are opaque tokens, R-ENG-8.3);
//     • `publicLog`    — the public history (`PublicLog.swift`), free of hidden identity;
//     • `legalActions` — the moves the seat may make right now;
//     • `rng`          — an injected `SeededRNG` (R-AI-3.2), the ONLY source of AI randomness; and
//     • `deadline`     — the compute budget as a wall-clock instant (R-AI-3.1).
// There is deliberately NO member of `DecisionContext` (or of anything reachable from it) that is a
// `GameState` / authoritative `State`. A strategy therefore *cannot* reach authoritative state — the
// barrier is enforced by the types, not by convention (R-AI-1.1). The compile-time test in the test suite
// asserts this shape (no State-typed member).
//
// EXECUTION (R-AI-3.1, R-AI-3.2). `AIStrategy` is `Sendable` and its `decide`/`hint` are plain `async`
// methods with NO main-actor isolation, so the host/`AIController` runs them off the main actor. All
// randomness flows through `context.rng` (a value-type `SeededRNG`), so an AI-vs-AI run is reproducible
// from its seeds. Long-running work honors `context.deadline` and `Task` cancellation (see
// `DecisionBudget.swift`) and returns its best-so-far choice on timeout.
//
// HINTS (R-AI-6.1, R-AI-6.2). `AIStrategy` also vends a `hint(_:)` returning a `Hint` (Hint.swift): the
// suggested action plus a short plain-language explanation. Because a hint reuses the same context and
// toolkit as `decide`, coach mode reuses the very same call (R-AI-6.2).

import Foundation
import EngineCore

// MARK: - DecisionContext (R-AI-1.1)

/// The ONLY input an `AIStrategy` receives — the redacted view, the public log, the legal actions, an
/// injected RNG, and a deadline (R-AI-1.1, R-AI-3.1, R-AI-3.2).
///
/// **This is the information barrier.** Its members are exactly the public/legal inputs plus the injected
/// RNG and the budget; there is no `GameState`/authoritative-`State` member and nothing reachable from
/// here leads to one. A strategy is thus structurally unable to consult hidden state (R-AI-1.1). The
/// `rng` is a `var` because drawing from a `SeededRNG` mutates it; a strategy takes a local mutable copy
/// (or the toolkit threads it) so draws are deterministic for a given seed (R-AI-3.2). `Sendable` so the
/// whole context crosses to an off-main-actor decision (R-AI-3.1).
public struct DecisionContext: Sendable {
    /// The seat's redacted snapshot — hidden pieces appear only as opaque tokens (R-ENG-8.2, R-ENG-8.3).
    /// Carries the seat's own `legalActions`, but `legalActions` below is the authoritative list a
    /// strategy chooses from.
    public let view: PlayerView

    /// The public, redacted history the strategy may read to model opponents (R-AI-1.1).
    public let publicLog: PublicLog

    /// The seat whose move is being decided.
    public let seat: SeatID

    /// The legal actions the seat may take right now — the strategy returns one of these (or `nil`).
    public let legalActions: [AnyGameAction]

    /// The injected RNG — the ONLY source of AI randomness, so AI-vs-AI is reproducible (R-AI-3.2).
    /// A `var` because `SeededRNG.next()` mutates; the toolkit threads it through `inout`.
    public var rng: SeededRNG

    /// The instant the decision must finish by — the compute budget (R-AI-3.1, R-AI-3.3).
    public let deadline: Deadline

    public init(
        view: PlayerView,
        publicLog: PublicLog,
        seat: SeatID,
        legalActions: [AnyGameAction],
        rng: SeededRNG,
        deadline: Deadline
    ) {
        self.view = view
        self.publicLog = publicLog
        self.seat = seat
        self.legalActions = legalActions
        self.rng = rng
        self.deadline = deadline
    }
}

// MARK: - AIStrategy (R-AI-1.1, R-AI-3.1, R-AI-6.1)

/// The protocol every AI plays through — it decides an action, and it can explain a suggested one
/// (R-AI-1.1, R-AI-6.1).
///
/// **Barrier & execution.** `decide`/`hint` receive only a `DecisionContext`, so they cannot see
/// authoritative state (R-AI-1.1). Both are `async` and carry no main-actor isolation, and the type is
/// `Sendable`, so the host runs a strategy off the main actor (R-AI-3.1). Randomness comes only from
/// `context.rng` (R-AI-3.2); long work honors `context.deadline` and `Task` cancellation, returning the
/// best choice found so far on timeout (`DecisionBudget.swift`).
///
/// A default `hint(_:)` is provided that wraps `decide` with a generic explanation, so a strategy gets a
/// working hint for free and only overrides when it can phrase a better reason (R-AI-6.1). Coach mode
/// calls the same `hint(_:)` (R-AI-6.2).
public protocol AIStrategy: Sendable {
    /// Choose a legal action for `context.seat`, or `nil` to pass / take no action where allowed
    /// (R-AI-1.1).
    ///
    /// Must return one of `context.legalActions` (or `nil`); the host re-validates at the boundary
    /// regardless (R-SESS-1). Honors `context.deadline` and `Task` cancellation.
    func decide(_ context: DecisionContext) async -> AnyGameAction?

    /// Suggest an action plus a short plain-language explanation (R-AI-6.1); reused by coach mode
    /// (R-AI-6.2). Returns `nil` only when there is no legal action to suggest.
    func hint(_ context: DecisionContext) async -> Hint?
}

extension AIStrategy {
    /// A generic hint: run `decide`, and if it chose an action, wrap it with a neutral explanation
    /// (R-AI-6.1).
    ///
    /// Games override `hint` to supply a specific, game-flavored reason ("Playing the eight now saves it
    /// for later"); this default gives every strategy a working hint without extra code, and guarantees
    /// the suggested action is exactly what the strategy would play. Coach mode uses this same call
    /// (R-AI-6.2).
    public func hint(_ context: DecisionContext) async -> Hint? {
        guard let action = await decide(context) else { return nil }
        return Hint(action: action, explanation: Hint.genericExplanation)
    }
}

// MARK: - Bridging to EngineCore's AIController (R-SESS-2.2)

/// Turn any `AIStrategy` into the `@Sendable (PlayerView, SeatID) async -> AnyGameAction?` closure that
/// EngineCore's `AIController` wraps (PlayerController.swift), given how to build a full `DecisionContext`
/// (R-SESS-2.2, R-AI-1.1).
///
/// The host owns the pieces a `DecisionContext` needs that a bare `PlayerView` lacks — the `PublicLog`,
/// the injected `SeededRNG`, and the `Deadline` from the chosen budget. `contextProvider` supplies them
/// per decision (typically: current public log, a per-decision RNG derived from the AI seed, and
/// `budget.deadline(from: Date())`). This is the seam a 4.6 game AI + the session layer use to run a
/// strategy inside the existing turn loop, off the main actor, without touching EngineCore.
public struct StrategyController: Sendable {
    private let strategy: any AIStrategy
    private let contextProvider: @Sendable (PlayerView, SeatID) -> (PublicLog, SeededRNG, Deadline)

    /// Wrap `strategy`, using `contextProvider` to assemble the non-view inputs of each decision.
    public init(
        strategy: any AIStrategy,
        contextProvider:
            @escaping @Sendable (PlayerView, SeatID) -> (PublicLog, SeededRNG, Deadline)
    ) {
        self.strategy = strategy
        self.contextProvider = contextProvider
    }

    /// The closure an `AIController` (EngineCore) wraps: build the context and run the strategy off the
    /// main actor (R-AI-3.1). Honors cancellation before starting.
    public var decisionClosure: @Sendable (PlayerView, SeatID) async -> AnyGameAction? {
        let strategy = self.strategy
        let provide = self.contextProvider
        return { view, seat in
            if Task.isCancelled { return nil }
            let (publicLog, rng, deadline) = provide(view, seat)
            let context = DecisionContext(
                view: view,
                publicLog: publicLog,
                seat: seat,
                legalActions: view.legalActions,
                rng: rng,
                deadline: deadline)
            return await strategy.decide(context)
        }
    }
}
