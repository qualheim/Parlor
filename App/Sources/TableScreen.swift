// TableScreen — the full-bleed table screen: table, quiet toolbar, HUD, pause menu, and in-place rules
// inspector (R-APP-3.1, R-APP-3.2).
//
// NOTE ON BUILD: like all of App/Sources, this file is compiled by the XcodeGen-generated Xcode project,
// NOT by SwiftPM (`swift build`/`make build` do not compile App/Sources; design.md §1). It is written to
// match the real package APIs it wires together:
//   • TableKit: `AnimationDriver` (the live render model + queue), `TableInteractionView` (the generic
//     interactive table), `TableHUDView` (seat plates / scoreboard / caption / history / toolbar),
//     `ToolbarAction`, `PauseMenuAction`, `TableLayout`.
//   • GamesUI: `KlondikeTableAdapter` (Klondike → TableKit interaction seam), `WinCelebrationCoordinator`
//     + `KlondikeWinCelebrationView` (the ≤ 3 s skippable win homage), `RulesDocumentLoader`.
//   • Persistence: `AutosaveSession` (the autosaving session driving the host).
//
// R-APP-3.1: the table screen presents a FULL-BLEED table (the table fills the window, chrome floats over
// it), a QUIET TOOLBAR (unobtrusive New/Undo/Hint/Rules/Menu), the HUD, and a PAUSE MENU. R-APP-3.2: the
// rules open IN PLACE AS AN INSPECTOR (SwiftUI `.inspector`), so the live game state is never lost when
// the player reads the rules — closing the inspector returns to exactly the same table.
//
// KEYBOARD (R-APP-6.1): the screen honors the standard table shortcuts — Space/Return to
// fast-forward/confirm, Esc to close the pause menu / inspector — routed here; the menu-bar shortcuts
// (⌘N, ⌘Z / ⇧⌘Z, ⌘?, H, ⌃⌘F) live in `ParlorCommands` and act on the focused window's game.

import DesignSystem  // EffectiveAccessibility, DeckStyle, CardAppearance
import GamesUI  // re-exports GamesRules (+ TableKit/EngineCore): Klondike, KlondikeTableAdapter, WinCelebration*, Rules*
import Persistence  // AutosaveSession, AppSettings, SaveStore
import SwiftUI
import TableKit

// MARK: - Table screen

/// The full-bleed table screen for one running game (R-APP-3.1).
///
/// Owns the per-window game view-model (`TableViewModel`) — so each window drives an INDEPENDENT game
/// (R-APP-6.2 / R-SESS-6.1); nothing here is shared across windows. The table fills the window edge to
/// edge; the HUD (seat plates, scoreboard, caption, quiet toolbar) floats over it; the pause menu and the
/// rules inspector are presented on top without tearing the table down.
struct TableScreen: View {
    /// The per-window game view-model (host + animation driver + celebration). Independent per window.
    @State private var model: TableViewModel

    /// Whether the rules inspector is open (R-APP-3.2). Presented via `.inspector`, so the table — and the
    /// live host behind it — is never lost while the rules are shown.
    @State private var showRules = false

    /// Whether the pause menu overlay is showing (R-APP-3.1).
    @State private var showPauseMenu = false

    // OS accessibility settings (R-A11Y-4.1). Read from the environment and folded with the app-level
    // overrides via `AppSettings.effectiveAccessibility(...)` into the flags the table subtree consumes.
    @Environment(\.accessibilityReduceMotion) private var osReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var osReduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Create a table screen for an already-started session view-model.
    init(model: TableViewModel) {
        _model = State(initialValue: model)
    }

    /// The effective accessibility flags for this frame: the OS settings folded with the app overrides
    /// (R-A11Y-4.1, R-A11Y-3.1). Recomputed whenever an OS flag or the settings change.
    private var effective: EffectiveAccessibility {
        model.settings.effectiveAccessibility(
            osReduceMotion: osReduceMotion,
            osReduceTransparency: osReduceTransparency,
            osIncreaseContrast: colorSchemeContrast == .increased)
    }

    var body: some View {
        ZStack {
            // FULL-BLEED table: the felt + interactive pieces fill the whole window (R-APP-3.1).
            tableSurface
                .ignoresSafeArea()

            // The HUD floats over the table: seat plates, scoreboard, caption, and the QUIET toolbar
            // (R-APP-3.1). It never covers needed cards (its regions are inset — R-TABLE-6.3).
            TableHUDView(
                plates: model.seatPlates,
                scoreboard: model.scoreboard,
                caption: model.caption,
                history: model.history,
                historyOpen: model.historyOpen,
                enabledToolbarActions: model.enabledToolbarActions,
                onToolbar: handleToolbar,
                onCloseHistory: { model.historyOpen = false }
            )
            .allowsHitTesting(true)

            Text(
                "Theme: \(model.preferredTheme.displayName) · Deck: \(model.preferredDeckStyle.displayName) · Moves: \(model.moveCount)"
            )
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Theme: \(model.preferredTheme.displayName) · Deck: \(model.preferredDeckStyle.displayName) · Moves: \(model.moveCount)"
            )
            .accessibilityIdentifier("table.appearance.status")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(16)
            .allowsHitTesting(false)

            // The ≤ 3 s skippable win celebration overlay (R-KLON-3.9); draws nothing until a win.
            KlondikeWinCelebrationView(coordinator: model.celebration)

            // The pause menu overlay (R-APP-3.1).
            if showPauseMenu {
                pauseMenu.transition(.opacity)
            }
        }
        // In-place rules inspector (R-APP-3.2): opens beside the table without disturbing the game.
        .inspector(isPresented: $showRules) {
            RulesInspectorView(gameID: model.gameID, title: model.gameTitle)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                .toolbar {
                    ToolbarItem {
                        Button {
                            showRules = false
                        } label: {
                            Label("Close Rules", systemImage: "sidebar.trailing")
                        }
                    }
                }
        }
        // Standard table keyboard shortcuts (R-APP-6.1).
        .onKeyPress(.escape) {
            if showPauseMenu { showPauseMenu = false; return .handled }
            if showRules { showRules = false; return .handled }
            return .ignored
        }
        .toolbar { quietToolbar }
        .navigationTitle(model.gameTitle)
        // A stable identifier so the accessibility UI suite can confirm it reached the table (task 7.4).
        .accessibilityIdentifier("table.screen")
        // Expose the actions the menu bar drives on the focused window (R-APP-6.1/6.2).
        .focusedSceneValue(\.tableActions, tableActions)
        // Apply the folded effective accessibility flags to the whole table subtree (R-A11Y-4.1,
        // R-A11Y-3.1):
        //   • deck style   — the Four-Color deck when the override is on, else the user's chosen style
        //     (suit SHAPES are always present regardless — R-A11Y-3.1).
        //   • card face    — the high-contrast variant when contrast is increased (a distinct cached
        //     face — R-TABLE-2.1).
        //   • transparency — translucent HUD/menu materials fall back to opaque fills under Reduce
        //     Transparency.
        .tableDeckStyle(effective.deckStyle(preferred: model.preferredDeckStyle))
        .cardAppearance(effective.cardAppearance)
        .reduceTransparency(effective.reduceTransparency)
        // Reduce Motion folds the OS flag with the app override onto the animation driver (crossfades,
        // no parallax/particles — R-TABLE-5.3). Applied on appear and whenever an OS flag changes.
        .onAppear { model.applyEffectiveAccessibility(effective) }
        .onChange(of: osReduceMotion) { model.applyEffectiveAccessibility(effective) }
    }

    // MARK: - Table surface

    /// The generic interactive table (TableKit), fed Klondike's interaction seam via `KlondikeTableAdapter`
    /// (R-TABLE-1, R-TABLE-3). No per-game rendering code lives here — the game supplies its layout + seam.
    private var tableSurface: some View {
        ZStack {
            TableSurface(theme: model.preferredTheme)
                .ignoresSafeArea()
            TableInteractionView(
                model: model.driver.model,
                layout: model.layout,
                input: model.interactionInput,
                zoneOrder: model.zoneOrder,
                // Honor the S/M/L/XL accessibility card-size setting: the resolver scales every card by the
                // chosen multiplier (R-A11Y-4.1).
                resolver: LayoutResolver(cardSizeScale: model.cardSizeScale),
                seatCount: 1,
                // The driver's current speed/reduce-motion, so a released drag settles over the SAME spring
                // the reconcile animates the move with (R-TABLE-5.1/5.3).
                animationSettings: model.driver.settings,
                faceContent: model.faceContent
            )
        }
    }

    // MARK: - Quiet toolbar (R-APP-3.1)

    /// The quiet window toolbar — unobtrusive New / Undo / Hint / Rules / Menu, mirroring the HUD toolbar
    /// so the actions are reachable from standard chrome too (R-APP-3.1).
    @ToolbarContentBuilder
    private var quietToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.newGame()
            } label: {
                Label("New Game", systemImage: "plus")
            }
            Button {
                model.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            Button {
                model.hint()
            } label: {
                Label("Hint", systemImage: "lightbulb")
            }
            .disabled(!model.hintsEnabled)
            Button {
                showRules.toggle()
            } label: {
                Label("Rules", systemImage: "book")
            }
            Button {
                showPauseMenu = true
            } label: {
                Label("Menu", systemImage: "pause.circle")
            }
            .accessibilityIdentifier("table.menu")
            appearanceMenu
        }
    }

    /// Live theme/deck controls used by the table UI test and by players; values come from the real
    /// DesignSystem registries and apply without restarting the session.
    private var appearanceMenu: some View {
        Menu {
            Section("Theme") {
                ForEach(TableTheme.all) { theme in
                    Button {
                        model.setTheme(theme.id)
                    } label: {
                        Label(
                            theme.displayName,
                            systemImage: model.preferredTheme.id == theme.id ? "checkmark" : "")
                    }
                    .accessibilityIdentifier("table.theme.\(theme.id)")
                }
            }
            Section("Deck") {
                ForEach(DeckStyle.all) { style in
                    Button {
                        model.setDeckStyle(style.id)
                    } label: {
                        Label(
                            style.displayName,
                            systemImage: model.preferredDeckStyle.id == style.id ? "checkmark" : "")
                    }
                    .accessibilityIdentifier("table.deck.\(style.id)")
                }
            }
        } label: {
            Label("Appearance", systemImage: "paintpalette")
        }
        .accessibilityIdentifier("table.appearance")
    }

    // MARK: - Pause menu (R-APP-3.1)

    /// The pause-menu overlay: Resume / Restart deal / New Game / Rules / Settings / Quit to Library.
    private var pauseMenu: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { showPauseMenu = false }
            VStack(spacing: 12) {
                Text("Paused").font(.title2.weight(.semibold))
                Button("Resume") { showPauseMenu = false }
                    .keyboardShortcut(.cancelAction)
                Button("Restart Deal") {
                    model.restart(); showPauseMenu = false
                }
                Button("New Game") {
                    model.newGame(); showPauseMenu = false
                }
                Button("Rules") {
                    showPauseMenu = false; showRules = true
                }
                Divider().frame(width: 200)
                Button("Quit to Library") {
                    model.quitToLibrary(); showPauseMenu = false
                }
                .accessibilityIdentifier("table.quitToLibrary")
            }
            .padding(28)
            .frame(width: 280)
            .background(pauseMenuBackground)
            .shadow(radius: 24, y: 8)
        }
    }

    /// The pause-menu card backdrop: a blurred material normally, an opaque surface fill under Reduce
    /// Transparency so nothing shows through (R-A11Y-4.1).
    @ViewBuilder
    private var pauseMenuBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if effective.reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    // MARK: - Action routing

    /// Route a HUD toolbar tap to the model / inspector / pause menu (R-APP-3.1).
    private func handleToolbar(_ action: ToolbarAction) {
        switch action {
        case .new: model.newGame()
        case .undo: model.undo()
        case .hint: model.hint()
        case .rules: showRules.toggle()
        case .menu: showPauseMenu = true
        }
    }

    /// The bundle of window actions the menu bar drives on the focused window (R-APP-6.1/6.2).
    private var tableActions: TableActions {
        TableActions(
            newGame: model.newGame,
            undo: model.undo,
            redo: model.redo,
            hint: model.hint,
            toggleRules: { showRules.toggle() },
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            hintsEnabled: model.hintsEnabled)
    }
}

// MARK: - Focused-window actions (menu bar → focused window)

/// The set of game actions the menu bar performs on the FOCUSED window's game (R-APP-6.1, R-APP-6.2).
///
/// Published via `focusedSceneValue` so the menu-bar commands act on whichever window is frontmost —
/// each window owns an independent game, so the menu never reaches into another window's session
/// (R-SESS-6.1). Closures + capability flags (so the menu items enable/disable correctly).
struct TableActions {
    var newGame: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var hint: () -> Void
    var toggleRules: () -> Void
    var canUndo: Bool
    var canRedo: Bool
    var hintsEnabled: Bool
}

extension FocusedValues {
    /// The focused window's table actions, or `nil` when no table window is frontmost (e.g. the library).
    var tableActions: TableActions? {
        get { self[TableActionsKey.self] }
        set { self[TableActionsKey.self] = newValue }
    }

    private struct TableActionsKey: FocusedValueKey {
        typealias Value = TableActions
    }
}
