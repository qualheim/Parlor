// GamesRules — per-family game rules (pure; stdlib + Foundation only).
//
// This umbrella target holds each family's `GameDefinition` conformance and rules logic. Depends on
// AIKit + EngineCore only (design.md §1). Imports ONLY the Swift standard library and Foundation so
// it stays Linux-portable (tech.md rule 1; R-BUILD-4.3).
//
// Klondike (task 3.1) and Crazy Eights (task 4.5) rules are added here following the fixed folder
// shape described in design.md §11. This file establishes the module for the scaffold.

import Foundation
import EngineCore
import AIKit

/// Marker describing this module. Real game definitions land in Phases 3–4.
public enum GamesRules {
    public static let moduleName = "GamesRules"
    public static let engineModuleName = EngineCore.moduleName
    public static let aiModuleName = AIKit.moduleName
}
