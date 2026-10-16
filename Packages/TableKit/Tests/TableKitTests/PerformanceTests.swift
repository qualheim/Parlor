// TableKit performance coverage for task 8.3 (R-QA-6.1, R-TABLE-7.1, R-TABLE-7.2,
// R-NFR-PERF.2, R-NFR-PERF.3, R-NFR-PERF.5).
//
// These are XCTest metric tests rather than only correctness tests. The 104-card fixture is the same
// public TableKit stress scene exposed by the app's profiling route, so a headless run measures the hot
// layout/reduction path while the UI suite measures the real SwiftUI surface.

import CoreGraphics
import EngineCore
import XCTest

@testable import TableKit

final class TableKitPerformanceTests: XCTestCase {
    private let frameBudgetNanoseconds: UInt64 = 1_000_000_000 / 60
    private let inputFeedbackBudgetNanoseconds: UInt64 = 50_000_000

    /// **Validates: Requirements R-TABLE-7.2, R-NFR-PERF.2**
    func testStressSceneContains104CardsAndResolvesWithinFrameBudget() {
        let view = PerformanceStressScene.playerView()
        XCTAssertEqual(
            view.zones.flatMap(\.pieces).count,
            PerformanceStressScene.cardCount,
            "The profiling fixture must keep the complete Spider-sized 104-card layout.")

        let resolver = LayoutResolver()
        let layout = PerformanceStressScene.layout()
        let tableSize = CGSize(width: 1280, height: 800)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
            let start = DispatchTime.now().uptimeNanoseconds
            let resolved = resolver.resolve(
                layout: layout,
                zones: view.zones,
                tableSize: tableSize,
                seatCount: 1,
                seatIndexForOwner: { _ in nil })
            let elapsed = DispatchTime.now().uptimeNanoseconds - start

            XCTAssertEqual(resolved.count, PerformanceStressScene.cardCount)
            XCTAssertLessThanOrEqual(
                elapsed,
                frameBudgetNanoseconds,
                "104-card layout resolution took \(elapsed) ns; 60 fps allows \(frameBudgetNanoseconds) ns/frame."
            )
        }
    }

    /// **Validates: Requirements R-QA-6.1, R-TABLE-7.1, R-NFR-PERF.2**
    func testDealAnimationFrameStaysWithin60FPSBudget() {
        let event = PerformanceStressScene.dealEvent()
        let timing = AnimationSettings(speed: .normal).timing()
        let layout = PerformanceStressScene.layout()
        let resolver = LayoutResolver()
        let tableSize = CGSize(width: 1280, height: 800)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
            var queue = AnimationQueue()
            queue.enqueue(event, timing: timing)
            var model = TableRenderModel()
            let start = DispatchTime.now().uptimeNanoseconds
            guard let step = queue.dequeue() else {
                XCTFail("The stress-scene deal must enqueue one animation step.")
                return
            }
            model.apply(step.event)
            let resolved = resolver.resolve(
                layout: layout,
                zones: model.zoneViews(),
                tableSize: tableSize,
                seatCount: 1,
                seatIndexForOwner: { _ in nil })
            queue.finish()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start

            XCTAssertEqual(resolved.count, PerformanceStressScene.cardCount)
            XCTAssertLessThanOrEqual(
                elapsed,
                frameBudgetNanoseconds,
                "A deal frame took \(elapsed) ns; 60 fps allows \(frameBudgetNanoseconds) ns/frame."
            )
        }
    }

    /// **Validates: Requirements R-NFR-PERF.3**
    func test104CardInputFeedbackStaysWithin50Milliseconds() {
        let initial = PerformanceStressScene.model()
        let first = PerformanceStressScene.cards()[0]
        let move = GameEvent.pieceMoved(
            PieceMoveDescriptor(
                piece: first.id,
                from: PerformanceStressScene.columnID(0),
                to: PerformanceStressScene.columnID(1),
                toIndex: 0,
                faceUp: true))
        let resolver = LayoutResolver()
        let layout = PerformanceStressScene.layout()
        let tableSize = CGSize(width: 1280, height: 800)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var model = initial
            let start = DispatchTime.now().uptimeNanoseconds
            model.apply(move)
            let resolved = resolver.resolve(
                layout: layout,
                zones: model.zoneViews(),
                tableSize: tableSize,
                seatCount: 1,
                seatIndexForOwner: { _ in nil })
            let elapsed = DispatchTime.now().uptimeNanoseconds - start

            XCTAssertEqual(resolved.count, PerformanceStressScene.cardCount)
            XCTAssertLessThanOrEqual(
                elapsed,
                inputFeedbackBudgetNanoseconds,
                "Input-to-render feedback took \(elapsed) ns; budget is \(inputFeedbackBudgetNanoseconds) ns."
            )
        }
    }
}
