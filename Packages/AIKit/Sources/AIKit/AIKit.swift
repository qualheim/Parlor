// AIKit — pure AI framework (stdlib + Foundation only).
//
// Depends on EngineCore. Strategies receive only a redacted PlayerView, the public log, and legal
// actions — never authoritative state (R-AI-1.1). Imports ONLY the Swift standard library and
// Foundation so it stays Linux-portable (tech.md rule 1; R-BUILD-4.3).
//
// The toolkit is built in task 4.4 and lives in sibling files:
//   • Strategy.swift        — `DecisionContext` + `AIStrategy` (the information barrier, R-AI-1.1);
//   • PublicLog.swift       — the public, redacted history a strategy may read (R-AI-1.1);
//   • DecisionBudget.swift  — `DecisionBudget` / `Deadline` / cancellation (R-AI-3.1, R-AI-3.3);
//   • Determinization.swift — the determinization sampler + inferred voids (R-AI-2.2, R-AI-3.2);
//   • Simulation.swift      — the `GameSimulation` seam games plug their rules into (R-AI-2.2);
//   • MonteCarlo.swift      — Monte Carlo rollouts (R-AI-2.2);
//   • ISMCTS.swift          — Information Set Monte Carlo Tree Search (R-AI-2.2);
//   • Evaluator.swift       — argmax / persona-style bias / RNG tie-break helpers (R-AI-2.2, R-AI-5.1);
//   • Tiers.swift           — `DifficultyTier` → technique + budget (R-AI-2.1, R-AI-3.3);
//   • Pacing.swift          — jittered thinking delay, independent of animation speed (R-AI-4);
//   • Personas.swift        — persona → strategy configuration (R-AI-5.1); and
//   • Hint.swift            — the hint interface reused by coach mode (R-AI-6).

import Foundation
import EngineCore

/// Marker describing this module.
public enum AIKit {
    public static let moduleName = "AIKit"

    /// The engine module this AI layer is built on. Confirms the wired dependency at compile time.
    public static let engineModuleName = EngineCore.moduleName
}
