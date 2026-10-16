// AI pacing — a natural, jittered thinking delay, independent of animation speed (R-AI-4.1, R-AI-4.2).
//
// An AI that answers instantly feels robotic; one that always pauses the same amount feels mechanical.
// R-AI-4.1 asks for a *natural, jittered* thinking delay with four settings — Instant / Fast / Normal /
// Relaxed — and R-AI-4.2 requires this pacing to be set INDEPENDENTLY of animation speed. This file models
// exactly that, and nothing else:
//
//   • `AIPacing` — the four settings, each mapping to a delay RANGE (min…max seconds). It is its OWN type,
//     unrelated to any animation-speed setting, which is how "independent of animation speed" is honored
//     structurally (R-AI-4.2): there is no coupling between this enum and the renderer's speed control.
//   • `jitteredDelay(using:)` — draws a delay uniformly within the setting's range using the injected RNG,
//     so the pause varies naturally yet reproducibly for a given seed (matching the AI's determinism
//     contract).
//
// COSMETIC, NOT COMPUTE (R-AI-3.3). This delay is a *cosmetic* pause the host applies AROUND the decision;
// it is explicitly EXCLUDED from the decision's compute budget (`DecisionBudget`). Pacing does not appear
// in `DecisionContext` and the toolkit's searches never consult it — a strategy computes under its budget,
// and the host separately waits out the pacing delay before revealing the move. Keeping the two apart in
// distinct types is what makes the exclusion enforceable rather than a convention.

import Foundation
import EngineCore

// MARK: - AIPacing (R-AI-4.1, R-AI-4.2)

/// The cosmetic thinking-delay setting for AI moves — Instant / Fast / Normal / Relaxed (R-AI-4.1).
///
/// Each case maps to a `delayRange` in seconds; the host draws a jittered value within it and waits that
/// long before revealing the AI's already-computed move. This is a standalone setting, deliberately NOT
/// tied to animation speed (R-AI-4.2), and its delay is NOT part of the decision budget (R-AI-3.3).
/// `CaseIterable` so Settings can list all four.
public enum AIPacing: String, Sendable, Hashable, Codable, CaseIterable {
    /// No perceptible pause — reveal the move as soon as it is computed.
    case instant
    /// A brisk pause.
    case fast
    /// A natural, human-like pause (the default).
    case normal
    /// A longer, leisurely pause.
    case relaxed

    /// The inclusive delay range (in seconds) this setting draws its jittered pause from (R-AI-4.1).
    ///
    /// Instant is a zero range (no delay); the others widen and lengthen so the pause both grows and
    /// varies more as the setting relaxes, which reads as "thinking harder". The host samples within this
    /// range via `jitteredDelay(using:)`.
    public var delayRange: ClosedRange<Double> {
        switch self {
        case .instant: return 0.0...0.0
        case .fast: return 0.15...0.40
        case .normal: return 0.40...1.10
        case .relaxed: return 0.90...2.20
        }
    }

    /// The default pacing when a player has not chosen one — a natural pause (R-AI-4.1).
    public static let `default` = AIPacing.normal

    /// Draw a jittered delay (seconds) within this setting's range using the injected RNG (R-AI-4.1,
    /// R-AI-3.2).
    ///
    /// `.instant` always returns `0`. Otherwise the value is uniform within `delayRange`, drawn from the
    /// same `SeededRNG` the AI uses so a replayed AI-vs-AI session reproduces the same pacing. The 53-bit
    /// unit draw avoids `Int.random`/`Double.random` (forbidden RNG APIs, R-ENG-4.2).
    public func jitteredDelay(using rng: inout SeededRNG) -> Double {
        let range = delayRange
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return range.lowerBound }
        let unit = Double(rng.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // uniform in [0, 1)
        return range.lowerBound + unit * span
    }
}
