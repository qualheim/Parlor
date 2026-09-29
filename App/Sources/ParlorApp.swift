// App — thin macOS SwiftUI shell.
//
// Nearly all logic lives in the local Swift packages; this target is intentionally a thin shell
// (R-BUILD-1.2). It depends on Games, Persistence, and DesignSystem (design.md §1) and is built via
// the XcodeGen-generated Xcode project (project.yml; R-BUILD-1.3), never by SwiftPM.
//
// Task 1.5 delivers the empty window (min 1024×700; R-APP-6.4), a standard macOS menu-bar skeleton
// built from SwiftUI commands, `os.Logger` categories (AppLog; R-NFR-QUAL.4), and the debug-only
// FPS / state-inspector overlay hook (DebugOverlay; R-NFR-QUAL.4). Real screens (library, table,
// settings) land in later phases; the chrome stays standard so the app inherits the current macOS
// design language automatically (design.md §10; R-APP-6.4).

import SwiftUI

@main
struct ParlorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Minimum window 1024×700; layouts scale up to 6K (R-APP-6.4). No max size so the
                // window grows freely on large displays.
                .frame(minWidth: 1024, minHeight: 700)
                // Debug builds show the FPS / state-inspector overlay; release builds compile it out
                // (R-NFR-QUAL.4). Foundation-stage snapshot lists the app phase; later phases feed it
                // live table/host state.
                .debugOverlay([DebugInspectorLine("phase", "foundation")])
                .onAppear { AppLog.lifecycle.info("main window opened") }
        }
        // Sensible default size on first launch; the frame minimum still governs how small it can go.
        .defaultSize(width: 1280, height: 800)
        .commands { ParlorCommands() }
    }
}

/// Empty-window placeholder content for the foundation stage.
///
/// The real library / table screens arrive in later phases; this keeps the window non-empty and
/// self-describing without pulling in any game code yet.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "suit.club.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Parlor")
                .font(.largeTitle.weight(.semibold))
            Text("Foundation build — the library and table arrive in later phases.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Standard macOS menu-bar skeleton built from SwiftUI `Commands` (design.md §10; R-APP-6.4).
///
/// Only the structure exists at the foundation stage: the standard app/File/Edit/View/Window/Help
/// menus are present, with a few Parlor-specific items wired to log placeholders. Real actions (New
/// Game, Undo, Hint, Rules) are connected as their features land in later phases. Using SwiftUI
/// commands means the app inherits the platform menu behavior, keyboard shortcuts, and accessibility.
struct ParlorCommands: Commands {
    var body: some Commands {
        // File ▸ New Game — the primary entry point for later phases.
        CommandGroup(replacing: .newItem) {
            Button("New Game…") {
                AppLog.ui.info("menu command: New Game (not yet wired)")
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        // A dedicated Game menu skeleton for gameplay actions filled in by later phases.
        CommandMenu("Game") {
            Button("Undo") { AppLog.ui.info("menu command: Undo (not yet wired)") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(true)
            Button("Redo") { AppLog.ui.info("menu command: Redo (not yet wired)") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(true)
            Divider()
            Button("Hint") { AppLog.ui.info("menu command: Hint (not yet wired)") }
                .keyboardShortcut("h", modifiers: .command)
                .disabled(true)
        }

        // Help ▸ Parlor Help — the standard Help slot; the rules inspector lands in Phase 6.
        CommandGroup(replacing: .help) {
            Button("Parlor Help") {
                AppLog.ui.info("menu command: Help (not yet wired)")
            }
        }
    }
}
