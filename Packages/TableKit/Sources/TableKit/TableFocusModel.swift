// TableFocusModel — pure keyboard-navigation logic with a visible focus target (R-TABLE-3.4, R-A11Y-2).
//
// Full keyboard play is a hard requirement: every game must be completable keyboard-only, with a visible
// focus indicator (R-A11Y-2.1, R-TABLE-3.4). The MOVEMENT rule — "given the current focus, a direction,
// and the set of zones and the pieces within them, what is the next focus?" — is pure logic, so it lives
// here as a deterministic function and is unit-tested without a running UI. The interaction view
// (`TableInteractionView`) owns a `@FocusState`-backed focus, renders a ring on the focused target, and
// on each arrow key calls `TableFocusModel.next(...)`; select/place/cancel map to space/return/escape and
// drive the `TableInteractionModel`.
//
// The navigation MODEL is a simple two-level topology: a horizontal ring of zones, and, within a zone, a
// vertical stack of pieces (bottom→top, matching `ZoneView` order). Left/Right move between zones;
// Up/Down move between the focused zone's pieces. This is game-agnostic — it reads only the resolved
// zones/pieces the renderer already produces, so a new game gets keyboard nav for free (R-TABLE-1.2).

import EngineCore
import Foundation

// MARK: - Focus target (R-TABLE-3.4)

/// What currently holds keyboard focus: a whole zone, or a specific piece within a zone (R-TABLE-3.4).
///
/// Focus starts on a zone (so an empty pile is still reachable and can be a place target); pressing
/// Down/Up moves into and through the zone's pieces. The view rings whatever this points at, giving the
/// visible focus indicator R-A11Y-2 requires.
public enum FocusTarget: Sendable, Hashable {
    /// The whole zone is focused (no specific piece) — e.g. an empty pile, or the zone header.
    case zone(ZoneID)
    /// A specific piece within a zone is focused, identified by its stable render key.
    case piece(RenderKey, in: ZoneID)

    /// The zone this focus belongs to, whichever case it is.
    public var zone: ZoneID {
        switch self {
        case .zone(let z): return z
        case .piece(_, let z): return z
        }
    }
}

// MARK: - Direction

/// A keyboard navigation direction (the four arrow keys) (R-TABLE-3.4).
public enum FocusDirection: Sendable, Hashable {
    case left
    case right
    case up
    case down
}

// MARK: - Focusable topology

/// The zones and their ordered pieces that keyboard focus can traverse (R-TABLE-3.4).
///
/// The interaction view builds one of these from the resolved pieces each refresh: `zoneOrder` is the
/// left→right ring of zones the player tabs between, and `pieces(in:)` gives a zone's pieces bottom→top
/// (matching `ZoneView`/`ResolvedPiece` order) for up/down traversal. Purely positional data; no rules.
public struct FocusTopology: Sendable, Hashable {
    /// The zones in left→right focus order (the horizontal ring).
    public let zoneOrder: [ZoneID]
    /// Each zone's pieces in bottom→top order (the vertical stack within a zone).
    public let piecesByZone: [ZoneID: [RenderKey]]

    public init(zoneOrder: [ZoneID], piecesByZone: [ZoneID: [RenderKey]]) {
        self.zoneOrder = zoneOrder
        self.piecesByZone = piecesByZone
    }

    /// The pieces in `zone`, bottom→top; empty if the zone has none.
    public func pieces(in zone: ZoneID) -> [RenderKey] {
        piecesByZone[zone] ?? []
    }

    /// Build a topology from resolved pieces and an explicit zone order.
    ///
    /// `zoneOrder` fixes the horizontal ring (a game's layout knows a sensible left→right order — e.g.
    /// stock, waste, foundations, tableaux); pieces within each zone are ordered by their `index`
    /// (bottom→top). Zones in `zoneOrder` with no pieces are kept (so empty piles stay focusable and can
    /// be place targets, R-KLON-1.4).
    public static func from(
        resolved: [ResolvedPiece], zoneOrder: [ZoneID]
    ) -> FocusTopology {
        var byZone: [ZoneID: [(Int, RenderKey)]] = [:]
        for piece in resolved {
            byZone[piece.zone, default: []].append((piece.index, piece.key))
        }
        var piecesByZone: [ZoneID: [RenderKey]] = [:]
        for (zone, entries) in byZone {
            piecesByZone[zone] = entries.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        // Ensure every ordered zone has an entry (possibly empty) so it stays focusable.
        for zone in zoneOrder where piecesByZone[zone] == nil {
            piecesByZone[zone] = []
        }
        return FocusTopology(zoneOrder: zoneOrder, piecesByZone: piecesByZone)
    }
}

// MARK: - Focus model (pure)

/// Pure keyboard-focus logic: the next-focus computation and the initial focus (R-TABLE-3.4, R-A11Y-2).
///
/// Stateless — the current focus is passed in and a new focus is returned, so the movement rule is a pure
/// function the tests can pin exactly (wrap/clamp behaviour per direction). The interaction view holds the
/// current `FocusTarget` and calls `next(...)` on each arrow key.
public enum TableFocusModel {
    /// The initial focus for a topology: the first zone in the ring, or `nil` if there are no zones.
    ///
    /// Starting on a *zone* (not a piece) means an empty table or an empty pile still has a valid focus,
    /// and Down then descends into pieces.
    public static func initialFocus(_ topology: FocusTopology) -> FocusTarget? {
        guard let first = topology.zoneOrder.first else { return nil }
        return .zone(first)
    }

    /// Compute the next focus from `current`, moving `direction` over `topology` (R-TABLE-3.4).
    ///
    /// Rules (game-agnostic):
    ///   • Left/Right move between ZONES along `zoneOrder`, wrapping around the ends. Moving to a new zone
    ///     lands on the whole zone (`.zone`), not a piece, so the player can then descend with Down.
    ///   • Down moves DOWN the stack toward the top piece: from a `.zone` it enters the zone's first
    ///     (bottom) piece; from a `.piece` it advances to the next piece, CLAMPING at the top (no wrap, so
    ///     repeated Down settles on the top card — the usual move candidate).
    ///   • Up moves UP toward the zone: from a `.piece` it steps to the previous piece, and stepping above
    ///     the bottom piece returns to the whole `.zone`; from a `.zone` it stays on the zone (clamp).
    ///   • An empty zone has no pieces, so Down/Up leave focus on the zone.
    /// If `current`'s zone is not in the topology (stale), focus resets to the initial focus.
    public static func next(
        from current: FocusTarget, direction: FocusDirection, in topology: FocusTopology
    ) -> FocusTarget {
        let zones = topology.zoneOrder
        guard !zones.isEmpty else { return current }
        guard let zoneIndex = zones.firstIndex(of: current.zone) else {
            return initialFocus(topology) ?? current
        }

        switch direction {
        case .left:
            let next = (zoneIndex - 1 + zones.count) % zones.count
            return .zone(zones[next])
        case .right:
            let next = (zoneIndex + 1) % zones.count
            return .zone(zones[next])
        case .down:
            return descend(current, zone: current.zone, in: topology)
        case .up:
            return ascend(current, zone: current.zone, in: topology)
        }
    }

    // MARK: Vertical traversal within a zone

    private static func descend(
        _ current: FocusTarget, zone: ZoneID, in topology: FocusTopology
    ) -> FocusTarget {
        let pieces = topology.pieces(in: zone)
        guard !pieces.isEmpty else { return .zone(zone) }
        switch current {
        case .zone:
            return .piece(pieces[0], in: zone)
        case .piece(let key, _):
            guard let idx = pieces.firstIndex(of: key) else { return .piece(pieces[0], in: zone) }
            let next = min(idx + 1, pieces.count - 1)  // clamp at the top piece
            return .piece(pieces[next], in: zone)
        }
    }

    private static func ascend(
        _ current: FocusTarget, zone: ZoneID, in topology: FocusTopology
    ) -> FocusTarget {
        let pieces = topology.pieces(in: zone)
        switch current {
        case .zone:
            return .zone(zone)  // already at the top of this zone's column; clamp
        case .piece(let key, _):
            guard let idx = pieces.firstIndex(of: key) else { return .zone(zone) }
            if idx == 0 {
                return .zone(zone)  // stepping above the bottom piece returns to the zone
            }
            return .piece(pieces[idx - 1], in: zone)
        }
    }
}
