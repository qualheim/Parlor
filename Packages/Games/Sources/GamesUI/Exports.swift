// GamesUI re-exports — the app-facing umbrella surface (design.md §1, §11).
//
// The App target depends on the `Games` product, which aggregates the two library targets `GamesRules`
// (pure rules) + `GamesUI` (UI). There is no separate `Games` *module*, so App code cannot `import Games`;
// it imports `GamesUI`, and GamesUI must re-export the symbols the app shell needs from the layers below.
//
// GamesUI already depends on GamesRules + TableKit. Re-exporting both here means `import GamesUI` gives the
// App a single umbrella surface that reaches:
//   • GamesUI's own UI seams — KlondikeTableAdapter, WinCelebrationCoordinator, KlondikeWinCelebrationView,
//     RulesDocument(Loader)/RulesLoadError, BundleRulesDocumentSource, FirstRunTour, TourStep.
//   • GamesRules rules types — Klondike, KlondikeState, KlondikeAction, GameCatalog, LibraryModel,
//     SetupSheetModel, CrazyEights, …
//   • EngineCore boundary types — RuleViolation, GameEvent, PlayerView, ActionEnvelope, AnyGameAction,
//     ZoneID, RenderKey, … — reached transitively because TableKit already `@_exported import EngineCore`.
//     (Re-exporting TableKit here re-exports that EngineCore surface too.)
//
// This matches the documented intent that "Games re-exports GamesUI + GamesRules": from the App's point of
// view, `import GamesUI` is that umbrella. This is the smallest change consistent with the package graph —
// no target/product restructuring.

@_exported import GamesRules
@_exported import TableKit
