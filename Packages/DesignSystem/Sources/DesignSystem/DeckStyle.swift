// DeckStyle — the deck-face style catalog: Classic, Modern, Four-Color, Jumbo Index (R-DS-3.1).
//
// A `DeckStyle` is a *pure value* describing how a card face is drawn — its per-suit colors, whether a
// suit always carries a distinguishing *shape* (it always does — R-A11Y-3.1), and the index/pip sizing
// that distinguishes, say, a large-index "Jumbo Index" deck from the standard corner index. It carries
// NO EngineCore types: the deck catalog is verifiable headless (`swift test`) without importing the
// engine, and the small bridge from `EngineCore.Suit`/`Rank`/`CardFace` to these style parameters lives
// in the UI layer (TableKit) where the cached vector faces are actually rendered.
//
// Why the four suits are modeled here with their own enum (`DeckSuit`) rather than `EngineCore.Suit`:
// DesignSystem is a leaf of the UI layer with no dependency on EngineCore (design.md §1; Package.swift).
// `DeckSuit` mirrors the four French suits purely for styling; TableKit maps the engine's `Suit` onto it.
//
// COLOR INDEPENDENCE (R-A11Y-3.1 / R-DS-3.3): every suit ALWAYS carries a shape (`SuitShape`), so the
// suit is never conveyed by color alone. The Four-Color style additionally gives each suit a *distinct*
// color (a common accessibility aid); the other styles use the traditional two-color (red/black) scheme.
// Court cards use original placeholder designs (see `CourtCardArt`), flagged "needs production art".

import Foundation

/// The four French suits, for *styling* only (mirrors `EngineCore.Suit`; carries no game semantics).
public enum DeckSuit: String, Sendable, Hashable, CaseIterable, Codable {
    case clubs
    case diamonds
    case hearts
    case spades

    /// The shape a suit always carries, so a suit is identifiable without relying on color (R-A11Y-3.1).
    public var shape: SuitShape {
        switch self {
        case .clubs: return .club
        case .diamonds: return .diamond
        case .hearts: return .heart
        case .spades: return .spade
        }
    }

    /// Which of the two traditional print colors this suit uses (red = hearts/diamonds).
    public var traditionalInkIsRed: Bool {
        switch self {
        case .hearts, .diamonds: return true
        case .clubs, .spades: return false
        }
    }
}

/// The distinguishing pip/index *shape* a suit carries. Present in every deck style so suit identity is
/// never color-dependent (R-A11Y-3.1). The concrete vector path is drawn in the UI layer; this only names
/// which shape a suit maps to.
public enum SuitShape: String, Sendable, Hashable, CaseIterable, Codable {
    case club
    case diamond
    case heart
    case spade
}

/// The index/pip layout scale for a deck style — how prominent the corner index and pips are.
public enum IndexProminence: String, Sendable, Hashable, CaseIterable, Codable {
    /// Standard corner index sized for normal play.
    case standard
    /// Oversized corner index ("Jumbo Index") for at-a-glance legibility across a fanned hand
    /// (R-DS-3.1; complements the S/M/L/XL card-size accessibility option — R-A11Y-4.1).
    case jumbo
}

/// A deck-face style: the colors, index prominence, and per-suit shapes a card face is drawn with
/// (R-DS-3.1). Pure and appearance-independent — the same style renders identically under any system
/// light/dark setting (matches the theme model in `TableTheme.swift`).
public struct DeckStyle: Sendable, Hashable, Identifiable, Codable {
    /// Stable identifier (kebab-case), also used as the manifest key in a theme pack's `decks.styles`
    /// list (design.md §7).
    public let id: String
    /// The name shown in Settings.
    public let displayName: String
    /// When `true`, each suit is given a *distinct* color (Four-Color deck — R-DS-3.1, R-A11Y-3.1);
    /// otherwise the traditional two-color (red/black) scheme is used.
    public let isFourColor: Bool
    /// How prominent the corner index / pips are (Jumbo Index uses `.jumbo`).
    public let indexProminence: IndexProminence
    /// The ink color for each suit, in this style. Always four entries (one per suit).
    public let suitColors: [DeckSuit: TokenColor]
    /// Whether court cards use the geometric/ornamental placeholder art (always `true` until production
    /// art replaces it — R-DS-3.3, R-DS-6). The concrete placeholder is described by `CourtCardArt`.
    public let usesPlaceholderCourtArt: Bool

    public init(
        id: String,
        displayName: String,
        isFourColor: Bool,
        indexProminence: IndexProminence,
        suitColors: [DeckSuit: TokenColor],
        usesPlaceholderCourtArt: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.isFourColor = isFourColor
        self.indexProminence = indexProminence
        self.suitColors = suitColors
        self.usesPlaceholderCourtArt = usesPlaceholderCourtArt
    }

    /// The ink color a suit is drawn with in this style. Falls back to a neutral black if (impossibly) a
    /// suit is missing from `suitColors`, so a face always renders.
    public func inkColor(for suit: DeckSuit) -> TokenColor {
        suitColors[suit] ?? TokenColor(hex: 0x111111)
    }
}

// MARK: - Palettes

extension DeckStyle {
    /// The traditional two-color print scheme: hearts/diamonds red, clubs/spades near-black.
    static func twoColor(red: TokenColor, black: TokenColor) -> [DeckSuit: TokenColor] {
        [.hearts: red, .diamonds: red, .clubs: black, .spades: black]
    }

    /// The classic Four-Color scheme: each suit a distinct, high-contrast hue (a widely used accessibility
    /// convention — hearts red, diamonds blue, clubs green, spades black) (R-DS-3.1, R-A11Y-3.1).
    static func fourColor(
        hearts: TokenColor,
        diamonds: TokenColor,
        clubs: TokenColor,
        spades: TokenColor
    ) -> [DeckSuit: TokenColor] {
        [.hearts: hearts, .diamonds: diamonds, .clubs: clubs, .spades: spades]
    }
}

// MARK: - Built-in deck styles (R-DS-3.1)

extension DeckStyle {
    /// Classic — a traditional two-color deck with a warm, slightly muted red and a standard index.
    public static let classic = DeckStyle(
        id: "classic",
        displayName: "Classic",
        isFourColor: false,
        indexProminence: .standard,
        suitColors: twoColor(
            red: TokenColor(hex: 0xC62828),  // classic card red
            black: TokenColor(hex: 0x1A1A1A)  // near-black ink
        )
    )

    /// Modern — a crisp two-color deck with a brighter red and a clean black, still standard index.
    public static let modern = DeckStyle(
        id: "modern",
        displayName: "Modern",
        isFourColor: false,
        indexProminence: .standard,
        suitColors: twoColor(
            red: TokenColor(hex: 0xE53935),  // vivid modern red
            black: TokenColor(hex: 0x101418)  // cool near-black
        )
    )

    /// Four-Color — each suit a distinct, high-contrast color so suits never rely on the two-color scheme
    /// (accessibility aid; also supports color-independence — R-DS-3.1, R-A11Y-3.1).
    public static let fourColor = DeckStyle(
        id: "four-color",
        displayName: "Four-Color",
        isFourColor: true,
        indexProminence: .standard,
        suitColors: fourColor(
            hearts: TokenColor(hex: 0xC62828),  // red
            diamonds: TokenColor(hex: 0x1565C0),  // blue
            clubs: TokenColor(hex: 0x2E7D32),  // green
            spades: TokenColor(hex: 0x1A1A1A)  // black
        )
    )

    /// Jumbo Index — a two-color deck with an oversized corner index for at-a-glance legibility
    /// (R-DS-3.1; complements the S/M/L/XL card sizes — R-A11Y-4.1).
    public static let jumboIndex = DeckStyle(
        id: "jumbo-index",
        displayName: "Jumbo Index",
        isFourColor: false,
        indexProminence: .jumbo,
        suitColors: twoColor(
            red: TokenColor(hex: 0xC62828),
            black: TokenColor(hex: 0x1A1A1A)
        )
    )

    /// The built-in deck styles, in presentation order. Exactly the four the manifest lists (R-DS-3.1):
    /// `classic`, `modern`, `four-color`, `jumbo-index`.
    public static let all: [DeckStyle] = [classic, modern, fourColor, jumboIndex]

    /// Look up a built-in deck style by its `id`, or `nil` if none matches.
    public static func style(id: String) -> DeckStyle? {
        all.first { $0.id == id }
    }

    /// The default deck style (Classic).
    public static let `default`: DeckStyle = .classic
}
