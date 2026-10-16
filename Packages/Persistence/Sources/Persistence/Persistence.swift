// Persistence — versioned save/restore, statistics, and settings storage.
//
// Depends on EngineCore. Stores data locally in the sandbox container only; no cloud (R-PERS-3.1).
// The versioned Codable save format (`SaveDocument`), the testable file-store abstraction (`SaveStore` /
// `SandboxSaveStore` / `InMemorySaveStore` + `SaveCodec`), and autosave/resume (`AutosaveSession`) land in
// task 6.1. The migration REGISTRY + corruption handling land in task 6.2; statistics (per game/variant
// counts, streaks, bests, and chart-series helpers) land in task 6.3 (Statistics.swift,
// StatisticsStore.swift, StatisticsSeries.swift); settings (the full `AppSettings` value + `SettingsStore`
// / `SandboxSettingsStore` / `InMemorySettingsStore` + `SettingsCodec`) land in task 6.4 (Settings.swift).
// This file establishes the module
// marker. Statistics are stored in the sandbox container only (R-PERS-3.1); the App renders the series
// helpers with Swift Charts (R-APP-4.2 — Persistence itself imports no UI framework).
//
// Persistence is not part of the pure layer (it may use Foundation persistence APIs) but it does not
// import UI frameworks.
//
// EngineCore is re-exported (`@_exported`) because Persistence's public surface is expressed in
// EngineCore's boundary types — a save is an action log + state, statistics key off a game's ids, and a
// stored `PlayerProfile` / `AIPersona` (Profiles.swift; R-SESS-5) is an EngineCore value type. The App
// links Persistence (design.md §1) and must edit the local profile (R-SESS-5.2) and list bundled personas
// without importing EngineCore directly (that internal module is not in the App's allowed dependency set).
// Re-exporting surfaces those types through Persistence, keeping the dependency graph legal — the same
// pattern TableKit uses to re-export EngineCore to its UI consumers.

import Foundation

@_exported import EngineCore

/// Marker describing this module. Real save/stats/settings types land in Phase 6.
public enum Persistence {
    public static let moduleName = "Persistence"
    public static let engineModuleName = EngineCore.moduleName
}
