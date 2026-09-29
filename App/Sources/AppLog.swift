// AppLog — structured logging categories for the Parlor app shell (R-NFR-QUAL.4).
//
// All logging goes through `os.Logger` with a shared subsystem and named categories so Console.app
// and `log stream`/`log show` can filter by area (tech.md; R-NFR-QUAL.4). The App target is the only
// place that owns UI-shell logging; packages define their own loggers close to their code. Keeping the
// subsystem tied to the bundle identifier means log records are attributed to Parlor without leaking
// anything private (Parlor is fully offline — nothing is transmitted).
//
// Usage:
//     AppLog.lifecycle.info("window opened")
//     AppLog.ui.debug("menu command: New Game")

import OSLog

/// Namespaces the app shell's `os.Logger` instances by category (R-NFR-QUAL.4).
///
/// Each property is a `Logger` scoped to one area of the shell. Categories are intentionally coarse at
/// the foundation stage; later phases add their own loggers in their own modules rather than widening
/// this list.
enum AppLog {
    /// Reverse-DNS subsystem shared by every category. Matches the app bundle identifier so log
    /// tooling attributes records to Parlor.
    static let subsystem = "com.parlor.Parlor"

    /// App/window lifecycle: launch, window open/close, scene phase changes.
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    /// User-facing chrome: menu commands, toolbar actions, navigation.
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Debug-only diagnostics such as the FPS / state-inspector overlay. Emitted only from debug
    /// builds; see `DebugOverlay`.
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
