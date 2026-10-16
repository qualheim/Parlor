// Player controllers — the async decision seam every seat is driven through (R-SESS-2).
//
// A seat's move can come from three sources that must be interchangeable: a local human (a UI gesture),
// an AI (a computed move), and — later — a remote peer (a move that arrives over the network). tech.md
// rule 6 and R-SESS-2.4 require the turn loop to be written against ONE async decision API so that the
// remote case "plugs in without restructuring". `PlayerController` is that API: a single `async` method
// that, given the seat's redacted `PlayerView`, returns the chosen action.
//
// The information barrier (R-SESS-1.2) is enforced by the signature itself: a controller receives only a
// `PlayerView` (which already carries the viewer's own `legalActions: [AnyGameAction]`, Views.swift) and
// its `SeatID` — there is NO parameter through which authoritative `State` could reach it. The AI's fuller
// barrier (strategy API over `(PlayerView, publicLog, legal)`) is task 4.4; here the seam is minimal and
// correct.
//
// Because `decide` is `async`, a decision can be arbitrarily slow (a human thinking, a network round-trip)
// without blocking the loop, and it participates in Swift structured concurrency: a superseded or
// timed-out decision is a cancelled `Task` (R-NFR-PERF.4 "cancellable and run off the main actor"; the AI
// strategy that honors the budget is task 4.4). Conformers observe `Task.isCancelled` / `Task.checkCancellation()`
// and unwind promptly.
//
// SCOPE (task 4.2). This file defines the protocol and the two conformers required now —
// `LocalHumanController` and `AIController` — plus documents the future `RemoteController` seam
// (R-SESS-2.3). NO networking code is written. The sequential/simultaneous/out-of-turn turn models and the
// driver that awaits these controllers live in `TurnCoordinator.swift`.

import Foundation

// MARK: - PlayerController (R-SESS-2.1)

/// The async decision API a seat is driven through (R-SESS-2.1).
///
/// A controller is asked to `decide` a move for `seat` given the seat's redacted `view`; it returns the
/// chosen `AnyGameAction`, or `nil` to pass / take no action where the turn model allows it. The method is
/// `async` so any conformer — a human fulfilled by a UI gesture, an AI computing a move, or a future remote
/// seat awaiting the network — plugs into the same turn loop without restructuring (R-SESS-2.4;
/// `tech.md` rule 6).
///
/// **Information barrier (R-SESS-1.2).** The only game input is the redacted `PlayerView`, whose own
/// `legalActions` enumerate the moves the seat may make; there is no parameter that exposes authoritative
/// `State`. A controller therefore *cannot* see hidden identities — the barrier is structural.
///
/// **Cancellation.** `decide` runs inside a `Task` the turn loop owns. When a decision is superseded or a
/// turn model's timeout fires, that `Task` is cancelled; conformers should honor `Task.isCancelled` (or
/// throw from `Task.checkCancellation()`), returning promptly. `Sendable` because a controller is held and
/// invoked across the concurrency boundary with the host actor (R-SESS-1.1).
public protocol PlayerController: Sendable {
    /// Decide `seat`'s action from its redacted `view`, or `nil` to pass / no-op where allowed
    /// (R-SESS-2.1).
    ///
    /// The view carries the seat's own `legalActions`; the returned action is expected to be one of them
    /// (the host re-validates at the boundary regardless, R-SESS-1). May suspend arbitrarily long; honors
    /// `Task` cancellation.
    func decide(view: PlayerView, seat: SeatID) async -> AnyGameAction?
}

// MARK: - LocalHumanController (R-SESS-2.2)

/// A controller whose decision is delivered externally by the UI — the seam GamesUI/TableKit drives
/// (R-SESS-2.2).
///
/// EngineCore has no UI, so a human's move cannot be *computed* here; it must be *awaited*. This controller
/// models exactly that: `decide` suspends until the UI calls ``provide(_:)`` with the action the human
/// chose (a drag that landed, a click-to-place, a "pass" button). It is an `actor` so the awaiting side and
/// the providing side are serialized safely across the concurrency boundary, and each continuation is
/// resumed exactly once.
///
/// Semantics:
///   • If `provide` is called before `decide`, the value is buffered and the next `decide` returns it
///     immediately (a UI that reacts faster than the loop asks does not lose the move).
///   • If `decide`'s `Task` is cancelled while awaiting, it resumes with `nil` (a pass/no-op) and the
///     pending continuation is cleared — the turn model then applies its fallback (R-SESS-3.4).
///   • Only one decision may be outstanding at a time (a seat is asked for one move at a time); a second
///     concurrent `decide` resolves any earlier waiter with `nil` before taking over.
public actor LocalHumanController: PlayerController {
    /// A move provided by the UI before `decide` asked for it, held until the next `decide` consumes it.
    private var buffered: AnyGameAction??

    /// The continuation of an in-flight `decide` awaiting a UI move, or `nil` when none is outstanding.
    private var waiting: CheckedContinuation<AnyGameAction?, Never>?

    public init() {
        self.buffered = nil
        self.waiting = nil
    }

    /// Deliver the human's chosen action (or `nil` to pass) to a waiting — or the next — `decide`
    /// (R-SESS-2.2).
    ///
    /// Called by the UI when the human commits a move. If a `decide` is currently awaiting, it is resumed
    /// with `action`; otherwise the value is buffered for the next `decide`.
    public func provide(_ action: AnyGameAction?) {
        if let continuation = waiting {
            waiting = nil
            continuation.resume(returning: action)
        } else {
            buffered = .some(action)
        }
    }

    /// Await the UI's decision for `seat` (R-SESS-2.1, R-SESS-2.2).
    ///
    /// Returns a buffered move immediately if one is pending; otherwise suspends until ``provide(_:)`` is
    /// called. Honors cancellation: a cancelled awaiting `decide` resolves to `nil` (a pass) so the turn
    /// model can apply its fallback (R-SESS-3.4). The `view`'s `legalActions` are what the UI offers the
    /// human; the parameter is part of the shared signature.
    public func decide(view: PlayerView, seat: SeatID) async -> AnyGameAction? {
        // Consume a move the UI provided ahead of the ask.
        if let pending = buffered {
            buffered = nil
            return pending
        }
        // Supersede any earlier waiter (one outstanding decision per seat).
        if let stale = waiting {
            waiting = nil
            stale.resume(returning: nil)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<AnyGameAction?, Never>) in
                // If cancellation already fired before we suspended, resume immediately as a pass.
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                waiting = continuation
            }
        } onCancel: {
            // Cancellation arrives off the actor; hop back on to resume the waiter exactly once.
            Task { await self.resumeForCancellation() }
        }
    }

    /// Resume a waiting `decide` with `nil` because its `Task` was cancelled (R-SESS-3.4). No-op if none
    /// is waiting (the continuation may have already resumed via `provide`).
    private func resumeForCancellation() {
        guard let continuation = waiting else { return }
        waiting = nil
        continuation.resume(returning: nil)
    }
}

// MARK: - AIController (R-SESS-2.2)

/// A controller that computes its move from an injected async strategy (R-SESS-2.2).
///
/// The concrete AI strategies (Easy/Medium/Hard, determinized Monte Carlo, ISMCTS — AIKit) are task 4.4.
/// This controller is the *seam* they drop into: it wraps a `@Sendable (PlayerView, SeatID) async ->
/// AnyGameAction?` closure, so a 4.4 strategy object becomes an `AIController` by supplying that closure.
/// The information barrier holds because the closure, like the protocol, receives only the redacted
/// `PlayerView` (R-SESS-1.2; the fuller `(PlayerView, publicLog, legal)` barrier is task 4.4).
///
/// A trivial built-in — ``firstLegal`` / ``randomLegal(seed:)`` — is provided so the controller and the
/// turn models are testable now without AIKit. `randomLegal` draws through a `SeededRNG` (RNG.swift) so the
/// choice is deterministic for a given seed, matching the engine's determinism contract (R-ENG-4.4).
public struct AIController: PlayerController {
    /// The injected decision function. `@Sendable` so the controller stays `Sendable` and can run
    /// off the main actor (R-NFR-PERF.4).
    private let strategy: @Sendable (PlayerView, SeatID) async -> AnyGameAction?

    /// Wrap an async decision `strategy` (R-SESS-2.2). AIKit strategies (task 4.4) inject their compute
    /// here.
    public init(strategy: @escaping @Sendable (PlayerView, SeatID) async -> AnyGameAction?) {
        self.strategy = strategy
    }

    /// Compute `seat`'s move via the injected strategy (R-SESS-2.1). Honors cancellation: if the enclosing
    /// `Task` is cancelled before the strategy runs, returns `nil` (a pass) so the turn model applies its
    /// fallback (R-SESS-3.4).
    public func decide(view: PlayerView, seat: SeatID) async -> AnyGameAction? {
        if Task.isCancelled { return nil }
        return await strategy(view, seat)
    }
}

extension AIController {
    /// A trivial controller that always plays the seat's first legal action (or passes when none)
    /// (R-SESS-2.2 testable built-in).
    ///
    /// Deterministic by construction — no RNG — so it drives the turn-model tests to a fixed outcome.
    public static var firstLegal: AIController {
        AIController { view, _ in view.legalActions.first }
    }

    /// A controller that picks uniformly among the seat's legal actions using a `SeededRNG`, so the choice
    /// is deterministic for a given `seed` (R-ENG-4.4; R-SESS-2.2 testable built-in).
    ///
    /// The generator is created per decision from `seed` combined with the number of legal actions, so the
    /// same view yields the same pick every run. Passes (returns `nil`) only when there are no legal
    /// actions.
    public static func randomLegal(seed: UInt64) -> AIController {
        AIController { view, _ in
            let legal = view.legalActions
            guard !legal.isEmpty else { return nil }
            var rng = SeededRNG(seed: seed &+ UInt64(legal.count))
            let index = Int(rng.next() % UInt64(legal.count))
            return legal[index]
        }
    }
}

// MARK: - RemoteController seam (documented, NOT implemented) (R-SESS-2.3)

// A future `RemoteController` conforms to `PlayerController` WITHOUT any change to the turn loop, host,
// rules, or UI (R-SESS-2.4). Its `decide` would await the remote peer's action over a network `Transport`
// (Transport.swift) — serialize the redacted `PlayerView` to the peer, await the `ClientMessage.submit`
// the peer sends back, and return its `AnyGameAction`. Because the loop already `await`s an async
// `decide`, and the whole boundary (`ActionEnvelope`/`PlayerView`/`ClientMessage`/`HostMessage`) is
// already `Codable`, multiplayer becomes a new `Transport` conformance — not a rewrite (design.md §2.9).
//
// Sketch ONLY — deliberately not compiled; NO networking is written in this spec (R-SESS-2.3):
//
//     public struct RemoteController: PlayerController {
//         let transport: any Transport          // a FUTURE network transport, not built here
//         public func decide(view: PlayerView, seat: SeatID) async -> AnyGameAction? {
//             // await the peer over `transport`, decode its ActionEnvelope, return the action
//         }
//     }
//
// See design.md §2.9 "RemoteController seam" for the architectural rationale.
