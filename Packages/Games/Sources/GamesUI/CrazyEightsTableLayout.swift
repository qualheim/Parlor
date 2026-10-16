// Crazy Eights table layout — declarative zones only; TableKit supplies rendering, focus, and motion.

import CoreGraphics
import GamesRules
import TableKit

extension TableLayout {
    /// A compact four-zone layout: the shared stock/discard sit in the play band and each owned hand is
    /// positioned by seat. Seat zero is the local hand at the bottom; opponents fan around the table edge.
    public static func crazyEights() -> TableLayout {
        var placements: [ZoneID: ZonePlacement] = [:]
        placements[CrazyEightsZone.stockID] = ZonePlacement(
            region: NormalizedRect(x: 0.38, y: 0.28, width: 0.10, height: 0.18),
            stacking: .stack())
        placements[CrazyEightsZone.discardID] = ZonePlacement(
            region: NormalizedRect(x: 0.53, y: 0.28, width: 0.10, height: 0.18),
            stacking: .pile())

        return TableLayout(
            placements: placements,
            seating: SeatArrangement(),
            dynamicPlacement: { zone, seatIndex, seatCount in
                guard zone.name == CrazyEightsZone.hand else { return nil }
                let index = seatIndex ?? 0
                if index == 0 {
                    return ZonePlacement(
                        region: NormalizedRect(x: 0.18, y: 0.72, width: 0.64, height: 0.16),
                        stacking: .fanRight(spacing: 0.12))
                }
                let anchor = SeatArrangement().anchor(seatIndex: index, count: seatCount)
                let width: CGFloat = 0.25
                let height: CGFloat = 0.15
                return ZonePlacement(
                    region: NormalizedRect(
                        x: anchor.x - width / 2,
                        y: anchor.y - height / 2,
                        width: width,
                        height: height),
                    stacking: .fanRight(spacing: 0.16))
            })
    }
}
