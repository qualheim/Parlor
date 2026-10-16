// PieceAccessibility — the pure, Foundation-only derivation of VoiceOver descriptions (task 7.1; R-A11Y-1).
//
// R-A11Y-1.1 requires EVERY card, tile, pile, and control to carry a meaningful label, value, and hint
// (e.g. "Queen of clubs, trump, playable"); R-A11Y-1.2 requires custom rotors for hands/piles and spoken
// announcements of opponent actions and results. Following design.md §9 — "VoiceOver labels/values/hints
// are derived from the same GameEvent/PlayerView data that drives visuals, so they can never drift" — this
// file is the PURE heart of that: given the exact `EngineCore` view data a card view already renders (a
// `CardFace`/`TileFace`, or a hidden token), plus optional game-supplied context flags, it produces the
// label/value/hint the SwiftUI views apply, the pile/zone descriptions, the rotor-entry model, and the
// announcement strings. It holds no SwiftUI, so every derivation is unit-testable headless and can never
// import a UI framework (R-BUILD-4.2).
//
// Game-agnostic on purpose: TableKit does not know what "trump" or "playable" means for a given game, so
// those adornments arrive as passed-in `PieceAccessibilityContext`. The engine supplies the FACE (what the
// card is); the host/game supplies the CONTEXT (what it means right now). Announcements reuse
// `HUDModel.narrate` so the spoken line and the history/caption line are the same derivation.

import EngineCore
import Foundation

// MARK: - Context supplied by the game/host

/// Game-supplied adornments layered onto a piece's derived description (R-A11Y-1.1).
///
/// TableKit is game-agnostic, so anything a specific game means — is this the trump suit? is this card
/// playable right now? is it selected? — is passed in here rather than inferred. The face gives the label
/// ("Queen of clubs"); this context adds the value words ("trump, playable") and picks the hint
/// ("Double-tap to play"). All fields default to "no adornment", so a plain resting card needs no context.
public struct PieceAccessibilityContext: Sendable, Hashable {
    /// Whether this piece is currently playable/selectable by the local player (adds "playable" and a
    /// "double-tap to play" hint). `nil` means "the game does not express playability here" (no word).
    public var isPlayable: Bool?
    /// Whether this piece is currently selected (adds "selected").
    public var isSelected: Bool
    /// Whether the game considers this the trump suit (adds "trump"). Game-specific concept, so passed in.
    public var isTrump: Bool
    /// An optional short, game-supplied effective-suit / role phrase inserted verbatim into the value
    /// (e.g. "leads the trick"). Kept free-form so a game surfaces its own vocabulary without TableKit
    /// knowing it.
    public var extraValue: String?
    /// The zone/pile name this piece sits in, for a positional hint (e.g. "in your hand"). Optional.
    public var containerName: String?
    /// The piece's 1-based position within its pile and the pile size, for "card 3 of 7" phrasing.
    public var position: PiecePosition?

    public init(
        isPlayable: Bool? = nil,
        isSelected: Bool = false,
        isTrump: Bool = false,
        extraValue: String? = nil,
        containerName: String? = nil,
        position: PiecePosition? = nil
    ) {
        self.isPlayable = isPlayable
        self.isSelected = isSelected
        self.isTrump = isTrump
        self.extraValue = extraValue
        self.containerName = containerName
        self.position = position
    }

    /// The no-adornment context (a plain resting piece).
    public static let none = PieceAccessibilityContext()
}

/// A 1-based position of a piece within its pile (e.g. "card 3 of 7"), used in labels and rotor entries.
public struct PiecePosition: Sendable, Hashable {
    /// The 1-based index of the piece within its pile (bottom→top, matching `Zone.contents` order).
    public let index: Int
    /// The number of pieces in the pile.
    public let count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

// MARK: - The derived description

/// A piece's full VoiceOver description: a `label` (what it is), a `value` (its current state words), and a
/// `hint` (how to act on it) — the three pieces R-A11Y-1.1 requires for every card/tile/pile/control.
///
/// A pure value: the SwiftUI views apply it with `.accessibilityLabel/.accessibilityValue/.accessibilityHint`.
/// `combinedLabel` joins label + value into the single comma-separated phrase the requirement's example
/// ("Queen of clubs, trump, playable") shows, for callers/tests that want one string.
public struct AccessibilityDescription: Sendable, Hashable {
    /// What the element IS, e.g. "Queen of clubs", "Foundation, 3 cards".
    public let label: String
    /// The element's current state words, e.g. "trump, playable", or empty when it has none.
    public let value: String
    /// How to act on the element, e.g. "Double-tap to play", or empty when there is no action.
    public let hint: String

    public init(label: String, value: String = "", hint: String = "") {
        self.label = label
        self.value = value
        self.hint = hint
    }

    /// Label and value joined into one comma-separated phrase (the requirement's "Queen of clubs, trump,
    /// playable" form). Empty value → just the label.
    public var combinedLabel: String {
        value.isEmpty ? label : "\(label), \(value)"
    }
}

// MARK: - PieceAccessibility (the pure derivation — R-A11Y-1.1)

/// The pure derivation of piece/pile VoiceOver descriptions from engine face data + game context.
///
/// Namespaced as an empty enum of static functions (like `HUDModel`/`TableFocusModel`): no instance state,
/// just deterministic transforms that are trivially unit-testable and free of SwiftUI (design.md §9).
public enum PieceAccessibility {
    // MARK: Suit / rank vocabulary

    /// The spoken name of a suit, e.g. "clubs". Pure.
    public static func suitName(_ suit: Suit) -> String {
        switch suit {
        case .clubs: return "clubs"
        case .diamonds: return "diamonds"
        case .hearts: return "hearts"
        case .spades: return "spades"
        }
    }

    /// The spoken name of a rank, e.g. "queen", "ten", "ace". Pure.
    public static func rankName(_ rank: Rank) -> String {
        switch rank {
        case .ace: return "ace"
        case .two: return "two"
        case .three: return "three"
        case .four: return "four"
        case .five: return "five"
        case .six: return "six"
        case .seven: return "seven"
        case .eight: return "eight"
        case .nine: return "nine"
        case .ten: return "ten"
        case .jack: return "jack"
        case .queen: return "queen"
        case .king: return "king"
        }
    }

    /// The spoken name of a tile color, e.g. "red". Pure.
    public static func colorName(_ color: TileColor) -> String {
        switch color {
        case .red: return "red"
        case .blue: return "blue"
        case .black: return "black"
        case .orange: return "orange"
        }
    }

    /// The bare spoken name of a card face, e.g. "Queen of clubs", "Joker". Capitalized for the start of a
    /// label. Pure — this is the "label" part before any context words.
    public static func cardName(_ face: CardFace) -> String {
        switch face {
        case .standard(let rank, let suit):
            return "\(rankName(rank).capitalizedFirst) of \(suitName(suit))"
        case .joker:
            return "Joker"
        }
    }

    /// The bare spoken name of a tile face, e.g. "Red 7", "Joker". Pure.
    public static func tileName(_ face: TileFace) -> String {
        switch face {
        case .numbered(let n, let color):
            return "\(colorName(color).capitalizedFirst) \(n)"
        case .joker:
            return "Joker"
        }
    }

    // MARK: Piece descriptions (R-A11Y-1.1)

    /// Derive the full description for a face-up CARD with optional game context (R-A11Y-1.1).
    ///
    /// Produces the requirement's example when given trump + playable: label "Queen of clubs",
    /// value "trump, playable", so `combinedLabel` reads "Queen of clubs, trump, playable".
    public static func card(
        _ face: CardFace, context: PieceAccessibilityContext = .none
    ) -> AccessibilityDescription {
        AccessibilityDescription(
            label: cardName(face),
            value: stateValue(context),
            hint: hint(context))
    }

    /// Derive the full description for a face-up TILE with optional game context (R-A11Y-1.1).
    public static func tile(
        _ face: TileFace, context: PieceAccessibilityContext = .none
    ) -> AccessibilityDescription {
        AccessibilityDescription(
            label: tileName(face),
            value: stateValue(context),
            hint: hint(context))
    }

    /// Derive the description for a FACE-DOWN piece (a hidden token or a face-down known piece). Its
    /// identity is intentionally not spoken — only that it is a face-down card/tile (R-A11Y-1.1,
    /// R-ENG-8.3: a view must never leak a hidden identity, and neither may its VoiceOver text).
    public static func faceDown(
        isTile: Bool = false, context: PieceAccessibilityContext = .none
    ) -> AccessibilityDescription {
        // The container/position adornments still apply (a face-down card in the stock can say "card 3 of
        // 12"), but the state words that would reveal playability etc. are dropped for a hidden piece.
        var positional = PieceAccessibilityContext()
        positional.position = context.position
        positional.containerName = context.containerName
        return AccessibilityDescription(
            label: isTile ? "Face-down tile" : "Face-down card",
            value: stateValue(positional),
            hint: "")
    }

    /// Derive the description for arbitrary render content directly from a `PieceFaceContent` + context —
    /// the single entry point the piece views call so a known card/tile and a back all route correctly.
    public static func description(
        for content: PieceFaceContent, context: PieceAccessibilityContext = .none
    ) -> AccessibilityDescription {
        switch content {
        case .card(let face): return card(face, context: context)
        case .tile(let face): return tile(face, context: context)
        case .back: return faceDown(context: context)
        }
    }

    // MARK: Pile / zone descriptions (R-A11Y-1.1)

    /// Derive the description for a PILE/zone: its name, count, and — depending on visibility — its top
    /// card or that it is face down (R-A11Y-1.1). Examples: "Foundation, 3 cards, top King of hearts",
    /// "Stock, 12 cards, face down", "Discard, empty".
    ///
    /// The `name` is the game-supplied display name for the zone (e.g. "Foundation", "Stock", "Your hand").
    /// `topContent` is the render content of the top piece, if the pile shows it (from `ZoneView`
    /// redaction); `nil` means the pile has no visible top identity, so the label falls back to the
    /// visibility policy ("face down" for a hidden pile).
    public static func pile(
        name: String,
        count: Int,
        visibility: Visibility,
        topContent: PieceFaceContent? = nil
    ) -> AccessibilityDescription {
        guard count > 0 else {
            return AccessibilityDescription(label: "\(name), empty")
        }
        let countPhrase = "\(count) \(count == 1 ? "card" : "cards")"
        let suffix: String
        switch topContent {
        case .card(let face):
            suffix = ", top \(cardName(face))"
        case .tile(let face):
            suffix = ", top \(tileName(face))"
        case .back, .none:
            // No visible top identity — describe by policy so a hidden/stock pile reads "face down".
            switch visibility {
            case .hidden, .ownerOnly:
                suffix = ", face down"
            default:
                suffix = ""
            }
        }
        return AccessibilityDescription(label: "\(name), \(countPhrase)\(suffix)")
    }

    /// Build the pile description straight from a redacted `ZoneView` + its display name, using the top
    /// piece's revealed face when present (R-A11Y-1.1; design.md §9 — derived from the same view data).
    public static func pile(
        _ zone: ZoneView, name: String
    ) -> AccessibilityDescription {
        let top = zone.pieces.last
        let topContent: PieceFaceContent?
        switch top {
        case .known(let known):
            switch known {
            case .card(let card): topContent = .card(card.face)
            case .tile(let tile): topContent = .tile(tile.face)
            }
        case .hidden:
            topContent = .back
        case .none:
            topContent = nil
        }
        return pile(
            name: name,
            count: zone.pieces.count,
            visibility: zone.visibility,
            topContent: topContent)
    }

    // MARK: Shared value/hint assembly

    /// Assemble the comma-separated state words for a piece from its context (e.g. "trump, playable",
    /// "card 3 of 7, selected"). Empty when the piece has no adornments. Order is: position, container,
    /// trump, extra, selected, playable — read from most-locating to most-actionable.
    static func stateValue(_ context: PieceAccessibilityContext) -> String {
        var parts: [String] = []
        if let position = context.position {
            parts.append("card \(position.index) of \(position.count)")
        }
        if let container = context.containerName {
            parts.append("in \(container)")
        }
        if context.isTrump { parts.append("trump") }
        if let extra = context.extraValue, !extra.isEmpty { parts.append(extra) }
        if context.isSelected { parts.append("selected") }
        if let playable = context.isPlayable {
            parts.append(playable ? "playable" : "not playable")
        }
        return parts.joined(separator: ", ")
    }

    /// The action hint for a piece, chosen from its context: a playable piece invites a play, a selectable
    /// piece invites selection, otherwise no hint. Kept short and imperative per VoiceOver convention.
    static func hint(_ context: PieceAccessibilityContext) -> String {
        if context.isPlayable == true { return "Double-tap to play" }
        if context.isSelected { return "Double-tap to deselect" }
        if context.isPlayable == false { return "" }
        return "Double-tap to select"
    }
}

// MARK: - Small string helper

extension String {
    /// This string with its first character uppercased (locale-independent), leaving the rest untouched —
    /// so "queen" → "Queen" without lowercasing "of clubs". Pure.
    fileprivate var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
