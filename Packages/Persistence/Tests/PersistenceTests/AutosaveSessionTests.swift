import Foundation
import Testing

@testable import Persistence

// Tests for the versioned save + autosave/resume (task 6.1; R-PERS-1.1, R-PERS-1.2, R-PERS-3.1).
//
// They drive the whole loop headless through an `InMemorySaveStore` (no real container touched), proving:
//   • the `SaveDocument` round-trips through the `SaveCodec` unchanged, versioned (R-PERS-2.1 seam);
//   • a save is written after EVERY accepted action, and NOT after a rejected one (R-PERS-1.1);
//   • resuming replays the recorded log so the restored session is byte-identical to the live one — and
//     continuing from the restore reaches the SAME state hash as an uninterrupted run, at every cut point
//     (R-PERS-1.2, R-QA-4.1 round-trip property);
//   • a corrupt or game-mismatched save resumes to a typed failure rather than a crash (seam for 6.2);
//   • the store abstraction keeps everything in memory (R-PERS-3.1 — nothing reaches the real container).

// MARK: - Toy multi-action game: "Counter"
//
// A two-seat toy whose hand takes SEVERAL accepted actions, so the action log grows to many entries and a
// resume can happen genuinely MID-HAND (R-PERS-1.2). State is a shared counter plus whose turn it is; the
// only action, `.bump`, is legal for the seat on turn and increments the counter, passing the turn. The
// hand ends when the counter reaches `target`. Self-contained, so it also shows the save/restore path runs
// a game with NO EngineCore edits (R-ENG-5.6).

private let seat0 = SeatID.index(0)
private let seat1 = SeatID.index(1)

private struct CounterState: GameState, Equatable {
    var counter: Int
    var onTurn: SeatID
    var target: Int
    var done: Bool
}

private enum CounterAction: GameAction, Equatable {
    case bump
}

private struct CounterOptions: GameOptions, Equatable {
    var target: Int
}

private struct Counter: GameDefinition {
    typealias State = CounterState
    typealias Action = CounterAction
    typealias Options = CounterOptions

    static let metadata = GameMetadata(
        id: "counter",
        name: "Counter",
        family: .shedding,
        seatRange: 2...2,
        typicalDuration: DurationRange(minMinutes: 1, maxMinutes: 1),
        complexity: .light)

    static let optionsSchema = OptionsSchema(defaults: CounterOptions(target: 4))

    let undoPolicy: UndoPolicy = .none

    func initialState(options: CounterOptions, seed: UInt64) -> CounterState {
        // The seed nudges who leads, so different seeds produce distinguishable initial states (proving
        // the initial state is seed-derived, R-ENG-5.3).
        let leader = (seed % 2 == 0) ? seat0 : seat1
        return CounterState(counter: 0, onTurn: leader, target: options.target, done: false)
    }

    func phase(of state: CounterState) -> Phase {
        state.done ? Phase(rawValue: "done") : Phase(rawValue: "play")
    }

    func legalActions(for seat: SeatID, in state: CounterState) -> [CounterAction] {
        guard !state.done, seat == state.onTurn else { return [] }
        return [.bump]
    }

    func apply(_ action: CounterAction, by seat: SeatID, to state: CounterState)
        -> Result<(CounterState, [GameEvent]), RuleViolation>
    {
        guard !state.done else {
            return .failure(RuleViolation(code: "hand-over", reason: "The hand is already over."))
        }
        guard seat == state.onTurn else {
            return .failure(
                RuleViolation(code: "not-your-turn", reason: "It is not your turn."))
        }
        var next = state
        next.counter += 1
        next.onTurn = (seat == seat0) ? seat1 : seat0
        var events: [GameEvent] = [.scoreChanged(seat: seat, delta: 1, total: next.counter)]
        if next.counter >= next.target {
            next.done = true
            events.append(.handEnded(outcome(next)))
        } else {
            events.append(.turnChanged(to: next.onTurn))
        }
        return .success((next, events))
    }

    func isTerminal(_ state: CounterState) -> Bool { state.done }

    func outcome(_ state: CounterState) -> HandOutcome {
        state.done ? HandOutcome(winners: [state.onTurn], scores: [state.onTurn: 1]) : .draw
    }

    func redactedView(of state: CounterState, for viewer: Viewer) -> PlayerView {
        let seat = { () -> SeatID? in
            if case .seat(let s) = viewer { return s }
            return nil
        }()
        let legal = seat.map { legalActions(for: $0, in: state) } ?? []
        let erased = legal.compactMap { try? AnyGameAction($0) }
        return PlayerView(
            viewer: viewer,
            scores: [seat0: state.counter, seat1: state.counter],
            phase: phase(of: state),
            legalActions: erased)
    }
}

// MARK: - Fixtures

private let counterSeed: UInt64 = 7

// A fixed human profile so seats are stable across `makeSeats()` calls (`defaultLocalHuman()` mints a
// random id each call, which would break an equality round-trip check).
private let humanProfile = PlayerProfile(
    id: ProfileID(raw: "profile-local-human"),
    displayName: "Player",
    avatar: .generatedGlyph(symbol: "person.crop.circle.fill", tint: "#4C6EF5"),
    controllerKind: .localHuman)

private func makeSeats() -> [SavedSeat] {
    let persona = AIPersona.bundled(withID: PersonaID(raw: "persona-cautious"))!
    return [
        SavedSeat(id: seat0, profile: humanProfile),
        SavedSeat(id: seat1, profile: persona.profile, personaDifficulty: persona.tier),
    ]
}

private func makeMatch() -> Match {
    Match(dealer: seat0, target: .targetScore(value: 100))
}

/// A fixed clock so `updatedAt` is deterministic in tests (metadata only; tech.md rule 8).
private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

private func bump(_ seat: SeatID) throws -> ActionEnvelope {
    ActionEnvelope(seat: seat, action: try AnyGameAction(CounterAction.bump))
}

/// The order of seats to bump for a target-`n` hand, alternating from seat-0 (the leader for even seeds).
/// `counterSeed` (7) is odd, so seat-1 leads.
private func bumpOrder(count: Int, leader: SeatID) -> [SeatID] {
    var order: [SeatID] = []
    var current = leader
    for _ in 0..<count {
        order.append(current)
        current = (current == seat0) ? seat1 : seat0
    }
    return order
}

@Suite("Versioned save + autosave/resume (R-PERS-1.1, R-PERS-1.2, R-PERS-3.1)")
struct AutosaveSessionTests {

    // MARK: - SaveDocument round-trips through the codec (R-PERS-2.1 seam)

    @Test("a SaveDocument encodes and decodes unchanged, carrying its schema version")
    func documentRoundTrips() throws {
        let doc = SaveDocument(
            gameID: "counter",
            options: CounterOptions(target: 4),
            match: makeMatch(),
            seats: makeSeats(),
            actionLog: [],
            cursor: -1,
            createdAt: fixedNow(),
            updatedAt: fixedNow())
        let codec = SaveCodec()
        let data = try codec.encode(doc)
        let decoded = try codec.decode(SaveDocument<CounterOptions>.self, from: data)

        #expect(decoded.schemaVersion == SaveDocument<CounterOptions>.currentSchemaVersion)
        #expect(decoded.gameID == "counter")
        #expect(decoded.options == CounterOptions(target: 4))
        #expect(decoded.cursor == -1)
        #expect(decoded.seats == makeSeats())
    }

    @Test("a save with no schemaVersion decodes as version 1 (migration seam)")
    func absentVersionDecodesAsV1() throws {
        // Encode a real document, then STRIP its `schemaVersion` key to simulate an older save the
        // migration registry (task 6.2) will upgrade. It must still decode today, defaulting to version 1.
        let doc = SaveDocument(
            gameID: "counter",
            options: CounterOptions(target: 4),
            match: makeMatch(),
            seats: makeSeats(),
            actionLog: [],
            cursor: -1,
            createdAt: fixedNow(),
            updatedAt: fixedNow())
        let data = try SaveCodec().encode(doc)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "schemaVersion")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SaveDocument<CounterOptions>.self, from: stripped)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.gameID == "counter")
    }

    // MARK: - Autosave after every accepted action (R-PERS-1.1)

    @Test("a save is written on start and rewritten after every accepted action")
    func autosaveAfterEveryAcceptedAction() async throws {
        let store = InMemorySaveStore()
        let session = try await AutosaveSession.start(
            game: Counter(),
            options: CounterOptions(target: 4),
            seats: makeSeats(),
            match: makeMatch(),
            seed: counterSeed,
            store: store,
            now: fixedNow)

        // Starting writes an initial save so "Continue" exists before the first move (R-APP-1.1).
        #expect(store.exists(.game("counter")))
        let codec = SaveCodec()
        func currentCursor() throws -> Int {
            let data = try #require(try store.read(.game("counter")))
            return try codec.decode(SaveDocument<CounterOptions>.self, from: data).cursor
        }
        #expect(try currentCursor() == -1)

        // seed 7 is odd, so seat-1 leads. Two accepted bumps → the save's cursor advances each time.
        let leader = seat1
        _ = try await session.submit(bump(leader))
        #expect(try currentCursor() == 0)

        _ = try await session.submit(bump(seat0))
        #expect(try currentCursor() == 1)
    }

    @Test("a rejected action does not write a new save")
    func rejectedActionDoesNotSave() async throws {
        let store = InMemorySaveStore()
        let session = try await AutosaveSession.start(
            game: Counter(),
            options: CounterOptions(target: 4),
            seats: makeSeats(),
            match: makeMatch(),
            seed: counterSeed,
            store: store,
            now: fixedNow)

        let before = try #require(try store.read(.game("counter")))

        // Wrong seat (seat-0, when seat-1 leads) — rejected, nothing changes.
        let result = try await session.submit(bump(seat0))
        #expect(!result.isAccepted)

        let after = try #require(try store.read(.game("counter")))
        #expect(after == before)
        #expect(await session.host.logCount == 0)
    }

    // MARK: - Resume replays exactly (R-PERS-1.2)

    @Test("resuming mid-hand rebuilds the exact state and log the live session had")
    func resumeMidHandRebuildsExactState() async throws {
        let store = InMemorySaveStore()
        let session = try await AutosaveSession.start(
            game: Counter(),
            options: CounterOptions(target: 6),
            seats: makeSeats(),
            match: makeMatch(),
            seed: counterSeed,
            store: store,
            now: fixedNow)

        // Play a few bumps MID-HAND (target is 6; play only 3), then "quit".
        let order = bumpOrder(count: 3, leader: seat1)
        for seat in order {
            let r = try await session.submit(bump(seat))
            #expect(r.isAccepted)
        }
        let liveHash = await session.host.lastStateHash
        let liveLog = await session.host.logCount
        #expect(liveLog == 3)

        // Resume from the SAME store (a fresh launch): the rebuilt host must match the live one exactly.
        let resumed = try await AutosaveSession.resume(
            game: Counter(), store: store, now: fixedNow
        ).get()
        #expect(await resumed.host.logCount == liveLog)
        #expect(await resumed.host.lastStateHash == liveHash)
    }

    // MARK: - Round-trip property: restore + continue == uninterrupted run (R-QA-4.1)

    @Test(
        "restore at any cut point, then continue, reaches the same final hash as an uninterrupted run"
    )
    func restoreThenContinueEqualsUninterrupted() async throws {
        // The full hand for target 6 takes 6 bumps. Run it uninterrupted once for the reference hash.
        let target = 6
        let fullOrder = bumpOrder(count: target, leader: seat1)

        func uninterruptedFinalHash() async throws -> StateHash? {
            let store = InMemorySaveStore()
            let session = try await AutosaveSession.start(
                game: Counter(), options: CounterOptions(target: target), seats: makeSeats(),
                match: makeMatch(), seed: counterSeed, store: store, now: fixedNow)
            for seat in fullOrder {
                _ = try await session.submit(bump(seat))
            }
            return await session.host.lastStateHash
        }
        let reference = try await uninterruptedFinalHash()
        #expect(reference != nil)

        // For every cut point k in 1..<target: play k bumps, resume from the save, then play the rest.
        // The final hash must equal the uninterrupted reference (R-QA-4.1).
        for k in 1..<target {
            let store = InMemorySaveStore()
            let session = try await AutosaveSession.start(
                game: Counter(), options: CounterOptions(target: target), seats: makeSeats(),
                match: makeMatch(), seed: counterSeed, store: store, now: fixedNow)
            for seat in fullOrder.prefix(k) {
                _ = try await session.submit(bump(seat))
            }

            // Fresh launch: resume, then continue with the remaining bumps.
            let resumed = try await AutosaveSession.resume(
                game: Counter(), store: store, now: fixedNow
            ).get()
            for seat in fullOrder.suffix(from: k) {
                _ = try await resumed.submit(bump(seat))
            }
            let resumedFinal = await resumed.host.lastStateHash
            #expect(
                resumedFinal == reference,
                "cut point \(k): resumed final hash must equal the uninterrupted run")
        }
    }

    @Test(
        "round-trip holds across several seeds and targets: restore + continue == uninterrupted (R-QA-4.1)"
    )
    func roundTripAcrossSeedsAndTargets() async throws {
        // Strengthen R-QA-4.1 beyond a single seed: for several seeds and target sizes, restoring at EVERY
        // cut point and continuing must reach the same final hash as an uninterrupted run — and the hash
        // AT the cut point must match between the live and resumed hosts (restore is byte-exact, not just
        // eventually-equal).
        let seeds: [UInt64] = [2, 7, 42, 100]
        let targets = [3, 5, 8]

        for seed in seeds {
            for target in targets {
                let leader: SeatID = (seed % 2 == 0) ? seat0 : seat1
                let fullOrder = bumpOrder(count: target, leader: leader)

                // Reference: one uninterrupted run.
                let refStore = InMemorySaveStore()
                let refSession = try await AutosaveSession.start(
                    game: Counter(), options: CounterOptions(target: target), seats: makeSeats(),
                    match: makeMatch(), seed: seed, store: refStore, now: fixedNow)
                for s in fullOrder { _ = try await refSession.submit(bump(s)) }
                let reference = await refSession.host.lastStateHash

                for k in 1..<target {
                    let store = InMemorySaveStore()
                    let session = try await AutosaveSession.start(
                        game: Counter(), options: CounterOptions(target: target),
                        seats: makeSeats(), match: makeMatch(), seed: seed, store: store,
                        now: fixedNow)
                    for s in fullOrder.prefix(k) { _ = try await session.submit(bump(s)) }
                    let liveCutHash = await session.host.lastStateHash

                    let resumed = try await AutosaveSession.resume(
                        game: Counter(), store: store, now: fixedNow
                    ).get()
                    // The restored host matches the live host EXACTLY at the cut point.
                    #expect(
                        await resumed.host.lastStateHash == liveCutHash,
                        "seed \(seed) target \(target) cut \(k): restore must be byte-exact")

                    for s in fullOrder.suffix(from: k) { _ = try await resumed.submit(bump(s)) }
                    #expect(
                        await resumed.host.lastStateHash == reference,
                        "seed \(seed) target \(target) cut \(k): continue must match uninterrupted")
                }
            }
        }
    }

    // MARK: - Graceful typed failures (seam for 6.2; R-PERS-2.2)

    /// The `ResumeError` a resume produced, or `nil` if it (unexpectedly) succeeded. `AutosaveSession` is
    /// not `Equatable`, so the whole `Result` cannot be compared; this pulls out the failure to assert on.
    private func resumeError(
        _ result: Result<AutosaveSession<Counter>, ResumeError>
    ) -> ResumeError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test("resuming with no save returns .noSave")
    func resumeNoSave() async {
        let store = InMemorySaveStore()
        let result = await AutosaveSession.resume(game: Counter(), store: store)
        #expect(resumeError(result) == .noSave)
    }

    @Test("resuming corrupt bytes returns .corruptSave rather than crashing")
    func resumeCorruptSave() async throws {
        let store = InMemorySaveStore()
        try store.write(Data("not json at all".utf8), for: .game("counter"))
        let result = await AutosaveSession.resume(game: Counter(), store: store)
        #expect(resumeError(result) == .corruptSave)
    }

    @Test("resuming a save for a different game returns .gameMismatch")
    func resumeGameMismatch() async throws {
        let store = InMemorySaveStore()
        // A well-formed document, but for a different game id.
        let doc = SaveDocument(
            gameID: "some-other-game",
            options: CounterOptions(target: 4),
            match: {
                var m = makeMatch(); m.handSeeds = [counterSeed]; return m
            }(),
            seats: makeSeats(),
            actionLog: [],
            cursor: -1,
            createdAt: fixedNow(),
            updatedAt: fixedNow())
        try store.write(try SaveCodec().encode(doc), for: .game("counter"))

        let result = await AutosaveSession.resume(game: Counter(), store: store)
        #expect(
            resumeError(result) == .gameMismatch(expected: "counter", found: "some-other-game"))
    }

    // MARK: - Store stays local / in-memory (R-PERS-3.1)

    @Test("SaveID sanitizes to a container-safe filename")
    func saveIDSanitizes() {
        #expect(SaveID("crazy-eights").sanitized == "crazy-eights")
        // Each non-[alphanumeric-_] character becomes "_", so a path-traversal attempt cannot escape the
        // container directory: "../escape/attempt" → "___escape_attempt".
        #expect(SaveID("../escape/attempt").sanitized == "___escape_attempt")
        #expect(SaveID("").sanitized == "save")
    }

    @Test("the in-memory store lists and deletes saves")
    func inMemoryStoreListsAndDeletes() throws {
        let store = InMemorySaveStore()
        try store.write(Data("a".utf8), for: .game("counter"))
        try store.write(Data("b".utf8), for: .game("klondike"))
        #expect(try store.allSaveIDs().map(\.raw) == ["counter", "klondike"])
        try store.delete(.game("counter"))
        #expect(!store.exists(.game("counter")))
        #expect(try store.allSaveIDs().map(\.raw) == ["klondike"])
    }
}

// MARK: - Migration registry (task 6.2; R-PERS-2.1)
//
// These prove the migration MECHANISM against the raw JSON form, before strong-typing (design.md §4):
//   • a synthetic v0 → v1 transform runs when a save is at version 0, and the chain reaches the current
//     schema so the migrated bytes decode into today's `SaveDocument`;
//   • transforms run IN ORDER, each stamping the next version;
//   • a save already at the current version is a no-op;
//   • a version NEWER than this build, or a gap with no registered transform, is a typed failure — not a
//     trap (R-PERS-2.2), which the loader turns into a discard + notice.

@Suite("Save migration registry (R-PERS-2.1)")
struct SaveMigrationTests {

    /// A migrator whose absent-version floor is 0 (so a save with no version is treated as v0) with a
    /// single v0 → v1 transform that adds the key a synthetic "v0" save was missing. Registering the
    /// transform proves the chain runs; the stamped `schemaVersion` proves it advances.
    private func v0ToV1Migrator(record: (@Sendable () -> Void)? = nil) -> SaveMigrator {
        SaveMigrator(absentVersionFloor: 0).registering(fromVersion: 0) { object in
            record?()
            var upgraded = object
            // A synthetic v0 save lacked `cursor`; v1 requires it. The transform supplies the missing key
            // (the real shape of an n → n+1 migration: fill/rename/restructure before strong-typing).
            if upgraded["cursor"] == nil {
                upgraded["cursor"] = -1
            }
            return upgraded
        }
    }

    @Test("a v0 save runs the v0 → v1 transform and reaches the current schema")
    func migratesV0ToCurrent() throws {
        // Build a current document, drop its schemaVersion AND its cursor to fake a "v0" encoding.
        let doc = SaveDocument(
            gameID: "counter",
            options: CounterOptions(target: 4),
            match: makeMatch(),
            seats: makeSeats(),
            actionLog: [],
            cursor: -1,
            createdAt: fixedNow(),
            updatedAt: fixedNow())
        let data = try SaveCodec().encode(doc)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "schemaVersion")
        object.removeValue(forKey: "cursor")
        let v0Data = try JSONSerialization.data(withJSONObject: object)

        // Decode through the migrating path: the transform must run and the result must decode as v1.
        let ranBox = MutableFlag()
        let migrator = v0ToV1Migrator(record: { ranBox.set() })
        let decoded = try SaveCodec().decodeMigrating(
            SaveDocument<CounterOptions>.self, from: v0Data, migrator: migrator)

        #expect(ranBox.value, "the v0 → v1 transform must have run")
        #expect(decoded.schemaVersion == SaveDocument<CounterOptions>.currentSchemaVersion)
        #expect(decoded.cursor == -1)
        #expect(decoded.gameID == "counter")
    }

    @Test("the migrator stamps the target version and runs transforms in order")
    func runsChainInOrder() throws {
        // A two-step synthetic chain 0 → 1 → 2, recording the order the steps ran in.
        let order = OrderRecorder()
        let migrator = SaveMigrator(absentVersionFloor: 0)
            .registering(fromVersion: 0) { obj in
                order.append(0)
                var o = obj
                o["step0"] = true
                return o
            }
            .registering(fromVersion: 1) { obj in
                order.append(1)
                var o = obj
                o["step1"] = true
                return o
            }

        let migrated = try migrator.migrate(["gameID": "counter"], to: 2)
        #expect(order.values == [0, 1], "transforms run in ascending version order")
        #expect(migrated["schemaVersion"] as? Int == 2, "the target version is stamped")
        #expect(migrated["step0"] as? Bool == true)
        #expect(migrated["step1"] as? Bool == true)
    }

    @Test("a save already at the current version is a no-op")
    func currentVersionIsNoOp() throws {
        let migrator = SaveMigrator(absentVersionFloor: 1)  // no transforms registered
        let object: [String: Any] = ["schemaVersion": 1, "gameID": "counter"]
        let migrated = try migrator.migrate(object, to: 1)
        #expect(migrated["schemaVersion"] as? Int == 1)
        #expect(migrated["gameID"] as? String == "counter")
    }

    @Test("a version newer than this build is a typed versionTooNew failure")
    func versionTooNewFails() {
        let migrator = SaveMigrator()
        let object: [String: Any] = ["schemaVersion": 99, "gameID": "counter"]
        #expect(throws: MigrationError.versionTooNew(found: 99, current: 1)) {
            _ = try migrator.migrate(object, to: 1)
        }
    }

    @Test("a gap in the chain is a typed noTransform failure")
    func missingTransformFails() {
        // Ask to migrate 0 → 2 but only register 0 → 1: the chain stalls at 1 with no transform.
        let migrator = SaveMigrator(absentVersionFloor: 0).registering(fromVersion: 0) { $0 }
        let object: [String: Any] = ["schemaVersion": 0]
        #expect(throws: MigrationError.noTransform(fromVersion: 1)) {
            _ = try migrator.migrate(object, to: 2)
        }
    }
}

// MARK: - Corruption / incompatible handling: discard + non-modal notice (task 6.2; R-PERS-2.2)
//
// The graceful path (`resumeOrDiscard`) must NEVER crash: a bad save is deleted and a non-modal notice
// value is returned for the App to render as a banner. These prove each unusable case discards + notices,
// a good save resumes untouched, and "no save" is a clean start with no notice and nothing deleted.

@Suite("Corrupt/incompatible save → discard + non-modal notice (R-PERS-2.2)")
struct SaveDiscardTests {

    /// The `SaveNotice` a discard outcome produced, failing the test on any other outcome.
    private func notice(_ outcome: ResumeOutcome<Counter>) -> SaveNotice? {
        if case .discarded(let notice) = outcome { return notice }
        return nil
    }

    @Test("corrupt bytes are discarded with a corrupt notice, never a crash")
    func corruptDiscarded() async throws {
        let store = InMemorySaveStore()
        try store.write(Data("not json at all".utf8), for: .game("counter"))

        let outcome = await AutosaveSession.resumeOrDiscard(game: Counter(), store: store)
        let n = notice(outcome)
        #expect(n?.reason == .corrupt)
        #expect(n?.saveID == .game("counter"))
        // The save was DISCARDED — it must be gone so it is never re-offered.
        #expect(!store.exists(.game("counter")))
    }

    @Test("an incompatible (too-new) version is discarded with an incompatibleVersion notice")
    func incompatibleVersionDiscarded() async throws {
        // A well-formed document, but bumped to a future schema version this build can't read.
        let doc = SaveDocument(
            gameID: "counter",
            options: CounterOptions(target: 4),
            match: {
                var m = makeMatch(); m.handSeeds = [counterSeed]; return m
            }(),
            seats: makeSeats(),
            actionLog: [],
            cursor: -1,
            createdAt: fixedNow(),
            updatedAt: fixedNow())
        let data = try SaveCodec().encode(doc)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 999
        let futureData = try JSONSerialization.data(withJSONObject: object)

        let store = InMemorySaveStore()
        try store.write(futureData, for: .game("counter"))

        let outcome = await AutosaveSession.resumeOrDiscard(game: Counter(), store: store)
        #expect(notice(outcome)?.reason == .incompatibleVersion)
        #expect(!store.exists(.game("counter")))
    }

    @Test("a wrong-game save is discarded with a gameMismatch notice")
    func gameMismatchDiscarded() async throws {
        let doc = SaveDocument(
            gameID: "some-other-game",
            options: CounterOptions(target: 4),
            match: {
                var m = makeMatch(); m.handSeeds = [counterSeed]; return m
            }(),
            seats: makeSeats(),
            actionLog: [],
            cursor: -1,
            createdAt: fixedNow(),
            updatedAt: fixedNow())
        let store = InMemorySaveStore()
        try store.write(try SaveCodec().encode(doc), for: .game("counter"))

        let outcome = await AutosaveSession.resumeOrDiscard(game: Counter(), store: store)
        #expect(
            notice(outcome)?.reason == .gameMismatch(expected: "counter", found: "some-other-game"))
        #expect(!store.exists(.game("counter")))
    }

    @Test("no save is a clean start: no notice, nothing deleted")
    func noSaveIsCleanStart() async {
        let store = InMemorySaveStore()
        let outcome = await AutosaveSession.resumeOrDiscard(game: Counter(), store: store)
        if case .noSave = outcome {
            // expected
        } else {
            Issue.record("resuming with no save should be a clean .noSave, not a discard")
        }
    }

    @Test("a valid save resumes and is NOT discarded")
    func validSaveResumesUntouched() async throws {
        let store = InMemorySaveStore()
        let session = try await AutosaveSession.start(
            game: Counter(),
            options: CounterOptions(target: 6),
            seats: makeSeats(),
            match: makeMatch(),
            seed: counterSeed,
            store: store,
            now: fixedNow)
        _ = try await session.submit(bump(seat1))

        let outcome = await AutosaveSession.resumeOrDiscard(
            game: Counter(), store: store, now: fixedNow)
        guard case .resumed(let resumed) = outcome else {
            Issue.record("a valid save should resume, not discard")
            return
        }
        #expect(await resumed.host.logCount == 1)
        // The save is still there — resuming does not discard a good save.
        #expect(store.exists(.game("counter")))
    }

    @Test("resumeOrDiscard runs the migration chain: a v0 save resumes")
    func migratedSaveResumes() async throws {
        // Start a normal session and play one bump, then rewrite its stored bytes as a synthetic "v0"
        // save (drop schemaVersion). A v0 → v1 migrator (identity reshape) must let it resume via the
        // graceful path, proving migration is wired into resume (R-PERS-2.1 + R-PERS-2.2 together).
        let store = InMemorySaveStore()
        let session = try await AutosaveSession.start(
            game: Counter(),
            options: CounterOptions(target: 6),
            seats: makeSeats(),
            match: makeMatch(),
            seed: counterSeed,
            store: store,
            now: fixedNow)
        _ = try await session.submit(bump(seat1))

        let current = try #require(try store.read(.game("counter")))
        var object = try #require(
            try JSONSerialization.jsonObject(with: current) as? [String: Any])
        object.removeValue(forKey: "schemaVersion")  // pretend it was written by "v0"
        try store.write(try JSONSerialization.data(withJSONObject: object), for: .game("counter"))

        let migrator = SaveMigrator(absentVersionFloor: 0).registering(fromVersion: 0) { $0 }
        let outcome = await AutosaveSession.resumeOrDiscard(
            game: Counter(), store: store, migrator: migrator, now: fixedNow)
        guard case .resumed(let resumed) = outcome else {
            Issue.record("a migratable v0 save should resume, not discard")
            return
        }
        #expect(await resumed.host.logCount == 1)
    }
}

// MARK: - Test helpers (thread-safe recorders for @Sendable transform closures)

/// A tiny lock-guarded boolean flag a `@Sendable` closure can set, so a test can assert a migration
/// transform actually ran. `@unchecked Sendable` because the `NSLock` makes access safe.
private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

/// A lock-guarded list recording the order migration transforms ran in — asserted to confirm the chain
/// runs in ascending version order.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    func append(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
    }
    var values: [Int] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
