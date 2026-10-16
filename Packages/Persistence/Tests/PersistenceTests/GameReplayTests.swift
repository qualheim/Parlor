// GameReplay tests (task 6.6) — "Replay last game" reconstructed from the action log (R-PERS-4.1).
//
// R-PERS-4.1 is a "Should": a solid, deterministic reconstruction path + tests is sufficient. These drive
// the whole path headless through an `InMemorySaveStore`, proving:
//   • the last game loads from its save and captures the recorded log, seed, options, and seats;
//   • rebuilding at the recorded END reproduces the exact end state the live session reached
//     (interactive re-entry);
//   • stepping through PREFIXES of the recorded log reproduces the game move-by-move (passive playback),
//     matching the state hash a live session had after the same number of actions;
//   • unusable saves (none / corrupt / wrong game) surface as typed `ReplayError`, never a crash.
//
// Q-8 (NEEDS REVIEW): the *scope* of "Replay last game" (last hand vs full match; passive vs interactive)
// is an open question. This reconstruction serves either, so it is correct whichever way Q-8 lands; the
// tests assert the reconstruction faithfulness, not a UX scope.

import Foundation
import Testing

@testable import Persistence

// MARK: - Toy multi-action game: "Tally"
//
// A self-contained two-seat toy (kept separate from AutosaveSessionTests' private `Counter`) whose hand
// takes several accepted actions so the recorded log has many entries to replay. `.add` is legal for the
// seat on turn, increments a shared total, and passes the turn; the hand ends at `target`.

private let seatA = SeatID.index(0)
private let seatB = SeatID.index(1)

private struct TallyState: GameState, Equatable {
    var total: Int
    var onTurn: SeatID
    var target: Int
    var done: Bool
}

private enum TallyAction: GameAction, Equatable {
    case add
}

private struct TallyOptions: GameOptions, Equatable {
    var target: Int
}

private struct Tally: GameDefinition {
    typealias State = TallyState
    typealias Action = TallyAction
    typealias Options = TallyOptions

    static let metadata = GameMetadata(
        id: "tally",
        name: "Tally",
        family: .shedding,
        seatRange: 2...2,
        typicalDuration: DurationRange(minMinutes: 1, maxMinutes: 1),
        complexity: .light)

    static let optionsSchema = OptionsSchema(defaults: TallyOptions(target: 4))

    let undoPolicy: UndoPolicy = .none

    func initialState(options: TallyOptions, seed: UInt64) -> TallyState {
        let leader = (seed % 2 == 0) ? seatA : seatB
        return TallyState(total: 0, onTurn: leader, target: options.target, done: false)
    }

    func phase(of state: TallyState) -> Phase {
        state.done ? Phase(rawValue: "done") : Phase(rawValue: "play")
    }

    func legalActions(for seat: SeatID, in state: TallyState) -> [TallyAction] {
        guard !state.done, seat == state.onTurn else { return [] }
        return [.add]
    }

    func apply(_ action: TallyAction, by seat: SeatID, to state: TallyState)
        -> Result<(TallyState, [GameEvent]), RuleViolation>
    {
        guard !state.done else {
            return .failure(RuleViolation(code: "hand-over", reason: "The hand is already over."))
        }
        guard seat == state.onTurn else {
            return .failure(RuleViolation(code: "not-your-turn", reason: "It is not your turn."))
        }
        var next = state
        next.total += 1
        next.onTurn = (seat == seatA) ? seatB : seatA
        var events: [GameEvent] = [.scoreChanged(seat: seat, delta: 1, total: next.total)]
        if next.total >= next.target {
            next.done = true
            events.append(.handEnded(outcome(next)))
        } else {
            events.append(.turnChanged(to: next.onTurn))
        }
        return .success((next, events))
    }

    func isTerminal(_ state: TallyState) -> Bool { state.done }

    func outcome(_ state: TallyState) -> HandOutcome {
        state.done ? HandOutcome(winners: [state.onTurn], scores: [state.onTurn: 1]) : .draw
    }

    func redactedView(of state: TallyState, for viewer: Viewer) -> PlayerView {
        let seat: SeatID? = {
            if case .seat(let s) = viewer { return s }
            return nil
        }()
        let legal = seat.map { legalActions(for: $0, in: state) } ?? []
        let erased = legal.compactMap { try? AnyGameAction($0) }
        return PlayerView(
            viewer: viewer,
            scores: [seatA: state.total, seatB: state.total],
            phase: phase(of: state),
            legalActions: erased)
    }
}

// MARK: - Fixtures

private let tallySeed: UInt64 = 7  // odd → seat-B leads

private let humanProfile = PlayerProfile(
    id: ProfileID(raw: "profile-local-human"),
    displayName: "Player",
    avatar: .generatedGlyph(symbol: "person.crop.circle.fill", tint: "#4C6EF5"),
    controllerKind: .localHuman)

private func makeSeats() -> [SavedSeat] {
    let persona = AIPersona.bundled(withID: PersonaID(raw: "persona-cautious"))!
    return [
        SavedSeat(id: seatA, profile: humanProfile),
        SavedSeat(id: seatB, profile: persona.profile, personaDifficulty: persona.tier),
    ]
}

private func makeMatch() -> Match {
    Match(dealer: seatA, target: .targetScore(value: 100))
}

private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

private func add(_ seat: SeatID) throws -> ActionEnvelope {
    ActionEnvelope(seat: seat, action: try AnyGameAction(TallyAction.add))
}

private func addOrder(count: Int, leader: SeatID) -> [SeatID] {
    var order: [SeatID] = []
    var current = leader
    for _ in 0..<count {
        order.append(current)
        current = (current == seatA) ? seatB : seatA
    }
    return order
}

/// Play a `count`-action hand into a fresh in-memory store and return the store, so a replay can be
/// reconstructed from it. Returns the store and the live end-state hash for comparison.
private func playAndSave(target: Int, count: Int) async throws -> (InMemorySaveStore, StateHash?) {
    let store = InMemorySaveStore()
    let session = try await AutosaveSession.start(
        game: Tally(),
        options: TallyOptions(target: target),
        seats: makeSeats(),
        match: makeMatch(),
        seed: tallySeed,
        store: store,
        now: fixedNow)
    for seat in addOrder(count: count, leader: seatB) {
        _ = try await session.submit(add(seat))
    }
    let liveHash = await session.host.lastStateHash
    return (store, liveHash)
}

@Suite("GameReplay — replay last game from the action log (R-PERS-4.1)")
struct GameReplayTests {

    private func replayError(_ result: Result<GameReplay<Tally>, ReplayError>) -> ReplayError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: - Load the last game

    @Test("loads the last game and captures the recorded log, seed, options, and seats")
    func loadsLastGame() async throws {
        let (store, _) = try await playAndSave(target: 6, count: 3)

        let replay = try GameReplay.loadLast(game: Tally(), store: store).get()
        #expect(replay.actionCount == 3)
        #expect(replay.seed == tallySeed)
        #expect(replay.options == TallyOptions(target: 6))
        #expect(replay.seats == makeSeats())
        #expect(replay.saveID == .game("tally"))
    }

    // MARK: - Interactive re-entry: rebuild at the recorded end

    @Test("rebuilding at the recorded end reproduces the exact live end state")
    func reconstructedEndMatchesLive() async throws {
        let (store, liveHash) = try await playAndSave(target: 6, count: 3)

        let replay = try GameReplay.loadLast(game: Tally(), store: store).get()
        let host = try replay.reconstructedHost().get()
        #expect(await host.logCount == 3)
        #expect(await host.lastStateHash == liveHash)
    }

    @Test("the reconstructed host can continue play (interactive re-entry)")
    func reconstructedHostCanContinue() async throws {
        // Reconstruct mid-hand (target 6, 3 actions played), then keep playing to the end.
        let (store, _) = try await playAndSave(target: 6, count: 3)
        let replay = try GameReplay.loadLast(game: Tally(), store: store).get()
        let host = try replay.reconstructedHost().get()

        // seat-B led; after 3 actions it is seat-B's turn again (B,A,B → next is A). Continue to target.
        let remaining = Array(addOrder(count: 6, leader: seatB).suffix(from: 3))
        for seat in remaining {
            let result = await host.submit(try add(seat))
            #expect(result.isAccepted)
        }
        #expect(await host.logCount == 6)
    }

    // MARK: - Passive playback: step through prefixes

    @Test("stepping through prefixes reproduces the game move-by-move")
    func stepThroughPrefixes() async throws {
        let target = 6
        let (store, _) = try await playAndSave(target: target, count: target)
        let replay = try GameReplay.loadLast(game: Tally(), store: store).get()
        #expect(replay.actionCount == target)

        // For each step, the replayed host's log count equals the step; hashes increase deterministically.
        var seenHashes: [StateHash] = []
        for step in 0...target {
            let host = try replay.hostAtStep(step).get()
            #expect(await host.logCount == step)
            if let hash = await host.lastStateHash {
                seenHashes.append(hash)
            }
        }
        // Each non-initial step produced a hash; consecutive states differ (the game advanced).
        #expect(seenHashes.count == target)
        #expect(Set(seenHashes).count == target)
    }

    @Test("a replayed step matches the same-length live session's state hash")
    func stepMatchesLiveAtSameLength() async throws {
        // A live session played to k actions must hash-match the replay rebuilt at step k.
        let target = 6
        let (store, _) = try await playAndSave(target: target, count: target)
        let replay = try GameReplay.loadLast(game: Tally(), store: store).get()

        for k in 1...target {
            let (liveStore, liveHash) = try await playAndSave(target: target, count: k)
            _ = liveStore
            let host = try replay.hostAtStep(k).get()
            #expect(
                await host.lastStateHash == liveHash,
                "replay step \(k) must match a live k-action run")
        }
    }

    @Test("step is clamped to 0...actionCount")
    func stepClamped() async throws {
        let (store, _) = try await playAndSave(target: 6, count: 3)
        let replay = try GameReplay.loadLast(game: Tally(), store: store).get()

        let atZero = try replay.hostAtStep(-5).get()
        #expect(await atZero.logCount == 0)

        let beyond = try replay.hostAtStep(999).get()
        #expect(await beyond.logCount == 3)  // clamped to the recorded end
    }

    @Test("viewSequence yields one view per step from the deal to the end")
    func viewSequenceLength() async throws {
        let target = 5
        let (store, _) = try await playAndSave(target: target, count: target)
        let replay = try GameReplay.loadLast(game: Tally(), store: store).get()

        let views = try await replay.viewSequence(for: .seat(seatA)).get()
        #expect(views.count == target + 1)  // step 0 (deal) through step target
    }

    // MARK: - Typed failures (never a crash)

    @Test("no save returns .noSave")
    func noSave() {
        let store = InMemorySaveStore()
        let result = GameReplay.loadLast(game: Tally(), store: store)
        #expect(replayError(result) == .noSave)
    }

    @Test("corrupt bytes return .corruptSave rather than crashing")
    func corruptSave() throws {
        let store = InMemorySaveStore()
        try store.write(Data("not json".utf8), for: .game("tally"))
        let result = GameReplay.loadLast(game: Tally(), store: store)
        #expect(replayError(result) == .corruptSave)
    }

    @Test("a save for a different game returns .gameMismatch")
    func gameMismatch() throws {
        let doc = SaveDocument(
            gameID: "some-other-game",
            options: TallyOptions(target: 4),
            match: {
                var m = makeMatch(); m.handSeeds = [tallySeed]; return m
            }(),
            seats: makeSeats(),
            actionLog: [],
            cursor: -1,
            createdAt: fixedNow(),
            updatedAt: fixedNow())
        let store = InMemorySaveStore()
        try store.write(try SaveCodec().encode(doc), for: .game("tally"))

        let result = GameReplay.loadLast(game: Tally(), store: store)
        #expect(replayError(result) == .gameMismatch(expected: "tally", found: "some-other-game"))
    }
}
