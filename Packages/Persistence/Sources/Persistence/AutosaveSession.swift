// Autosave + resume — the session wrapper that persists after every accepted action and rebuilds on
// relaunch (R-PERS-1.1, R-PERS-1.2; design.md §3.1, §4).
//
// This is the piece that ties the pieces together. `AutosaveSession` wraps a `GameHost<Game>` (the sole
// state authority, EngineCore) together with a `SaveStore` (where bytes live), a `SaveCodec` (bytes ⇄
// document), and the static context a save needs (game id, options, seats, match). It presents the same
// submit boundary the host does — but AFTER the host accepts an action, it writes an up-to-date
// `SaveDocument` (R-PERS-1.1). The sequence diagram design.md §3.1 shows exactly this: on an accepted
// action the host advances, then "autosave after accepted action".
//
// RESUME (R-PERS-1.2). `resume(...)` reads the save bytes, decodes the versioned document, and rebuilds the
// host by REPLAYING the recorded log against the recorded seed via `GameHost.restoring(...)` — restore +
// continue equals an uninterrupted run (R-QA-4.1). Because the host is rebuilt to the exact recorded state
// (log, hashes verified), a resumed game continues precisely where it left off, including mid-hand against
// the AI (R-PERS-1.2).
//
// LOCAL ONLY (R-PERS-3.1). All persistence flows through the injected `SaveStore`; the production store is
// the sandbox container store, so nothing leaves the Mac. Tests inject `InMemorySaveStore`, so the whole
// autosave/resume loop runs headless.
//
// SCOPE (task 6.1). This establishes the versioned format + autosave/resume. Corruption/incompatible-save
// handling (a notice + discard) and the migration REGISTRY are task 6.2; `resume` already returns a typed
// failure (never traps) so that task attaches the graceful handling without reshaping this seam.

import Foundation

// MARK: - Resume failure (typed; graceful handling is task 6.2)

/// Why a `resume` could not reconstruct a session (R-PERS-1.2).
///
/// Returned (never trapped) so the app can, in task 6.2, show a non-modal notice and discard the save
/// rather than crash (R-PERS-2.2). Task 6.1 surfaces the categories; the notice/discard UX is 6.2.
public enum ResumeError: Error, Sendable, Equatable {
    /// No save exists under the requested id — nothing to resume (a fresh start, not an error condition
    /// for the caller to worry about, but distinguished so "Continue" can be hidden).
    case noSave
    /// The save bytes could not be decoded into a `SaveDocument` (corrupt encoding, or not JSON at all).
    case corruptSave
    /// The save's schema version is newer than this build understands, or the migration chain has a gap —
    /// an incompatible save this build cannot bring up to the current schema (R-PERS-2.1, R-PERS-2.2).
    case incompatibleVersion
    /// The save decoded, but its game id does not match the game being resumed.
    case gameMismatch(expected: String, found: String)
    /// The save decoded, but replaying its action log against the recorded seed failed — the log does not
    /// describe a faithful run (corruption or a version mismatch caught by the replay hash check).
    case replayFailed
}

// MARK: - Non-modal notice (R-PERS-2.2)

/// A testable, non-modal signal that a save could not be resumed and was discarded — the value the App
/// renders as a NON-MODAL banner (never a modal dialog, never a crash) (R-PERS-2.2; design.md §4).
///
/// Kept as a plain, `Equatable` value with NO UI dependency so the Persistence layer stays free of UI
/// frameworks and the discard/notice behavior is fully testable headless: a test asserts the notice's
/// `reason` and that the save was deleted from the store. The `reason` mirrors the `ResumeError` that
/// triggered the discard so the App can word the banner (e.g. "This saved game was damaged and has been
/// removed"). `noSave` never produces a notice — there was nothing to discard.
public struct SaveNotice: Sendable, Equatable {
    /// Why the save was discarded — the resume failure that could not be recovered from.
    public enum Reason: Sendable, Equatable {
        /// The save bytes were corrupt (undecodable / not JSON).
        case corrupt
        /// The save's schema version is incompatible with this build (too new, or an unbridgeable gap).
        case incompatibleVersion
        /// The save was for a different game than the one being resumed.
        case gameMismatch(expected: String, found: String)
        /// The save decoded but replaying its log failed a hash check.
        case replayFailed
    }

    /// The id of the save that was discarded — so the App can clear any "Continue" affordance for it.
    public let saveID: SaveID
    /// Why the save was discarded.
    public let reason: Reason

    public init(saveID: SaveID, reason: Reason) {
        self.saveID = saveID
        self.reason = reason
    }
}

// MARK: - Resume outcome with discard + notice (R-PERS-2.2)

/// The result of the graceful resume path (`resumeOrDiscard`): either a rebuilt session, a clean "nothing
/// to resume", or "the save was unusable, so it was discarded and here is the non-modal notice to show"
/// (R-PERS-2.2).
///
/// This is what the App drives: `.resumed` continues the game, `.noSave` shows the normal new-game entry,
/// and `.discarded` renders `notice` as a non-modal banner while the save has ALREADY been removed from
/// the store — so the app never crashes on a bad save and never re-offers it. `AutosaveSession` is not
/// `Equatable`, so callers pattern-match rather than compare the whole outcome.
public enum ResumeOutcome<Game: GameDefinition>: Sendable {
    /// The save was valid and a session was rebuilt from it.
    case resumed(AutosaveSession<Game>)
    /// There was no save to resume — a normal fresh start, not an error.
    case noSave
    /// The save was unusable and has been discarded; show `notice` as a non-modal banner.
    case discarded(SaveNotice)
}

// MARK: - AutosaveSession

/// A game session that autosaves after every accepted action and can be resumed from its save
/// (R-PERS-1.1, R-PERS-1.2).
///
/// Generic over the game so the options snapshot in the save stays strongly typed (see `SaveDocument`).
/// Construct one for a NEW game with `start(...)`, or reconstruct one from disk with `resume(...)`. Submit
/// actions through ``submit(_:)`` — the session forwards to the host and, on acceptance, rewrites the save
/// so the on-disk state always reflects the latest accepted action (R-PERS-1.1). The live `host` is exposed
/// (read-only) so the app drives views/events exactly as it would a bare host; the session only adds the
/// save-after-accept behavior around `submit`.
///
/// An `actor` so the "submit → host accepts → write save" step is atomic per action: two concurrent submits
/// cannot interleave a stale save. The store/codec it holds are `Sendable`.
public actor AutosaveSession<Game: GameDefinition> {
    /// The authoritative host this session drives (R-SESS-1.1). Exposed so the app requests views/events
    /// through it; the session never lets a client mutate state except via ``submit(_:)``.
    public let host: GameHost<Game>

    private let game: Game
    private let saveID: SaveID
    private let gameID: String
    private let options: Game.Options
    private let seats: [SavedSeat]
    private let store: any SaveStore
    private let codec: SaveCodec

    /// The match bookkeeping snapshot (seeds/dealer/scores/target/summaries) recorded in each save. The
    /// action log itself is read live from the host on each save, so it is never stale (R-PERS-1.1).
    private var match: Match

    /// The save's creation timestamp, preserved across rewrites (only `updatedAt` advances).
    private let createdAt: Date

    /// A clock for `updatedAt`, injectable so tests are deterministic. Metadata only (tech.md rule 8).
    private let now: @Sendable () -> Date

    private init(
        host: GameHost<Game>,
        game: Game,
        saveID: SaveID,
        gameID: String,
        options: Game.Options,
        seats: [SavedSeat],
        match: Match,
        store: any SaveStore,
        codec: SaveCodec,
        createdAt: Date,
        now: @escaping @Sendable () -> Date
    ) {
        self.host = host
        self.game = game
        self.saveID = saveID
        self.gameID = gameID
        self.options = options
        self.seats = seats
        self.match = match
        self.store = store
        self.codec = codec
        self.createdAt = createdAt
        self.now = now
    }

    // MARK: - Start a new session (R-PERS-1.1)

    /// Begin a NEW game session for `game`, seating `seats` and dealing `match`'s current hand from `seed`,
    /// and write the initial save (R-PERS-1.1).
    ///
    /// Builds a fresh `GameHost` from `(options, seed)` (R-ENG-5.3), records the seating and match, and
    /// writes the save immediately so a "Continue" entry exists before the first move (R-APP-1.1). The
    /// `saveID` defaults to one slot per game id (task 6.1); `now` is injectable for deterministic tests.
    public static func start(
        game: Game,
        options: Game.Options,
        seats: [SavedSeat],
        match: Match,
        seed: UInt64,
        store: any SaveStore,
        codec: SaveCodec = SaveCodec(),
        saveID: SaveID? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> AutosaveSession<Game> {
        let host = GameHost(
            game: game, options: options, seats: seats.map(\.id), seed: seed)
        let created = now()
        let session = AutosaveSession(
            host: host,
            game: game,
            saveID: saveID ?? .game(Game.metadata.id),
            gameID: Game.metadata.id,
            options: options,
            seats: seats,
            match: match,
            store: store,
            codec: codec,
            createdAt: created,
            now: now)
        try await session.persist()
        return session
    }

    // MARK: - Resume from disk (R-PERS-1.2)

    /// Reconstruct a session for `game` from its save, replaying the recorded log so play continues exactly
    /// where it left off — mid-hand vs AI included (R-PERS-1.2, R-QA-4.1).
    ///
    /// Reads the bytes for `saveID`, runs the migration chain against the raw form up to the current schema
    /// (R-PERS-2.1), decodes the versioned `SaveDocument`, checks the game id matches, and rebuilds the
    /// host via `GameHost.restoring(...)`, which replays the recorded action log against the recorded seed
    /// and verifies each resulting state hash. Returns a typed `ResumeError` (never traps); the graceful
    /// discard + non-modal notice is layered on by `resumeOrDiscard` (R-PERS-2.2). The rebuilt session
    /// shares the same save slot, so its next accepted action rewrites the same save.
    ///
    /// `migrator` supplies the `n → n+1` transform chain; the default is empty, which is correct while
    /// `currentSchemaVersion` is 1 (a current save needs no migration). A save at a version this build
    /// cannot reach through the chain surfaces as `.incompatibleVersion`.
    public static func resume(
        game: Game,
        store: any SaveStore,
        codec: SaveCodec = SaveCodec(),
        migrator: SaveMigrator = SaveMigrator(),
        saveID: SaveID? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> Result<AutosaveSession<Game>, ResumeError> {
        let id = saveID ?? .game(Game.metadata.id)

        let data: Data?
        do {
            data = try store.read(id)
        } catch {
            return .failure(.corruptSave)
        }
        guard let data else { return .failure(.noSave) }

        let document: SaveDocument<Game.Options>
        do {
            document = try codec.decodeMigrating(
                SaveDocument<Game.Options>.self, from: data, migrator: migrator)
        } catch let error as MigrationError {
            // A version this build cannot bridge is incompatible; a non-object payload is corrupt.
            switch error {
            case .versionTooNew, .noTransform:
                return .failure(.incompatibleVersion)
            case .notAnObject, .transformFailed:
                return .failure(.corruptSave)
            }
        } catch {
            return .failure(.corruptSave)
        }

        guard document.gameID == Game.metadata.id else {
            return .failure(.gameMismatch(expected: Game.metadata.id, found: document.gameID))
        }

        // The seed the hand was dealt from — the last recorded hand seed, or a fresh deal's seed. A save
        // written for the current hand records that hand's seed as the most recent `handSeeds` entry;
        // when the current hand has not been summarized yet the seed lives at the end of `handSeeds`.
        guard let seed = document.match.handSeeds.last else {
            // No recorded hand seed means nothing was dealt — treat as corrupt rather than guessing.
            return .failure(.corruptSave)
        }

        let restore = GameHost.restoring(
            game: game,
            options: document.options,
            seats: document.seats.map(\.id),
            seed: seed,
            replaying: document.entriesToReplay)

        switch restore {
        case .failure:
            return .failure(.replayFailed)
        case .success(let host):
            let session = AutosaveSession(
                host: host,
                game: game,
                saveID: id,
                gameID: document.gameID,
                options: document.options,
                seats: document.seats,
                match: document.match,
                store: store,
                codec: codec,
                createdAt: document.createdAt,
                now: now)
            return .success(session)
        }
    }

    // MARK: - Graceful resume: discard + non-modal notice (R-PERS-2.2)

    /// Resume the save, and if it is unusable (corrupt, incompatible version, wrong game, or a failed
    /// replay) DISCARD it and return a non-modal notice instead of failing — never a crash (R-PERS-2.2;
    /// design.md §4).
    ///
    /// This is the graceful path the App drives. It runs `resume`, then:
    ///   • `.success` → `.resumed(session)` — play continues.
    ///   • `.noSave` → `.noSave` — a normal fresh start; nothing to discard, no notice.
    ///   • any other `ResumeError` → the save is DELETED from the store (so it is never re-offered) and the
    ///     matching `SaveNotice` is returned as `.discarded(notice)` — the value the App renders as a
    ///     non-modal banner. A `delete` failure is swallowed: the outcome is still a discard notice, so a
    ///     stubborn bad save still can't crash the app or block a new game.
    ///
    /// The whole path is testable headless (an `InMemorySaveStore` proves the save is gone and the notice
    /// carries the right reason), because the notice is a plain value with no UI dependency.
    public static func resumeOrDiscard(
        game: Game,
        store: any SaveStore,
        codec: SaveCodec = SaveCodec(),
        migrator: SaveMigrator = SaveMigrator(),
        saveID: SaveID? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> ResumeOutcome<Game> {
        let id = saveID ?? .game(Game.metadata.id)
        let result = await resume(
            game: game, store: store, codec: codec, migrator: migrator, saveID: id, now: now)

        switch result {
        case .success(let session):
            return .resumed(session)
        case .failure(let error):
            let reason: SaveNotice.Reason
            switch error {
            case .noSave:
                // Nothing was saved — a clean fresh start, not a discard. No notice.
                return .noSave
            case .corruptSave:
                reason = .corrupt
            case .incompatibleVersion:
                reason = .incompatibleVersion
            case .gameMismatch(let expected, let found):
                reason = .gameMismatch(expected: expected, found: found)
            case .replayFailed:
                reason = .replayFailed
            }
            // Discard the unusable save so it is never re-offered. A failed delete must not crash or
            // block the app, so the notice is returned regardless (R-PERS-2.2).
            try? store.delete(id)
            return .discarded(SaveNotice(saveID: id, reason: reason))
        }
    }

    // MARK: - Submit with autosave (R-PERS-1.1)

    /// Submit `envelope` to the host and, if accepted, rewrite the save so disk reflects the new state
    /// (R-PERS-1.1; design.md §3.1).
    ///
    /// Forwards to `GameHost.submit(_:)` (the single mutator, R-SESS-1.1). On `.accepted` the session
    /// persists the up-to-date document — the action log read live from the host, so the save always
    /// includes the just-applied action. On `.rejected` nothing changed, so no save is written. Returns the
    /// host's `ResultEnvelope` unchanged so the caller drives events/views exactly as with a bare host.
    @discardableResult
    public func submit(_ envelope: ActionEnvelope) async throws -> ResultEnvelope {
        let result = await host.submit(envelope)
        if result.isAccepted {
            try await persist()
        }
        return result
    }

    /// Undo the most recent accepted action and persist the shortened log when the game allows it. The
    /// host rebuilds its private state; this actor only writes the resulting save document (R-PERS-1.1,
    /// R-ENG-7.3).
    @discardableResult
    public func undo() async throws -> Bool {
        let changed = await host.undo()
        if changed { try await persist() }
        return changed
    }

    /// Redo the most recently undone action and persist the resulting log (R-ENG-7.3).
    @discardableResult
    public func redo() async throws -> Bool {
        let changed = await host.redo()
        if changed { try await persist() }
        return changed
    }

    /// The current redacted view for `viewer` — forwarded to the host so the session is a drop-in for a
    /// bare host at the view boundary (R-ENG-8.2, R-SESS-1.2).
    public func view(for viewer: Viewer) async -> PlayerView {
        await host.view(for: viewer)
    }

    // MARK: - Persist (R-PERS-1.1)

    /// Write the current `SaveDocument` for this session to the store (R-PERS-1.1).
    ///
    /// Reads the action log LIVE from the host so the save reflects every accepted action, sets the resume
    /// `cursor` to the last log index, refreshes `updatedAt` (metadata only, tech.md rule 8), encodes via
    /// the codec, and hands the bytes to the store — which, in production, writes only inside the sandbox
    /// container (R-PERS-3.1).
    private func persist() async throws {
        let entries = await host.actionLog.entries
        let currentSeed = await host.handSeed

        // The save's `handSeeds` must include the seed the CURRENT (possibly in-progress, not-yet-
        // summarized) hand was dealt from, because restore replays the log against it (design.md §4;
        // R-PERS-1.2). `Match.handSeeds` records one seed per *completed* hand via `applyHand`, so for a
        // hand still in play the current seed is not there yet. Snapshot the match and ensure its last
        // seed is the current hand's, so `resume` finds it as `handSeeds.last`.
        var snapshot = match
        if snapshot.handSeeds.last != currentSeed {
            snapshot.handSeeds.append(currentSeed)
        }

        let document = SaveDocument(
            gameID: gameID,
            options: options,
            match: snapshot,
            seats: seats,
            actionLog: entries,
            cursor: entries.count - 1,
            createdAt: createdAt,
            updatedAt: now())
        let data = try codec.encode(document)
        try store.write(data, for: saveID)
    }
}
