// AnimationDriver — the SwiftUI application layer that plays the pure `AnimationQueue` (task 5.5).
//
// The queue itself (`AnimationQueue.swift`) is Foundation-only and knows nothing about time or SwiftUI.
// This driver is the thin shell that gives it a clock and a `withAnimation`: it owns the `TableRenderModel`
// the `TableView` renders, holds the pending queue, and steps through it one animation at a time. It is
// `@MainActor @Observable` so a SwiftUI host binds to `model` and re-renders as each step applies — the
// same "pure core, thin observable shell" split used by `ThemePackStore` and `LocalProfileStore`.
//
// How the requirements are met:
//   • Sequencing + speed (R-TABLE-5.1): `enqueue(_:)` resolves each event to an `AnimationTiming` from the
//     current `AnimationSettings` (speed → duration) and appends it; `playNext()` applies the head inside
//     `withAnimation(timing…)` and schedules the following step after `timing.duration`.
//   • Non-blocking (R-TABLE-5.2): only ONE step is ever "playing"; the rest sit un-applied in the queue.
//     Input is therefore softly blocked for at most the current step's duration, never the whole batch,
//     and `fastForward()` empties the queue instantly on demand.
//   • Fast-forward on click/keypress (R-TABLE-5.1): `fastForward()` collapses the playing + pending steps
//     to `Motion.instant` and applies them all at once, then unblocks; the host wires it to a tap gesture
//     and a key handler via `fastForwardOnInput()`.
//   • Reduce Motion (R-TABLE-5.3): when `settings.reduceMotion` is on, each step resolves to a crossfade
//     with decorations disabled; `decorationsEnabled` gates any parallax/particles the host may add.

import DesignSystem
import EngineCore
import SwiftUI

/// Drives the animation queue for a table: owns the render model, sequences queued events at the current
/// speed, and supports click/keypress fast-forward (R-TABLE-5.1–5.3).
///
/// Usage: the SwiftUI host creates one `AnimationDriver`, feeds it each `HostMessage.events` batch via
/// `enqueue(_:)`, and renders `driver.model` in a `TableView`. `driver.timing.decorationsEnabled` tells
/// the host whether parallax/particles may play for the step currently on screen.
@MainActor
@Observable
public final class AnimationDriver {
    /// The live render model the `TableView` draws. Advanced one step at a time as the queue plays.
    public private(set) var model: TableRenderModel

    /// The animation settings (speed + reduce-motion). Set by the host from user settings / the system
    /// Reduce-Motion flag; changes apply to steps enqueued afterwards.
    public var settings: AnimationSettings

    /// The pure queue of pending/playing steps.
    private var queue = AnimationQueue()

    /// A monotonically increasing token that invalidates a scheduled advance when the queue is collapsed
    /// or cleared, so a stale delayed continuation can't resurrect a fast-forwarded step.
    private var generation = 0

    /// The timing of the step currently on screen (defaults to the settings' resting timing when idle).
    /// The host reads `decorationsEnabled`/`style` to gate parallax/particles for the current motion.
    public private(set) var timing: AnimationTiming

    /// Whether the queue still has work (a playing or pending step). Useful to gate a "skip" affordance.
    public var isAnimating: Bool { queue.isActive }

    /// Create a driver.
    ///
    /// - Parameters:
    ///   - model: the initial render model (usually built from the first `PlayerView`).
    ///   - settings: the animation settings (speed + reduce-motion).
    public init(
        model: TableRenderModel = TableRenderModel(), settings: AnimationSettings = .minimal
    ) {
        self.model = model
        self.settings = settings
        self.timing = settings.timing()
    }

    // MARK: Enqueue

    /// Enqueue a batch of host events (a `HostMessage.events` payload) to play in order at the current
    /// speed (R-TABLE-5.1). Starts playing if idle.
    public func enqueue(_ events: [GameEvent]) {
        let stepTiming = settings.timing()
        queue.enqueue(events, timing: stepTiming)
        playNextIfIdle()
    }

    /// Enqueue a single event.
    public func enqueue(_ event: GameEvent) { enqueue([event]) }

    // MARK: Playback

    /// If nothing is currently playing, hand out and play the next queued step.
    private func playNextIfIdle() {
        guard queue.playing == nil else { return }
        playNext()
    }

    /// Play the head of the queue: apply its event inside `withAnimation` and schedule the following step
    /// after the step's duration. One step in flight at a time keeps input non-blocking (R-TABLE-5.2).
    private func playNext() {
        guard let step = queue.dequeue() else {
            // Idle: settle the reported timing back to the resting value for the current settings.
            timing = settings.timing()
            return
        }
        timing = step.timing
        apply(step.event, with: step.timing)

        generation += 1
        let token = generation
        let delay = max(0, step.timing.duration)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.generation == token else { return }
            self.queue.finish()
            self.playNext()
        }
    }

    /// Apply one event to the model inside a `withAnimation` matching its timing. A crossfade still uses a
    /// spring (SwiftUI interpolates the matched-geometry frames); the *visual* difference between slide and
    /// crossfade is realized by the host's transition on the piece views keyed off `timing.style`.
    private func apply(_ event: GameEvent, with timing: AnimationTiming) {
        withAnimation(timing.token.swiftUIAnimation) {
            model.apply(event)
        }
    }

    // MARK: Fast-forward (R-TABLE-5.1)

    /// Fast-forward: collapse everything still pending (plus the step playing) and apply it instantly, then
    /// unblock (R-TABLE-5.1, R-TABLE-5.2). Wire to a click and a keypress via `fastForwardOnInput()`.
    ///
    /// Safe to call when idle (does nothing). Invalidates any scheduled advance so a stale timer can't
    /// re-play a collapsed step.
    public func fastForward() {
        let collapsed = queue.fastForward()
        guard !collapsed.isEmpty else { return }
        generation += 1  // invalidate any in-flight scheduled advance
        for step in collapsed { model.apply(step.event) }
        timing = settings.timing()
    }

    /// Reconcile the live model to a fresh `PlayerView` inside a `withAnimation`, so the table animates to
    /// exactly what the host says the viewer can now see (the single source of truth, design.md §2.8/§6).
    ///
    /// This is the driver-level counterpart to `TableRenderModel.reconcile(to:)`: after the host accepts an
    /// action, the controller calls this with the fresh redacted view. Any pending/playing queued steps are
    /// discarded first (the view supersedes them), then the model is reconciled under the current timing so
    /// matched geometry slides moved cards and crossfades a hidden→known reveal. Known pieces keep their
    /// `RenderKey`, so untouched cards do not jump; new/removed pieces appear/disappear.
    public func reconcile(to playerView: PlayerView) {
        // Invalidate any in-flight scheduled advance; the fresh view is now authoritative.
        generation += 1
        queue.clear()
        let target = model.reconciling(to: playerView)
        guard target != model else {
            timing = settings.timing()
            return
        }
        withAnimation(settings.timing().token.swiftUIAnimation) {
            model = target
        }
        timing = settings.timing()
    }

    /// Discard all pending/playing steps without applying them (e.g. a new deal / hard reset). Distinct
    /// from `fastForward`, which still applies the collapsed steps.
    public func reset(to model: TableRenderModel) {
        generation += 1
        queue.clear()
        self.model = model
        timing = settings.timing()
    }
}

// MARK: - View wiring (fast-forward on click / keypress)

extension View {
    /// Fast-forward the driver's queue on a click anywhere on this view or on the space/return key
    /// (R-TABLE-5.1). Layer this over the table so a player can skip a long deal.
    ///
    /// The tap gesture is `simultaneous` so it does not steal drag/selection gestures the interaction layer
    /// installs; it only collapses in-flight animation. The key handler covers keyboard-only play
    /// (R-A11Y-2): pressing space or return while animation is running snaps it to completion.
    public func fastForwardOnInput(_ driver: AnimationDriver) -> some View {
        self
            .simultaneousGesture(TapGesture().onEnded { driver.fastForward() })
            .onKeyPress { press in
                guard driver.isAnimating else { return .ignored }
                switch press.key {
                case .space, .return:
                    driver.fastForward()
                    return .handled
                default:
                    return .ignored
                }
            }
    }
}
