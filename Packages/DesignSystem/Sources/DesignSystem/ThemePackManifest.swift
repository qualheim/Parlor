// ThemePackManifest — the on-disk JSON shape of a theme pack (R-DS-4.1, R-DS-4.2; design.md §7).
//
// A theme pack is a folder under `Assets/ThemePacks/<id>/` holding a `theme.json` manifest plus vector
// assets and audio, loaded at runtime and switchable without a restart (R-DS-4.1). This file is the
// *wire model*: a Foundation-only, `Codable` mirror of the JSON exactly as it sits on disk (see
// `Assets/ThemePacks/*/theme.json`). Keeping the manifest a plain value with no SwiftUI/Metal import
// means the whole decode → validate → resolve pipeline runs headless in `swift test`.
//
// The manifest is deliberately close to the raw JSON (hex color strings, string material/shader names,
// string deck/back ids). `ThemePackDecoder` is what turns this wire model into the resolved DesignSystem
// values (`TableTheme` / `DeckStyle` / `CardBack`), validating along the way and failing with a typed,
// human-readable error instead of crashing on malformed input (R-DS-4.1). Because the manifest maps
// asset references by *path/id*, commissioned production art can replace a placeholder pack's files with
// NO code change — only the `placeholder` flag flips to `false` (R-DS-4.2).

import Foundation

/// The current theme-pack manifest schema version this loader understands (design.md §7).
public let themePackSchemaVersion = 1

/// The raw, on-disk manifest for one theme pack — a `Codable` mirror of `theme.json` (design.md §7).
///
/// This is the *wire* type; use `ThemePackDecoder` to resolve it into a `ThemePack` of DesignSystem
/// values with validation. Fields mirror the JSON keys exactly.
public struct ThemePackManifest: Sendable, Hashable, Codable {
    /// Manifest schema version; must equal `themePackSchemaVersion` to decode (design.md §7).
    public let schemaVersion: Int
    /// Stable pack id; also the `Assets/ThemePacks/<id>/` folder name (design.md §7).
    public let id: String
    /// The name shown in Settings.
    public let displayName: String
    /// The table-surface material/shader parameters.
    public let table: Table
    /// The deck styles and card backs this pack offers.
    public let decks: Decks
    /// Where the pack's assets live and in what form (procedural shader source, or vector art).
    public let assets: Assets
    /// Optional randomized audio-cue variations, keyed by cue name (R-DS-5.1). Absent in packs whose
    /// audio is still "needs production art".
    public let audio: [String: [String]]?
    /// `true` while any asset in the pack is a placeholder — surfaces "needs production art" in Settings
    /// and the task-8.5 audit (R-DS-4.2, R-DS-6).
    public let placeholder: Bool

    public init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        table: Table,
        decks: Decks,
        assets: Assets,
        audio: [String: [String]]? = nil,
        placeholder: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.table = table
        self.decks = decks
        self.assets = assets
        self.audio = audio
        self.placeholder = placeholder
    }

    /// The `table` block: material family + procedural parameters, with colors as hex strings.
    public struct Table: Sendable, Hashable, Codable {
        /// The material family name (`felt` / `wood` / `matte`) — maps to `TableMaterial`.
        public let material: String
        /// The stitchable shader function name (informational; the material picks the function).
        public let shader: String?
        /// The dominant surface color, as `#RRGGBB`.
        public let base: String
        /// The accent color the shader blends toward, as `#RRGGBB`.
        public let accent: String
        /// Fiber/grain frequency (> 0 after validation).
        public let grainScale: Double
        /// Fiber/grain contrast, 0...1.
        public let grainStrength: Double
        /// Directional sheen strength, 0...1.
        public let sheenStrength: Double
        /// Vignette depth, 0...1.
        public let vignette: Double
        /// The shadow-tint ink for this surface, as `#RRGGBB`.
        public let shadowInk: String

        public init(
            material: String,
            shader: String? = nil,
            base: String,
            accent: String,
            grainScale: Double,
            grainStrength: Double,
            sheenStrength: Double,
            vignette: Double,
            shadowInk: String
        ) {
            self.material = material
            self.shader = shader
            self.base = base
            self.accent = accent
            self.grainScale = grainScale
            self.grainStrength = grainStrength
            self.sheenStrength = sheenStrength
            self.vignette = vignette
            self.shadowInk = shadowInk
        }
    }

    /// The `decks` block: the deck-style ids and card-back ids this pack offers.
    public struct Decks: Sendable, Hashable, Codable {
        /// Deck-style ids (map to `DeckStyle`), e.g. `classic`, `four-color` (R-DS-3.1).
        public let styles: [String]
        /// Card-back ids (map to `CardBack`), e.g. `lattice`, `crest`; at least six (R-DS-3.2).
        public let backs: [String]

        public init(styles: [String], backs: [String]) {
            self.styles = styles
            self.backs = backs
        }
    }

    /// The `assets` block: how the pack's art is delivered (procedural shader source, or vector files).
    public struct Assets: Sendable, Hashable, Codable {
        /// Delivery kind: `procedural` (shader source) or `vector` (vector art files).
        public let kind: String
        /// For `procedural` packs: the `.metal` shader source path, relative to the pack folder.
        public let shaderSource: String?
        /// For `vector` packs: the vector-asset directory, relative to the pack folder.
        public let path: String?

        public init(kind: String, shaderSource: String? = nil, path: String? = nil) {
            self.kind = kind
            self.shaderSource = shaderSource
            self.path = path
        }
    }
}
