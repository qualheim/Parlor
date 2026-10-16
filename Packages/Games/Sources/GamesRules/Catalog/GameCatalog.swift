// The game catalog — a pure, feature-flagged registry of the games the Library can show (R-APP-1.2).
//
// This is game-agnostic Library infrastructure kept in the pure layer (GamesRules: stdlib + Foundation
// only, R-BUILD-4.3) so it is unit-testable headless. The App imports it through the `Games` product and
// renders thin SwiftUI tiles on top; the *logic* — what games exist, which are visible, their metadata,
// their placeholder tile art — lives here as plain values (design.md §10; R-APP-1.2).
//
// FEATURE FLAGS (R-APP-1.2). Every game on the roadmap can register a `CatalogEntry`, but a game that is
// not yet built registers with `enabled: false` — and `GameCatalog.visibleEntries` returns ONLY enabled
// entries, so unbuilt games never appear in the Library (R-APP-1.2; product.md roadmap). Two games are
// built today (Klondike, Crazy Eights); both register enabled. A future game (e.g. Euchre) registers
// disabled until its rules/AI/layout land, then flips its flag — no other code changes (design.md §11
// step 6). `GameCatalog.bundled` shows exactly this pattern, including one disabled "coming soon" entry
// to prove the mechanism.
//
// TILE ART (R-APP-1.3, R-DS-6.1). Each entry carries a `TileArt` reference — a UI-free descriptor the App
// resolves to artwork. Today every entry uses a generated PLACEHOLDER flagged "needs production art"
// (R-DS-6.1; the Placeholder-art register in tasks.md tracks it). The App draws the placeholder and, on
// hover, applies subtle parallax that it DISABLES under Reduce Motion (R-APP-1.3) — parallax is a
// rendering concern the App owns; the pure catalog only carries the art reference and the
// `prefersParallax` hint so the resolver knows the intent.

import EngineCore
import Foundation

// MARK: - Tile art reference (R-APP-1.3, R-DS-6.1)

/// A UI-free reference to a game tile's artwork (R-APP-1.3), resolved to pixels by the App.
///
/// GamesRules has no UI framework (R-BUILD-4.3), so tile art is modeled as *data the App resolves*, not a
/// rendered image — the same pattern as `AvatarReference` (EngineCore Profiles.swift). Today the only form
/// is a generated placeholder flagged for replacement (R-DS-6.1); commissioned art later swaps the App's
/// resolver with no catalog change (R-DS-4.2).
public enum TileArt: Hashable, Codable, Sendable {
    /// A procedurally drawn placeholder tile: an SF Symbol `symbol` over a `tint` hex gradient, flagged
    /// "needs production art" (🎨 R-DS-6.1). The App draws it and applies hover parallax (disabled under
    /// Reduce Motion, R-APP-1.3).
    case generatedPlaceholder(symbol: String, tint: String)

    /// Whether this art *needs production art* — true for every placeholder, so an audit (task 8.5) can
    /// enumerate what still must be commissioned (R-DS-6.1).
    public var needsProductionArt: Bool {
        switch self {
        case .generatedPlaceholder: return true
        }
    }
}

// MARK: - Catalog entry (R-APP-1.2, R-APP-1.3)

/// One game's registration in the catalog: its metadata, a feature flag, and its tile art (R-APP-1.2).
///
/// The `metadata` comes straight from the game's `GameDefinition.metadata` (id, name, family, seat range,
/// duration, complexity) so the Library reads it without instantiating the game. `enabled` is the feature
/// flag: a game not yet built registers `false` and never appears (R-APP-1.2). `tileArt` is the (currently
/// placeholder) artwork the App renders with hover parallax (R-APP-1.3, R-DS-6.1). Pure `Codable & Sendable`
/// data so a catalog can be snapshotted or cached.
public struct CatalogEntry: Hashable, Codable, Sendable, Identifiable {
    /// The game's descriptive metadata (from `GameDefinition.metadata`).
    public let metadata: GameMetadata
    /// The feature flag: `true` when the game is built and should appear in the Library (R-APP-1.2).
    public let enabled: Bool
    /// The tile artwork reference the App resolves and renders (R-APP-1.3, R-DS-6.1).
    public let tileArt: TileArt
    /// Whether the App should apply subtle hover parallax to this tile (R-APP-1.3). The App still
    /// DISABLES parallax under Reduce Motion regardless of this hint — that is an App/OS concern.
    public let prefersParallax: Bool

    /// The stable game id, so `CatalogEntry` is `Identifiable` by the same id used everywhere (save
    /// slots, rules docs, statistics).
    public var id: String { metadata.id }

    public init(
        metadata: GameMetadata,
        enabled: Bool,
        tileArt: TileArt,
        prefersParallax: Bool = true
    ) {
        self.metadata = metadata
        self.enabled = enabled
        self.tileArt = tileArt
        self.prefersParallax = prefersParallax
    }
}

// MARK: - GameCatalog (R-APP-1.2)

/// The feature-flagged catalog of games the Library can present (R-APP-1.2).
///
/// A pure value over a list of `CatalogEntry`. Its whole job is the R-APP-1.2 guarantee: `visibleEntries`
/// returns only the *enabled* entries, so a registered-but-unbuilt game never surfaces in the Library. The
/// bundled catalog registers the two built games enabled plus one disabled "coming soon" entry to prove
/// the flag mechanism (design.md §11 step 6).
public struct GameCatalog: Sendable {
    /// Every registered entry, enabled or not, in registration order.
    public let entries: [CatalogEntry]

    public init(entries: [CatalogEntry]) {
        self.entries = entries
    }

    /// The entries the Library shows — ONLY the enabled ones (R-APP-1.2). Unbuilt games registered with
    /// `enabled: false` are filtered out here, which is the single point that enforces "games not yet
    /// built do not appear".
    public var visibleEntries: [CatalogEntry] {
        entries.filter(\.enabled)
    }

    /// Look up any entry (enabled or not) by its stable game id.
    public func entry(id: String) -> CatalogEntry? {
        entries.first { $0.metadata.id == id }
    }

    /// Look up a *visible* (enabled) entry by id, or `nil` if it is unknown or disabled — so a caller
    /// (e.g. a deep link) can never open the setup sheet for an unbuilt game (R-APP-1.2).
    public func visibleEntry(id: String) -> CatalogEntry? {
        entry(id: id).flatMap { $0.enabled ? $0 : nil }
    }
}

// MARK: - Bundled catalog (the games this build knows about)

extension GameCatalog {
    /// The catalog this build ships (R-APP-1.2).
    ///
    /// The two built games register ENABLED with placeholder tile art; one representative future game
    /// registers DISABLED to demonstrate that an unbuilt game can be listed in source yet stay hidden
    /// until its flag flips (R-APP-1.2; design.md §11 step 6). All tile art is a generated placeholder
    /// flagged "needs production art" (🎨 R-DS-6.1; tracked in the tasks.md Placeholder-art register).
    public static let bundled = GameCatalog(entries: [
        CatalogEntry(
            metadata: Klondike.metadata,
            enabled: true,
            tileArt: .generatedPlaceholder(symbol: "square.stack.3d.up.fill", tint: "#2F9E44")),
        CatalogEntry(
            metadata: CrazyEights.metadata,
            enabled: true,
            tileArt: .generatedPlaceholder(symbol: "8.circle.fill", tint: "#1971C2")),
        // A representative not-yet-built game: listed in source behind a feature flag, hidden from the
        // Library until its rules/AI/layout land and this flag flips to `true` (R-APP-1.2). It is NOT a
        // playable game — only a catalog placeholder proving the flag mechanism.
        CatalogEntry(
            metadata: GameMetadata(
                id: "euchre",
                name: "Euchre",
                family: .trickTaking,
                seatRange: 4...4,
                typicalDuration: DurationRange(minMinutes: 15, maxMinutes: 30),
                complexity: .medium),
            enabled: false,
            tileArt: .generatedPlaceholder(symbol: "suit.spade.fill", tint: "#5F3DC4")),
    ])
}
