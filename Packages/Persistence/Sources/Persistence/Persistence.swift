// Persistence — versioned save/restore, statistics, and settings storage.
//
// Depends on EngineCore. Stores data locally in the sandbox container only; no cloud (R-PERS-3.1).
// The versioned save format, migration registry, autosave/resume, statistics, and settings are built
// in Phase 6. This file establishes the module for the scaffold.
//
// Persistence is not part of the pure layer (it may use Foundation persistence APIs) but it does not
// import UI frameworks.

import Foundation
import EngineCore

/// Marker describing this module. Real save/stats/settings types land in Phase 6.
public enum Persistence {
    public static let moduleName = "Persistence"
    public static let engineModuleName = EngineCore.moduleName
}
