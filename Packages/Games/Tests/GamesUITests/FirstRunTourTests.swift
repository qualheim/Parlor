// FirstRunTour tests (task 6.6) — the pure ≤ 3-step, skippable first-run tour model (R-APP-7.1).
//
// The tour overlay is a thin SwiftUI shell; the guarantees that must hold — at most 3 steps, skippable,
// shown only when not already seen, finishing exactly once — live in the pure model and are tested here
// headless (no UI, no storage).

import Foundation
import Testing

@testable import GamesUI

@Suite("FirstRunTour — pure model (R-APP-7.1)")
struct FirstRunTourTests {

    private func steps(_ n: Int) -> [TourStep] {
        (0..<n).map { TourStep(id: "s\($0)", title: "T\($0)", body: "B\($0)") }
    }

    // MARK: ≤ 3-step cap (R-APP-7.1)

    @Test("the tour keeps at most 3 steps even if handed more")
    func capsAtThree() {
        let tour = FirstRunTour(steps: steps(5))
        #expect(tour.steps.count == FirstRunTour.maxSteps)
        #expect(FirstRunTour.maxSteps == 3)
        #expect(tour.steps.map(\.id) == ["s0", "s1", "s2"])
    }

    @Test("the bundled tour is within the 3-step cap and non-empty")
    func bundledWithinCap() {
        let tour = FirstRunTour.bundled
        #expect(tour.steps.count <= FirstRunTour.maxSteps)
        #expect(!tour.steps.isEmpty)
    }

    // MARK: Presentation decision (the seen flag)

    @Test("present only when not seen and there is something to show")
    func presentDecision() {
        #expect(FirstRunTour.shouldPresent(seen: false, steps: steps(3)))
        #expect(!FirstRunTour.shouldPresent(seen: true, steps: steps(3)))
        #expect(!FirstRunTour.shouldPresent(seen: false, steps: []))
    }

    // MARK: Walking through

    @Test("advancing through every step finishes the tour")
    func advanceToFinish() {
        var tour = FirstRunTour(steps: steps(3))
        #expect(tour.currentStep?.id == "s0")
        #expect(tour.stepNumber == 1)
        #expect(!tour.isOnLastStep)

        #expect(tour.advance() == false)
        #expect(tour.currentStep?.id == "s1")

        #expect(tour.advance() == false)
        #expect(tour.currentStep?.id == "s2")
        #expect(tour.isOnLastStep)
        #expect(tour.stepNumber == 3)

        #expect(tour.advance() == true)  // past the last step → finished
        #expect(tour.isFinished)
        #expect(tour.currentStep == nil)
        #expect(!tour.didSkip)
        #expect(tour.stepNumber == 0)
    }

    @Test("advancing past the end is idempotent")
    func advanceIdempotentAfterFinish() {
        var tour = FirstRunTour(steps: steps(1))
        #expect(tour.advance() == true)
        #expect(tour.isFinished)
        #expect(tour.advance() == true)  // still finished, no crash
        #expect(tour.isFinished)
    }

    // MARK: Skip (R-APP-7.1)

    @Test("skip finishes immediately and records didSkip")
    func skipFinishes() {
        var tour = FirstRunTour(steps: steps(3))
        tour.skip()
        #expect(tour.isFinished)
        #expect(tour.didSkip)
        #expect(tour.currentStep == nil)
    }

    @Test("skip is a no-op once finished")
    func skipNoOpAfterFinish() {
        var tour = FirstRunTour(steps: steps(2))
        tour.advance()
        tour.advance()
        #expect(tour.isFinished)
        #expect(!tour.didSkip)
        tour.skip()  // already finished
        #expect(!tour.didSkip)
    }

    // MARK: Empty tour

    @Test("an empty tour is already finished with nothing to show")
    func emptyTour() {
        let tour = FirstRunTour(steps: [])
        #expect(tour.isFinished)
        #expect(tour.currentStep == nil)
    }
}
