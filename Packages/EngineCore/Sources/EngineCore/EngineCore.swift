// EngineCore — pure game engine (stdlib + Foundation only).
//
// This is the base of the pure layer: it defines pieces, decks, zones, RNG, the GameDefinition
// protocol, events, views/redaction, the action log, and the match model. It imports ONLY the Swift
// standard library and Foundation so it stays Linux-portable for a future server (tech.md rule 1;
// R-BUILD-4.3). No SwiftUI / AppKit / SpriteKit / Combine.
//
// The concrete types (Card, Tile, Zone, SeededRNG, GameDefinition, GameHost, …) are added in Phase 2
// (tasks 2.1–2.8). This file establishes the module and its import discipline for the scaffold.

import Foundation

/// Marker describing this module. Real engine types land in Phase 2.
public enum EngineCore {
    /// Human-readable module name, useful in logs and diagnostics.
    public static let moduleName = "EngineCore"
}
