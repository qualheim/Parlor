// Seat identity — who a thing belongs to at the table.
//
// A `SeatID` names a *position* at the table (not a human being): "the dealer's seat", "seat to the
// left of the lead", the seat that owns a hand zone, the seat a turn passes to. It is the identity that
// zones, events, the action log, the match model, and views all key off of (design.md §2.3–§2.9), so it
// lives here in the pure layer with the pieces rather than being redefined per game.
//
// It is a thin value type over a stable string ("seat-0", "seat-2", …). A string keeps IDs readable in
// logs and saved games and lets a game name seats however it likes, while `Hashable`/`Codable`/`Sendable`
// make it usable as a dictionary key (cumulative scores, per-seat views), round-trippable in saves, and
// safe to pass across the concurrency boundary to the host actor. It carries no seat *state* (name,
// avatar, controller) — those are session/profile concerns layered on top, keeping the engine pure.

import Foundation

/// A stable identity for a seat (a position at the table), independent of whoever occupies it.
///
/// Used as the owner of a `Zone` (R-ENG-3.1) and as the key for turns, scores, events, and per-seat
/// views throughout the engine. The `raw` string is an opaque, stable token (e.g. `"seat-0"`); treat it
/// as a handle rather than parsing meaning out of it.
public struct SeatID: Hashable, Codable, Sendable {
    /// Opaque, stable seat token, e.g. `"seat-0"`. Stability matters for saved games and replay.
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

extension SeatID {
    /// Convenience for the common `"seat-<index>"` naming used across the design's examples.
    ///
    /// This is just a naming helper; the engine never derives ordering or adjacency from the index —
    /// turn order and rotation are the match model's job (R-ENG-6).
    public static func index(_ i: Int) -> SeatID {
        SeatID(raw: "seat-\(i)")
    }
}

extension SeatID: CustomStringConvertible {
    public var description: String { raw }
}
