// PieceView — a placeholder rectangle card/tile view with stable identity (R-TABLE-1.1; task 3.3).
//
// The MINIMAL piece view for the vertical slice: a rounded rectangle that shows a piece's face for a
// `.known` piece (rank+suit for a card, number+color for a tile) and a plain back for a `.hidden` piece.
// It is deliberately drawn with SwiftUI primitives — no cached vector faces, no shaders. Cached vector
// faces keyed by (theme,face,scale,appearance) are task 5.3; theme shaders are task 5.2. This view exists
// only so the generic renderer has something to place and animate now.
//
// Stable identity: the containing `TableView` keys each piece by its `RenderKey` and applies
// `matchedGeometryEffect`, so THIS view carries no identity itself — it just draws whatever face/back it
// is handed. That separation is what lets a piece animate across zones and across a reveal.

import EngineCore
import SwiftUI

/// What a `PieceView` should draw: a known face or a face-down back.
public enum PieceFaceContent: Sendable, Hashable {
    /// A visible card: its rank/suit label and suit color.
    case card(CardFace)
    /// A visible tile: its number and color.
    case tile(TileFace)
    /// A face-down piece (hidden token, or a face-down known piece).
    case back
}

/// A placeholder rectangle view for one card/tile (R-TABLE-1.1). Minimal by design (task 3.3).
public struct PieceView: View {
    /// The content to render (known face or back).
    public let content: PieceFaceContent
    /// The size to draw at, in points (comes from `LayoutResolver`).
    public let size: CGSize

    public init(content: PieceFaceContent, size: CGSize) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        let corner = min(size.width, size.height) * 0.12
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
            )
            .overlay(faceLabel)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
    }

    // MARK: Drawing

    private var fillColor: Color {
        switch content {
        case .back:
            return Color(red: 0.15, green: 0.28, blue: 0.55)  // simple card-back blue
        case .card, .tile:
            return .white
        }
    }

    @ViewBuilder
    private var faceLabel: some View {
        switch content {
        case .back:
            // A minimal back motif: a rounded inset. Real backs are task 5.3.
            RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.08, style: .continuous)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                .padding(size.width * 0.12)
        case .card(let face):
            Text(Self.cardLabel(face))
                .font(.system(size: size.height * 0.3, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.cardColor(face))
                .minimumScaleFactor(0.4)
                .padding(4)
        case .tile(let face):
            Text(Self.tileLabel(face))
                .font(.system(size: size.height * 0.3, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.tileColor(face))
                .minimumScaleFactor(0.4)
                .padding(4)
        }
    }

    // MARK: Label helpers (pure; also unit-testable)

    /// A short label for a card face, e.g. "A♠", "10♥", "Jkr". Pure.
    ///
    /// `nonisolated` so this pure formatting helper is callable off the main actor (and directly from
    /// tests) even though `PieceView`, being a SwiftUI `View`, is implicitly `@MainActor`.
    public nonisolated static func cardLabel(_ face: CardFace) -> String {
        switch face {
        case .standard(let rank, let suit):
            return rankGlyph(rank) + suitGlyph(suit)
        case .joker:
            return "Jkr"
        }
    }

    /// A short label for a tile face, e.g. "7", "13", "J". Pure.
    public nonisolated static func tileLabel(_ face: TileFace) -> String {
        switch face {
        case .numbered(let n, _):
            return String(n)
        case .joker:
            return "J"
        }
    }

    static func cardColor(_ face: CardFace) -> Color {
        switch face {
        case .standard(_, let suit):
            switch suit {
            case .hearts, .diamonds: return .red
            case .clubs, .spades: return .black
            }
        case .joker:
            return .purple
        }
    }

    static func tileColor(_ face: TileFace) -> Color {
        switch face {
        case .numbered(_, let color):
            switch color {
            case .red: return .red
            case .blue: return .blue
            case .black: return .black
            case .orange: return .orange
            }
        case .joker:
            return .purple
        }
    }

    nonisolated static func rankGlyph(_ rank: Rank) -> String {
        switch rank {
        case .ace: return "A"
        case .jack: return "J"
        case .queen: return "Q"
        case .king: return "K"
        case .ten: return "10"
        default: return String(rank.rawValue)
        }
    }

    nonisolated static func suitGlyph(_ suit: Suit) -> String {
        switch suit {
        case .clubs: return "\u{2663}"  // ♣
        case .diamonds: return "\u{2666}"  // ♦
        case .hearts: return "\u{2665}"  // ♥
        case .spades: return "\u{2660}"  // ♠
        }
    }
}

// MARK: - Face lookup convenience

extension PlayerView {
    /// Build a `RenderKey → PieceFaceContent` map from this view's currently-known faces, for the
    /// generic `TableView` to draw each piece (hosts pass the result, or their own closure, as
    /// `faceContent`). Known cards/tiles map to their face; hidden tokens map to `.back`. Pure.
    public func faceContentMap() -> [RenderKey: PieceFaceContent] {
        var map: [RenderKey: PieceFaceContent] = [:]
        for zone in zones {
            for piece in zone.pieces {
                switch piece {
                case .known(let known):
                    switch known {
                    case .card(let card): map[.known(card.id)] = .card(card.face)
                    case .tile(let tile): map[.known(tile.id)] = .tile(tile.face)
                    }
                case .hidden(let token):
                    map[.hidden(token)] = .back
                }
            }
        }
        return map
    }
}
