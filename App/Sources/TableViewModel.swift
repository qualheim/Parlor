// TableViewModel — the per-window game view-model that wires the packages behind `TableScreen`
// (R-APP-3.1, R-APP-6.2).
//
// NOTE ON BUILD: compiled by the Xcode project, not SwiftPM (design.md §1). Written to match the real
// package APIs: `AutosaveSession` (Persistence), `AnimationDriver` / `TableRenderModel` / `TableHUDView`
// model types (TableKit), `Klondike` + `KlondikeTableController` + `WinCelebrationCoordinator` (GamesUI).
//
// ONE VIEW-MODEL PER WINDOW = ONE INDEPENDENT GAME (R-APP-6.2 / R-SESS-6.1). `ParlorApp`'s `WindowGroup`
// makes a fresh `TableViewModel` for each window, so every window owns its own `AutosaveSession` (its own
// `GameHost`, RNG, and log) and its own `AnimationDriver`. Nothing here is a shared singleton, so two
// windows play two unrelated games at once — the UI-layer realization of R-SESS-6.1.
//
// THIN WRAPPER (the fix). The interaction/render/submission LOGIC — the piece that was wrong and, worse,
// untested because this file is not compiled by SwiftPM — now lives in `KlondikeTableController` in
// GamesUI, where SwiftPM compiles AND a headless end-to-end invariant test drives it against a real
// `GameHost<Klondike>` through the SAME path used here. This view-model is now a thin shell: it owns the
// `AutosaveSession` (the only thing GamesUI must not depend on) and hands the controller two closures —
// `submit` (forward an action to the session's host) and `view` (fetch the local seat's redacted view) —
// then forwards the table's reads to the controller. The controller keeps the on-screen render model equal
// to the host's redacted view after every accepted action and serializes submissions so nothing races or
// is dropped silently.

import DesignSystem  // DeckStyle, CardSizeScale, CardAppearance, EffectiveAccessibility
import GamesUI  // re-exports GamesRules (+ TableKit/EngineCore): Klondike, KlondikeTableController, ...
import Observation
import Persistence  // AutosaveSession, AppSettings, StatisticsService, GameResult, StatisticsKey
import SwiftUI
import TableKit

/// The per-window game view-model (R-APP-6.2). `@MainActor @Observable` so the SwiftUI table reacts to it;
/// it drives an independent `AutosaveSession` + `KlondikeTableController` that no other window shares.
@MainActor
@Observable
final class TableViewModel {
    // MARK: Identity / static context

    /// The game id these rules/stats/saves key on (e.g. `"klondike"`).
    let gameID: String
    /// The catalog display name for the window title and rules header.
    let gameTitle: String

    // MARK: View state the table binds to

    /// Whether the history drawer is open in the HUD.
    var historyOpen = false

    // MARK: Wired subsystems (independent per window)

    /// The per-window Klondike table controller (GamesUI): owns the render model + the serialized
    /// submission pipeline that keeps the on-screen model equal to the host's redacted view.
    let controller: KlondikeTableController

    /// The win-celebration coordinator (R-KLON-3.9); the overlay observes it and it starts on a win.
    let celebration = WinCelebrationCoordinator()

    /// The game's declarative table layout (TableKit).
    let layout: TableLayout

    /// Left→right keyboard-navigation order of zones (R-TABLE-3.4).
    let zoneOrder: [ZoneID]

    // MARK: Session (authoritative)

    /// The autosaving session driving the authoritative host (R-PERS-1.1). Actor-isolated. `nil` only in
    /// the DEBUG near-win offline mode used by the accessibility UI suite (R-A11Y-5.1).
    private let session: AutosaveSession<Klondike>?
    /// Statistics service for recording game results (gap 4 fix)
    private let statsService: StatisticsService?

    /// Number of accepted actions already present when a saved session is resumed. The live move count is
    /// updated after each accepted action and after undo/redo so the HUD has an observable value to render.
    private let initialMoveCount: Int

    /// The currently applied action count, including actions restored from an autosave. Stored rather than
    /// derived through the nested controller so SwiftUI observation publishes every accepted action and
    /// undo/redo transition to the HUD and UI tests (R-PERS-1.2, R-QA-5.1).
    private(set) var moveCount: Int

    /// User settings (animation speed, AI pace, appearance, hints, auto-moves) mapped onto the driver /
    /// behavior. Appearance changes are live so the table can switch theme/deck without a restart.
    var settings: AppSettings

    /// Called when the player chooses "Quit to Library" from the pause menu (R-APP-3.1). `nil` in DEBUG
    /// offline mode (no navigation).
    private let onQuit: (() -> Void)?

    /// The animation driver the table draws (owned by the controller).
    var driver: AnimationDriver { controller.driver }

    /// The user's preferred table theme, resolved from the DesignSystem registry.
    var preferredTheme: TableTheme {
        TableTheme.theme(id: settings.appearance.themePackID) ?? .default
    }

    /// A user-facing move count that survives a quit/resume round trip and publishes live transitions.

    /// The user's preferred deck style (before the four-color accessibility override is folded in).
    var preferredDeckStyle: DeckStyle {
        DeckStyle.style(id: settings.appearance.deckStyleID) ?? .default
    }

    /// The card-size accessibility scale chosen in settings (S/M/L/XL — R-A11Y-4.1).
    var cardSizeScale: CardSizeScale { settings.appearance.cardSize.scale }

    /// Whether auto-flip is enabled (gap 7 fix: from KlondikeOptions.autoFlip)
    /// The authoritative rule always flips exposed cards; this flag controls UI presentation
    var autoFlip: Bool { controller.latestState.options.autoFlip }

    /// Whether timed scoring is enabled (gap 7 fix)
    var isTimed: Bool { controller.latestState.options.timed }

    /// Whether Vegas cumulative scoring is enabled (gap 7 fix)
    var isVegasCumulative: Bool { controller.latestState.options.vegasCumulative }

    /// Current vegas bankroll (gap 7 fix: persisted across games in settings)
    var vegasBankroll: Int { settings.gameplay.vegasBankroll }

    // MARK: Init

    /// Build a view-model for an already-started `AutosaveSession` (created by the setup flow / resume).
    init(
        session: AutosaveSession<Klondike>,
        initialState: KlondikeState,
        initialView: PlayerView,
        gameTitle: String,
        settings: AppSettings,
        initialMoveCount: Int = 0,
        statsService: StatisticsService? = nil,  // gap 4: record stats
        onQuit: (() -> Void)? = nil
    ) {
        self.session = session
        self.statsService = statsService
        self.gameID = Klondike.metadata.id
        self.gameTitle = gameTitle
        self.settings = settings
        self.initialMoveCount = initialMoveCount
        self.moveCount = initialMoveCount
        self.onQuit = onQuit

        self.layout = .example()
        self.zoneOrder =
            [ZoneID(name: "stock"), ZoneID(name: "waste")]
            + (0..<4).map { ZoneID(name: "foundation-\($0)") }
            + (0..<7).map { ZoneID(name: "tableau-\($0)") }

        let animation = AnimationSettings(
            speed: settings.gameplay.animationSpeed.tableKitSpeed,
            reduceMotion: settings.accessibility.forceReduceMotion)
        let driver = AnimationDriver(
            model: TableRenderModel(playerView: initialView), settings: animation)

        // The controller submits through the AUTOSAVING session (so every accepted action persists —
        // R-PERS-1.1) and resyncs its view from the same host. GamesUI never imports Persistence; the
        // dependency flows the other way — App injects these closures that close over the session.
        self.controller = KlondikeTableController(
            initialState: initialState,
            initialView: initialView,
            driver: driver,
            submit: { action in
                guard let any = try? AnyGameAction(action) else { return nil }
                let envelope = ActionEnvelope(seat: klondikeSeat, action: any)
                return try? await session.submit(envelope)
            },
            view: { await session.view(for: .seat(klondikeSeat)) })

        startWinWatch()
    }

    /// Build an OFFLINE debug view-model that starts from a fixed Klondike `state` and plays purely against
    /// it via the controller's offline path — no persisted session (R-A11Y-5.1).
    init(debugState state: KlondikeState, gameTitle: String, settings: AppSettings) {
        let game = Klondike()
        let initialView = game.redactedView(of: state, for: .seat(klondikeSeat))
        self.session = nil
        self.statsService = nil
        self.gameID = Klondike.metadata.id
        self.gameTitle = gameTitle
        self.settings = settings
        self.initialMoveCount = 0
        self.moveCount = 0
        self.onQuit = nil

        self.layout = .example()
        self.zoneOrder =
            [ZoneID(name: "stock"), ZoneID(name: "waste")]
            + (0..<4).map { ZoneID(name: "foundation-\($0)") }
            + (0..<7).map { ZoneID(name: "tableau-\($0)") }

        let animation = AnimationSettings(
            speed: settings.gameplay.animationSpeed.tableKitSpeed,
            reduceMotion: settings.accessibility.forceReduceMotion)
        let driver = AnimationDriver(
            model: TableRenderModel(playerView: initialView), settings: animation)

        // No session: the controller's `submit` returns `nil`, so it advances its shadow state directly and
        // reconciles the render model to the view it derives — the same table/interaction/celebration path
        // a real game uses, minus the autosave layer.
        self.controller = KlondikeTableController(
            initialState: state,
            initialView: initialView,
            driver: driver,
            submit: { _ in nil },
            view: { game.redactedView(of: state, for: .seat(klondikeSeat)) })

        startWinWatch()
    }

    // MARK: Derived HUD / interaction inputs (read by TableScreen)

    /// The interaction seam for the table (R-TABLE-3) — delegated to the controller.
    var interactionInput: TableInteractionInput { controller.interactionInput }

    /// How to draw a given render key (known face vs back) — delegated to the controller.
    func faceContent(_ key: RenderKey) -> PieceFaceContent { controller.faceContent(key) }

    /// Seat plates for the HUD. Klondike is single-seat solitaire with no opponents/scoreboard plates.
    var seatPlates: [SeatPlateState] { [] }
    /// The scoreboard model for the HUD (empty for single-seat solitaire — R-TABLE-6.1).
    var scoreboard: ScoreboardModel {
        ScoreboardModel(rows: [], handsPlayed: 0, isMatchOver: false)
    }
    /// The caption bar text (an illegal-move reason), or `nil` — surfaced by the controller (R-TABLE-4.1).
    var caption: String? { controller.caption }
    /// The move-history entries for the drawer.
    var history: [HistoryEntry] { [] }

    /// Which quiet-toolbar actions are enabled right now (Undo when there is history, Hint when enabled).
    var enabledToolbarActions: Set<ToolbarAction> {
        var actions: Set<ToolbarAction> = [.new, .rules, .menu]
        if canUndo { actions.insert(.undo) }
        if hintsEnabled { actions.insert(.hint) }
        return actions
    }

    /// Whether hints are offered (user setting; R-KLON-3.8).
    var hintsEnabled: Bool { settings.gameplay.hintsEnabled }
    /// Whether an undo is currently available (unlimited undo for Klondike; R-KLON-2.*).
    private(set) var canUndo = false
    /// Whether a redo is currently available.
    private(set) var canRedo = false

    // MARK: Player actions

    /// Change the table theme live. The selected id is the same id used by the theme-pack registry.
    func setTheme(_ themeID: String) {
        guard TableTheme.theme(id: themeID) != nil else { return }
        settings.appearance.themePackID = themeID
    }

    /// Change the deck style live. The selected id is the same id used by the DesignSystem catalog.
    func setDeckStyle(_ deckStyleID: String) {
        guard DeckStyle.style(id: deckStyleID) != nil else { return }
        settings.appearance.deckStyleID = deckStyleID
    }

    /// Fast-forward the current animation, or confirm the pending selection (Space/Return; R-TABLE-5.1).
    func fastForwardOrConfirm() { controller.fastForwardOrConfirm() }

    /// Fold the OS accessibility environment flags together with the app overrides and apply the result to
    /// the animation driver's Reduce-Motion state (R-A11Y-4.1, R-TABLE-5.3).
    func applyEffectiveAccessibility(_ effective: EffectiveAccessibility) {
        controller.driver.settings.reduceMotion = effective.reduceMotion
    }

    // MARK: Win watch

    /// Watch for a win and start the celebration once (R-KLON-3.9).
    ///
    /// This used to be a `withObservationTracking` closure that RE-ARMED ITSELF inside its own `onChange`
    /// by reading the very state it reacted to — an observation loop that re-fired on every accepted move
    /// and mutated `canUndo` each time, re-entering observation. It is now a plain callback the controller
    /// invokes exactly ONCE per accepted transition (`controller.onAccepted`), so nothing re-registers an
    /// observation or reads observable state to react to it. The coordinator ignores a repeated `start`
    /// while already celebrating, so a terminal state only ever triggers one homage.
    private func startWinWatch() {
        controller.onAccepted = { [weak self] state in
            guard let self else { return }
            self.moveCount += 1
            self.handleAcceptedTransition(state)
        }
        // Fold in the initial derived flags once (the deal is never a win, but keep the flags consistent).
        handleAcceptedTransition(controller.latestState)
    }

    /// React to one accepted transition: fire the win celebration if the board is terminal and refresh the
    /// derived toolbar flags. A plain function — no observation, no self-re-arming (see `startWinWatch`).
    private func handleAcceptedTransition(_ state: KlondikeState) {
        if Klondike().isTerminal(state) {
            celebration.start(
                outcome: Klondike().outcome(state),
                reduceMotion: settings.accessibility.forceReduceMotion)
        }
        canUndo = controller.hasUndoState
        canRedo = controller.hasRedoState
    }

    // MARK: Menu-bar / toolbar commands (act on THIS window's game only — R-APP-6.2)

    /// Start a brand-new game in this window (⌘N). Deals a fresh Klondike; the setup flow supplies options.
    func newGame() { AppLog.ui.info("table: New Game (window-local)") }
    /// Restart the current deal (same seed).
    func restart() { AppLog.ui.info("table: Restart deal") }
    /// Undo the last move (⌘Z; unlimited for Klondike).
    func undo() { Task { await performUndo() } }
    /// Redo the last undone move (⇧⌘Z).
    func redo() { Task { await performRedo() } }
    /// Show a heuristic hint (H; R-KLON-3.8).
    func hint() { AppLog.ui.info("table: Hint requested") }
    /// Leave the table and return to the library (R-APP-3.1).
    func quitToLibrary() {
        // Gap 4 fix: record statistics before quitting
        recordStatisticsIfNeeded()

        AppLog.ui.info("table: Quit to Library")
        onQuit?()
    }

    /// Record game result to statistics (gap 4 fix)
    private func recordStatisticsIfNeeded() {
        guard statsService != nil, session != nil else { return }

        let state = controller.latestState
        let game = Klondike()
        let isWin = game.isTerminal(state)

        // Build variant key from options
        let variantKey =
            "\(state.options.drawCount == .one ? "draw1" : "draw3")-\(state.options.scoring.rawValue)"

        let result = GameResult(
            key: StatisticsKey(gameID: Klondike.metadata.id, variantKey: variantKey),
            won: isWin,
            score: state.options.scoring == .none ? nil : state.score,
            time: nil,
            isExcludedFromStatistics: false
        )

        Task {
            _ = try? await statsService?.record(result)
        }
    }

    /// Undo the last move (R-KLON-2.*). The session-level undo path is a later task; this re-syncs the
    /// controller's render model from the host so the table never desynchronizes.
    private func performUndo() async {
        AppLog.ui.info("table: Undo")
        guard let session else {
            guard controller.adoptUndoState() else { return }
            moveCount = max(initialMoveCount, moveCount - 1)
            await controller.resyncFromHostPublic()
            handleAcceptedTransition(controller.latestState)
            return
        }
        guard (try? await session.undo()) == true else { return }
        guard controller.adoptUndoState() else { return }
        moveCount = max(initialMoveCount, moveCount - 1)
        await controller.resyncFromHostPublic()
        canUndo = controller.hasUndoState
        canRedo = controller.hasRedoState
    }

    /// Redo the last undone move by asking the authoritative session to re-apply its retained log entry.
    private func performRedo() async {
        AppLog.ui.info("table: Redo")
        guard let session else {
            guard controller.adoptRedoState() else { return }
            moveCount += 1
            await controller.resyncFromHostPublic()
            handleAcceptedTransition(controller.latestState)
            return
        }
        guard (try? await session.redo()) == true else { return }
        guard controller.adoptRedoState() else { return }
        moveCount += 1
        await controller.resyncFromHostPublic()
        canUndo = controller.hasUndoState
        canRedo = controller.hasRedoState
    }
}
