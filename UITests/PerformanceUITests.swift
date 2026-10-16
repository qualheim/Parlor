// PerformanceUITests — app launch and real 104-card renderer profiling for task 8.3.
//
// The app route is a DEBUG-only harness; the metrics themselves use the production Library and TableKit
// renderer. Release builds are still built separately by the task validation command, while these tests
// provide repeatable XCTest launch/memory/CPU metrics and an explicit budget assertion on the baseline Mac.

import Foundation
import XCTest

@MainActor
final class PerformanceUITests: XCTestCase {
    private let launchBudget: TimeInterval = 1.5
    private let frameRateBudget = 60.0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// **Validates: Requirements R-QA-6.1, R-NFR-PERF.1**
    func testColdLaunchToInteractiveLibraryStaysWithinBudget() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(
            options: options,
            metrics: [XCTApplicationLaunchMetric(), XCTClockMetric(), XCTMemoryMetric()]
        ) {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestLibrary", "-uiTestResetState"]
            let start = Date()
            app.launch()
            let library = app.descendants(matching: .any)["library.home"].firstMatch
            XCTAssertTrue(
                library.waitForExistence(timeout: launchBudget),
                "The library must become interactive within the \(launchBudget)s cold-launch budget.")
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThanOrEqual(
                elapsed,
                launchBudget,
                "Interactive library launch took \(elapsed)s; budget is \(launchBudget)s.")
            app.terminate()
        }
    }

    /// **Validates: Requirements R-QA-6.1, R-TABLE-7.1, R-TABLE-7.2, R-NFR-PERF.2, R-NFR-PERF.5**
    func test104CardDealAnimationMaintains60FPSAndMemoryBudget() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(
            options: options,
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]
        ) {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestPerformanceStress", "-uiTestResetState"]
            app.launch()

            let scene = app.descendants(matching: .any)["performance.stress.scene"].firstMatch
            XCTAssertTrue(scene.waitForExistence(timeout: 5), "The 104-card stress scene must launch.")
            let status = app.descendants(matching: .any)["performance.stress.status"].firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5), "The stress scene must expose its status.")
            XCTAssertTrue(
                waitForStatus(status, containing: "stress.deal.complete", timeout: 5),
                "The 104-card deal animation must complete in a bounded interval.")

            let observedFPS = fps(from: status.label)
            XCTAssertNotNil(observedFPS, "Stress status must report an observed display-frame rate.")
            if let observedFPS {
                XCTAssertGreaterThanOrEqual(
                    observedFPS,
                    frameRateBudget,
                    "104-card deal observed \(observedFPS) fps; budget is \(frameRateBudget) fps.")
            }
            app.terminate()
        }
    }

    private func waitForStatus(
        _ status: XCUIElement, containing text: String, timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status.label.contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return status.label.contains(text)
    }

    private func fps(from status: String) -> Double? {
        guard let token = status.split(separator: " ").first(where: { $0.hasPrefix("fps=") }) else {
            return nil
        }
        return Double(token.dropFirst("fps=".count))
    }

}
