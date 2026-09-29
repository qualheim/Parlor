// swift-tools-version: 6.0
//
// Parlor — root Swift package.
//
// Nearly all code lives in local Swift packages (targets) under `Packages/`; the `App/` target is a
// thin macOS shell (R-BUILD-1.2). This single package wires the whole graph so `swift build` and
// `swift test` run headless from a terminal, identically in CI (R-BUILD-1.2).
//
// The `dependencies` of each target below encode the enforced dependency direction from
// `structure.md` / `design.md` §1. Lint (task 1.4) additionally fails on any *import* that crosses
// this direction; keeping the manifest itself minimal is the first line of defense (R-BUILD-1.4).
//
// Dependency direction (A depends on B):
//   App            -> GamesUI, Persistence, DesignSystem   (thin shell; not built by SwiftPM here — see note)
//   GamesUI        -> GamesRules, TableKit
//   TableKit       -> DesignSystem, EngineCore
//   GamesRules     -> AIKit, EngineCore
//   AIKit          -> EngineCore
//   Persistence    -> EngineCore
//   SimulationCLI  -> GamesRules, AIKit, EngineCore
//
// Pure layer (EngineCore, AIKit, GamesRules) imports only the Swift standard library and Foundation
// — no SwiftUI/AppKit/SpriteKit/Combine — so it stays Linux-portable (tech.md rule 1; R-BUILD-4.3).
//
// NOTE ON THE APP TARGET: the SwiftUI `App/` shell is a macOS app bundle target and is defined in
// `project.yml` for XcodeGen (R-BUILD-1.3). SwiftPM cannot produce a signed .app bundle, so the App
// executable is intentionally NOT declared here; the App consumes these packages through the generated
// Xcode project. This keeps `swift build`/`swift test` headless and package-only.

import PackageDescription

// Swift 6 language mode with complete strict-concurrency checking, warnings-as-errors (R-BUILD-5.1,
// R-BUILD-5.2). Applied uniformly to every target.
let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("StrictConcurrency"),
    .unsafeFlags(["-warnings-as-errors"]),
]

let package = Package(
    name: "Parlor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "EngineCore", targets: ["EngineCore"]),
        .library(name: "AIKit", targets: ["AIKit"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "TableKit", targets: ["TableKit"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        // The `Games` product aggregates the per-family rules + UI targets. Later games add targets
        // under Packages/Games/<Family>/{Rules,AI,Layout,...} and extend this product (design.md §11).
        .library(name: "Games", targets: ["GamesRules", "GamesUI"]),
        // parlor-sim: headless AI-vs-AI / random-legal harness (design.md §8; fleshed out in task 8.1).
        .executable(name: "parlor-sim", targets: ["SimulationCLI"]),
    ],
    targets: [
        // MARK: - Pure layer (stdlib + Foundation only) ------------------------------------------

        .target(
            name: "EngineCore",
            path: "Packages/EngineCore/Sources/EngineCore",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: ["EngineCore"],
            path: "Packages/EngineCore/Tests/EngineCoreTests",
            swiftSettings: sharedSwiftSettings
        ),

        .target(
            name: "AIKit",
            dependencies: ["EngineCore"],
            path: "Packages/AIKit/Sources/AIKit",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "AIKitTests",
            dependencies: ["AIKit"],
            path: "Packages/AIKit/Tests/AIKitTests",
            swiftSettings: sharedSwiftSettings
        ),

        // Games/<Family> rules targets are pure. `GamesRules` is the umbrella rules target that later
        // families extend; it depends only on AIKit + EngineCore (design.md §1).
        .target(
            name: "GamesRules",
            dependencies: ["AIKit", "EngineCore"],
            path: "Packages/Games/Sources/GamesRules",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "GamesRulesTests",
            dependencies: ["GamesRules"],
            path: "Packages/Games/Tests/GamesRulesTests",
            swiftSettings: sharedSwiftSettings
        ),

        // MARK: - UI layer (SwiftUI/AppKit interop allowed) --------------------------------------

        .target(
            name: "DesignSystem",
            path: "Packages/DesignSystem/Sources/DesignSystem",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"],
            path: "Packages/DesignSystem/Tests/DesignSystemTests",
            swiftSettings: sharedSwiftSettings
        ),

        .target(
            name: "TableKit",
            dependencies: ["DesignSystem", "EngineCore"],
            path: "Packages/TableKit/Sources/TableKit",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "TableKitTests",
            dependencies: ["TableKit"],
            path: "Packages/TableKit/Tests/TableKitTests",
            swiftSettings: sharedSwiftSettings
        ),

        // Games/<Family>UI targets. `GamesUI` is the umbrella UI target depending on GamesRules +
        // TableKit (design.md §1).
        .target(
            name: "GamesUI",
            dependencies: ["GamesRules", "TableKit"],
            path: "Packages/Games/Sources/GamesUI",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "GamesUITests",
            dependencies: ["GamesUI"],
            path: "Packages/Games/Tests/GamesUITests",
            swiftSettings: sharedSwiftSettings
        ),

        // MARK: - Persistence --------------------------------------------------------------------

        .target(
            name: "Persistence",
            dependencies: ["EngineCore"],
            path: "Packages/Persistence/Sources/Persistence",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
            path: "Packages/Persistence/Tests/PersistenceTests",
            swiftSettings: sharedSwiftSettings
        ),

        // MARK: - Simulation CLI (parlor-sim) ----------------------------------------------------

        .executableTarget(
            name: "SimulationCLI",
            dependencies: ["GamesRules", "AIKit", "EngineCore"],
            path: "Packages/SimulationCLI/Sources/SimulationCLI",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "SimulationCLITests",
            dependencies: ["SimulationCLI"],
            path: "Packages/SimulationCLI/Tests/SimulationCLITests",
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
