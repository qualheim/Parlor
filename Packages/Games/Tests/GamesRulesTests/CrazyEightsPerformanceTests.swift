// Crazy Eights Hard AI performance coverage for task 8.3 (R-QA-6.1, R-NFR-PERF.4).
//
// The test measures the real Hard strategy through its redacted-view DecisionContext. Cosmetic pacing is
// not included; only strategy computation from context creation through the returned legal action is timed.

import AIKit
import EngineCore
import Foundation
import XCTest

@testable import GamesRules

final class CrazyEightsPerformanceTests: XCTestCase {
    /// **Validates: Requirements R-QA-6.1, R-NFR-PERF.4**
    func testHardDecisionP95StaysWithinOneSecond() async {
        let game = CrazyEights()
        let options = CrazyEightsOptions(playerCount: 2)
        let strategy = CrazyEightsHardStrategy(options: options)
        let sampleCount = 20
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)

        for sample in 0..<sampleCount {
            let state = game.initialState(options: options, seed: UInt64(0x8_3000 + sample))
            let seat = state.turn
            let legal = game.legalActions(for: seat, in: state).compactMap {
                try? AnyGameAction($0)
            }
            let context = DecisionContext(
                view: game.redactedView(of: state, for: .seat(seat)),
                publicLog: .empty,
                seat: seat,
                legalActions: legal,
                rng: SeededRNG(seed: UInt64(0xA1_0000 + sample)),
                deadline: DecisionBudget.hardDefault.deadline())

            let start = DispatchTime.now().uptimeNanoseconds
            let action = await strategy.decide(context)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            samples.append(Double(elapsed) / 1_000_000_000)

            XCTAssertNotNil(action, "Hard should return a move for sample \(sample).")
            XCTAssertTrue(
                action.map { legal.contains($0) } ?? false,
                "Hard returned an action outside the legal set for sample \(sample).")
        }

        let sorted = samples.sorted()
        let p95Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let p95 = sorted[p95Index]
        XCTAssertLessThanOrEqual(
            p95,
            DecisionBudget.hardDefault.seconds,
            "Hard decision p95 was \(p95)s; budget is \(DecisionBudget.hardDefault.seconds)s. "
                + "samples=\(samples)")
    }
}
