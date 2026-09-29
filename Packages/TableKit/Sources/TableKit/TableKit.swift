// TableKit — generic table renderer, input, and animation (UI layer).
//
// UI-layer package: may import SwiftUI/AppKit/SpriteKit. Depends on DesignSystem + EngineCore.
// TableKit consumes EngineCore *views and events only*, never authoritative state (structure.md;
// R-SESS-1.2). The generic renderer, input paths, and animation queue are built in Phase 3 and
// polished in Phase 5.
//
// SwiftUI is imported to establish this as a UI-layer module. Concrete renderer types land in
// task 3.3.

import Foundation
import SwiftUI
import EngineCore
import DesignSystem

/// Marker describing this module. Real renderer/input/animation types land in Phases 3 & 5.
public enum TableKit {
    public static let moduleName = "TableKit"
    public static let engineModuleName = EngineCore.moduleName
    public static let designModuleName = DesignSystem.moduleName
}
