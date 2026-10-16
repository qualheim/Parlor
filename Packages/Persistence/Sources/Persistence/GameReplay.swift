// GameReplay — "Replay last game" reconstructed from the action log (R-PERS-4.1, a "Should").
//
// R-PERS-4.1 asks the app to be able to REPLAY the last game, reconstructed FROM THE ACTION LOG. The
// pieces to do that already exist: a save (`SaveDocument`) holds the ordered `actionLog` plus the seed and
// options needed to replay it, and `GameHost.restoring(...)` deterministically rebuilds a host by replaying
// that log against the seed (design.md §4; R-ENG-7.2). This file adds the small, testable RECONSTRUCTION
// PATH on top of those primitives: given the last save, rebuild the recorded run and expose it for the App
// to present as a replay.
//
// SCOPE IS DELIBERATELY OPEN (Q-8, NEEDS REVIEW). The spec's Open Question Q-8 has not settled whether
// "Replay last game" is the last hand or the full match, and whether it is PASSIVE PLAYBACK or INTERACTIVE
// RE-ENTRY. So rather than bake a UX decision into the engine, this path is built to serve EITHER:
//   • `reconstructedHost(...)` / `reconstructedSession(...)` rebuild the game to the recorded end state, so
//     the App can drop the player back in to continue (interactive re-entry), and
//   • `hostAtStep(_:)` rebuilds the game to any PREFIX of the recorded log, so the App can step forward
//     entry-by-entry to play the game back (passive playback), reusing the same deterministic replay.
// Both are pure functions of the recorded save, so whichever scope Q-8 lands on, the reconstruction is
// already correct and tested. The App wires the chosen presentation; nothing here fabricates a rule.
//
// LOCAL ONLY (R-PERS-3.1). Everything flows through the injected `SaveStore`, exactly like resume — no
// network, no cloud; tests inject `InMemorySaveStore` and run the whole path headless.

import Foundation

// MARK: - Replay reconstruction failure (typed; never traps)

/// Why the last game could not be reconstructed for replay (R-PERS-4.1).
///
/// Mirrors `ResumeError` (the reconstruction shares the same replay primitive) so the App can treat a
/// replay that cannot be rebuilt the same calm way it treats an unusable resume — a note, not a crash.
public enum ReplayError: Error, Sendable, Equatable {
    /// There is no last save to replay.
    case noSave
    /// The save bytes could not be decoded into a `SaveDocument`.
    case corruptSave
    /// The save's schema version is incompatible with this build, or the migration chain has a gap.
    case incompatibleVersion
    /// The save decoded, but its game id does not match the game being replayed.
    case gameMismatch(expected: String, found: String)
    /// The save has no recorded hand seed to replay against.
    case missingSeed
    /// Replaying the recorded log (up to the requested step) against the recorded seed failed a hash check.
    case replayFailed
}

// MARK: - Reconstructed replay

/// The last game, reconstructed from its saved action log and ready to replay (R-PERS-4.1).
///
/// A pure value built from the last `SaveDocument`: the game, its options/seats, the seed the hand was
/// dealt from, and the recorded `actionLog`. From these it can deterministically rebuild the `GameHost` at
/// the recorded end (`reconstructedHost`) or at any earlier step (`hostAtStep`) — the App drives whichever
/// the settled Q-8 scope calls for (passive playback vs interactive re-entry). Generic over the game so the
/// options snapshot stays strongly typed, matching `AutosaveSession` / `SaveDocument`.
public struct GameReplay<Game: GameDefinition>: Sendable {
    /// The game whose recorded run this replays.
    public let game: Game
    /// The options the recorded run was configured with.
    public let options: Game.Options
    /// The seats of the recorded run, in order.
    public let seats: [SavedSeat]
    /// The seed the recorded hand was dealt from — the base of every deterministic rebuild.
    public let seed: UInt64
    /// The ordered action log recorded in the save — the authoritative record replayed (R-ENG-7.2).
    public let recordedLog: [LogEntry]
    /// The save slot this replay was reconstructed from (so the App can label it / re-open it).
    public let saveID: SaveID

    /// The number of recorded actions available to replay — the maximum `step` for `hostAtStep`.
    public var actionCount: Int { recordedLog.count }

    private init(
        game: Game,
        options: Game.Options,
        seats: [SavedSeat],
        seed: UInt64,
        recordedLog: [LogEntry],
        saveID: SaveID
    ) {
        self.game = game
        self.options = options
        self.seats = seats
        self.seed = seed
        self.recordedLog = recordedLog
        self.saveID = saveID
    }

    // MARK: - Load the last game (R-PERS-4.1)

    /// Reconstruct the last game for `game` from its save so it can be replayed (R-PERS-4.1).
    ///
    /// Reads the bytes for `saveID` (defaulting to the game's autosave slot — the "last game" for that
    /// game), runs the same migration + decode + game-id check as resume, and captures the options, seats,
    /// seed, and recorded log. Returns a typed `ReplayError` on any problem (never traps), so the App shows
    /// a calm note instead of crashing. This does NOT itself replay — it captures the record; call
    /// `reconstructedHost()` or `hostAtStep(_:)` to build the actual game.
    public static func loadLast(
        game: Game,
        store: any SaveStore,
        codec: SaveCodec = SaveCodec(),
        migrator: SaveMigrator = SaveMigrator(),
        saveID: SaveID? = nil
    ) -> Result<GameReplay<Game>, ReplayError> {
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
        guard let seed = document.match.handSeeds.last else {
            return .failure(.missingSeed)
        }

        return .success(
            GameReplay(
                game: game,
                options: document.options,
                seats: document.seats,
                seed: seed,
                recordedLog: document.entriesToReplay,
                saveID: id))
    }

    // MARK: - Rebuild the game (deterministic replay)

    /// Rebuild the `GameHost` at `step` — after replaying the first `step` recorded actions (R-PERS-4.1).
    ///
    /// `step` is clamped to `0...actionCount`: `0` is the freshly dealt starting position (nothing replayed
    /// yet), `actionCount` is the recorded end. Because it replays a PREFIX of the same recorded log against
    /// the same seed, stepping `0, 1, 2, …` reproduces the game move-by-move — the passive-playback path.
    /// Returns `.replayFailed` if a hash check fails (a corrupt/incompatible log), never trapping.
    public func hostAtStep(_ step: Int) -> Result<GameHost<Game>, ReplayError> {
        let clamped = min(max(step, 0), recordedLog.count)
        let prefix = Array(recordedLog.prefix(clamped))
        let restore = GameHost.restoring(
            game: game,
            options: options,
            seats: seats.map(\.id),
            seed: seed,
            replaying: prefix)
        switch restore {
        case .success(let host):
            return .success(host)
        case .failure:
            return .failure(.replayFailed)
        }
    }

    /// Rebuild the `GameHost` at the recorded END of the game (all actions replayed) — the position for
    /// interactive re-entry (R-PERS-4.1).
    public func reconstructedHost() -> Result<GameHost<Game>, ReplayError> {
        hostAtStep(recordedLog.count)
    }

    /// The ordered redacted views for a viewer as the replay steps forward — one `PlayerView` per step
    /// from the deal (step 0) through the recorded end (R-PERS-4.1).
    ///
    /// A convenience for the passive-playback presentation: it rebuilds the host at each step and asks for
    /// `viewer`'s view, so the App can animate the recorded game back without re-implementing replay.
    /// Returns `.replayFailed` if any step fails to rebuild. This is `async` because reading a view from a
    /// `GameHost` (an actor) is.
    public func viewSequence(for viewer: Viewer) async -> Result<[PlayerView], ReplayError> {
        var views: [PlayerView] = []
        views.reserveCapacity(recordedLog.count + 1)
        for step in 0...recordedLog.count {
            switch hostAtStep(step) {
            case .success(let host):
                views.append(await host.view(for: viewer))
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(views)
    }
}
