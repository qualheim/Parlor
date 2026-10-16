// LibraryNavigation — the per-window navigation coordinator that connects the Library → Setup → Table
// flow and builds the real game session on "Deal" (R-APP-1, R-APP-2, R-APP-3, R-PERS-1.1, R-PERS-4.1).
//
// NOTE ON BUILD: compiled by the Xcode project, not SwiftPM (design.md §1).
//
// ONE COORDINATOR PER WINDOW = ONE INDEPENDENT GAME (R-APP-6.2 / R-SESS-6.1). Each window's `RootView`
// owns one `LibraryNavigation`; when the player deals, it constructs a fresh `AutosaveSession` + a
// `TableViewModel` that no other window shares, and pushes `TableScreen` onto this window's path. Quitting
// to the library pops back; the save on disk lets the Library show a "Continue" hero and lets
// "Replay last game" reconstruct the deal (R-PERS-4.1).
//
// WHAT "DEAL" DOES (the real path, NOT the offline debug one):
//   1. Resolve the chosen `KlondikeOptions` from the setup selections.
//   2. `AutosaveSession<Klondike>.start(...)` — this builds the authoritative `GameHost` from
//      `(options, seed)` and writes the initial save, so a "Continue" entry exists before the first move
//      (R-PERS-1.1).
//   3. Compute the initial `KlondikeState` + redacted `PlayerView` purely (`Klondike.initialState` /
//      `redactedView`) to seed the table's first frame — the same starting position the host built from
//      the same seed (R-ENG-4.4), so the render matches the authoritative deal.
//   4. Build `TableViewModel(session:initialState:initialView:gameTitle:settings:)` — the REAL session
//      initializer — and navigate to it (R-APP-3.1).
//
// CRAZY EIGHTS. Crazy Eights registers in the catalog and has a complete setup sheet (opponents, house
// rules), so it is browsable and configurable. Its multi-seat TABLE layout/adapter is a later game-module
// task (design.md §11 step 4; there is no Crazy Eights table adapter in GamesUI yet), so dealing it cannot
// yet reach a playable table. Rather than crash or dead-end, the coordinator surfaces a calm, honest
// "table coming soon" state for games without a wired table. Klondike is fully playable end-to-end.

import GamesUI  // Klondike, KlondikeOptions, GameCatalog, CatalogEntry, SetupSheetModel, ...
import Observation
import Persistence  // AutosaveSession, SaveStore, SandboxSaveStore, AppSettings, SavedSeat, Match
import SwiftUI

// MARK: - Navigation destinations

/// A destination this window can navigate to beyond the library root (R-APP-3.1).
///
/// Only the table is a pushed destination; setup is presented as a `.sheet` over the library (R-APP-2.1),
/// so it is modeled separately (`presentedSetup`) rather than as a path entry. `Identifiable`/`Hashable`
/// so it drives a `NavigationStack` path.
enum LibraryRoute: Hashable {
    /// A running game's table screen. Carries the game id so the path is `Hashable`; the live view-model
    /// is held on the coordinator (`activeTable`) since it is reference type and not `Hashable`.
    case table(gameID: String)
}

// MARK: - Coordinator

/// The per-window navigation + deal coordinator (R-APP-1, R-APP-2, R-APP-3). `@MainActor @Observable` so
/// the SwiftUI shell reacts to path/sheet/table changes.
@MainActor
@Observable
final class LibraryNavigation {
    // MARK: Shared window context

    /// The feature-flagged catalog the Library shows (R-APP-1.2). Bundled today (Klondike, Crazy Eights).
    let catalog: GameCatalog

    /// The persisted Library state (favorites / recents / in-progress) the Library composes with the
    /// catalog (R-APP-1.1).
    let libraryState: LibraryStateStore

    /// The user settings snapshot the table view-model maps onto the driver/behavior (R-APP-5.1).
    let settings: AppSettings

    /// The save store the sessions autosave into and the Library sources "Continue" from (R-PERS-1.1,
    /// R-APP-1.1). The sandbox container store in production.
    let saveStore: any SaveStore

    /// The deterministic near-win fixture used only by the full UI-test flow. It still goes through the
    /// normal setup → autosave → host → table path.
    private let debugNearWin: Bool

    // MARK: Navigation state

    /// The pushed navigation path for this window (library root is implicit; `.table` is the only push).
    var path: [LibraryRoute] = []

    /// The catalog entry whose setup sheet is presented over the library, or `nil` when none (R-APP-2.1).
    var presentedSetup: CatalogEntry?

    /// The live table view-model for the running game, or `nil` when at the library. Built by `deal(...)`
    /// / `resume(...)`; `TableScreen` binds to it. Reference type, so it is held here rather than in the
    /// `Hashable` route.
    private(set) var activeTable: TableViewModel?

    /// The active Crazy Eights table model, kept separate from the solitaire model because its multi-seat
    /// renderer and AI turn loop have a different game-specific surface.
    private(set) var activeCrazyEights: CrazyEightsTableViewModel?

    /// A calm banner shown when the player tries to open a game whose table is not wired yet (Crazy
    /// Eights, pending its table layout — design.md §11 step 4). `nil` when there is nothing to say.
    var unsupportedTableMessage: String?

    // MARK: Init

    /// Build a coordinator for one window. The save store defaults to the sandbox container store; a
    /// test/preview can inject an in-memory store.
    init(
        catalog: GameCatalog = .bundled,
        settings: AppSettings = .defaults,
        saveStore: (any SaveStore)? = nil,
        libraryState: LibraryStateStore? = nil,
        debugNearWin: Bool = false
    ) {
        let store = saveStore ?? ((try? SandboxSaveStore()) ?? InMemorySaveStore())
        self.catalog = catalog
        self.settings = settings
        self.saveStore = store
        self.libraryState = libraryState ?? LibraryStateStore(saveStore: store)
        self.debugNearWin = debugNearWin
    }

    // MARK: - Setup presentation (R-APP-2.1)

    /// Open the setup sheet for `entry` (from a tile tap). Only visible/enabled entries reach here, so an
    /// unbuilt game can never be configured (R-APP-1.2).
    func openSetup(for entry: CatalogEntry) {
        presentedSetup = entry
    }

    /// Dismiss the setup sheet without dealing.
    func cancelSetup() {
        presentedSetup = nil
    }

    // MARK: - Deal (R-APP-2 → R-APP-3, R-PERS-1.1)

    /// Deal a new game for `entry` with the chosen Klondike `options`, building the real session + table
    /// and navigating to it (R-APP-3.1, R-PERS-1.1). Klondike only; other games route through
    /// `dealUnsupported` until their table lands.
    ///
    /// The setup sheet already resolved the player's selections into concrete options; this constructs the
    /// authoritative session from them, seeds the table's first frame from the same seed, and pushes the
    /// table. Records the game in recents and refreshes the in-progress set so the Library reflects the
    /// new save (R-APP-1.1).
    func dealKlondike(_ entry: CatalogEntry, options: KlondikeOptions) async {
        presentedSetup = nil
        let seed = LibraryNavigation.freshSeed()
        let game = Klondike()
        var dealOptions = options
        if debugNearWin { dealOptions.debugNearWin = true }

        // The authoritative session: builds the host from (options, seed) and writes the initial save
        // (R-PERS-1.1). One save slot per game id (task 6.1).
        let seats = [SavedSeat(id: klondikeSeat, profile: settings.profile)]
        let match = Match(dealer: klondikeSeat, target: .openEnded)
        do {
            let session = try await AutosaveSession<Klondike>.start(
                game: game,
                options: dealOptions,
                seats: seats,
                match: match,
                seed: seed,
                store: saveStore,
                saveID: .game(Klondike.metadata.id))

            // Seed the table's first frame from the SAME seed the host dealt from, so the render matches
            // the authoritative deal (R-ENG-4.4). The initial state/view are computed purely; the host
            // remains the sole state authority (R-SESS-1.2) — this is just the starting snapshot.
            let initialState = game.initialState(options: dealOptions, seed: seed)
            let initialView = game.redactedView(of: initialState, for: .seat(klondikeSeat))

            let model = TableViewModel(
                session: session,
                initialState: initialState,
                initialView: initialView,
                gameTitle: entry.metadata.name,
                settings: settings,
                onQuit: { [weak self] in self?.quitToLibrary() })

            activeTable = model
            activeCrazyEights = nil
            libraryState.recordPlayed(entry.metadata.id)
            libraryState.refreshInProgress()
            path.append(.table(gameID: entry.metadata.id))
            AppLog.ui.info("dealt a new game and navigated to the table")
        } catch {
            AppLog.ui.error("failed to start session: \(String(describing: error))")
            unsupportedTableMessage = "This game couldn't be dealt right now. Please try again."
        }
    }

    /// Deal a real Crazy Eights hand against one AI seat. The same autosaving session boundary used by
    /// Klondike carries the hidden per-seat views and every accepted human/AI action to disk.
    func dealCrazyEights(
        _ entry: CatalogEntry,
        options: CrazyEightsOptions,
        seed: UInt64? = nil
    ) async {
        presentedSetup = nil
        let game = CrazyEights()
        let handSeed = seed ?? LibraryNavigation.freshSeed()
        let humanSeat = SeatID.index(0)

        // Create seats: 1 human + (playerCount - 1) AI players (gap 1 fix)
        var seats: [SavedSeat] = []
        seats.append(SavedSeat(id: humanSeat, profile: settings.profile))

        // Get AI personas - cycle through bundled personas for variety
        let aiPersonas = AIPersona.bundled
        for i in 1..<options.playerCount {
            let aiSeat = SeatID.index(i)
            let persona = aiPersonas[i % aiPersonas.count]
            let ai = SavedSeat(id: aiSeat, profile: persona.profile)
            seats.append(ai)
        }

        let match = Match(
            dealer: humanSeat,
            target: .targetScore(value: options.matchTarget))
        do {
            let session = try await AutosaveSession<CrazyEights>.start(
                game: game,
                options: options,
                seats: seats,
                match: match,
                seed: handSeed,
                store: saveStore,
                saveID: .game(CrazyEights.metadata.id))
            let initialState = game.initialState(options: options, seed: handSeed)
            let initialView = game.redactedView(of: initialState, for: .seat(humanSeat))
            let aiSeatIDs = Set((1..<options.playerCount).map { SeatID.index($0) })
            let statsService = StatisticsService(store: saveStore)
            let model = CrazyEightsTableViewModel(
                session: session,
                initialState: initialState,
                initialView: initialView,
                gameTitle: entry.metadata.name,
                settings: settings,
                aiSeats: aiSeatIDs,
                statsService: statsService,
                onQuit: { [weak self] in self?.quitToLibrary() })
            activeCrazyEights = model
            activeTable = nil
            libraryState.recordPlayed(entry.metadata.id)
            libraryState.refreshInProgress()
            path.append(.table(gameID: entry.metadata.id))
        } catch {
            AppLog.ui.error("failed to start Crazy Eights: \(String(describing: error))")
            unsupportedTableMessage = "This game couldn't be dealt right now. Please try again."
        }
    }

    /// Eights — design.md §11 step 4). Configurable and browsable, but not yet playable.
    func dealUnsupported(_ entry: CatalogEntry) {
        presentedSetup = nil
        unsupportedTableMessage =
            "\(entry.metadata.name) can be set up here, but its table is still being built. "
            + "Klondike is fully playable today."
        AppLog.ui.info("deal requested for a game without a wired table: \(entry.metadata.id)")
    }

    // MARK: - Continue / Replay (R-APP-1.1, R-PERS-4.1)

    /// Resume the in-progress game for `entry` from its autosave, rebuilding the session by replaying its
    /// log and navigating to the table (R-PERS-1.2).
    func resume(_ entry: CatalogEntry) async {
        if entry.metadata.id == CrazyEights.metadata.id {
            await resumeCrazyEights(entry)
            return
        }
        guard entry.metadata.id == Klondike.metadata.id else {
            dealUnsupported(entry)
            return
        }
        presentedSetup = nil
        let game = Klondike()

        // Reconstruct the authoritative session by REPLAYING the recorded log (R-PERS-1.2). If the save is
        // unusable it is discarded with a calm note (R-PERS-2.2), never a crash.
        let outcome = await AutosaveSession<Klondike>.resumeOrDiscard(
            game: game, store: saveStore, saveID: .game(Klondike.metadata.id))

        switch outcome {
        case .resumed(let session):
            // Seed the table's first frame from the same recorded run. The host never vends raw state
            // (R-SESS-1.2), so the App rebuilds the render-seed `KlondikeState` by replaying the recorded
            // log through the PURE `Klondike.apply` — the exact deterministic run the host restored to
            // (R-ENG-4.4). This touches no authoritative state; it is pure computation over the save's log.
            let replaySeed = LibraryNavigation.replayedState(game: game, store: saveStore)
            let initialState = replaySeed ?? game.initialState(options: KlondikeOptions(), seed: 0)
            let initialView = game.redactedView(of: initialState, for: .seat(klondikeSeat))
            let initialMoveCount = LibraryNavigation.replayedKlondikeActionCount(
                game: game, store: saveStore)
            let model = TableViewModel(
                session: session,
                initialState: initialState,
                initialView: initialView,
                gameTitle: entry.metadata.name,
                settings: settings,
                initialMoveCount: initialMoveCount,
                onQuit: { [weak self] in self?.quitToLibrary() })
            activeTable = model
            activeCrazyEights = nil
            libraryState.recordPlayed(entry.metadata.id)
            path.append(.table(gameID: entry.metadata.id))
            AppLog.ui.info("resumed a game and navigated to the table")
        case .noSave:
            // Nothing to resume — fall back to a fresh setup sheet.
            openSetup(for: entry)
        case .discarded:
            libraryState.refreshInProgress()
            unsupportedTableMessage =
                "That saved game couldn't be resumed and has been removed. Start a new one."
        }
    }

    private func resumeCrazyEights(_ entry: CatalogEntry) async {
        presentedSetup = nil
        let game = CrazyEights()
        let outcome = await AutosaveSession<CrazyEights>.resumeOrDiscard(
            game: game, store: saveStore, saveID: .game(CrazyEights.metadata.id))
        switch outcome {
        case .resumed(let session):
            let replayed = LibraryNavigation.replayedCrazyEightsState(
                game: game, store: saveStore)
            let initialState = replayed ?? game.initialState(options: .init(), seed: 0)
            let initialView = game.redactedView(of: initialState, for: .seat(SeatID.index(0)))
            let model = CrazyEightsTableViewModel(
                session: session,
                initialState: initialState,
                initialView: initialView,
                gameTitle: entry.metadata.name,
                settings: settings,
                onQuit: { [weak self] in self?.quitToLibrary() })
            activeCrazyEights = model
            activeTable = nil
            libraryState.recordPlayed(entry.metadata.id)
            path.append(.table(gameID: entry.metadata.id))
        case .noSave:
            openSetup(for: entry)
        case .discarded:
            libraryState.refreshInProgress()
            unsupportedTableMessage =
                "That saved game couldn't be resumed and has been removed. Start a new one."
        }
    }

    /// Rebuild the current Klondike state by replaying the last save's recorded log through the PURE rules.
    /// `Klondike` transition (R-PERS-1.2, R-ENG-4.4). Used only to seed the table's first render frame on
    /// resume/replay — it reads the save record (options, seed, log) and computes, touching no
    /// authoritative host state (R-SESS-1.2). Returns `nil` if there is no usable save.
    private static func replayedState(game: Klondike, store: any SaveStore) -> KlondikeState? {
        guard case .success(let replay) = GameReplay.loadLast(game: game, store: store) else {
            return nil
        }
        var state = game.initialState(options: replay.options, seed: replay.seed)
        for entry in replay.recordedLog {
            guard let action = try? entry.action.decode(as: KlondikeAction.self) else { return nil }
            guard case .success(let (next, _)) = game.apply(action, by: entry.seat, to: state)
            else {
                return nil
            }
            state = next
        }
        return state
    }

    private static func replayedKlondikeActionCount(
        game: Klondike, store: any SaveStore
    ) -> Int {
        guard case .success(let replay) = GameReplay.loadLast(game: game, store: store) else {
            return 0
        }
        return replay.recordedLog.count
    }

    /// Rebuild the Crazy Eights state used to seed the table after a resume. This is a render snapshot only;
    /// the restored `AutosaveSession` remains authoritative.
    private static func replayedCrazyEightsState(
        game: CrazyEights, store: any SaveStore
    ) -> CrazyEightsState? {
        guard case .success(let replay) = GameReplay.loadLast(game: game, store: store) else {
            return nil
        }
        var state = game.initialState(options: replay.options, seed: replay.seed)
        for entry in replay.recordedLog {
            guard let action = try? entry.action.decode(as: CrazyEightsAction.self),
                case .success(let (next, _)) = game.apply(action, by: entry.seat, to: state)
            else { return nil }
            state = next
        }
        return state
    }

    /// "Replay last game" — reconstruct the most recently played game from its save and open its table
    /// (R-PERS-4.1). Reuses the resume path (the save's action log is the source of truth).
    func replayLastGame() async {
        let recents = libraryState.state.recentlyPlayedGameIDs
        let candidateID =
            recents.first { catalog.visibleEntry(id: $0) != nil }
            ?? Array(libraryState.state.inProgressGameIDs).first
        guard let candidateID, let entry = catalog.visibleEntry(id: candidateID) else {
            unsupportedTableMessage = "There's no recent game to replay yet."
            return
        }
        await resume(entry)
    }

    // MARK: - Quit to Library (R-APP-3.1)

    /// Leave the table and return to the library, refreshing the in-progress set so the Continue hero is
    /// current (R-APP-1.1). The save on disk is untouched, so the game can be resumed.
    func quitToLibrary() {
        path.removeAll()
        activeTable = nil
        activeCrazyEights = nil
        unsupportedTableMessage = nil
        libraryState.refreshInProgress()
        AppLog.ui.info("quit to library")
    }

    // MARK: - Helpers

    /// A fresh per-hand seed for a new deal. Seed generation happens OUTSIDE the rules (R-ENG-4.2); the
    /// App mints it once per deal and hands it to the session, which records it for replay (R-ENG-4.3).
    private static func freshSeed() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return UInt64.random(in: .min ... .max, using: &generator)
    }
}
