// ThemePack — a resolved theme pack: a `TableTheme` plus its offered deck styles / card backs
// (R-DS-4.1, R-DS-4.2; design.md §7).
//
// A `ThemePackManifest` is the raw on-disk JSON; a `ThemePack` is what you get after `ThemePackDecoder`
// has parsed the hex colors, mapped the material name to `TableMaterial`, and resolved the manifest's
// deck-style / card-back ids to the built-in `DeckStyle` / `CardBack` catalogs. It is the runtime value
// the app hands to the environment (`.tableTheme` / `.deckStyle` / `.cardBack`) to render a table, and it
// is switchable without a restart (R-DS-4.1) — swapping the selected pack in `ThemePackRegistry` just
// changes which of these values is injected.
//
// A pack keeps its `placeholder` flag so Settings and the task-8.5 audit can show "needs production art"
// (R-DS-4.2, R-DS-6). Everything here is a pure, Foundation-only value: no SwiftUI/Metal, verifiable
// headless.

import Foundation

/// A fully resolved theme pack (R-DS-4.1). Built from a `ThemePackManifest` by `ThemePackDecoder`.
public struct ThemePack: Sendable, Hashable, Identifiable, Codable {
    /// Stable pack id; also the `Assets/ThemePacks/<id>/` folder name (design.md §7).
    public let id: String
    /// The name shown in Settings.
    public let displayName: String
    /// The resolved table theme (material + procedural parameters + shadow ink) this pack renders.
    public let tableTheme: TableTheme
    /// The deck styles this pack offers, resolved from the built-in catalog (R-DS-3.1).
    public let deckStyles: [DeckStyle]
    /// The card backs this pack offers, resolved from the built-in catalog (R-DS-3.2).
    public let cardBacks: [CardBack]
    /// Randomized audio-cue variations keyed by cue name (R-DS-5.1); empty when audio is not yet shipped.
    public let audio: [String: [String]]
    /// `true` while any asset in the pack is a placeholder — surfaces "needs production art" (R-DS-4.2).
    public let placeholder: Bool

    public init(
        id: String,
        displayName: String,
        tableTheme: TableTheme,
        deckStyles: [DeckStyle],
        cardBacks: [CardBack],
        audio: [String: [String]] = [:],
        placeholder: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.tableTheme = tableTheme
        self.deckStyles = deckStyles
        self.cardBacks = cardBacks
        self.audio = audio
        self.placeholder = placeholder
    }

    /// The pack's default deck style (its first offered style, falling back to the catalog default).
    public var defaultDeckStyle: DeckStyle { deckStyles.first ?? .default }

    /// The pack's default card back (its first offered back, falling back to the catalog default).
    public var defaultCardBack: CardBack { cardBacks.first ?? .default }
}
