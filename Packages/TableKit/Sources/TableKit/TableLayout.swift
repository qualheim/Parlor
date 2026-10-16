// TableLayout — a game's declarative description of where zones sit and how pieces stack (R-TABLE-1.1).
//
// This is the "(a) declarative layout" half of the generic renderer (R-TABLE-1.1): a game describes its
// table as data — which `ZoneID` goes where, how its pieces stack/fan, and how 1–9 seats are arranged —
// and TableKit turns that plus a table size into concrete per-piece frames. A NEW GAME writes only this
// data (its layout file, e.g. Klondike's in task 3.4); it never writes motion code, because the motion is
// derived generically from layout + the event stream (R-TABLE-1.2, see `TableRenderModel`).
//
// Positions are expressed in a NORMALIZED coordinate space (0…1 across the table rect) so a layout scales
// to any window size — a 1024×700 window or a 6K display resolve the same layout to proportional frames
// (R-APP-6.4). Nothing here imports a UI framework beyond the geometry types; it is pure, deterministic,
// and unit-testable without a running UI.

import CoreGraphics
import EngineCore
import Foundation

// MARK: - Stacking style (R-TABLE-1.1)

/// How the pieces of a zone are arranged relative to the zone's anchor point (R-TABLE-1.1).
///
/// The renderer applies a per-index offset derived from the style so that, e.g., a `stack` overlaps
/// tightly while a `fanRight` spreads cards to the right. Offsets are expressed as a fraction of a card's
/// size, so they scale with the resolved card size (and therefore the table). This is layout data, not
/// animation code: a game picks a style per zone and the renderer does the rest (R-TABLE-1.2).
public enum StackingStyle: Codable, Sendable, Hashable {
    /// A tight pile: each successive piece is nudged by a small fixed fraction of the card size, so the
    /// pile reads as a single stack (e.g. the stock/deck, a foundation). `dx`/`dy` are fractions of the
    /// card's width/height.
    case stack(dx: CGFloat = 0.004, dy: CGFloat = 0.004)

    /// A horizontal fan to the right: pieces step right by `spacing` × card width (e.g. a spread hand).
    case fanRight(spacing: CGFloat = 0.28)

    /// A vertical spread downward: pieces step down by `spacing` × card height (e.g. a Klondike tableau
    /// column). Optionally a smaller step for face-down pieces via `faceDownSpacing`.
    case spreadDown(spacing: CGFloat = 0.22, faceDownSpacing: CGFloat = 0.12)

    /// A messy/overlapping pile like a discard heap: a tiny deterministic per-index jitter. `magnitude`
    /// is a fraction of card size; it is derived from the index (not random) so layout stays pure and
    /// reproducible.
    case pile(magnitude: CGFloat = 0.02)

    /// The per-piece offset (in fractions of card size) for the piece at `index` among `count` pieces,
    /// given whether that piece is face-up. Returned as `(dx, dy)` fractions to be multiplied by the
    /// resolved card width/height. Pure and deterministic.
    public func offsetFraction(index: Int, count: Int, faceUp: Bool) -> CGSize {
        switch self {
        case .stack(let dx, let dy):
            return CGSize(width: dx * CGFloat(index), height: dy * CGFloat(index))
        case .fanRight(let spacing):
            return CGSize(width: spacing * CGFloat(index), height: 0)
        case .spreadDown(let spacing, let faceDownSpacing):
            // A simple uniform down-step at this piece's own spacing. This is the fallback offset;
            // `LayoutResolver` computes the EXACT cumulative spread by walking pieces in order with their
            // real per-piece face flags (so face-down cards sit tighter than face-up ones), which this
            // per-index form cannot see. Kept consistent in sign/scale for callers that use it directly.
            let step = faceUp ? spacing : faceDownSpacing
            return CGSize(width: 0, height: step * CGFloat(index))
        case .pile(let magnitude):
            // Deterministic pseudo-jitter from the index so the heap looks organic but stays reproducible.
            let seed = CGFloat((index &* 2_654_435_761) % 97) / 97 - 0.5
            let seed2 = CGFloat((index &* 40_503) % 89) / 89 - 0.5
            return CGSize(width: seed * magnitude * 2, height: seed2 * magnitude * 2)
        }
    }
}

// MARK: - Normalized rect (R-APP-6.4)

/// A rectangle in the table's normalized coordinate space, with the origin at the top-left, `x`/`y`/
/// `width`/`height` all in 0…1 (R-APP-6.4).
///
/// Multiplying a `NormalizedRect` by a concrete table size yields a pixel/point rect, which is what makes
/// a layout scale to any resolution (a 6K display and a 1024×700 window resolve the same normalized rect
/// to proportional frames).
public struct NormalizedRect: Codable, Sendable, Hashable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The center of this normalized rect (still in 0…1 space).
    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

    /// Resolve this normalized rect against a concrete table `size`, yielding a rect in points.
    public func resolved(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}

// MARK: - Zone placement (R-TABLE-1.1)

/// Where one zone sits on the table and how its pieces stack (R-TABLE-1.1).
///
/// `region` is the zone's anchor region in normalized space; the first piece is drawn at the region's
/// origin and successive pieces are offset per `stacking`. This is pure layout data authored by a game.
public struct ZonePlacement: Codable, Sendable, Hashable {
    /// The zone's anchor region in normalized (0…1) table space.
    public let region: NormalizedRect
    /// How the zone's pieces stack/fan relative to the region.
    public let stacking: StackingStyle

    public init(region: NormalizedRect, stacking: StackingStyle) {
        self.region = region
        self.stacking = stacking
    }
}

// MARK: - Seat arrangement (R-TABLE-1.1)

/// Generic seat arrangement for 1–9 seats: the local seat is bottom-center, others are placed clockwise
/// around the table edge (R-TABLE-1.1; ux table conventions).
///
/// This returns only the normalized ANCHOR POINT for each seat index; full seat plates (avatar/name/
/// score/dealer badge) are HUD work in task 5.6. A game (or the host) maps its `SeatID`s to seat indices
/// `0..<count`, with index 0 being the local viewer's seat. Purely positional and deterministic.
public struct SeatArrangement: Codable, Sendable, Hashable {
    /// How far in from the table edge each seat sits, as a fraction of the table's half-extent
    /// (0 = dead center, 1 = at the edge). Kept generous so seat zones do not overlap the center.
    public let edgeInset: CGFloat

    public init(edgeInset: CGFloat = 0.86) {
        self.edgeInset = edgeInset
    }

    /// The normalized anchor point (0…1 space) for `seatIndex` of `count` total seats (1…9).
    ///
    /// Seat 0 is the local player at bottom-center; the remaining seats are distributed clockwise around
    /// the ellipse starting from bottom and going left→top→right, matching how a player sees opponents
    /// arranged around the table. Deterministic and independent of table size (it is normalized).
    public func anchor(seatIndex: Int, count: Int) -> CGPoint {
        let clamped = max(1, min(9, count))
        let idx = ((seatIndex % clamped) + clamped) % clamped
        let center = CGPoint(x: 0.5, y: 0.5)
        // Seat 0 always sits at bottom-center.
        if idx == 0 {
            return CGPoint(x: 0.5, y: 0.5 + 0.5 * edgeInset)
        }
        // Distribute the remaining (count - 1) seats around the ellipse. Angles measured from the bottom
        // (local seat, 90° in standard math orientation) going clockwise. We advance by an even fraction
        // of the full circle per seat so seat 0 and the others are evenly spaced.
        let step = (2 * CGFloat.pi) / CGFloat(clamped)
        // Bottom is at angle +90° (pointing down in screen space where y grows downward). Going clockwise
        // in screen space means DECREASING the standard-math angle. Start below and sweep clockwise.
        let bottomAngle = CGFloat.pi / 2
        let angle = bottomAngle - step * CGFloat(idx)  // clockwise from bottom
        // Ellipse radii in normalized space (slightly wider than tall to match a table aspect).
        let rx: CGFloat = 0.5 * edgeInset
        let ry: CGFloat = 0.5 * edgeInset
        // Screen space: y grows downward, so we ADD sin() to move down from center at the bottom.
        let px = center.x + rx * cos(angle)
        let py = center.y + ry * sin(angle)
        return CGPoint(x: px, y: py)
    }
}

// MARK: - TableLayout (R-TABLE-1.1)

/// A game's complete declarative layout: fixed zone placements, an optional dynamic placement rule, and a
/// seat arrangement (R-TABLE-1.1).
///
/// A game authors one of these as pure data (Klondike's lands in task 3.4). The renderer resolves it
/// against a table size and a `PlayerView`'s zones to produce concrete per-piece frames — no per-game
/// motion code is required (R-TABLE-1.2). `dynamicPlacement` covers zones whose position depends on the
/// seat count (per-seat hands): given a `ZoneID` and seat context it returns a placement. Fixed
/// `placements` win over the dynamic rule when both match.
public struct TableLayout: Sendable {
    /// Fixed, per-`ZoneID` placements (shared table zones like stock/discard/foundations).
    public let placements: [ZoneID: ZonePlacement]

    /// Seat arrangement used to position per-seat zones (hands) around the table.
    public let seating: SeatArrangement

    /// Optional rule for zones not in `placements`: given a `ZoneID` and the seat context, return a
    /// placement (e.g. "a hand owned by seat N sits at that seat's anchor, fanned right"). Pure closure.
    public let dynamicPlacement:
        (@Sendable (_ zone: ZoneID, _ seatIndexForOwner: Int?, _ seatCount: Int) -> ZonePlacement?)?

    public init(
        placements: [ZoneID: ZonePlacement],
        seating: SeatArrangement = SeatArrangement(),
        dynamicPlacement: (
            @Sendable (_ zone: ZoneID, _ seatIndexForOwner: Int?, _ seatCount: Int) ->
                ZonePlacement?
        )? = nil
    ) {
        self.placements = placements
        self.seating = seating
        self.dynamicPlacement = dynamicPlacement
    }

    /// Resolve the placement for a zone, given the seat context. Fixed placements take precedence; then
    /// the dynamic rule; otherwise `nil` (the renderer will skip a zone it has no placement for).
    public func placement(
        for zone: ZoneID, seatIndexForOwner: Int?, seatCount: Int
    ) -> ZonePlacement? {
        if let fixed = placements[zone] { return fixed }
        return dynamicPlacement?(zone, seatIndexForOwner, seatCount)
    }
}
