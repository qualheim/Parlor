// GamesUI — per-family game UI (UI layer).
//
// UI-layer package: may import SwiftUI/AppKit. Depends on GamesRules + TableKit (design.md §1). Each
// family's table layout, setup UI, and screen wiring live here. This file establishes the module for
// the scaffold; per-family UI is added alongside each game (design.md §11).

import Foundation
import SwiftUI
import GamesRules
import TableKit

/// Marker describing this module. Real per-family UI lands with each game.
public enum GamesUI {
    public static let moduleName = "GamesUI"
    public static let rulesModuleName = GamesRules.moduleName
    public static let tableModuleName = TableKit.moduleName
}
