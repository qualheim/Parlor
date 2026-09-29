// SimulationCLI (parlor-sim) — headless simulation harness (pure-adjacent CLI).
//
// Depends on GamesRules + AIKit + EngineCore (design.md §1). Runs AI-vs-AI and random-legal games
// checking invariants (piece conservation, only-legal-actions, bounded length, scoring consistency,
// deterministic replay) — built out in task 8.1. Imports only Foundation + pure packages; no UI.
//
// This scaffold entry point simply reports the wired module graph so `swift build`/`swift run
// parlor-sim` succeed headless.

import Foundation
import EngineCore
import AIKit
import GamesRules

print("parlor-sim — Parlor simulation harness (scaffold)")
print("  wired modules: \(EngineCore.moduleName), \(AIKit.moduleName), \(GamesRules.moduleName)")
print("  invariant runner is implemented in task 8.1.")
