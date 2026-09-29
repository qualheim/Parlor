// LayoutResolver — (layout + table size + zones) → concrete per-piece frames (R-TABLE-1.1, R-APP-6.4).
//
// This is the pure resolution step of the generic renderer: it takes a game's declarative `TableLayout`,
// a concrete table `size`, and the redacted `ZoneView`s from a `PlayerView`, and returns a frame (a
// `CGRect` in points) for every piece on the table. The SwiftUI view (`TableView`) is a thin layer over
// these frames; keeping resolution here — as a pure, deterministic function — is what makes the renderer
// testable without a running UI (assert regions, stacking offsets, seat placement, and scaling).
//
// No per-game code lives here: a new game supplies only its `TableLayout`; the same resolver serves every
// game (R-TABLE-1.2).

import CoreGraphics
import EngineCore
import Foundation

// MARK: - Resolved piece frame

/// A single piece placed on the table: its stable render key, its frame in points, and whether it is
/// face-up (R-TABLE-1.1).
///
/// `key` is the piece's stable identity for the SwiftUI view — a `PieceID` for a `.known` piece or a
/// `ViewToken` for a `.hidden` one — so matched-geometry animation can track a piece across zones and
/// across a reveal (design.md §6; R-ENG-8.4).
public struct ResolvedPiece: Sendable, Hashable {
    /// The stable render identity of this piece (known id or hidden token).
    public let key: RenderKey
    /// The zone the piece currently belongs to.
    public let zone: ZoneID
    /// The piece's index within its zone (0-based, bottom→top of the pile).
    public let index: Int
    /// The piece's frame on the table, in points.
    public let frame: CGRect
    /// Whether the piece is rendered face-up.
    public let faceUp: Bool

    public init(key: RenderKey, zone: ZoneID, index: Int, frame: CGRect, faceUp: Bool) {
        self.key = key
        self.zone = zone
        self.index = index
        self.frame = frame
        self.faceUp = faceUp
    }
}

// MARK: - Render key (stable identity)

/// The stable identity a rendered piece is keyed by for matched-geometry motion (design.md §6).
///
/// A visible piece is keyed by its real `PieceID`; a hidden piece is keyed by the opaque per-view
/// `ViewToken` it was assigned. On `pieceRevealed` the render model rebinds the token's node to the
/// revealed identity so the flip stays continuous (R-ENG-8.4).
public enum RenderKey: Sendable, Hashable, Codable {
    case known(PieceID)
    case hidden(ViewToken)
}

// MARK: - Resolver

/// Resolves a `TableLayout` against a table size and a set of redacted zones into per-piece frames.
///
/// Stateless and pure: the same inputs always produce the same output, which is exactly what the layout
/// tests assert. Card size is derived from the table size so everything scales together (R-APP-6.4).
public struct LayoutResolver: Sendable {
    /// The card's size as a fraction of the table width/height. Cards are taller than wide (a 2.5×3.5
    /// playing-card aspect), sized so a typical table shows a comfortable spread.
    public let cardWidthFraction: CGFloat
    public let cardAspect: CGFloat  // height / width

    public init(cardWidthFraction: CGFloat = 0.072, cardAspect: CGFloat = 1.4) {
        self.cardWidthFraction = cardWidthFraction
        self.cardAspect = cardAspect
    }

    /// The resolved card size for a given table size, in points. Scales linearly with the table so a 6K
    /// display and a small window keep the same proportions (R-APP-6.4).
    public func cardSize(in tableSize: CGSize) -> CGSize {
        let w = cardWidthFraction * tableSize.width
        return CGSize(width: w, height: w * cardAspect)
    }

    /// Resolve every piece in `zones` to a concrete frame, using `layout` and `tableSize`.
    ///
    /// `seatIndexForOwner` maps a zone owner (`SeatID`) to a seat index `0..<seatCount` (0 = local); the
    /// renderer uses it to place per-seat zones via the layout's seat arrangement. Pieces in zones the
    /// layout has no placement for are skipped (returned frames omit them).
    public func resolve(
        layout: TableLayout,
        zones: [ZoneView],
        tableSize: CGSize,
        seatCount: Int,
        seatIndexForOwner: @escaping (SeatID) -> Int?
    ) -> [ResolvedPiece] {
        let card = cardSize(in: tableSize)
        var out: [ResolvedPiece] = []

        for zoneView in zones {
            let ownerSeat = zoneView.id.owner.flatMap(seatIndexForOwner)
            guard
                let placement = resolvedPlacement(
                    layout: layout,
                    zone: zoneView.id,
                    ownerSeatIndex: ownerSeat,
                    seatCount: seatCount
                )
            else { continue }

            let anchor = placement.region.resolved(in: tableSize).origin
            var cumulativeSpread: CGFloat = 0  // running y for spreadDown with per-piece face state

            for (index, piece) in zoneView.pieces.enumerated() {
                let key: RenderKey
                let faceUp: Bool
                switch piece {
                case .known(let known):
                    key = .known(known.id)
                    // A `.known` piece in a view is, by definition, one the viewer may see face-up.
                    faceUp = true
                case .hidden(let token):
                    key = .hidden(token)
                    faceUp = false
                }

                let frame = frameFor(
                    index: index,
                    faceUp: faceUp,
                    anchor: anchor,
                    card: card,
                    stacking: placement.stacking,
                    cumulativeSpread: &cumulativeSpread
                )
                out.append(
                    ResolvedPiece(
                        key: key, zone: zoneView.id, index: index, frame: frame, faceUp: faceUp)
                )
            }
        }
        return out
    }

    /// Placement for a per-seat zone uses the seat arrangement to derive the anchor when the layout does
    /// not fix it; otherwise the layout's own placement (fixed or dynamic) is used.
    private func resolvedPlacement(
        layout: TableLayout, zone: ZoneID, ownerSeatIndex: Int?, seatCount: Int
    ) -> ZonePlacement? {
        if let placement = layout.placement(
            for: zone, seatIndexForOwner: ownerSeatIndex, seatCount: seatCount)
        {
            return placement
        }
        // Fallback for an owned zone with no explicit placement: center it on the seat's anchor with a
        // right-fan, so a brand-new game still gets sensible per-seat positions with zero custom code.
        if let seatIndex = ownerSeatIndex {
            let anchor = layout.seating.anchor(seatIndex: seatIndex, count: seatCount)
            let w: CGFloat = 0.24
            let h: CGFloat = 0.14
            let region = NormalizedRect(
                x: anchor.x - w / 2, y: anchor.y - h / 2, width: w, height: h)
            return ZonePlacement(region: region, stacking: .fanRight())
        }
        return nil
    }

    /// Compute a single piece's frame from its index and the zone's stacking style.
    private func frameFor(
        index: Int,
        faceUp: Bool,
        anchor: CGPoint,
        card: CGSize,
        stacking: StackingStyle,
        cumulativeSpread: inout CGFloat
    ) -> CGRect {
        let origin: CGPoint
        switch stacking {
        case .spreadDown(let spacing, let faceDownSpacing):
            // Walk the running spread so face-down cards sit tighter than face-up ones (Klondike tableau).
            let y = anchor.y + cumulativeSpread * card.height
            cumulativeSpread += (faceUp ? spacing : faceDownSpacing)
            origin = CGPoint(x: anchor.x, y: y)
        default:
            let off = stacking.offsetFraction(index: index, count: 0, faceUp: faceUp)
            origin = CGPoint(
                x: anchor.x + off.width * card.width,
                y: anchor.y + off.height * card.height
            )
        }
        return CGRect(origin: origin, size: card)
    }
}
