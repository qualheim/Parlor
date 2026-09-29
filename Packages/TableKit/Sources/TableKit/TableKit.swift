// TableKit — generic table renderer, input, and animation (UI layer).
//
// UI-layer package: may import SwiftUI/AppKit/SpriteKit. Depends on DesignSystem + EngineCore.
// TableKit consumes EngineCore *views and events only*, never authoritative state (structure.md;
// R-SESS-1.2). The generic renderer, input paths, and animation queue are built in Phase 3 and
// polished in Phase 5.
//
// SwiftUI is imported to establish this as a UI-layer module. Concrete renderer types land in
// task 3.3.
//
// EngineCore is re-exported (`@_exported`) because TableKit's entire public surface is expressed in
// EngineCore types — `ZoneID`, `PieceID`, `RenderKey`, `ViewToken`, `PlayerView`, `GameEvent`,
// `MoveTarget`/`TableMove`, `RuleViolation`. A UI consumer of TableKit (GamesUI) therefore inherently
// needs those types to name a zone, a piece, or a move target; re-exporting them keeps the dependency
// direction clean (GamesUI imports only GamesRules + TableKit, never EngineCore directly) while still
// giving the UI layer the vocabulary TableKit's API is written in. This is an allowed edge
// (TableKit → EngineCore); it changes no behavior.

import DesignSystem
import Foundation
import SwiftUI

@_exported import EngineCore

/// Marker describing this module. Real renderer/input/animation types land in Phases 3 & 5.
public enum TableKit {
    public static let moduleName = "TableKit"
    public static let engineModuleName = EngineCore.moduleName
    public static let designModuleName = DesignSystem.moduleName
}
