// DesignSystem — tokens, themes, deck styles, and the sound engine (UI layer).
//
// This is a UI-layer package: it may import SwiftUI/AppKit. It is a leaf of the UI layer with no
// dependency on EngineCore (design.md §1). Tokens, themes/shaders, deck styles, the theme-pack
// loader, and the sound engine are built in Phase 5.
//
// SwiftUI is imported to establish this as a UI-layer module (the pure-layer import lint must NOT
// flag this package). Design tokens (color/type/spacing/radius/shadow/motion) land in task 5.1
// (`DesignTokens`, `SemanticColors`, `Tokens`); themes/shaders, deck styles, the theme-pack loader,
// and the sound engine follow in tasks 5.2–5.7.

import Foundation
import SwiftUI

/// Marker describing this module. Tokens land in task 5.1; themes/decks/sound follow in Phase 5.
public enum DesignSystem {
    public static let moduleName = "DesignSystem"

    /// The default (light) design-token set. The app injects the chosen palette into the environment;
    /// this is the convenient default entry point (R-DS-1.1).
    public static let defaultTokens: DesignTokens = .light

    /// The built-in procedural table themes (≥ 4: Classic Felt, Midnight, Walnut Parlor, Minimal), each
    /// rendered from Metal shaders/materials and independent of the system appearance (R-DS-2.1,
    /// R-DS-2.2). The app injects the chosen theme via `.tableTheme(_:)`.
    public static let tableThemes: [TableTheme] = TableTheme.all

    /// The default table theme (Classic Felt).
    public static let defaultTableTheme: TableTheme = .default

    /// The built-in deck-face styles: Classic, Modern, Four-Color, and Jumbo Index (R-DS-3.1). The app
    /// injects the chosen style; TableKit renders cached vector faces from it (R-TABLE-2.1).
    public static let deckStyles: [DeckStyle] = DeckStyle.all

    /// The default deck style (Classic).
    public static let defaultDeckStyle: DeckStyle = .default

    /// The built-in card backs (≥ 6 — R-DS-3.2). The app injects the chosen back for face-down cards.
    public static let cardBacks: [CardBack] = CardBack.all

    /// The default card back (Lattice).
    public static let defaultCardBack: CardBack = .default

    /// The original placeholder court-card designs (Jack/Queen/King), each flagged "needs production art"
    /// (R-DS-3.3, R-DS-6). Audited in task 8.5.
    public static let courtCardPlaceholders: [CourtCardArt] = CourtCardArt.placeholders

    /// The semantic sound cues the event-driven sound engine plays (shuffle/deal/flip/place/chips/win).
    /// TableKit maps the shared `GameEvent` stream onto these; the engine picks a no-repeat variation per
    /// cue and resolves volume/mute (R-DS-5.1). Shipped audio is original/CC0/synthesized, recorded in
    /// `THIRD_PARTY_NOTICES.md` and flagged "needs production art" (🎨 R-DS-5.2, tasks 5.4/5.7).
    public static let soundCues: [SoundCue] = SoundCue.allCases

    /// The built-in theme packs synthesized from the catalog, used as a runtime fallback when no
    /// `Assets/ThemePacks/*/theme.json` manifests load (R-DS-4.1). Every entry is a placeholder pack
    /// flagged "needs production art" (R-DS-4.2, R-DS-6).
    public static let builtInThemePacks: [ThemePack] = ThemePackRegistry.builtIn

    /// Load the theme packs under `directory` (each `<id>/theme.json`) into a runtime-switchable
    /// registry, skipping and reporting any malformed pack (R-DS-4.1). Falls back to `builtInThemePacks`
    /// if none load.
    public static func loadThemePacks(from directory: URL, selectedID: String? = nil)
        -> ThemePackRegistry.LoadReport
    {
        ThemePackRegistry.loadingDirectory(directory, selectedID: selectedID)
    }
}
