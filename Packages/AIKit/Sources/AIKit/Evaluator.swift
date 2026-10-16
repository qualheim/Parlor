// Evaluator helpers — small reusable scoring utilities games' evaluators compose (R-AI-2.2, R-AI-5.1).
//
// Every tier ultimately picks a move by scoring candidates and taking the best. Rather than each game
// reimplementing argmax, tie-breaking, and persona bias, AIKit provides the generic primitives:
//
//   • `argMax` — pick the highest-scoring element, breaking ties with the injected RNG so equal choices
//     are still reproducible (R-AI-3.2) and not biased toward the first (R-AI-2.2).
//   • `styleBias` / `applyingStyle` — fold a `PersonaStyle` (aggression, riskTolerance) into a score, so a
//     persona's character shows up in its play (R-AI-5.1). A game tags each candidate with how aggressive
//     / how risky it is; the helper weights the base score by the persona's knobs.
//   • `softmaxIndex` — sample an index proportional to score (for a nondeterministic-but-reproducible pick,
//     e.g. an Easy tier that should not always play the same move), again via the injected RNG.
//
// All helpers are pure, generic, and draw randomness only from an injected `SeededRNG` (R-AI-3.2) — never
// `Int.random`/`SystemRandomNumberGenerator` (forbidden, R-ENG-4.2).

import Foundation
import EngineCore

// MARK: - Evaluator (R-AI-2.2, R-AI-5.1)

/// Generic evaluation utilities games' AIs compose — argmax, persona-style weighting, and RNG-driven
/// tie-breaking / sampling (R-AI-2.2, R-AI-5.1).
public enum Evaluator {
    /// The element of `items` with the highest `score`, breaking ties uniformly with the injected RNG
    /// (R-AI-2.2, R-AI-3.2).
    ///
    /// Collecting all maximal elements and drawing one via `rng` means equal-value choices are chosen
    /// fairly and reproducibly, not always the first. Returns `nil` for an empty input. Uses a small
    /// epsilon so floating-point scores that are equal "in spirit" tie together.
    public static func argMax<Item>(
        _ items: [Item],
        score: (Item) -> Double,
        using rng: inout SeededRNG,
        epsilon: Double = 1e-9
    ) -> Item? {
        guard !items.isEmpty else { return nil }
        var best = -Double.infinity
        for item in items {
            let s = score(item)
            if s > best { best = s }
        }
        let leaders = items.filter { score($0) >= best - epsilon }
        if leaders.count == 1 { return leaders[0] }
        let index = Int(rng.next() % UInt64(leaders.count))
        return leaders[index]
    }

    /// Bias a base score by a persona's style: aggression rewards a candidate's `aggressiveness`, risk
    /// tolerance rewards (or, when low, penalizes) its `riskiness` (R-AI-5.1).
    ///
    /// Both style knobs are `0...1` (PersonaStyle clamps them). The bias is centered so a neutral persona
    /// (0.5/0.5) leaves scores essentially unchanged: aggression adds `(aggression - 0.5) * weight *
    /// aggressiveness`, and risk adds `(riskTolerance - 0.5) * weight * riskiness`. A high-aggression
    /// persona thus prefers a more aggressive candidate; a risk-averse one shies from a risky one. `weight`
    /// scales how strongly style tilts play relative to the base score.
    public static func styleBias(
        base: Double,
        aggressiveness: Double,
        riskiness: Double,
        style: PersonaStyle,
        weight: Double = 1.0
    ) -> Double {
        let aggressionBias = (style.aggression - 0.5) * weight * aggressiveness
        let riskBias = (style.riskTolerance - 0.5) * weight * riskiness
        return base + aggressionBias + riskBias
    }

    /// Pick the best of `items` after applying persona-style bias to each candidate's base score
    /// (R-AI-5.1, R-AI-2.2).
    ///
    /// `descriptor` returns each candidate's `(base, aggressiveness, riskiness)` triple; the helper folds
    /// in `style` via `styleBias`, then `argMax`es with RNG tie-breaking. This is the one call a game's
    /// evaluator makes to turn "here are my candidates and how aggressive/risky each is" into a
    /// persona-flavored choice. Returns `nil` for an empty input.
    public static func bestApplyingStyle<Item>(
        _ items: [Item],
        style: PersonaStyle,
        weight: Double = 1.0,
        using rng: inout SeededRNG,
        descriptor: (Item) -> (base: Double, aggressiveness: Double, riskiness: Double)
    ) -> Item? {
        argMax(
            items,
            score: { item in
                let d = descriptor(item)
                return styleBias(
                    base: d.base,
                    aggressiveness: d.aggressiveness,
                    riskiness: d.riskiness,
                    style: style,
                    weight: weight)
            },
            using: &rng)
    }

    /// Sample an index into `scores` with probability proportional to `exp(score / temperature)` — a
    /// reproducible soft choice (R-AI-2.2, R-AI-3.2).
    ///
    /// Useful for an Easy tier that should be beatable and varied rather than always playing the single
    /// best move. A low `temperature` sharpens toward the max; a high one flattens toward uniform. Draws
    /// via the injected `rng`. Returns `nil` for empty input; a non-positive temperature falls back to a
    /// hard argmax (deterministic).
    public static func softmaxIndex(
        _ scores: [Double],
        temperature: Double = 1.0,
        using rng: inout SeededRNG
    ) -> Int? {
        guard !scores.isEmpty else { return nil }
        guard temperature > 0 else {
            // Degenerate: pick the max (first on ties) deterministically.
            var bestIndex = 0
            for i in scores.indices where scores[i] > scores[bestIndex] { bestIndex = i }
            return bestIndex
        }
        let maxScore = scores.max() ?? 0
        // Subtract the max for numerical stability before exponentiating.
        let weights = scores.map { exp(($0 - maxScore) / temperature) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        // Draw a uniform in [0, total) reproducibly from the 64-bit RNG output (53-bit mantissa in
        // [0, 1)).
        let unit = Double(rng.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        var target = unit * total
        for (i, w) in weights.enumerated() {
            target -= w
            if target <= 0 { return i }
        }
        return weights.count - 1
    }
}
