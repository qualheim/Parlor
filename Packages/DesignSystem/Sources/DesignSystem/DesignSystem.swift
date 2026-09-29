// DesignSystem — tokens, themes, deck styles, and the sound engine (UI layer).
//
// This is a UI-layer package: it may import SwiftUI/AppKit. It is a leaf of the UI layer with no
// dependency on EngineCore (design.md §1). Tokens, themes/shaders, deck styles, the theme-pack
// loader, and the sound engine are built in Phase 5.
//
// SwiftUI is imported to establish this as a UI-layer module (the pure-layer import lint must NOT
// flag this package). Concrete design tokens land in task 5.1.

import Foundation
import SwiftUI

/// Marker describing this module. Real tokens/themes/sound land in Phase 5.
public enum DesignSystem {
    public static let moduleName = "DesignSystem"
}
