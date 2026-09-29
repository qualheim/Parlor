// AIKit — pure AI framework (stdlib + Foundation only).
//
// Depends on EngineCore. Strategies receive only a redacted PlayerView, the public log, and legal
// actions — never authoritative state (R-AI-1.1). Imports ONLY the Swift standard library and
// Foundation so it stays Linux-portable (tech.md rule 1; R-BUILD-4.3).
//
// The toolkit (determinization sampler, Monte Carlo, ISMCTS, evaluator, personas, hint interface)
// is built in task 4.4. This file establishes the module for the scaffold.

import Foundation
import EngineCore

/// Marker describing this module. Real AI toolkit types land in Phase 4.
public enum AIKit {
    public static let moduleName = "AIKit"

    /// The engine module this AI layer is built on. Confirms the wired dependency at compile time.
    public static let engineModuleName = EngineCore.moduleName
}
