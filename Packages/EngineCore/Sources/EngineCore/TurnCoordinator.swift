// Turn models and the driver that runs them through the host boundary (R-SESS-2.4, R-SESS-3).
//
// A game advances by asking seats for moves and submitting them to the authoritative host. R-SESS-3 names
// three shapes that must be supported:
//
//   • sequential (R-SESS-3.1) — one seat acts at a time in turn order;
//   • simultaneous (R-SESS-3.2) — collect an action from every required seat, THEN resolve them together;
//   • out-of-turn windows (R-SESS-3.3) — a bounded window in which a non-active seat may act (an
//     interrupt), otherwise the window closes with no action.
//
// Each carries an OPTIONAL timeout; the default is none, meaning a decision is awaited indefinitely
// (R-SESS-3.4). When a timeout is set, the controller decision runs in a child `Task` that is cancelled on
// expiry, and the turn model's configured fallback is applied.
//
// The driver only ever `await`s a `PlayerController` and submits the result through the host's
// `ClientMessage.submit` boundary — it NEVER mutates state itself (R-SESS-1.1). Because it awaits an async
// decision, a `RemoteController` slots in with no change (R-SESS-2.4; `tech.md` rule 6). It lives in
// EngineCore because it is pure orchestration over controllers + the host boundary, with no UI (tech.md
// rule 1).

import Foundation

// MARK: - Timeout policy (R-SESS-3.4)

/// How long to wait for a controller's decision, and what to do if it does not arrive (R-SESS-3.4).
///
/// The DEFAULT is `.none`: the driver awaits the decision indefinitely — the correct behavior for a human
/// who may take as long as they like, and the spec's required default (R-SESS-3.4). When a positive
/// duration is given, the decision runs in a child `Task` cancelled on expiry; on timeout the driver
/// substitutes the `onTimeout` fallback action (or a pass when `nil`).
public struct TurnTimeout: Sendable {
    /// The wait budget in nanoseconds; `nil` means wait forever (the default, R-SESS-3.4).
    public let nanoseconds: UInt64?

    /// The action to submit if the decision times out; `nil` means pass / take no action.
    public let onTimeout: AnyGameAction?

    /// No timeout — await the decision indefinitely (the default, R-SESS-3.4).
    public static let none = TurnTimeout(nanoseconds: nil, onTimeout: nil)

    /// A timeout of `seconds`, falling back to `onTimeout` (a pass when `nil`) on expiry (R-SESS-3.4).
    public static func seconds(_ seconds: Double, onTimeout: AnyGameAction? = nil) -> TurnTimeout {
        TurnTimeout(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000), onTimeout: onTimeout)
    }

    /// A timeout of `nanoseconds`, falling back to `onTimeout` (a pass when `nil`) on expiry.
    public init(nanoseconds: UInt64?, onTimeout: AnyGameAction? = nil) {
        self.nanoseconds = nanoseconds
        self.onTimeout = onTimeout
    }
}

// MARK: - Turn model (R-SESS-3)

/// Which collection strategy the coordinator runs for a step (R-SESS-3).
///
/// The model names *how* seats are asked; it carries the participating seat(s) and the step's `timeout`
/// (default none, R-SESS-3.4). Resolution always goes through the host's submit boundary (R-SESS-1.1).
public enum TurnModel: Sendable {
    /// One seat acts, then the turn advances (R-SESS-3.1). The active seat is asked; its move is submitted.
    case sequential(seat: SeatID, timeout: TurnTimeout = .none)

    /// Every required seat is asked concurrently; all decisions are collected, THEN submitted together in
    /// seat order (R-SESS-3.2). No submission happens until every seat has decided (or timed out).
    case simultaneous(seats: [SeatID], timeout: TurnTimeout = .none)

    /// A bounded window in which a non-active seat MAY act (R-SESS-3.3). The eligible seat is asked; if it
    /// returns an action within the window it is submitted, otherwise the window closes with nothing done.
    case outOfTurn(seat: SeatID, timeout: TurnTimeout = .none)
}

// MARK: - Step outcome

/// What a single coordinator step did — for tests and a driver's own bookkeeping.
public struct TurnStepOutcome: Sendable {
    /// The `ResultEnvelope` for each action the step submitted, in submission order. Empty when nothing was
    /// submitted (e.g. an out-of-turn window that closed with no action, or a seat that passed).
    public let results: [ResultEnvelope]

    /// The seats that timed out and hit their fallback during this step (R-SESS-3.4).
    public let timedOutSeats: [SeatID]

    public init(results: [ResultEnvelope], timedOutSeats: [SeatID] = []) {
        self.results = results
        self.timedOutSeats = timedOutSeats
    }
}

// MARK: - TurnCoordinator (R-SESS-2.4, R-SESS-3)

/// Runs turn models against a `GameHost`, awaiting each seat's `PlayerController` and submitting through
/// the host boundary (R-SESS-2.4, R-SESS-3).
///
/// Construct it with the seat→controller bindings and a `Transport` to the host; then drive it with
/// `run(_:)` per step (or `play(sequence:)` to run a toy game to completion). It holds no game state and
/// never mutates any — resolution is always a `ClientMessage.submit` (R-SESS-1.1). Generic over the game
/// via the `Transport` it was given, like `GameHost`.
public struct TurnCoordinator: Sendable {
    /// The seat → controller bindings the driver awaits (R-SESS-2.2).
    private let controllers: [SeatID: any PlayerController]

    /// The channel to the authoritative host; every decision is submitted through it (R-SESS-4.2).
    private let transport: any Transport

    /// Bind each seat to its controller and the `transport` to the host (R-SESS-2.4).
    public init(controllers: [SeatID: any PlayerController], transport: any Transport) {
        self.controllers = controllers
        self.transport = transport
    }

    // MARK: Running a step (R-SESS-3)

    /// Run one `model`, returning what it submitted (R-SESS-3).
    ///
    /// Dispatches to the sequential / simultaneous / out-of-turn strategy; each awaits controllers (with
    /// the model's timeout) and submits through the host (R-SESS-1.1, R-SESS-2.4).
    @discardableResult
    public func run(_ model: TurnModel) async -> TurnStepOutcome {
        switch model {
        case .sequential(let seat, let timeout):
            return await runSequential(seat: seat, timeout: timeout)
        case .simultaneous(let seats, let timeout):
            return await runSimultaneous(seats: seats, timeout: timeout)
        case .outOfTurn(let seat, let timeout):
            return await runOutOfTurn(seat: seat, timeout: timeout)
        }
    }

    // MARK: Sequential (R-SESS-3.1)

    /// Ask the active `seat`, then submit its move — one seat at a time (R-SESS-3.1).
    private func runSequential(seat: SeatID, timeout: TurnTimeout) async -> TurnStepOutcome {
        let decision = await decide(seat: seat, timeout: timeout)
        guard let action = decision.action else {
            // A pass / no move (or an empty legal set) submits nothing.
            return TurnStepOutcome(results: [], timedOutSeats: decision.timedOut ? [seat] : [])
        }
        let result = await submit(action, by: seat)
        return TurnStepOutcome(results: [result], timedOutSeats: decision.timedOut ? [seat] : [])
    }

    // MARK: Simultaneous (R-SESS-3.2)

    /// Ask EVERY required seat concurrently, collect all decisions, THEN submit them in seat order
    /// (R-SESS-3.2).
    ///
    /// The distinguishing property: no action is submitted until every seat has decided (or timed out), so
    /// resolution is a single ordered batch rather than interleaved with collection.
    private func runSimultaneous(seats: [SeatID], timeout: TurnTimeout) async -> TurnStepOutcome {
        // Collect concurrently, keyed by seat so results are order-independent while gathering.
        let decisions = await withTaskGroup(of: (SeatID, Decision).self) { group in
            for seat in seats {
                group.addTask { (seat, await self.decide(seat: seat, timeout: timeout)) }
            }
            var collected: [SeatID: Decision] = [:]
            for await (seat, decision) in group {
                collected[seat] = decision
            }
            return collected
        }

        // THEN resolve: submit in the caller's seat order for a deterministic batch.
        var results: [ResultEnvelope] = []
        var timedOut: [SeatID] = []
        for seat in seats {
            guard let decision = decisions[seat] else { continue }
            if decision.timedOut { timedOut.append(seat) }
            if let action = decision.action {
                results.append(await submit(action, by: seat))
            }
        }
        return TurnStepOutcome(results: results, timedOutSeats: timedOut)
    }

    // MARK: Out-of-turn (R-SESS-3.3)

    /// Offer a bounded window to a non-active `seat`; submit its action if it acts, otherwise close the
    /// window with nothing done (R-SESS-3.3).
    ///
    /// Mechanically like sequential, but a `nil` decision (the seat declines / the window elapses) is the
    /// normal, expected outcome rather than a fallback — an out-of-turn window may simply pass unused.
    private func runOutOfTurn(seat: SeatID, timeout: TurnTimeout) async -> TurnStepOutcome {
        let decision = await decide(seat: seat, timeout: timeout)
        guard let action = decision.action else {
            return TurnStepOutcome(results: [], timedOutSeats: decision.timedOut ? [seat] : [])
        }
        let result = await submit(action, by: seat)
        return TurnStepOutcome(results: [result], timedOutSeats: decision.timedOut ? [seat] : [])
    }

    // MARK: Deciding with an optional timeout (R-SESS-3.4)

    /// A controller's resolved decision plus whether it came from a timeout fallback.
    private struct Decision: Sendable {
        let action: AnyGameAction?
        let timedOut: Bool
    }

    /// Ask `seat`'s controller for a move, honoring the `timeout` (R-SESS-3.4).
    ///
    /// With `.none` (the default), awaits the decision indefinitely. With a positive budget, races the
    /// decision against a timer: if the timer wins, the decision `Task` is cancelled and the `onTimeout`
    /// fallback (a pass when `nil`) is used (R-SESS-3.4). A seat with no bound controller passes.
    private func decide(seat: SeatID, timeout: TurnTimeout) async -> Decision {
        guard let controller = controllers[seat] else {
            return Decision(action: nil, timedOut: false)
        }
        let view = await requestView(for: seat)

        // No timeout: await the controller directly (R-SESS-3.4 default).
        guard let budget = timeout.nanoseconds else {
            let action = await controller.decide(view: view, seat: seat)
            return Decision(action: action, timedOut: false)
        }

        // Timed: race the decision against a sleep. Whichever finishes first wins; the loser's `Task` is
        // cancelled (structured concurrency), so a timed-out `decide` is actually cancelled (R-SESS-3.4,
        // R-NFR-PERF.4).
        return await withTaskGroup(of: DecisionRace.self) { group in
            group.addTask {
                let action = await controller.decide(view: view, seat: seat)
                return .decided(action)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: budget)
                return Task.isCancelled ? .decided(nil) : .expired
            }
            // Take the first result, cancel the rest.
            let first = await group.next() ?? .expired
            group.cancelAll()
            for await _ in group {}  // drain so children finish before returning

            switch first {
            case .decided(let action):
                return Decision(action: action, timedOut: false)
            case .expired:
                return Decision(action: timeout.onTimeout, timedOut: true)
            }
        }
    }

    /// The internal result of the decision-vs-timer race.
    private enum DecisionRace: Sendable {
        case decided(AnyGameAction?)
        case expired
    }

    // MARK: Host boundary (R-SESS-1.1, R-SESS-4)

    /// Fetch `seat`'s current redacted view through the host boundary (R-ENG-8.2). The controller sees only
    /// this — never raw state (R-SESS-1.2).
    private func requestView(for seat: SeatID) async -> PlayerView {
        let reply = await transport.send(.requestView(.seat(seat)))
        if case .viewUpdate(let view) = reply { return view }
        // The in-process transport always replies with a view to `requestView`; fall back defensively.
        return PlayerView(viewer: .seat(seat), scores: [:], phase: Phase(rawValue: "unknown"))
    }

    /// Submit `action` for `seat` through the host boundary and return its verdict (R-SESS-1.1, R-SESS-4.1).
    /// The coordinator NEVER mutates state — this is the only way it advances the game.
    private func submit(_ action: AnyGameAction, by seat: SeatID) async -> ResultEnvelope {
        let reply = await transport.send(.submit(ActionEnvelope(seat: seat, action: action)))
        if case .result(let result) = reply { return result }
        return .rejected(RuleViolation(code: "no-result", reason: "The host returned no result."))
    }
}

// MARK: - Driving a sequence to completion

extension TurnCoordinator {
    /// Run an ordered `sequence` of turn models, returning each step's outcome (R-SESS-3).
    ///
    /// A convenience for a scripted turn order (and the tests): drives the toy game by running the given
    /// models in order through the host boundary.
    @discardableResult
    public func play(sequence: [TurnModel]) async -> [TurnStepOutcome] {
        var outcomes: [TurnStepOutcome] = []
        for model in sequence {
            outcomes.append(await run(model))
        }
        return outcomes
    }
}
