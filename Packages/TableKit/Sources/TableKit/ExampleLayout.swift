// ExampleLayout — a tiny sample layout that proves the generic renderer end to end (task 3.3).
//
// This is NOT a game. It is a minimal demonstration/fixture showing that a layout authored as pure data
// resolves to sensible per-piece frames, so the generic types (`TableLayout`, `LayoutResolver`,
// `TableRenderModel`) are exercised without any game code. Klondike authors its own real layout in task
// 3.4; this stands in until then and backs the layout-resolution tests.

import CoreGraphics
import EngineCore

extension TableLayout {
    /// A small solitaire-flavored example layout: a stock top-left, a waste beside it, four foundations
    /// across the top-right, and seven tableau columns spread down. Purely illustrative (task 3.3).
    public static func example() -> TableLayout {
        var placements: [ZoneID: ZonePlacement] = [:]

        // Stock (face-down pile), top-left.
        placements[ZoneID(name: "stock")] = ZonePlacement(
            region: NormalizedRect(x: 0.04, y: 0.06, width: 0.10, height: 0.18),
            stacking: .stack()
        )
        // Waste (spread of drawn cards), to the right of the stock.
        placements[ZoneID(name: "waste")] = ZonePlacement(
            region: NormalizedRect(x: 0.17, y: 0.06, width: 0.14, height: 0.18),
            stacking: .fanRight(spacing: 0.22)
        )
        // Four foundations across the top-right.
        for i in 0..<4 {
            let x = 0.46 + CGFloat(i) * 0.13
            placements[ZoneID(name: "foundation-\(i)")] = ZonePlacement(
                region: NormalizedRect(x: x, y: 0.06, width: 0.10, height: 0.18),
                stacking: .stack()
            )
        }
        // Seven tableau columns spread down.
        for i in 0..<7 {
            let x = 0.06 + CGFloat(i) * 0.13
            placements[ZoneID(name: "tableau-\(i)")] = ZonePlacement(
                region: NormalizedRect(x: x, y: 0.34, width: 0.10, height: 0.55),
                stacking: .spreadDown()
            )
        }

        return TableLayout(placements: placements)
    }
}
