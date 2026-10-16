// CardBack — the card-back catalog: at least six procedural backs (R-DS-3.2).
//
// A `CardBack` is a *pure value* describing a face-down card's design as a procedural motif plus two ink
// colors, mirroring the theme/deck model (no bitmaps, verifiable headless). The catalog ships the six
// backs named in every theme-pack manifest's `decks.backs` list (design.md §7): lattice, art-deco, linen,
// checker, wave, and crest. The concrete vector drawing of each motif lives in the UI layer (TableKit);
// this file only names the motif and its palette so the catalog and its "≥ 6" guarantee are testable
// without importing SwiftUI.

import Foundation

/// The procedural motif a card back is drawn with. Each case is rendered by a small vector routine in the
/// UI layer; the value here just names which motif and lets the "≥ 6 backs" catalog be verified headless.
public enum CardBackMotif: String, Sendable, Hashable, CaseIterable, Codable {
    /// A diagonal criss-cross lattice.
    case lattice
    /// An angular art-deco fan/sunburst.
    case artDeco
    /// A fine woven-linen cross-hatch.
    case linen
    /// A two-tone checkerboard.
    case checker
    /// Concentric/undulating waves.
    case wave
    /// A centered ornamental crest medallion.
    case crest
}

/// A card-back design: a procedural `motif` drawn in `ink` over a `field` color, framed by a thin border
/// inset (R-DS-3.2). Pure and appearance-independent, matching `DeckStyle` / `TableTheme`.
public struct CardBack: Sendable, Hashable, Identifiable, Codable {
    /// Stable identifier (kebab-case); also the key used in a theme pack's `decks.backs` list
    /// (design.md §7).
    public let id: String
    /// The name shown in Settings.
    public let displayName: String
    /// The procedural motif drawn on the back.
    public let motif: CardBackMotif
    /// The background field color the motif is drawn over.
    public let field: TokenColor
    /// The ink the motif is drawn with.
    public let ink: TokenColor

    public init(
        id: String,
        displayName: String,
        motif: CardBackMotif,
        field: TokenColor,
        ink: TokenColor
    ) {
        self.id = id
        self.displayName = displayName
        self.motif = motif
        self.field = field
        self.ink = ink
    }
}

// MARK: - Built-in backs (≥ 6 — R-DS-3.2)

extension CardBack {
    /// Lattice — a classic blue back with a diagonal criss-cross lattice.
    public static let lattice = CardBack(
        id: "lattice",
        displayName: "Lattice",
        motif: .lattice,
        field: TokenColor(hex: 0x274690),  // royal blue field
        ink: TokenColor(hex: 0xBFD0F5)  // light lattice lines
    )

    /// Art Deco — a deep red back with an angular deco fan.
    public static let artDeco = CardBack(
        id: "art-deco",
        displayName: "Art Deco",
        motif: .artDeco,
        field: TokenColor(hex: 0x7B1E1E),  // deco crimson
        ink: TokenColor(hex: 0xE8C86A)  // brass/gold lines
    )

    /// Linen — a muted taupe back with a fine woven cross-hatch.
    public static let linen = CardBack(
        id: "linen",
        displayName: "Linen",
        motif: .linen,
        field: TokenColor(hex: 0x6E6552),  // taupe field
        ink: TokenColor(hex: 0xD8D0BC)  // pale thread
    )

    /// Checker — a green two-tone checkerboard.
    public static let checker = CardBack(
        id: "checker",
        displayName: "Checker",
        motif: .checker,
        field: TokenColor(hex: 0x1F6E43),  // green field
        ink: TokenColor(hex: 0x0E3F26)  // darker check
    )

    /// Wave — a teal back with undulating concentric waves.
    public static let wave = CardBack(
        id: "wave",
        displayName: "Wave",
        motif: .wave,
        field: TokenColor(hex: 0x11565E),  // teal field
        ink: TokenColor(hex: 0x8FE3E0)  // aqua waves
    )

    /// Crest — a slate back with a centered ornamental medallion.
    public static let crest = CardBack(
        id: "crest",
        displayName: "Crest",
        motif: .crest,
        field: TokenColor(hex: 0x2E3440),  // slate field
        ink: TokenColor(hex: 0xC9B37E)  // gold crest
    )

    /// The built-in card backs, in presentation order. At least six ship (R-DS-3.2), matching the
    /// `decks.backs` list in the theme-pack manifests (design.md §7).
    public static let all: [CardBack] = [lattice, artDeco, linen, checker, wave, crest]

    /// Look up a built-in card back by its `id`, or `nil` if none matches.
    public static func back(id: String) -> CardBack? {
        all.first { $0.id == id }
    }

    /// The default card back (Lattice).
    public static let `default`: CardBack = .lattice
}
