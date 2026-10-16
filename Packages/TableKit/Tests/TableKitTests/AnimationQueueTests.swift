import DesignSystem
import EngineCore
import Foundation
import Testing

@testable import TableKit

// Tests for task 5.5 — the pure animation-queue core (R-TABLE-5.1–5.3).
//
// The queue, speed→duration mapping, fast-forward collapse, and reduce-motion selection are all
// Foundation-only value logic, so this file exercises them headless (no SwiftUI, no clock). Both
// example-based unit tests and hand-rolled property tests (deterministic over `SeededRNG`, matching the
// repo's `ViewLeakPropertyTests` convention) are included — the properties assert the universal
// guarantees the requirements state, the units pin specific behaviors.

// MARK: - Fixtures

private func pid(_ n: UInt64) -> PieceID { PieceID(raw: n) }

private func deal(_ n: UInt64) -> GameEvent {
    .dealt(pieces: [
        PieceMoveDescriptor(
            piece: pid(n), from: nil, to: ZoneID(name: "stock"), toIndex: 0, faceUp: false)
    ])
}

private func move(_ n: UInt64, to zone: String) -> GameEvent {
    .pieceMoved(
        PieceMoveDescriptor(
            piece: pid(n), from: ZoneID(name: "stock"), to: ZoneID(name: zone), toIndex: 0,
            faceUp: true))
}

// MARK: - Speed → duration mapping (R-TABLE-5.1, R-TABLE-5.3)

@Suite("Speed setting maps to durations in the 150–350 ms band (R-TABLE-5.3)")
struct AnimationSpeedTests {
    @Test(
        "Relaxed/Normal/Fast durations sit inside the 150–350 ms default band",
        arguments: [AnimationSpeed.relaxed, .normal, .fast])
    func nonInstantSpeedsInBand(_ speed: AnimationSpeed) {
        #expect(
            Motion.defaultBand.contains(speed.duration),
            "\(speed) duration \(speed.duration) is outside the 150–350 ms band")
    }

    @Test("Instant is deliberately below the band (state snaps)")
    func instantBelowBand() {
        #expect(!Motion.defaultBand.contains(AnimationSpeed.instant.duration))
        #expect(AnimationSpeed.instant.duration < Motion.defaultBand.lowerBound)
    }

    @Test("speeds are ordered Relaxed > Normal > Fast > Instant by duration")
    func speedsOrderedByDuration() {
        #expect(AnimationSpeed.relaxed.duration > AnimationSpeed.normal.duration)
        #expect(AnimationSpeed.normal.duration > AnimationSpeed.fast.duration)
        #expect(AnimationSpeed.fast.duration > AnimationSpeed.instant.duration)
    }

    @Test("every speed is representable and round-trips through its raw value")
    func speedsRoundTrip() {
        for speed in AnimationSpeed.allCases {
            #expect(AnimationSpeed(rawValue: speed.rawValue) == speed)
        }
    }
}

// MARK: - Reduce-Motion selection (R-TABLE-5.3)

@Suite("Reduce Motion swaps slides for crossfades and disables decorations (R-TABLE-5.3)")
struct ReduceMotionTests {
    @Test(
        "motion on → slide with decorations for non-instant speeds",
        arguments: [
            AnimationSpeed.relaxed, .normal, .fast,
        ])
    func motionOnSlides(_ speed: AnimationSpeed) {
        let timing = AnimationSettings(speed: speed, reduceMotion: false).timing()
        #expect(timing.style == .slide)
        #expect(timing.decorationsEnabled)
    }

    @Test("Instant speed slides but disables decorations even with motion on")
    func instantDisablesDecorations() {
        let timing = AnimationSettings(speed: .instant, reduceMotion: false).timing()
        #expect(timing.style == .slide)
        #expect(!timing.decorationsEnabled)
    }

    @Test(
        "Reduce Motion → crossfade with NO decorations at every speed (no parallax/particles)",
        arguments: AnimationSpeed.allCases)
    func reduceMotionCrossfades(_ speed: AnimationSpeed) {
        let timing = AnimationSettings(speed: speed, reduceMotion: true).timing()
        #expect(timing.style == .crossfade, "\(speed) under Reduce Motion should crossfade")
        #expect(!timing.decorationsEnabled, "\(speed) under Reduce Motion must disable decorations")
    }

    @Test(
        "Reduce Motion never produces a long drifting fade (bounded by quick token)",
        arguments: AnimationSpeed.allCases)
    func reduceMotionBoundedDuration(_ speed: AnimationSpeed) {
        let timing = AnimationSettings(speed: speed, reduceMotion: true).timing()
        #expect(timing.duration <= Motion.quick.duration + 1e-9)
    }
}

// MARK: - Queue sequencing (R-TABLE-5.1)

@Suite("Queue sequences steps FIFO, one in flight at a time")
struct QueueSequencingTests {
    private let timing = AnimationSettings().timing()

    @Test("enqueued events dequeue in the order they arrived")
    func fifoOrder() {
        var queue = AnimationQueue()
        queue.enqueue([deal(1), deal(2), deal(3)], timing: timing)
        #expect(queue.pendingCount == 3)

        let first = queue.dequeue()
        #expect(first?.event == deal(1))
        // A second dequeue is refused while one is playing (one in flight → non-blocking; R-TABLE-5.2).
        #expect(queue.dequeue() == nil)

        queue.finish()
        #expect(queue.dequeue()?.event == deal(2))
        queue.finish()
        #expect(queue.dequeue()?.event == deal(3))
        queue.finish()
        #expect(queue.dequeue() == nil)
        #expect(!queue.isActive)
    }

    @Test("isActive reflects playing or pending work")
    func isActiveTracking() {
        var queue = AnimationQueue()
        #expect(!queue.isActive)
        queue.enqueue(deal(1), timing: timing)
        #expect(queue.isActive)  // pending
        _ = queue.dequeue()
        #expect(queue.isActive)  // playing
        queue.finish()
        #expect(!queue.isActive)  // drained
    }

    @Test("only one step plays at a time — dequeue is refused until finish()")
    func oneInFlight() {
        var queue = AnimationQueue()
        queue.enqueue([deal(1), deal(2)], timing: timing)
        #expect(queue.dequeue() != nil)
        #expect(queue.dequeue() == nil)  // blocked until finish
        #expect(queue.pendingCount == 1)  // the second is still pending, un-played
    }
}

// MARK: - Fast-forward collapse (R-TABLE-5.1, R-TABLE-5.2)

@Suite("Fast-forward collapses the queue to instant and unblocks (R-TABLE-5.1)")
struct FastForwardTests {
    private let timing = AnimationSettings().timing()

    @Test("fast-forward returns the playing + all pending steps, in order, re-timed to instant")
    func collapsesAllStepsInstant() {
        var queue = AnimationQueue()
        queue.enqueue([deal(1), move(1, to: "waste"), deal(2)], timing: timing)
        _ = queue.dequeue()  // deal(1) now playing

        let collapsed = queue.fastForward()
        #expect(collapsed.count == 3)
        #expect(collapsed.map(\.event) == [deal(1), move(1, to: "waste"), deal(2)])
        #expect(collapsed.allSatisfy { $0.timing.duration == Motion.instant.duration })
        // The queue is empty and idle afterwards → input unblocked immediately (R-TABLE-5.2).
        #expect(!queue.isActive)
        #expect(queue.pendingCount == 0)
    }

    @Test("fast-forward on an idle queue returns nothing and stays idle")
    func fastForwardIdleNoop() {
        var queue = AnimationQueue()
        #expect(queue.fastForward().isEmpty)
        #expect(!queue.isActive)
    }

    @Test("fast-forward preserves every event exactly once (no drop, no dupe)")
    func fastForwardPreservesEvents() {
        var queue = AnimationQueue()
        let events = [deal(1), deal(2), deal(3), move(2, to: "foundation-0")]
        queue.enqueue(events, timing: timing)
        _ = queue.dequeue()
        let collapsed = queue.fastForward().map(\.event)
        #expect(collapsed == events)
    }

    @Test("clear discards without applying and leaves the queue idle")
    func clearDiscards() {
        var queue = AnimationQueue()
        queue.enqueue([deal(1), deal(2)], timing: timing)
        _ = queue.dequeue()
        queue.clear()
        #expect(!queue.isActive)
        #expect(queue.fastForward().isEmpty)
    }
}

// MARK: - Property tests (deterministic over SeededRNG; R-QA convention)

@Suite("Animation-queue properties hold across random event batches")
struct AnimationQueuePropertyTests {
    /// A random batch of geometry events derived from a seed, so a failure is reproducible.
    private func randomEvents(seed: UInt64) -> [GameEvent] {
        var rng = SeededRNG(seed: seed)
        let count = Int(rng.next() % 12) + 1  // 1...12 events
        var events: [GameEvent] = []
        for i in 0..<count {
            let id = UInt64(i) + 1
            events.append(rng.next() & 1 == 0 ? deal(id) : move(id, to: "waste"))
        }
        return events
    }

    @Test(
        "PROPERTY: fully draining the queue yields exactly the enqueued events in order",
        arguments: 0..<200 as Range<UInt64>)
    func drainPreservesOrder(seed: UInt64) {
        let events = randomEvents(seed: seed)
        var queue = AnimationQueue()
        queue.enqueue(events, timing: AnimationSettings().timing())
        var drained: [GameEvent] = []
        while let step = queue.dequeue() {
            drained.append(step.event)
            queue.finish()
        }
        #expect(drained == events, "seed \(seed): drain order diverged")
        #expect(!queue.isActive)
    }

    @Test(
        "PROPERTY: fast-forward at any point preserves the multiset of remaining events",
        arguments: 0..<200 as Range<UInt64>)
    func fastForwardPreservesRemaining(seed: UInt64) {
        let events = randomEvents(seed: seed)
        var rng = SeededRNG(seed: seed &+ 1)
        let playedBefore = Int(rng.next() % UInt64(events.count + 1))  // 0...count finished first

        var queue = AnimationQueue()
        queue.enqueue(events, timing: AnimationSettings().timing())

        var applied: [GameEvent] = []
        for _ in 0..<playedBefore {
            if let step = queue.dequeue() {
                applied.append(step.event)
                queue.finish()
            }
        }
        // Fast-forward the rest.
        let collapsed = queue.fastForward().map(\.event)
        #expect(applied + collapsed == events, "seed \(seed): fast-forward lost/duplicated events")
        #expect(!queue.isActive, "seed \(seed): queue not unblocked after fast-forward")
    }

    @Test(
        "PROPERTY: no dequeued step ever blocks longer than the animation currently playing",
        arguments: AnimationSpeed.allCases)
    func nonBlockingBoundedByCurrentStep(speed: AnimationSpeed) {
        // R-TABLE-5.2: with one step in flight, the only time input waits is the current step's duration,
        // which for a real (non-instant) speed is within the 150–350 ms band, and for instant is tiny.
        let settings = AnimationSettings(speed: speed, reduceMotion: false)
        let timing = settings.timing()
        var queue = AnimationQueue()
        queue.enqueue([deal(1), deal(2), deal(3)], timing: timing)
        let step = queue.dequeue()
        #expect(step != nil)
        let bound =
            speed == .instant ? Motion.defaultBand.lowerBound : Motion.defaultBand.upperBound
        #expect(step!.timing.duration <= bound + 1e-9)
    }
}
