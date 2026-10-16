// CardFaceCanvas — the vector drawing of a card face or back (R-DS-3.1/3.2/3.3, R-TABLE-2.1).
//
// This is the pure *drawing* of a card: a SwiftUI `Canvas` that renders one face or back as vectors —
// corner indices, pips, the original court-card placeholder medallion, joker, or a procedural back motif.
// It knows nothing about caching or interaction; `CardFaceCache` rasterizes it once per `CardFaceKey`
// (R-TABLE-2.1) and `CardView` composes the cached image with flip/lift/selection/highlight/dimming
// (R-TABLE-2.2).
//
// Drawing is driven by the DesignSystem catalogs: a `DeckStyle` provides per-suit ink colors and index
// prominence (Classic/Modern/Four-Color/Jumbo Index — R-DS-3.1); a `CardBack` provides the back motif +
// palette (≥ 6 — R-DS-3.2); court cards use the original geometric `CourtCardArt` medallion, flagged
// "needs production art" (R-DS-3.3). Suits always carry a shape via `SuitShapePath` (R-A11Y-3.1).

import DesignSystem
import SwiftUI

/// Renders one card face or back as vectors for a given key + catalogs (R-TABLE-2.1). Stateless: the same
/// inputs always draw the same image, which is what lets `CardFaceCache` memoize the result by key.
struct CardFaceCanvas: View {
    let key: CardFaceKey
    let style: DeckStyle
    let back: CardBack
    let theme: TableTheme
    /// The point size to draw at (the cache renders at this size × display scale).
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            switch key.face {
            case .back(let backID):
                drawBack(&context, in: rect, backID: backID)
            case .joker(let index):
                drawFaceCard(&context, in: rect)
                drawJoker(&context, in: rect, index: index)
            case .spot(let rank, let suit):
                drawFaceCard(&context, in: rect)
                drawSpot(&context, in: rect, rank: rank, suit: suit)
            case .court(let rank, let suit):
                drawFaceCard(&context, in: rect)
                drawCourt(&context, in: rect, rank: rank, suit: suit)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Shared face background

    private var cornerRadius: CGFloat { min(size.width, size.height) * 0.10 }

    private var faceInk: Color {
        // A faint theme-driven frame tint keeps a face grounded on its surface; keyed by theme so a
        // theme switch produces a distinct cached image (design.md §6).
        theme.shadowInk.swiftUIColor.opacity(0.18)
    }

    private func drawFaceCard(_ context: inout GraphicsContext, in rect: CGRect) {
        let card = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: rect)
        context.fill(card, with: .color(.white))
        context.stroke(card, with: .color(faceInk), lineWidth: max(1, rect.width * 0.01))
    }

    private func inkColor(for suit: DeckSuit) -> Color {
        let token = style.inkColor(for: suit)
        let color = token.swiftUIColor
        // High-contrast appearance deepens the ink toward pure black/saturated for legibility (R-A11Y-4.1).
        if key.appearance == .highContrast {
            return token.blended(toward: TokenColor(hex: 0x000000), amount: 0.35).swiftUIColor
        }
        return color
    }

    // MARK: - Corner index

    private var indexScale: CGFloat { style.indexProminence == .jumbo ? 1.6 : 1.0 }

    private func rankGlyph(_ rank: Int) -> String {
        switch rank {
        case 1: return "A"
        case 10: return "10"
        default: return String(rank)
        }
    }

    /// Draw the corner index (rank glyph + a small suit shape) in the two opposite corners. The index is
    /// larger for the Jumbo Index deck style (R-DS-3.1).
    private func drawIndex(
        _ context: inout GraphicsContext, in rect: CGRect, label: String, suit: DeckSuit
    ) {
        let ink = inkColor(for: suit)
        let unit = min(rect.width, rect.height)
        let fontSize = unit * 0.16 * indexScale
        let pad = unit * 0.06
        let glyphSize = unit * 0.12 * indexScale

        func drawCorner(at origin: CGPoint, flipped: Bool) {
            var ctx = context
            if flipped {
                ctx.translateBy(x: rect.maxX, y: rect.maxY)
                ctx.rotate(by: .degrees(180))
            }
            let text = Text(label).font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundColor(ink)
            let resolved = ctx.resolve(text)
            let textOrigin = CGPoint(x: origin.x, y: origin.y)
            ctx.draw(resolved, at: textOrigin, anchor: .topLeading)
            // Suit shape just below the glyph.
            let shapeRect = CGRect(
                x: origin.x, y: origin.y + fontSize * 1.05, width: glyphSize, height: glyphSize)
            ctx.fill(suit.shape.path(in: shapeRect), with: .color(ink))
        }

        drawCorner(at: CGPoint(x: rect.minX + pad, y: rect.minY + pad), flipped: false)
        drawCorner(at: CGPoint(x: pad, y: pad), flipped: true)
    }

    // MARK: - Spot (pip) cards

    private func drawSpot(
        _ context: inout GraphicsContext, in rect: CGRect, rank: Int, suit: DeckSuit
    ) {
        drawIndex(&context, in: rect, label: rankGlyph(rank), suit: suit)
        let ink = inkColor(for: suit)
        let positions = pipLayout(for: rank)
        let pipW = rect.width * 0.16
        let pipH = rect.height * 0.16
        for pos in positions {
            let center = CGPoint(
                x: rect.minX + rect.width * pos.x, y: rect.minY + rect.height * pos.y)
            let pipRect = CGRect(
                x: center.x - pipW / 2, y: center.y - pipH / 2, width: pipW, height: pipH)
            var pip = suit.shape.path(in: pipRect)
            // Bottom-half pips are drawn upside down, as on a real card.
            if pos.y > 0.5 {
                let transform = CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: .pi)
                    .translatedBy(x: -center.x, y: -center.y)
                pip = pip.applying(transform)
            }
            context.fill(pip, with: .color(ink))
        }
    }

    /// Normalized pip positions (x,y in 0...1) for ranks A(1)…10. Ace is a single large center pip;
    /// numbers use the conventional columns. Kept simple and legible.
    private func pipLayout(for rank: Int) -> [CGPoint] {
        let lx = 0.32
        let rx = 0.68
        let cx = 0.5
        switch rank {
        case 1: return [CGPoint(x: cx, y: 0.5)]
        case 2: return [CGPoint(x: cx, y: 0.28), CGPoint(x: cx, y: 0.72)]
        case 3: return [CGPoint(x: cx, y: 0.26), CGPoint(x: cx, y: 0.5), CGPoint(x: cx, y: 0.74)]
        case 4:
            return [
                CGPoint(x: lx, y: 0.28), CGPoint(x: rx, y: 0.28),
                CGPoint(x: lx, y: 0.72), CGPoint(x: rx, y: 0.72),
            ]
        case 5:
            return [
                CGPoint(x: lx, y: 0.28), CGPoint(x: rx, y: 0.28), CGPoint(x: cx, y: 0.5),
                CGPoint(x: lx, y: 0.72), CGPoint(x: rx, y: 0.72),
            ]
        case 6:
            return [
                CGPoint(x: lx, y: 0.28), CGPoint(x: rx, y: 0.28),
                CGPoint(x: lx, y: 0.5), CGPoint(x: rx, y: 0.5),
                CGPoint(x: lx, y: 0.72), CGPoint(x: rx, y: 0.72),
            ]
        case 7:
            return [
                CGPoint(x: lx, y: 0.26), CGPoint(x: rx, y: 0.26), CGPoint(x: cx, y: 0.38),
                CGPoint(x: lx, y: 0.5), CGPoint(x: rx, y: 0.5),
                CGPoint(x: lx, y: 0.74), CGPoint(x: rx, y: 0.74),
            ]
        case 8:
            return [
                CGPoint(x: lx, y: 0.24), CGPoint(x: rx, y: 0.24), CGPoint(x: cx, y: 0.37),
                CGPoint(x: lx, y: 0.5), CGPoint(x: rx, y: 0.5), CGPoint(x: cx, y: 0.63),
                CGPoint(x: lx, y: 0.76), CGPoint(x: rx, y: 0.76),
            ]
        case 9:
            return [
                CGPoint(x: lx, y: 0.24), CGPoint(x: rx, y: 0.24),
                CGPoint(x: lx, y: 0.42), CGPoint(x: rx, y: 0.42), CGPoint(x: cx, y: 0.5),
                CGPoint(x: lx, y: 0.58), CGPoint(x: rx, y: 0.58),
                CGPoint(x: lx, y: 0.76), CGPoint(x: rx, y: 0.76),
            ]
        default:  // 10
            return [
                CGPoint(x: lx, y: 0.22), CGPoint(x: rx, y: 0.22), CGPoint(x: cx, y: 0.33),
                CGPoint(x: lx, y: 0.4), CGPoint(x: rx, y: 0.4),
                CGPoint(x: lx, y: 0.6), CGPoint(x: rx, y: 0.6), CGPoint(x: cx, y: 0.67),
                CGPoint(x: lx, y: 0.78), CGPoint(x: rx, y: 0.78),
            ]
        }
    }

    // MARK: - Court cards (original geometric placeholder — R-DS-3.3)

    private func drawCourt(
        _ context: inout GraphicsContext, in rect: CGRect, rank: CourtRank, suit: DeckSuit
    ) {
        drawIndex(&context, in: rect, label: rank.monogram, suit: suit)
        let ink = inkColor(for: suit)
        let unit = min(rect.width, rect.height)
        // A symmetric medallion: nested rounded frames around a central suit shape + monogram. Original,
        // geometric placeholder art — no traditional court figures (R-DS-3.3).
        let inset = unit * 0.24
        let panel = rect.insetBy(dx: inset, dy: inset * 0.7)
        for (i, factor) in [1.0, 0.86, 0.72].enumerated() {
            let frameRect = panel.insetBy(
                dx: panel.width * (1 - factor) / 2, dy: panel.height * (1 - factor) / 2)
            let framePath = RoundedRectangle(cornerRadius: unit * 0.06, style: .continuous)
                .path(in: frameRect)
            context.stroke(
                framePath, with: .color(ink.opacity(i == 0 ? 0.9 : 0.5)),
                lineWidth: max(1, unit * 0.012))
        }
        // Central suit shape.
        let shapeSize = unit * 0.28
        let shapeRect = CGRect(
            x: rect.midX - shapeSize / 2, y: rect.midY - shapeSize / 2,
            width: shapeSize, height: shapeSize)
        context.fill(suit.shape.path(in: shapeRect), with: .color(ink))
        // Monogram above the shape.
        let mono = Text(rank.monogram)
            .font(.system(size: unit * 0.22, weight: .heavy, design: .serif))
            .foregroundColor(ink.opacity(0.85))
        context.draw(
            context.resolve(mono),
            at: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.28), anchor: .center)
    }

    // MARK: - Joker

    private func drawJoker(_ context: inout GraphicsContext, in rect: CGRect, index: Int) {
        let ink = TokenColor(hex: 0x6A1B9A).swiftUIColor  // joker purple
        let unit = min(rect.width, rect.height)
        let text = Text("JOKER").font(.system(size: unit * 0.14, weight: .bold, design: .rounded))
            .foregroundColor(ink)
        context.draw(
            context.resolve(text), at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        // A small differentiating star per joker index.
        let starCount = max(1, index + 1)
        for s in 0..<min(starCount, 3) {
            let star = Text("★").font(.system(size: unit * 0.12))
                .foregroundColor(ink.opacity(0.7))
            context.draw(
                context.resolve(star),
                at: CGPoint(x: rect.midX, y: rect.midY + unit * (0.22 + Double(s) * 0.12)),
                anchor: .center)
        }
    }

    // MARK: - Backs (≥ 6 procedural motifs — R-DS-3.2)

    private func drawBack(_ context: inout GraphicsContext, in rect: CGRect, backID: String) {
        let cardBack = CardBack.back(id: backID) ?? back
        let field = cardBack.field.swiftUIColor
        let ink = cardBack.ink.swiftUIColor
        let card = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
        context.fill(card, with: .color(field))
        // Draw the motif clipped to the card, inset by a border.
        let inset = min(rect.width, rect.height) * 0.08
        let inner = rect.insetBy(dx: inset, dy: inset)
        var clipped = context
        clipped.clip(
            to: RoundedRectangle(cornerRadius: cornerRadius * 0.7, style: .continuous).path(
                in: inner))
        drawMotif(&clipped, in: inner, motif: cardBack.motif, ink: ink)
        // Border frame.
        context.stroke(
            RoundedRectangle(cornerRadius: cornerRadius * 0.7, style: .continuous).path(in: inner),
            with: .color(ink.opacity(0.9)), lineWidth: max(1, rect.width * 0.015))
    }

    private func drawMotif(
        _ context: inout GraphicsContext, in rect: CGRect, motif: CardBackMotif, ink: Color
    ) {
        let step = min(rect.width, rect.height) * 0.14
        switch motif {
        case .lattice:
            var path = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
                path.move(to: CGPoint(x: x + rect.height, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += step
            }
            context.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: max(1, step * 0.12))
        case .linen:
            var path = Path()
            var y = rect.minY
            while y < rect.maxY {
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += step * 0.4
            }
            var x = rect.minX
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += step * 0.4
            }
            context.stroke(path, with: .color(ink.opacity(0.5)), lineWidth: max(0.5, step * 0.04))
        case .checker:
            let cols = Int((rect.width / step).rounded(.up))
            let rows = Int((rect.height / step).rounded(.up))
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    let cell = CGRect(
                        x: rect.minX + CGFloat(c) * step, y: rect.minY + CGFloat(r) * step,
                        width: step, height: step)
                    context.fill(Path(cell), with: .color(ink.opacity(0.85)))
                }
            }
        case .wave:
            var path = Path()
            var y = rect.minY
            while y < rect.maxY {
                path.move(to: CGPoint(x: rect.minX, y: y))
                var x = rect.minX
                while x < rect.maxX {
                    path.addQuadCurve(
                        to: CGPoint(x: x + step, y: y),
                        control: CGPoint(x: x + step / 2, y: y - step * 0.4))
                    x += step
                }
                y += step * 0.6
            }
            context.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: max(1, step * 0.1))
        case .artDeco:
            let center = CGPoint(x: rect.midX, y: rect.minY)
            var path = Path()
            let rays = 14
            let radius = rect.height * 1.1
            for i in 0...rays {
                let angle = Double.pi * (Double(i) / Double(rays))
                path.move(to: center)
                path.addLine(
                    to: CGPoint(
                        x: center.x + CGFloat(cos(angle)) * radius,
                        y: center.y + CGFloat(sin(angle)) * radius))
            }
            context.stroke(path, with: .color(ink.opacity(0.75)), lineWidth: max(1, step * 0.08))
        case .crest:
            let inset = min(rect.width, rect.height) * 0.18
            let medallion = rect.insetBy(dx: inset, dy: inset)
            context.stroke(
                Ellipse().path(in: medallion), with: .color(ink.opacity(0.9)),
                lineWidth: max(1, step * 0.14))
            let inner = medallion.insetBy(dx: medallion.width * 0.18, dy: medallion.height * 0.18)
            context.fill(
                SuitShape.spade.path(
                    in: inner.insetBy(dx: inner.width * 0.2, dy: inner.height * 0.2)),
                with: .color(ink.opacity(0.85)))
        }
    }
}
