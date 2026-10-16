// CardFaceKey — the cache key that makes card faces/backs cached, not redrawn per frame (R-TABLE-2.1).
//
// R-TABLE-2.1 requires card views to use CACHED vector faces and backs keyed by
// `(theme, face, scale, appearance)`, never redrawn every frame. `CardFaceKey` is exactly that key: a
// `Hashable` value combining the four dimensions, so the renderer caches one rasterized vector image per
// distinct combination and reuses it for every frame that shares the key.
//
// The four dimensions (design.md §6):
//   • theme      — the `TableTheme.id` the face is drawn for (a face reads a couple of theme-driven
//                  tints, e.g. the frame ink, so it is keyed by theme).
//   • face       — WHAT is drawn: a specific rank+suit, a joker, a court placeholder, or a card back
//                  (identified by its `CardBack.id`). Captured by `CardFaceDescriptor`.
//   • scale      — the pixel scale bucket (card size × display scale). Faces are rasterized at a discrete
//                  bucket so hovering/animating a card never re-rasterizes it.
//   • appearance — the resolved appearance the vector is tinted for. Table faces are appearance-independent
//                  by default (like themes — R-DS-2.2), but the key carries the dimension so an
//                  increase-contrast / high-contrast variant is a *distinct* cached image, not a repaint.
//
// This file is pure (Foundation-only) so the key's identity and the bridge from `EngineCore.CardFace` are
// unit-testable headless; the actual drawing + cache live in the UI-only files.

import DesignSystem
import EngineCore
import Foundation

// MARK: - What is drawn

/// The specific artwork a card view draws — the "face" dimension of the cache key (R-TABLE-2.1).
///
/// A descriptor captures WHAT is drawn independently of size/theme/appearance, so two cards showing the
/// same thing share one cached image. It covers every drawable: a numbered/ace pip face, a court
/// placeholder, a joker, and a face-down back (identified by the chosen `CardBack`).
public enum CardFaceDescriptor: Sendable, Hashable, Codable {
    /// A standard spot (pip) card — ace through ten — of a suit.
    case spot(rank: Int, suit: DeckSuit)
    /// A court card (Jack/Queen/King) of a suit, drawn with the original placeholder medallion.
    case court(rank: CourtRank, suit: DeckSuit)
    /// A joker, distinguished by its pack index.
    case joker(index: Int)
    /// A face-down back, identified by the chosen back's id.
    case back(backID: String)

    /// Build a face descriptor from an `EngineCore.CardFace`, mapping the engine's suit/rank onto the
    /// styling types. Court ranks (J/Q/K) route to `.court`; ace–ten route to `.spot`. Pure.
    public init(_ face: CardFace) {
        switch face {
        case .standard(let rank, let suit):
            let deckSuit = DeckSuit(suit)
            switch rank {
            case .jack: self = .court(rank: .jack, suit: deckSuit)
            case .queen: self = .court(rank: .queen, suit: deckSuit)
            case .king: self = .court(rank: .king, suit: deckSuit)
            default: self = .spot(rank: rank.rawValue, suit: deckSuit)
            }
        case .joker(let index):
            self = .joker(index: index)
        }
    }

    /// The face-down back descriptor for a chosen `CardBack`.
    public static func back(_ back: CardBack) -> CardFaceDescriptor { .back(backID: back.id) }
}

// MARK: - Appearance dimension

/// The resolved appearance a card vector is tinted for — the "appearance" dimension of the cache key.
///
/// Table faces are appearance-independent by default (like table themes — R-DS-2.2); the key still carries
/// this dimension so a high-contrast variant caches as a *separate* image rather than forcing a repaint,
/// satisfying Increase Contrast (R-A11Y-4.1) without breaking the "cached, not redrawn" rule (R-TABLE-2.1).
public enum CardAppearance: String, Sendable, Hashable, CaseIterable, Codable {
    /// The standard tinting for a card face.
    case standard
    /// A higher-contrast variant (Increase Contrast — R-A11Y-4.1).
    case highContrast
}

// MARK: - The cache key

/// The cache key for a rendered card vector: `(theme, face, scale, appearance)` (R-TABLE-2.1).
///
/// Two card views that agree on all four dimensions share ONE cached rasterized vector; the renderer
/// looks the image up by this key and only draws the vector on a cache miss — never every frame.
public struct CardFaceKey: Sendable, Hashable, Codable {
    /// The `TableTheme.id` the face is drawn for.
    public let themeID: String
    /// The deck-style `id` the face is drawn in (colors, index prominence). Ignored for `.back`, which
    /// carries its own palette; kept in the key so a style switch produces distinct cached faces.
    public let deckStyleID: String
    /// What is drawn.
    public let face: CardFaceDescriptor
    /// The discrete pixel-scale bucket (card size × display scale), rounded so nearby sizes share a key.
    public let scaleBucket: Int
    /// The resolved appearance the vector is tinted for.
    public let appearance: CardAppearance

    public init(
        themeID: String,
        deckStyleID: String,
        face: CardFaceDescriptor,
        scaleBucket: Int,
        appearance: CardAppearance
    ) {
        self.themeID = themeID
        self.deckStyleID = deckStyleID
        self.face = face
        self.scaleBucket = scaleBucket
        self.appearance = appearance
    }

    /// Quantize a continuous point-size (a card's larger dimension × display scale) into a discrete
    /// bucket so animating/hovering a card — which nudges its size fractionally — reuses one cached image
    /// instead of re-rasterizing every frame (R-TABLE-2.1). Buckets step every `step` device pixels.
    public static func scaleBucket(forPixelSize pixels: Double, step: Double = 8) -> Int {
        let clamped = max(0, pixels)
        return Int((clamped / max(1, step)).rounded())
    }
}

// MARK: - EngineCore.Suit → DeckSuit bridge

extension DeckSuit {
    /// Map an `EngineCore.Suit` onto the DesignSystem styling suit. The two enums intentionally share
    /// case names; this bridge keeps DesignSystem free of any EngineCore dependency (design.md §1).
    public init(_ suit: Suit) {
        switch suit {
        case .clubs: self = .clubs
        case .diamonds: self = .diamonds
        case .hearts: self = .hearts
        case .spades: self = .spades
        }
    }
}
