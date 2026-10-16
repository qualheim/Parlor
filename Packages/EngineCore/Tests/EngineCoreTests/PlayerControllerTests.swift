import Foundation
import Testing

@testable import EngineCore

// Tests for the PlayerController seam, the two controllers, and the turn-model coordinator (task 4.2;
// R-SESS-2, R-SESS-3).
//
// They prove:
//   • LocalHumanController.decide awaits a UI-provided move and returns it (buffered or awaited)
//     (R-SESS-2.2);
//   • AIController.decide returns the injected strategy's action; the random-legal built-in is
//     deterministic under a seed (R-SESS-2.2, R-ENG-4.4);
//   • sequential: two AI controllers play a toy game to completion, each move submitted through the host,
//     in turn order (R-SESS-3.1);
//   • simultaneous: two seats are collected concurrently and only then resolved together (R-SESS-3.2);
//   • out-of-turn: a non-active seat's action is accepted in a window; an unused window closes cleanly
//     (R-SESS-3.3);
//   • timeouts: default none awaits until provided; a short timeout cancels the decision and applies the
//     fallback; the decision Task is actually cancelled (R-SESS-3.4);
//   • the information barrier: decide receives only a redacted PlayerView (R-SESS-1.2).

// MARK: - Toy multi-seat game: "Count"
//
// Two seats share a public counter starting at 0. On its turn a seat may `.bump`, which adds 1 and passes
// the turn to the other seat; the hand ends when the counter reaches `target` (default 3). `legalActions`
// returns `.bump` only for the seat whose turn it is — so a controller playing the first legal action
// drives strict alternation, which lets a test assert turn order. A second action, `.mark`, is legal for
// EITHER seat at ANY time and simply records that a seat acted (used to exercise simultaneous and
// out-of-turn windows without affecting turn order). Self-contained: proves the coordinator runs a game
// with no EngineCore edits (R-ENG-5.6).

private let seatA = SeatID.index(0)
private let seatB = SeatID.index(1)

private struct CountState: GameState, Equatable {
    var counter: Int
    var turn: SeatID
    var target: Int
    /// Seats that have `.mark`ed, in order — observable via the score map for out-of-turn/simultaneous.
    var marks: [SeatID]
}

private enum CountAction: GameAction, Equatable {
    case bump
    case mark
}

private struct CountOptions: GameOptions, Equatable {
    var target: Int = 3
}

private struct Count: GameDefinition {
    typealias State = CountState
    typealias Action = CountAction
    typealias Options = CountOptions

    static let metadata = GameMetadata(
        id: "count",
        name: "Count",
        family: .shedding,
        seatRange: 2...2,
        typicalDuration: DurationRange(minMinutes: 1, maxMinutes: 1),
        complexity: .light)

    static let optionsSchema = OptionsSchema(defaults: CountOptions())

    let undoPolicy: UndoPolicy = .none

    func initialState(options: CountOptions, seed: UInt64) -> CountState {
        CountState(counter: 0, turn: seatA, target: options.target, marks: [])
    }

    func phase(of state: CountState) -> Phase {
        isTerminal(state) ? Phase(rawValue: "done") : Phase(rawValue: "play")
    }

    func legalActions(for seat: SeatID, in state: CountState) -> [CountAction] {
        guard !isTerminal(state) else { return [] }
        // `.mark` is always available to either seat; `.bump` only on the seat's turn.
        var actions: [CountAction] = [.mark]
        if seat == state.turn { actions.insert(.bump, at: 0) }
        return actions
    }

    func apply(_ action: CountAction, by seat: SeatID, to state: CountState)
        -> Result<(CountState, [GameEvent]), RuleViolation>
    {
        guard !isTerminal(state) else {
            return .failure(RuleViolation(code: "hand-over", reason: "The hand is already over."))
        }
        switch action {
        case .bump:
            guard seat == state.turn else {
                return .failure(
                    RuleViolation(code: "not-your-turn", reason: "It is not your turn to bump."))
            }
            var next = state
            next.counter += 1
            next.turn = (seat == seatA) ? seatB : seatA
            var events: [GameEvent] = [.turnChanged(to: next.turn)]
            if isTerminal(next) { events.append(.handEnded(outcome(next))) }
            return .success((next, events))
        case .mark:
            var next = state
            next.marks.append(seat)
            return .success(
                (next, [.captioned(LocalizedKey("caption.marked", arguments: [seat.raw]))]))
        }
    }

    func isTerminal(_ state: CountState) -> Bool { state.counter >= state.target }

    func outcome(_ state: CountState) -> HandOutcome {
        guard isTerminal(state) else { return .draw }
        // The seat that made the final bump (whoever was NOT to move) wins.
        let winner = state.turn == seatA ? seatB : seatA
        return HandOutcome(winners: [winner], scores: [winner: 1])
    }

    func redactedView(of state: CountState, for viewer: Viewer) -> PlayerView {
        let seat = seatOf(viewer)
        let legal = seat.map { legalActions(for: $0, in: state) } ?? []
        let erased = legal.compactMap { try? AnyGameAction($0) }
        // Expose counter + mark count through the score map so tests can observe progress via the view.
        var scores: [SeatID: Int] = [seatA: 0, seatB: 0]
        for m in state.marks { scores[m, default: 0] += 1 }
        return PlayerView(
            viewer: viewer,
            zones: [],
            scores: scores,
            phase: phase(of: state),
            legalActions: erased)
    }

    private func seatOf(_ viewer: Viewer) -> SeatID? {
        if case .seat(let s) = viewer { return s }
        return nil
    }
}

private func makeCountHost(target: Int = 3) -> GameHost<Count> {
    GameHost(game: Count(), options: CountOptions(target: target), seats: [seatA, seatB], seed: 7)
}

// A controller that never decides — used to force a timeout (R-SESS-3.4). It records whether its
// enclosing Task was cancelled, so a test can assert cancellation actually happened.
private actor NeverController: PlayerController {
    private(set) var wasCancelled = false

    func decide(view: PlayerView, seat: SeatID) async -> AnyGameAction? {
        await withTaskCancellationHandler {
            // Suspend "forever"; a cancelled sleep throws and we fall through to observe cancellation.
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return nil
        } onCancel: {
            Task { await self.markCancelled() }
        }
    }

    private func markCancelled() { wasCancelled = true }
    func cancelledFlag() -> Bool { wasCancelled }
}

@Suite("PlayerController + turn models (R-SESS-2, R-SESS-3)")
struct PlayerControllerTests {

    // MARK: - LocalHumanController (R-SESS-2.2)

    @Test("LocalHumanController.decide awaits a provided action and returns it")
    func humanAwaitsProvidedAction() async throws {
        let human = LocalHumanController()
        let action = try AnyGameAction(CountAction.bump)
        let view = PlayerView(viewer: .seat(seatA), scores: [:], phase: Phase(rawValue: "play"))

        // Start the awaiting decision, then provide the move from "the UI".
        async let decided = human.decide(view: view, seat: seatA)
        // Yield so `decide` reaches its suspension point before we provide.
        await Task.yield()
        await human.provide(action)
        let result = await decided
        #expect(result == action)
    }

    @Test("LocalHumanController returns a move provided before decide was called (buffered)")
    func humanBuffersEarlyProvide() async throws {
        let human = LocalHumanController()
        let action = try AnyGameAction(CountAction.mark)
        await human.provide(action)
        let view = PlayerView(viewer: .seat(seatA), scores: [:], phase: Phase(rawValue: "play"))
        let result = await human.decide(view: view, seat: seatA)
        #expect(result == action)
    }

    // MARK: - AIController (R-SESS-2.2, R-ENG-4.4)

    @Test("AIController.decide returns the injected strategy's action")
    func aiReturnsInjectedStrategy() async throws {
        let chosen = try AnyGameAction(CountAction.bump)
        let ai = AIController { _, _ in chosen }
        let view = PlayerView(viewer: .seat(seatA), scores: [:], phase: Phase(rawValue: "play"))
        let result = await ai.decide(view: view, seat: seatA)
        #expect(result == chosen)
    }

    @Test("AIController.firstLegal plays the first legal action; passes when none")
    func aiFirstLegal() async throws {
        let legal = [try AnyGameAction(CountAction.bump), try AnyGameAction(CountAction.mark)]
        let view = PlayerView(
            viewer: .seat(seatA), scores: [:], phase: Phase(rawValue: "play"), legalActions: legal)
        #expect(await AIController.firstLegal.decide(view: view, seat: seatA) == legal.first)

        let empty = PlayerView(viewer: .seat(seatA), scores: [:], phase: Phase(rawValue: "done"))
        #expect(await AIController.firstLegal.decide(view: empty, seat: seatA) == nil)
    }

    @Test("AIController.randomLegal is deterministic for a given seed")
    func aiRandomLegalDeterministic() async throws {
        let legal = [
            try AnyGameAction(CountAction.bump),
            try AnyGameAction(CountAction.mark),
        ]
        let view = PlayerView(
            viewer: .seat(seatA), scores: [:], phase: Phase(rawValue: "play"), legalActions: legal)
        let first = await AIController.randomLegal(seed: 99).decide(view: view, seat: seatA)
        let again = await AIController.randomLegal(seed: 99).decide(view: view, seat: seatA)
        #expect(first == again)
        #expect(first != nil)
        #expect(legal.contains(first!))
    }

    // MARK: - Sequential turn model (R-SESS-3.1)

    @Test("sequential: two AI controllers play the toy game to completion in turn order")
    func sequentialPlaysToCompletion() async {
        let host = makeCountHost(target: 3)
        let transport = InProcessTransport(host: host)
        // Each controller plays the first legal action; on its turn that is `.bump`.
        let coordinator = TurnCoordinator(
            controllers: [seatA: AIController.firstLegal, seatB: AIController.firstLegal],
            transport: transport)

        // Turn order alternates A, B, A. After three bumps the counter hits the target.
        let outcomes = await coordinator.play(sequence: [
            .sequential(seat: seatA),
            .sequential(seat: seatB),
            .sequential(seat: seatA),
        ])

        // Every step submitted exactly one accepted action, in turn order.
        #expect(outcomes.count == 3)
        for outcome in outcomes {
            #expect(outcome.results.count == 1)
            #expect(outcome.results.first?.isAccepted == true)
        }
        // The game reached its terminal phase, observed only through a view (R-SESS-1.2).
        let view = await host.view(for: .seat(seatA))
        #expect(view.phase == Phase(rawValue: "done"))
        // The log grew by one entry per accepted bump.
        #expect(await host.logCount == 3)
    }

    // MARK: - Simultaneous turn model (R-SESS-3.2)

    @Test("simultaneous: both seats are collected before either is resolved")
    func simultaneousCollectsBeforeResolving() async throws {
        let host = makeCountHost()
        let transport = InProcessTransport(host: host)

        // A barrier controller that only returns once BOTH seats have entered decide — proving the
        // coordinator awaits all seats concurrently before resolving any (R-SESS-3.2).
        actor Barrier {
            private var entered = 0
            private var waiters: [CheckedContinuation<Void, Never>] = []
            func arriveAndWait() async {
                entered += 1
                if entered >= 2 {
                    for w in waiters { w.resume() }
                    waiters.removeAll()
                    return
                }
                await withCheckedContinuation { waiters.append($0) }
            }
        }
        let barrier = Barrier()
        struct BarrierController: PlayerController {
            let barrier: Barrier
            let action: AnyGameAction
            func decide(view: PlayerView, seat: SeatID) async -> AnyGameAction? {
                await barrier.arriveAndWait()
                return action
            }
        }
        let mark = try AnyGameAction(CountAction.mark)
        let coordinator = TurnCoordinator(
            controllers: [
                seatA: BarrierController(barrier: barrier, action: mark),
                seatB: BarrierController(barrier: barrier, action: mark),
            ],
            transport: transport)

        // If collection were sequential (submit A, then ask B), the barrier would deadlock and this would
        // time out. Reaching here proves both were collected concurrently, then resolved.
        let outcome = await coordinator.run(.simultaneous(seats: [seatA, seatB]))
        #expect(outcome.results.count == 2)
        #expect(outcome.results.allSatisfy { $0.isAccepted })

        // Both marks landed (both seats' actions resolved).
        let view = await host.view(for: .spectator)
        #expect((view.scores[seatA] ?? 0) + (view.scores[seatB] ?? 0) == 2)
    }

    // MARK: - Out-of-turn window (R-SESS-3.3)

    @Test("out-of-turn: a non-active seat's action is accepted in the window")
    func outOfTurnAccepted() async throws {
        let host = makeCountHost()
        let transport = InProcessTransport(host: host)
        // It is seatA's turn (initial). seatB acts out of turn with `.mark`, which is legal for either.
        let coordinator = TurnCoordinator(
            controllers: [seatB: AIController { _, _ in try? AnyGameAction(CountAction.mark) }],
            transport: transport)

        let outcome = await coordinator.run(.outOfTurn(seat: seatB))
        #expect(outcome.results.count == 1)
        #expect(outcome.results.first?.isAccepted == true)

        let view = await host.view(for: .spectator)
        #expect(view.scores[seatB] == 1)
    }

    @Test("out-of-turn: an unused window closes with nothing submitted")
    func outOfTurnWindowClosesUnused() async {
        let host = makeCountHost()
        let transport = InProcessTransport(host: host)
        // A controller that declines (returns nil) — the window elapses unused.
        let coordinator = TurnCoordinator(
            controllers: [seatB: AIController { _, _ in nil }],
            transport: transport)

        let outcome = await coordinator.run(.outOfTurn(seat: seatB))
        #expect(outcome.results.isEmpty)
        #expect(await host.logCount == 0)
    }

    // MARK: - Timeouts + cancellation (R-SESS-3.4)

    @Test("timeout none: decide awaits until the move is provided (no premature return)")
    func timeoutNoneAwaitsIndefinitely() async throws {
        let host = makeCountHost()
        let transport = InProcessTransport(host: host)
        let human = LocalHumanController()
        let coordinator = TurnCoordinator(controllers: [seatA: human], transport: transport)

        // Run the step; it must NOT complete until we provide a move.
        async let outcome = coordinator.run(.sequential(seat: seatA, timeout: .none))
        // Give the coordinator time to reach the await; it should still be pending.
        try await Task.sleep(nanoseconds: 50_000_000)
        await human.provide(try AnyGameAction(CountAction.bump))
        let result = await outcome
        #expect(result.results.count == 1)
        #expect(result.results.first?.isAccepted == true)
        #expect(result.timedOutSeats.isEmpty)
    }

    @Test("timeout: a controller that never decides triggers the fallback and is cancelled")
    func timeoutTriggersFallbackAndCancels() async {
        let host = makeCountHost()
        let transport = InProcessTransport(host: host)
        let never = NeverController()
        let coordinator = TurnCoordinator(controllers: [seatA: never], transport: transport)

        // Short timeout, no fallback action → a pass; nothing submitted, seat flagged as timed out.
        let outcome = await coordinator.run(
            .sequential(seat: seatA, timeout: .seconds(0.05)))
        #expect(outcome.results.isEmpty)
        #expect(outcome.timedOutSeats == [seatA])

        // The decision Task was actually cancelled (R-SESS-3.4).
        // Give the cancellation handler a moment to record the flag.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await never.cancelledFlag() == true)
    }

    @Test("timeout with a fallback action submits that action on expiry")
    func timeoutSubmitsFallbackAction() async throws {
        let host = makeCountHost()
        let transport = InProcessTransport(host: host)
        let never = NeverController()
        let coordinator = TurnCoordinator(controllers: [seatA: never], transport: transport)

        // On timeout, fall back to `.bump` (legal for the active seat).
        let fallback = try AnyGameAction(CountAction.bump)
        let outcome = await coordinator.run(
            .sequential(seat: seatA, timeout: .seconds(0.05, onTimeout: fallback)))
        #expect(outcome.timedOutSeats == [seatA])
        #expect(outcome.results.count == 1)
        #expect(outcome.results.first?.isAccepted == true)
        #expect(await host.logCount == 1)
    }

    // MARK: - Information barrier (R-SESS-1.2)

    @Test("a controller's decide receives only a redacted PlayerView (structural barrier)")
    func controllerSeesOnlyRedactedView() async throws {
        // Structural: the only game input to `decide` is a `PlayerView`. Capture it and assert it is a
        // redacted view for the seat with its own legal actions — no path to State exists (compile-time).
        actor Captor: PlayerController {
            private(set) var seen: PlayerView?
            func decide(view: PlayerView, seat: SeatID) async -> AnyGameAction? {
                seen = view
                return view.legalActions.first
            }
            func captured() -> PlayerView? { seen }
        }
        let host = makeCountHost()
        let transport = InProcessTransport(host: host)
        let captor = Captor()
        let coordinator = TurnCoordinator(controllers: [seatA: captor], transport: transport)

        _ = await coordinator.run(.sequential(seat: seatA))
        let seen = await captor.captured()
        #expect(seen?.viewer == .seat(seatA))
        // The view carries the seat's own legal actions and no raw state (there is no State-typed member).
        #expect(seen?.legalActions.isEmpty == false)
    }
}
