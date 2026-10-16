// App — thin macOS SwiftUI shell.
//
// Nearly all logic lives in the local Swift packages; this target is intentionally a thin shell
// (R-BUILD-1.2). It depends on Games, Persistence, and DesignSystem (design.md §1) and is built via
// the XcodeGen-generated Xcode project (project.yml; R-BUILD-1.3), never by SwiftPM.
//
// Task 6.6 wires the app shell's macOS integration on top of the earlier phases (R-APP-3, R-APP-6,
// R-APP-7):
//   • A multi-window `WindowGroup` so EACH WINDOW HOLDS AN INDEPENDENT GAME (R-APP-6.2 — the UI-layer
//     realization of R-SESS-6.1): every window builds its own `TableViewModel`, which owns its own
//     autosaving session/host, so two windows play two unrelated games with no shared game-state singleton.
//   • The standard macOS menu bar with the exact shortcuts from ux-guidelines (⌘N, ⌘Z / ⇧⌘Z, ⌘,, ⌘?, H,
//     Space/Return, Esc, ⌃⌘F). ⌘, is the standard Settings scene; ⌃⌘F is the standard Enter Full Screen;
//     Space/Return/Esc are table-level keys handled by `TableScreen`. Menu commands act on the FOCUSED
//     window's game via a `focusedSceneValue` (`TableActions`), so a command never reaches another window.
//   • A standard About window augmented with the bundled third-party notices (R-APP-6.3).
//   • The ≤ 3-step, skippable first-run tour shown once over the library (R-APP-7.1).
// Full-screen support and window restoration are standard SwiftUI scene behavior; nothing custom is needed.

import GamesUI  // re-exports GamesRules (+ TableKit/EngineCore): catalog, first-run tour model, Klondike, ...
import Persistence
import SwiftUI
import TableKit

@main
struct ParlorApp: App {
    /// The app's editable local player profile, persisted (interim) in the sandbox UserDefaults
    /// (R-SESS-5.2). One store shared across windows and the Settings scene; each game session is still
    /// independent (R-SESS-6.1) — the profile is just the local identity, not game state.
    @State private var profileStore = LocalProfileStore()

    /// Whether the ≤ 3-step first-run tour has been shown; persisted so it shows once (R-APP-7.1).
    @State private var tourStore = FirstRunTourStore()

    init() {
        UITestLaunch.resetPersistentStateIfRequested()
    }
    var body: some Scene {
        // WindowGroup → multiple windows, each an INDEPENDENT game (R-APP-6.2 / R-SESS-6.1). SwiftUI also
        // gives us window restoration for free (R-APP-6.1); each window restores its own scene.
        WindowGroup {
            RootView(tourStore: tourStore)
                // Minimum window 1024×700; layouts scale up to 6K (R-APP-6.4). No max size.
                .frame(minWidth: 1024, minHeight: 700)
                .debugOverlay([DebugInspectorLine("phase", "platform")])
                .onAppear { AppLog.lifecycle.info("window opened") }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { ParlorCommands() }

        // The standard macOS Settings scene (⌘,) — the shortcut is provided automatically (R-APP-6.1).
        Settings {
            ParlorSettingsView(profileStore: profileStore)
        }
    }
}

/// The window root: the real Library home, the setup sheet, and the table — wired as a NavigationStack
/// (library → `TableScreen`) with setup presented as a sheet, plus the ≤ 3-step first-run tour on first
/// launch (R-APP-1, R-APP-2, R-APP-3, R-APP-7.1).
///
/// Each window gets its own `RootView` and its own `LibraryNavigation` coordinator, so a game launched
/// here owns an independent `AutosaveSession` + `TableViewModel` and is unrelated to other windows
/// (R-APP-6.2 / R-SESS-6.1). The normal launch shows the real Library over the pure `LibraryModel`;
/// tapping a tile opens the real setup sheet over the pure `SetupSheetModel`; confirming DEALS a real
/// session and pushes the table (design.md §10).
struct RootView: View {
    @Bindable var tourStore: FirstRunTourStore

    /// The per-window navigation + deal coordinator (catalog, library state, deal/resume/quit routing).
    @State private var navigation = LibraryNavigation()

    /// Whether to show the first-run tour — computed from the persisted "seen" flag (R-APP-7.1).
    @State private var showTour: Bool

    init(tourStore: FirstRunTourStore) {
        self.tourStore = tourStore
        _navigation = State(
            initialValue: {
                switch UITestLaunch.route {
                case .crazyEights:
                    // The deterministic full-hand test must not share the sandbox save slot with another
                    // test process; it still exercises the real AutosaveSession/host boundary in memory.
                    return LibraryNavigation(saveStore: InMemorySaveStore())
                case .fullKlondike:
                    return LibraryNavigation(debugNearWin: true)
                default:
                    return LibraryNavigation()
                }
            }())
        _showTour = State(
            initialValue: FirstRunTour.shouldPresent(
                seen: tourStore.hasSeenTour, steps: FirstRunTour.bundled.steps))
    }

    var body: some View {
        Group {
            // DEBUG launch-argument hooks for the accessibility UI suite (task 7.4; R-A11Y-5.1, R-A11Y-5.2).
            // They boot straight to a specific REAL screen (skipping the tour) so a test can drive
            // keyboard-only play or run an accessibility audit deterministically. No effect in normal use.
            if let route = UITestLaunch.route {
                uiTestRoot(route)
            } else {
                normalRoot
            }
        }
    }

    /// The normal launch: the real Library in a NavigationStack, the setup sheet, and the pushed table,
    /// with the first-run tour overlaid once (R-APP-1, R-APP-2, R-APP-3, R-APP-7.1).
    private var normalRoot: some View {
        NavigationStack(path: $navigation.path) {
            LibraryView(navigation: navigation)
                .navigationDestination(for: LibraryRoute.self) { route in
                    tableDestination(route)
                }
        }
        .sheet(item: $navigation.presentedSetup) { entry in
            SetupSheetView(
                entry: entry, navigation: navigation,
                onClose: { navigation.presentedSetup = nil })
        }
        .overlay {
            if showTour {
                FirstRunTourView(onFinished: {
                    tourStore.markSeen()
                    showTour = false
                })
            }
        }
    }

    /// The same library → setup → table navigation used by production, with the tour omitted for UI-test
    /// flow routes. It intentionally keeps the real catalog, setup sheet, and destination wiring.
    private var uiTestFlowRoot: some View {
        NavigationStack(path: $navigation.path) {
            LibraryView(navigation: navigation)
                .navigationDestination(for: LibraryRoute.self) { route in
                    tableDestination(route)
                }
        }
        .sheet(item: $navigation.presentedSetup) { entry in
            SetupSheetView(
                entry: entry, navigation: navigation,
                onClose: {
                    navigation.presentedSetup = nil
                })
        }
    }

    @ViewBuilder
    private func tableDestination(_ route: LibraryRoute) -> some View {
        switch route {
        case .table(let gameID) where gameID == CrazyEights.metadata.id:
            if let model = navigation.activeCrazyEights {
                CrazyEightsTableScreen(model: model)
            } else {
                ProgressView("Loading Crazy Eights…")
            }
        case .table:
            if let model = navigation.activeTable {
                TableScreen(model: model)
            } else {
                LibraryView(navigation: navigation)
            }
        }
    }

    /// The DEBUG UI-test root: each route boots straight to its REAL screen (task 7.4). The near-win table
    /// uses the offline `debugState` path (no persisted session, deterministic — R-A11Y-5.1); library and
    /// setup show the real Library / setup sheet the audits run against (R-A11Y-5.2).
    @ViewBuilder
    private func uiTestRoot(_ route: UITestLaunch.Route) -> some View {
        switch route {
        case .klondikeNearWin:
            TableScreen(
                model: .init(
                    debugState: Klondike.nearWinState(),
                    gameTitle: "Klondike",
                    settings: .defaults))
        case .setup:
            // The real setup sheet for Klondike, shown standalone so the audit runs against the actual
            // grouped-controls surface (presets, options, house rules) — not a stand-in.
            SetupSheetView(
                entry: navigation.catalog.entry(id: Klondike.metadata.id)
                    ?? GameCatalog.bundled.entries[0],
                navigation: navigation,
                onClose: {})
        case .library:
            NavigationStack {
                LibraryView(navigation: navigation)
            }
        case .fullKlondike, .resume:
            uiTestFlowRoot
        case .crazyEights:
            CrazyEightsUITestRoot(navigation: navigation)
        case .performanceStress:
            PerformanceStressSceneView()
        }
    }
}

/// The DEBUG launch-argument router for the accessibility UI suite (task 7.4).
///
/// The tests launch the app with one of these arguments to jump directly to the screen under test, keeping
/// each test deterministic and fast (no random deal to solve, no tour to dismiss). Reading a launch
/// argument — not a debug menu — keeps the hook out of the shipping UI while remaining fully driveable by
/// XCUITest. Guarded by `#if DEBUG` so it is compiled out of release builds.
enum UITestLaunch {
    enum Route {
        case klondikeNearWin
        case setup
        case library
        case fullKlondike
        case crazyEights
        case resume
        case performanceStress
    }

    /// The route requested by launch arguments, or `nil` for a normal launch.
    static var route: Route? {
        #if DEBUG
            let args = Set(ProcessInfo.processInfo.arguments)
            if args.contains("-uiTestKlondikeNearWin") { return .klondikeNearWin }
            if args.contains("-uiTestSetup") { return .setup }
            if args.contains("-uiTestLibrary") { return .library }
            if args.contains("-uiTestFullKlondike") { return .fullKlondike }
            if args.contains("-uiTestCrazyEights") { return .crazyEights }
            if args.contains("-uiTestResume") { return .resume }
            if args.contains("-uiTestPerformanceStress") { return .performanceStress }
        #endif
        return nil
    }

    /// Clear only when an explicit DEBUG UI-test launch flag asks for isolation. Production launches never
    /// delete user data from this hook.
    static func resetPersistentStateIfRequested() {
        #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-uiTestResetState") else { return }
            if let store = try? SandboxSaveStore(), let ids = try? store.allSaveIDs() {
                for id in ids { try? store.delete(id) }
            }
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
        #endif
    }
}

/// A deterministic direct Crazy Eights route used by the full-hand UI test. It starts a real autosaving
/// session with the same two-seat table and easy AI as the production setup path.
struct CrazyEightsUITestRoot: View {
    @Bindable var navigation: LibraryNavigation
    @State private var didStart = false

    var body: some View {
        Group {
            if let model = navigation.activeCrazyEights {
                CrazyEightsTableScreen(model: model)
            } else if let message = navigation.unsupportedTableMessage {
                VStack(spacing: 10) {
                    Text("Crazy Eights could not start")
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("crazy.error.title")
                    Text(message)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("crazy.error")
                }
                .padding(32)
            } else {
                ProgressView("Dealing Crazy Eights…")
                    .accessibilityIdentifier("crazy.loading")
            }
        }
        .onAppear {
            guard !didStart, navigation.activeCrazyEights == nil else { return }
            didStart = true
            let coordinator = navigation
            Task { @MainActor in
                guard let entry = coordinator.catalog.visibleEntry(id: CrazyEights.metadata.id)
                else {
                    coordinator.unsupportedTableMessage =
                        "The Crazy Eights catalog entry is unavailable in this debug build."
                    return
                }
                await coordinator.dealCrazyEights(
                    entry,
                    options: CrazyEightsOptions(
                        playerCount: 2,
                        drawMode: .drawOneThenPass,
                        stockOut: .endHand,
                        matchTarget: 50,
                        actionCards: false),
                    seed: 0xCE18_2024)
            }
        }
    }
}

/// The standard macOS menu bar with the exact ux-guidelines shortcuts (R-APP-6.1).
///
/// Menu commands act on the FOCUSED window's game through the `TableActions` published by `TableScreen`
/// via `focusedSceneValue`, so a command reaches only the frontmost window's independent session
/// (R-APP-6.2 / R-SESS-6.1). Where the focused window has no game (e.g. the library), the item is disabled.
/// Standard slots (Settings ⌘,, full screen ⌃⌘F, window restoration) come from SwiftUI/AppKit for free.
struct ParlorCommands: Commands {
    /// The focused window's game actions, or `nil` when no table window is frontmost.
    @FocusedValue(\.tableActions) private var tableActions

    var body: some Commands {
        // File ▸ New Game (⌘N) — opens a new game in the focused window's flow.
        CommandGroup(replacing: .newItem) {
            Button("New Game…") {
                if let tableActions {
                    tableActions.newGame()
                } else {
                    AppLog.ui.info("menu: New Game (from library)")
                }
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        // App menu ▸ About Parlor — standard About panel augmented with third-party notices (R-APP-6.3).
        CommandGroup(replacing: .appInfo) {
            Button("About Parlor") { AboutPanel.show() }
        }

        // Edit ▸ Undo / Redo (⌘Z / ⇧⌘Z) — act on the focused game (R-APP-6.1).
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { tableActions?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(tableActions?.canUndo != true)
            Button("Redo") { tableActions?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(tableActions?.canRedo != true)
        }

        // A Game menu for gameplay actions: Hint (H per ux-guidelines).
        CommandMenu("Game") {
            Button("Hint") { tableActions?.hint() }
                .keyboardShortcut("h", modifiers: [])
                .disabled(tableActions?.hintsEnabled != true)
        }

        // Help ▸ Rules (⌘?) — opens the in-place rules inspector on the focused table (R-APP-3.2).
        // `⌘?` is `⌘` + `/` + shift on a US layout; SwiftUI maps `?` to that chord.
        CommandGroup(replacing: .help) {
            Button("Parlor Rules") { tableActions?.toggleRules() }
                .keyboardShortcut("?", modifiers: .command)
                .disabled(tableActions == nil)
        }
    }
}
