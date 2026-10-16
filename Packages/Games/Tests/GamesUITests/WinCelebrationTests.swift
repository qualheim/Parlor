// WinCelebration tests (task 5.8) — the pure, Foundation-only celebration controller (R-KLON-3.9).
//
// The celebration's VIEW is a SpriteKit overlay, but the decisions that must be correct — WHEN it fires
// (win only), WHICH style (Reduce Motion → crossfade), the ≤ 3 s hard cap, and skippability — all live in
// the pure controller so they can be tested headless. These tests drive the state machine with chosen
// elapsed times (no clock, no SpriteKit) and assert those guarantees.

import EngineCore
import GamesRules
import Testing

@testable import GamesUI

@Suite("WinCelebration — pure controller (R-KLON-3.9, R-TABLE-5.3)")
struct WinCelebrationTests {

    private let winSeat = klondikeSeat

    private func winOutcome(score: Int = 100) -> HandOutcome {
        HandOutcome(winners: [winSeat], scores: [winSeat: score])
    }

    // MARK: Trigger (R-KLON-3.9)

    @Test("a win outcome should celebrate; a no-winner outcome should not")
    func triggerOnlyOnWin() {
        #expect(shouldCelebrate(winOutcome()))
        #expect(!shouldCelebrate(.draw))
        #expect(!shouldCelebrate(HandOutcome(winners: [], scores: [winSeat: 0])))
    }

    @Test("start only fires for a win and only from idle")
    func startGuards() {
        var c = WinCelebrationController()
        #expect(c.phase == .idle)

        // No-win outcome: stays idle.
        #expect(c.start(outcome: .draw, reduceMotion: false) == false)
        #expect(c.phase == .idle)

        // Win: starts playing.
        #expect(c.start(outcome: winOutcome(), reduceMotion: false) == true)
        #expect(c.phase == .playing)
        #expect(c.isPlaying)

        // Starting again while playing is ignored.
        #expect(c.start(outcome: winOutcome(), reduceMotion: false) == false)
        #expect(c.phase == .playing)
    }

    // MARK: Style selection (R-TABLE-5.3 / R-A11Y-4.1)

    @Test("Reduce Motion picks the crossfade flourish; otherwise the cascade")
    func styleSelection() {
        #expect(CelebrationStyle.resolve(reduceMotion: false) == .cascade)
        #expect(CelebrationStyle.resolve(reduceMotion: true) == .crossfade)
        #expect(CelebrationStyle.cascade.animatesParticles)
        #expect(!CelebrationStyle.crossfade.animatesParticles)
    }

    @Test("start records the reduce-motion style")
    func startResolvesStyle() {
        var motion = WinCelebrationController()
        motion.start(outcome: winOutcome(), reduceMotion: false)
        #expect(motion.style == .cascade)

        var reduced = WinCelebrationController()
        reduced.start(outcome: winOutcome(), reduceMotion: true)
        #expect(reduced.style == .crossfade)
    }

    // MARK: Duration cap (R-KLON-3.9)

    @Test("every style's duration is within the 3 s hard cap")
    func durationWithinCap() {
        for style in CelebrationStyle.allCases {
            let d = WinCelebration.duration(for: style)
            #expect(d <= WinCelebration.maxDuration)
            #expect(d >= 0)
        }
        #expect(WinCelebration.maxDuration == 3.0)
    }

    @Test("remaining never exceeds the capped duration and clamps to zero")
    func remainingClamped() {
        var c = WinCelebrationController()
        c.start(outcome: winOutcome(), reduceMotion: false)
        let d = c.duration

        #expect(c.remaining(at: 0) == d)
        #expect(c.remaining(at: -5) == d)  // negative elapsed treated as 0
        #expect(c.remaining(at: d / 2) == d / 2)
        #expect(c.remaining(at: d) == 0)
        #expect(c.remaining(at: d + 10) == 0)  // never beyond the cap
        #expect(c.remaining(at: 100) <= WinCelebration.maxDuration)
    }

    @Test("progress runs 0…1 across the duration")
    func progressMonotonic() {
        var c = WinCelebrationController()
        c.start(outcome: winOutcome(), reduceMotion: false)
        let d = c.duration
        #expect(c.progress(at: 0) == 0)
        #expect(abs(c.progress(at: d / 2) - 0.5) < 1e-9)
        #expect(c.progress(at: d) == 1)
        #expect(c.progress(at: d * 2) == 1)
    }

    // MARK: Self-dismiss at the cap (R-KLON-3.9)

    @Test("tick ends the celebration once the capped duration elapses")
    func tickFinishesAtCap() {
        var c = WinCelebrationController()
        c.start(outcome: winOutcome(), reduceMotion: false)
        let d = c.duration

        #expect(c.tick(elapsed: d - 0.001) == false)
        #expect(c.phase == .playing)

        #expect(c.tick(elapsed: d) == true)  // the transition
        #expect(c.phase == .finished)
        #expect(c.hasFinished)
        #expect(!c.didSkip)  // ended by the cap, not a skip

        // Idempotent: further ticks do nothing.
        #expect(c.tick(elapsed: d + 5) == false)
        #expect(c.phase == .finished)
    }

    @Test("isFinished agrees with the capped duration")
    func isFinishedQuery() {
        var c = WinCelebrationController()
        #expect(!c.isFinished(at: 0))  // idle is not finished
        c.start(outcome: winOutcome(), reduceMotion: false)
        let d = c.duration
        #expect(!c.isFinished(at: d - 0.01))
        #expect(c.isFinished(at: d))
        #expect(c.isFinished(at: d + 1))
    }

    // MARK: Skip (R-KLON-3.9)

    @Test("skip ends a playing celebration early and records it")
    func skipEndsEarly() {
        var c = WinCelebrationController()
        c.start(outcome: winOutcome(), reduceMotion: false)
        #expect(c.skip() == true)
        #expect(c.phase == .finished)
        #expect(c.didSkip)
        #expect(c.remaining(at: 0) == 0)  // nothing left once skipped
    }

    @Test("skip is a no-op when idle or already finished")
    func skipNoOpWhenNotPlaying() {
        var idle = WinCelebrationController()
        #expect(idle.skip() == false)
        #expect(idle.phase == .idle)

        var done = WinCelebrationController()
        done.start(outcome: winOutcome(), reduceMotion: false)
        done.skip()
        #expect(done.skip() == false)  // second skip is a no-op
        #expect(done.phase == .finished)
    }

    // MARK: Reset

    @Test("reset returns the controller to idle")
    func resetToIdle() {
        var c = WinCelebrationController()
        c.start(outcome: winOutcome(), reduceMotion: true)
        c.skip()
        c.reset()
        #expect(c.phase == .idle)
        #expect(!c.didSkip)
        #expect(c.style == .cascade)  // back to the default
    }
}
