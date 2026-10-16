// AnimationQueue — the pure, testable animation queue core (task 5.5; R-TABLE-5.1–5.3).
//
// This is the Foundation-only heart of the table's animation policy. It carries NO SwiftUI and NO timers:
// it is a value/logic layer that answers three questions the SwiftUI driver (`AnimationDriver`) and the
// `TableView` need to render motion correctly:
//
//   1. How long should a step play? — the SPEED setting (Relaxed/Normal/Fast/Instant) maps to a duration
//      drawn from the DesignSystem `Motion` tokens, all inside the 150–350 ms band except `Instant`
//      (R-TABLE-5.1, R-TABLE-5.3).
//   2. HOW should a step move? — normally a spring SLIDE; under Reduce Motion a CROSSFADE, with
//      parallax/particles disabled and no loss of information (R-TABLE-5.3).
//   3. What plays next, and what does a FAST-FORWARD do? — the queue sequences events in order and, on a
//      click/keypress, collapses every still-pending step so it applies immediately, keeping input
//      non-blocking (R-TABLE-5.1, R-TABLE-5.2).
//
// Keeping this Foundation-only means the sequencing, speed→duration mapping, fast-forward collapse, and
// reduce-motion selection are all unit-testable headless; the SwiftUI shell (`AnimationDriver`) only has
// to turn a resolved `AnimationTiming` into a `withAnimation` call.

import DesignSystem
import EngineCore
import Foundation

// MARK: - Speed setting (R-TABLE-5.1)

/// The user-facing animation speed setting (R-TABLE-5.1).
///
/// Speed scales the *duration* of table motion, not what is shown: at every speed the same slide/crossfade
/// plays, only faster or slower. `Instant` collapses motion to a near-zero duration so state snaps into
/// place — the same near-instant token Reduce Motion uses (`Motion.instant`).
public enum AnimationSpeed: String, Sendable, Hashable, CaseIterable, Codable {
    /// Slow, followable motion (~350 ms) — the top of the default band.
    case relaxed
    /// The default table pace (~250 ms).
    case normal
    /// Brisk motion (~150 ms) — the bottom of the default band.
    case fast
    /// Near-instant: state snaps with only a hair of motion so identity stays continuous.
    case instant

    /// The DesignSystem motion token this speed plays at (R-TABLE-5.3). All but `instant` sit inside the
    /// 150–350 ms band (`Motion.defaultBand`); `instant` is deliberately below it.
    public var motionToken: MotionToken {
        switch self {
        case .relaxed: return Motion.relaxed
        case .normal: return Motion.standard
        case .fast: return Motion.quick
        case .instant: return Motion.instant
        }
    }

    /// The step duration in seconds at this speed.
    public var duration: Double { motionToken.duration }
}

// MARK: - Transition style (R-TABLE-5.3)

/// How a step's change is shown: a spring slide, or — under Reduce Motion — a crossfade (R-TABLE-5.3).
///
/// The queue never *drops* information when it swaps a slide for a crossfade: the same piece ends in the
/// same place with the same face; only the motion between differs. Parallax and particle embellishments
/// are gated off in the `crossfade` case (see `AnimationTiming.decorationsEnabled`).
public enum TransitionStyle: String, Sendable, Hashable, Codable {
    /// A physically plausible spring slide (default, motion allowed).
    case slide
    /// A crossfade with no positional parallax or particles (Reduce Motion; R-TABLE-5.3).
    case crossfade
}

// MARK: - Resolved timing for one step

/// The fully resolved animation description for a single queued step: how long, which style, and whether
/// decorative parallax/particles may play. This is what the SwiftUI driver turns into `withAnimation`.
public struct AnimationTiming: Sendable, Hashable {
    /// The motion token to animate with (its spring/duration).
    public let token: MotionToken
    /// Whether to slide or crossfade (R-TABLE-5.3).
    public let style: TransitionStyle
    /// Whether decorative parallax/particles may play. Always `false` under Reduce Motion (R-TABLE-5.3).
    public let decorationsEnabled: Bool

    public init(token: MotionToken, style: TransitionStyle, decorationsEnabled: Bool) {
        self.token = token
        self.style = style
        self.decorationsEnabled = decorationsEnabled
    }

    /// The duration in seconds this step plays for. This is the *maximum* time input may be softly blocked
    /// before the step completes; the driver keeps input responsive within it (R-TABLE-5.2).
    public var duration: Double { token.duration }
}

// MARK: - Animation settings (the seam formerly in TableRenderModel)

/// The animation-queue settings (task 5.5; R-TABLE-5). Replaces the earlier minimal placeholder seam.
///
/// A plain, `Sendable` value: the SwiftUI shell holds one and hands it to the driver/queue. It resolves a
/// per-step `AnimationTiming` from the current speed and the Reduce-Motion flag, so all timing/style logic
/// lives in one testable place.
public struct AnimationSettings: Sendable, Hashable {
    /// The current speed setting (R-TABLE-5.1).
    public var speed: AnimationSpeed
    /// Whether the system Reduce-Motion setting is on: motion becomes a crossfade and parallax/particles
    /// are disabled, with no loss of information (R-TABLE-5.3, R-A11Y-4.1).
    public var reduceMotion: Bool

    public init(speed: AnimationSpeed = .normal, reduceMotion: Bool = false) {
        self.speed = speed
        self.reduceMotion = reduceMotion
    }

    /// The default settings (Normal speed, motion on).
    public static let minimal = AnimationSettings()

    /// Resolve the timing for a step under the current settings.
    ///
    /// Reduce Motion forces a crossfade and disables decorations, and clamps the visible motion to the
    /// near-instant token so nothing slides across the table (R-TABLE-5.3). Otherwise a slide plays at the
    /// speed's token, within the 150–350 ms band (R-TABLE-5.3).
    public func timing() -> AnimationTiming {
        if reduceMotion {
            // Crossfade at a gentle, near-instant duration; no parallax/particles. A crossfade honoring
            // the chosen speed still reads as "no movement": we take the shorter of the speed token and
            // the quick token so a Relaxed setting does not produce a long, drifting fade.
            let fadeToken = speed == .instant ? Motion.instant : Motion.quick
            return AnimationTiming(token: fadeToken, style: .crossfade, decorationsEnabled: false)
        }
        return AnimationTiming(
            token: speed.motionToken, style: .slide, decorationsEnabled: speed != .instant)
    }

    /// The base spring duration in seconds for a move/flip at the current settings (design.md §6). Kept
    /// for callers that only need the number (e.g. a plain `withAnimation` outside the queue).
    public var baseDuration: Double { timing().duration }
}

// MARK: - Queue step

/// One queued unit of motion: a `GameEvent` to apply plus the timing it should play at (resolved from the
/// settings when it was enqueued). The queue plays these in FIFO order; a fast-forward collapses the
/// remaining tail into a single instant batch.
public struct AnimationStep: Sendable, Hashable {
    /// The event to apply to the render model when this step plays.
    public let event: GameEvent
    /// The resolved timing for this step (nil once collapsed → apply instantly).
    public let timing: AnimationTiming

    public init(event: GameEvent, timing: AnimationTiming) {
        self.event = event
        self.timing = timing
    }
}

// MARK: - Pure queue

/// The pure, Foundation-only animation queue (R-TABLE-5.1, R-TABLE-5.2).
///
/// It sequences steps in the order events arrive and hands them out one at a time. It never touches
/// SwiftUI or a clock: the driver asks for the next step, plays it for `timing.duration`, then asks again.
/// Because the queue only ever hands out ONE playing step at a time, input is blocked for at most the
/// duration of the animation currently playing (R-TABLE-5.2) — everything else waits, un-played, and can
/// be collapsed instantly by a fast-forward.
public struct AnimationQueue: Sendable, Hashable {
    /// The pending steps, in play order. The head is the next to play.
    public private(set) var pending: [AnimationStep]
    /// The step currently playing, if any (handed out by `dequeue()` and not yet `finish()`ed).
    public private(set) var playing: AnimationStep?

    public init() {
        self.pending = []
        self.playing = nil
    }

    /// Whether anything is left to play (a playing step or pending steps).
    public var isActive: Bool { playing != nil || !pending.isEmpty }

    /// The count of steps not yet started (excludes the one currently playing).
    public var pendingCount: Int { pending.count }

    /// Enqueue the events of a `HostMessage.events` batch, each resolved to the given timing. Events are
    /// appended in order so the deal/move sequence plays as the host emitted it (design.md §6).
    public mutating func enqueue(_ events: [GameEvent], timing: AnimationTiming) {
        for event in events { pending.append(AnimationStep(event: event, timing: timing)) }
    }

    /// Convenience: enqueue a single event.
    public mutating func enqueue(_ event: GameEvent, timing: AnimationTiming) {
        pending.append(AnimationStep(event: event, timing: timing))
    }

    /// Hand out the next step to play, moving it from `pending` to `playing`. Returns `nil` if a step is
    /// already playing (the driver must `finish()` it first) or nothing is pending. This one-at-a-time
    /// discipline is what bounds input blocking to the current animation (R-TABLE-5.2).
    public mutating func dequeue() -> AnimationStep? {
        guard playing == nil, !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        playing = next
        return next
    }

    /// Mark the currently playing step complete, freeing the queue to hand out the next.
    public mutating func finish() {
        playing = nil
    }

    /// Collapse the queue for a fast-forward (click/keypress; R-TABLE-5.1): return every step that still
    /// needs to be *applied* — the one currently playing (which the driver will complete immediately) plus
    /// all pending steps — re-timed to `instant` so they snap into place, and clear the queue.
    ///
    /// Returns the collapsed steps in play order. After this the queue is empty and idle, so input is
    /// unblocked at once (R-TABLE-5.2). Calling it on an idle queue returns an empty array.
    public mutating func fastForward() -> [AnimationStep] {
        let instant = AnimationTiming(
            token: Motion.instant, style: .slide, decorationsEnabled: false)
        var collapsed: [AnimationStep] = []
        if let playing {
            collapsed.append(AnimationStep(event: playing.event, timing: instant))
        }
        for step in pending {
            collapsed.append(AnimationStep(event: step.event, timing: instant))
        }
        pending.removeAll()
        playing = nil
        return collapsed
    }

    /// Discard everything without applying (e.g. a hard reset / new deal). Distinct from `fastForward`,
    /// which still applies the collapsed steps.
    public mutating func clear() {
        pending.removeAll()
        playing = nil
    }
}
