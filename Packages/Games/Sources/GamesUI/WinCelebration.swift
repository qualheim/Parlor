// WinCelebration — the pure, Foundation-only controller for Klondike's win celebration (task 5.8;
// R-KLON-3.9).
//
// R-KLON-3.9 asks for a short (≤ 3 s), skippable win celebration when the player wins Klondike: a homage
// to the classic cascading cards plus a modern flourish. The *visual* is a SpriteKit overlay
// (`KlondikeWinCelebrationView.swift`, the thin shell); everything that can be decided WITHOUT SpriteKit —
// when the celebration should fire, which style to play, how long it may run, and whether a skip ended it
// early — lives here so it is unit-testable headless (no SpriteKit, no clock, no SwiftUI).
//
// This file carries NO SpriteKit and NO SwiftUI: it is value/logic only, so the trigger/cap/skip/style
// decisions are unit-testable headless. It imports `TableKit` purely to reach the re-exported EngineCore
// boundary type `HandOutcome` (GamesUI's allowed dependencies are GamesRules + TableKit; design.md §1).
//
// The three testable decisions this makes:
//   1. TRIGGER (R-KLON-3.9): a celebration is warranted only for a *win* — Klondike's terminal/outcome
//      API reports the single seat as a winner (Klondike.outcome / isTerminal, task 3.1). `shouldCelebrate`
//      turns a `HandOutcome` into that yes/no.
//   2. STYLE (R-TABLE-5.3 / R-A11Y-4.1): Reduce Motion swaps the particle cascade for a static crossfade
//      flourish with no loss of the "you won" signal. `CelebrationStyle.resolve(reduceMotion:)` picks it.
//   3. DURATION + SKIP (R-KLON-3.9): the celebration is hard-capped at ≤ 3 s and a click/keypress dismisses
//      it early. `WinCelebrationController` is a small state machine (`idle → playing → finished`) that a
//      driver advances by feeding it elapsed time and a `skip()`; it never runs longer than the cap.
//
// The SpriteKit scene is the thin shell over this: it reads `style`, plays cards for `remaining(at:)`
// seconds, and calls `skip()` on input — the same fast-forward-on-input idea TableKit's `AnimationDriver`
// uses (View.fastForwardOnInput / space|return), reused by the view layer.

import Foundation
import GamesRules
import TableKit

// MARK: - Style (R-TABLE-5.3 / R-A11Y-4.1)

/// Which celebration to play. Reduce Motion never shows the moving cascade/particles; it shows a static
/// crossfade flourish instead, with the same "you won" signal preserved (R-TABLE-5.3, R-A11Y-4.1).
public enum CelebrationStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// The full homage: cascading cards bouncing down the table plus a modern particle flourish.
    case cascade
    /// Reduce-Motion alternative: a static "You won" flourish that crossfades in — no cascade, no
    /// particles, no parallax (R-TABLE-5.3). The win is still signalled clearly (R-A11Y-4.1).
    case crossfade

    /// Resolve the style for the current accessibility setting: Reduce Motion → `crossfade`, else the full
    /// `cascade` (R-TABLE-5.3, R-A11Y-4.1).
    public static func resolve(reduceMotion: Bool) -> CelebrationStyle {
        reduceMotion ? .crossfade : .cascade
    }

    /// Whether this style animates moving cards/particles. `false` for the Reduce-Motion crossfade, which
    /// gates off any parallax/particles in the view (R-TABLE-5.3).
    public var animatesParticles: Bool { self == .cascade }
}

// MARK: - Trigger (R-KLON-3.9)

/// Whether a finished hand warrants the win celebration: only a genuine win — the seat is among the
/// winners (R-KLON-3.9). A drawn/no-winner outcome does not celebrate.
///
/// Klondike's `outcome(_:)` reports `[klondikeSeat]` as the winner exactly when the board is terminal (all
/// 52 home), so this is the pure trigger the host consults when a `handEnded` arrives.
public func shouldCelebrate(_ outcome: HandOutcome) -> Bool {
    !outcome.winners.isEmpty
}

// MARK: - Duration cap (R-KLON-3.9)

/// The hard cap on the celebration's length: it SHALL be short — ≤ 3 s (R-KLON-3.9). Exposed so the view
/// and tests share the single source of truth.
public enum WinCelebration {
    /// The maximum celebration duration in seconds (R-KLON-3.9). The controller never reports the
    /// celebration playing beyond this, whether or not the player skips.
    public static let maxDuration: Double = 3.0

    /// The default full-cascade duration in seconds — the un-skipped length of the homage. Bounded to the
    /// cap so it can never exceed it even if this constant is edited upward by mistake.
    public static let cascadeDuration: Double = 2.6

    /// The default Reduce-Motion crossfade flourish duration in seconds — a brief, gentle fade, well under
    /// the cap and not a long drift (mirrors the animation queue's crossfade philosophy).
    public static let crossfadeDuration: Double = 1.0

    /// The intended (un-skipped) play duration for a style, always clamped to `maxDuration` (R-KLON-3.9).
    public static func duration(for style: CelebrationStyle) -> Double {
        let raw: Double
        switch style {
        case .cascade: raw = cascadeDuration
        case .crossfade: raw = crossfadeDuration
        }
        return min(max(0, raw), maxDuration)
    }
}

// MARK: - Controller (R-KLON-3.9)

/// The pure, clock-free state machine that governs one celebration: it starts on a win, plays a bounded
/// style, and ends either when its (capped) duration elapses or when the player skips (R-KLON-3.9).
///
/// A driver (the SpriteKit view's coordinator) owns one of these, feeds it the elapsed time since the
/// celebration began, and calls `skip()` on a click/keypress — exactly the fast-forward-on-input pattern
/// `AnimationDriver` uses. Because the controller is pure it can be unit-tested without SpriteKit or a
/// real clock: tests advance time by calling `isFinished(at:)` / `remaining(at:)` with chosen elapsed
/// values.
public struct WinCelebrationController: Sendable, Hashable {

    /// The lifecycle phases of a celebration.
    public enum Phase: String, Sendable, Hashable, Codable {
        /// Not started — no win yet (the resting state).
        case idle
        /// Actively playing the celebration (cascade or crossfade).
        case playing
        /// Ended — either the capped duration elapsed or the player skipped.
        case finished
    }

    /// The current phase.
    public private(set) var phase: Phase

    /// The resolved style for this run (fixed when the celebration starts).
    public private(set) var style: CelebrationStyle

    /// The (capped) intended duration for the chosen style in seconds (R-KLON-3.9). Never exceeds
    /// `WinCelebration.maxDuration`.
    public private(set) var duration: Double

    /// Whether the celebration was ended by an explicit skip (vs. running out its duration). Useful for a
    /// view/analytics-free test assertion; does not change the visual outcome (both end the overlay).
    public private(set) var didSkip: Bool

    /// A resting, un-started controller (no celebration).
    public init() {
        self.phase = .idle
        self.style = .cascade
        self.duration = WinCelebration.duration(for: .cascade)
        self.didSkip = false
    }

    /// Whether a celebration is currently playing (used by the view to keep the overlay on screen).
    public var isPlaying: Bool { phase == .playing }

    /// Whether the celebration has ended (the overlay should be removed).
    public var hasFinished: Bool { phase == .finished }

    /// Begin a celebration for a finished hand, if it was a win (R-KLON-3.9), choosing the style for the
    /// current Reduce-Motion setting (R-TABLE-5.3). A no-win outcome leaves the controller idle and returns
    /// `false`. Starting an already-playing controller is ignored (returns `false`).
    ///
    /// - Returns: `true` iff a celebration actually started.
    @discardableResult
    public mutating func start(outcome: HandOutcome, reduceMotion: Bool) -> Bool {
        guard phase == .idle, shouldCelebrate(outcome) else { return false }
        let resolved = CelebrationStyle.resolve(reduceMotion: reduceMotion)
        style = resolved
        duration = WinCelebration.duration(for: resolved)
        didSkip = false
        phase = .playing
        return true
    }

    /// The seconds of celebration remaining at `elapsed` seconds since it started. Clamped to `[0,
    /// duration]` and always `0` once finished, so it never reports time beyond the (capped) duration
    /// (R-KLON-3.9). On an idle controller this is `0`.
    public func remaining(at elapsed: Double) -> Double {
        guard phase == .playing else { return 0 }
        return max(0, duration - max(0, elapsed))
    }

    /// The fraction of the celebration completed at `elapsed` seconds, in `[0, 1]`. `1` once finished or
    /// when the duration is zero. Drives the view's progress if it wants a wind-down.
    public func progress(at elapsed: Double) -> Double {
        guard phase == .playing, duration > 0 else { return 1 }
        return min(1, max(0, elapsed) / duration)
    }

    /// Whether the celebration should be over at `elapsed` seconds — its (capped) duration has elapsed
    /// (R-KLON-3.9). Pure query; `tick(elapsed:)` uses it to transition.
    public func isFinished(at elapsed: Double) -> Bool {
        guard phase == .playing else { return phase == .finished }
        return max(0, elapsed) >= duration
    }

    /// Advance the state machine to `elapsed` seconds since start: if the (capped) duration has elapsed,
    /// transition to `finished` (R-KLON-3.9). Idempotent and monotonic — once finished it stays finished.
    ///
    /// - Returns: `true` if this tick ended the celebration (a `playing → finished` transition happened).
    @discardableResult
    public mutating func tick(elapsed: Double) -> Bool {
        guard phase == .playing else { return false }
        if max(0, elapsed) >= duration {
            phase = .finished
            return true
        }
        return false
    }

    /// Skip the celebration immediately (a click/keypress; R-KLON-3.9), ending it early. Mirrors
    /// `AnimationDriver.fastForward`: safe to call at any time — a no-op unless a celebration is playing.
    ///
    /// - Returns: `true` if this call ended a playing celebration.
    @discardableResult
    public mutating func skip() -> Bool {
        guard phase == .playing else { return false }
        didSkip = true
        phase = .finished
        return true
    }

    /// Reset to the resting idle state (e.g. a new deal), discarding any in-flight celebration.
    public mutating func reset() {
        self = WinCelebrationController()
    }
}
