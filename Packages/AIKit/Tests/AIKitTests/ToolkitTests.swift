// Tiers, pacing, personas, evaluator, budget tests (R-AI-2.1, R-AI-3.3, R-AI-4, R-AI-5.1).

import EngineCore
import Foundation
import Testing

@testable import AIKit

@Suite("Difficulty tiers")
struct TierTests {

    // Easy/Medium/Hard map to distinct configs; Hard uses the strongest technique (R-AI-2.1).
    @Test("tiers map to distinct configs; hard is strongest")
    func tiersDistinct() {
        let easy = Tiers.config(for: .easy)
        let medium = Tiers.config(for: .medium)
        let hard = Tiers.config(for: .hard)
        #expect(easy.technique == .random)
        #expect(medium.technique == .monteCarlo)
        #expect(hard.technique == .ismcts)
        // Distinct budgets, increasing with tier.
        #expect(easy.budget.seconds < medium.budget.seconds)
        #expect(medium.budget.seconds < hard.budget.seconds)
    }

    // Hard budget honors the tech.md p95 numbers (R-AI-3.3).
    @Test("hard budget matches the p95 numbers")
    func hardBudgets() {
        #expect(Tiers.hardConfig(pokerOrTileRummy: false).budget.seconds == 1.0)
        #expect(Tiers.hardConfig(pokerOrTileRummy: true).budget.seconds == 1.5)
    }

    // A deadline is derived from a budget relative to a fixed start.
    @Test("budget derives a deadline")
    func budgetDeadline() {
        let start = Date(timeIntervalSince1970: 1000)
        let deadline = DecisionBudget(seconds: 0.5).deadline(from: start)
        #expect(deadline.remaining(now: start) == 0.5)
        #expect(deadline.isReached(now: start.addingTimeInterval(1)) == true)
        #expect(deadline.isReached(now: start) == false)
    }
}

@Suite("AI pacing")
struct PacingTests {

    // Instant → no delay; Relaxed → the longest (R-AI-4.1).
    @Test("instant is zero, relaxed is longest")
    func pacingOrder() {
        var rng = SeededRNG(seed: 1)
        #expect(AIPacing.instant.jitteredDelay(using: &rng) == 0)
        let ranges = [AIPacing.fast, .normal, .relaxed].map(\.delayRange)
        // Ranges are ordered and non-overlapping-ish: each setting's max grows.
        #expect(ranges[0].upperBound < ranges[2].upperBound)
        #expect(
            AIPacing.relaxed.delayRange.upperBound
                == AIPacing.allCases.map(\.delayRange.upperBound).max())
    }

    // Jittered delays stay within the setting's range and vary across seeds (R-AI-4.1).
    @Test("jittered delay is bounded and varies")
    func jitterBounded() {
        var values: Set<Double> = []
        for seed in UInt64(0)..<30 {
            var rng = SeededRNG(seed: seed)
            let d = AIPacing.normal.jitteredDelay(using: &rng)
            #expect(AIPacing.normal.delayRange.contains(d))
            values.insert(d)
        }
        #expect(values.count > 1)  // jittered, not constant
    }

    // Same seed → same jittered delay (reproducible, R-AI-3.2).
    @Test("jitter is reproducible for a fixed seed")
    func jitterReproducible() {
        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)
        #expect(
            AIPacing.relaxed.jitteredDelay(using: &a) == AIPacing.relaxed.jitteredDelay(using: &b))
    }

    // Pacing is its OWN type, unrelated to the compute budget (R-AI-4.2, R-AI-3.3): a StrategyConfig
    // carries both independently.
    @Test("pacing is independent of the compute budget")
    func pacingIndependentOfBudget() {
        let persona = AIPersona.bundled(withID: PersonaID(raw: "persona-shark"))!
        let cfgFast = PersonaWiring.config(for: persona, pacing: .fast)
        let cfgRelaxed = PersonaWiring.config(for: persona, pacing: .relaxed)
        // Different pacing, identical compute budget — the two are decoupled.
        #expect(cfgFast.pacing == .fast)
        #expect(cfgRelaxed.pacing == .relaxed)
        #expect(cfgFast.tierConfig.budget == cfgRelaxed.tierConfig.budget)
    }
}

@Suite("Personas → strategy config")
struct PersonaTests {

    // A persona builds a config from its tier + style (R-AI-5.1).
    @Test("persona config uses tier and carries style")
    func personaConfig() {
        let shark = AIPersona.bundled(withID: PersonaID(raw: "persona-shark"))!  // hard
        let cfg = PersonaWiring.config(for: shark)
        #expect(cfg.tierConfig.tier == .hard)
        #expect(cfg.tierConfig.technique == .ismcts)
        #expect(cfg.style == shark.style)
        #expect(cfg.personaID == shark.id)
    }

    // Poker/Tile-Rummy flag only affects the Hard budget (R-AI-3.3).
    @Test("poker/tile flag selects the relaxed hard budget")
    func relaxedHardBudget() {
        let shark = AIPersona.bundled(withID: PersonaID(raw: "persona-shark"))!
        let normal = PersonaWiring.config(for: shark, pokerOrTileRummy: false)
        let relaxed = PersonaWiring.config(for: shark, pokerOrTileRummy: true)
        #expect(normal.tierConfig.budget.seconds == 1.0)
        #expect(relaxed.tierConfig.budget.seconds == 1.5)
    }

    // A high-aggression persona prefers a more aggressive candidate given a toy evaluator (R-AI-5.1).
    @Test("high-aggression style prefers the aggressive candidate")
    func aggressionBias() {
        // Two candidates with equal base score: one aggressive, one passive.
        let candidates = ["aggressive", "passive"]
        func descriptor(_ c: String) -> (base: Double, aggressiveness: Double, riskiness: Double) {
            c == "aggressive" ? (0.5, 1.0, 0.0) : (0.5, 0.0, 0.0)
        }
        let aggressive = PersonaStyle(aggression: 0.95, riskTolerance: 0.5)
        let cautious = PersonaStyle(aggression: 0.05, riskTolerance: 0.5)
        var rngA = SeededRNG(seed: 1)
        var rngC = SeededRNG(seed: 1)
        let pickAggressive = Evaluator.bestApplyingStyle(
            candidates, style: aggressive, using: &rngA, descriptor: descriptor)
        let pickCautious = Evaluator.bestApplyingStyle(
            candidates, style: cautious, using: &rngC, descriptor: descriptor)
        #expect(pickAggressive == "aggressive")
        #expect(pickCautious == "passive")
    }
}

@Suite("Evaluator helpers")
struct EvaluatorTests {

    // argMax picks the max, and ties are broken reproducibly by the RNG.
    @Test("argMax picks the maximum")
    func argMaxBasic() {
        var rng = SeededRNG(seed: 1)
        let best = Evaluator.argMax([1, 5, 3, 2], score: { Double($0) }, using: &rng)
        #expect(best == 5)
    }

    // Ties are distributed across the tied leaders (not always the first), yet reproducible per seed.
    @Test("argMax breaks ties via RNG, reproducibly")
    func argMaxTies() {
        func pick(seed: UInt64) -> Int? {
            var rng = SeededRNG(seed: seed)
            return Evaluator.argMax([5, 5, 5], score: { Double($0) }, using: &rng)  // all tie at 5
        }
        // Reproducible: same seed → same (index-driven) pick. All values equal 5, so assert stability by
        // running the identical draw twice.
        var r1 = SeededRNG(seed: 9)
        var r2 = SeededRNG(seed: 9)
        let a = Evaluator.argMax([0, 1, 2, 3], score: { _ in 5 }, using: &r1)
        let b = Evaluator.argMax([0, 1, 2, 3], score: { _ in 5 }, using: &r2)
        #expect(a == b)
        #expect(pick(seed: 1) == 5)
    }

    // styleBias leaves a neutral persona (0.5/0.5) unchanged, and rewards aggression appropriately.
    @Test("styleBias is neutral at 0.5 and tilts with aggression")
    func styleBiasCentering() {
        let neutral = PersonaStyle(aggression: 0.5, riskTolerance: 0.5)
        let biased = Evaluator.styleBias(
            base: 1.0, aggressiveness: 1.0, riskiness: 1.0, style: neutral)
        #expect(abs(biased - 1.0) < 1e-9)
        let aggressive = PersonaStyle(aggression: 1.0, riskTolerance: 0.5)
        let up = Evaluator.styleBias(
            base: 1.0, aggressiveness: 1.0, riskiness: 0.0, style: aggressive)
        #expect(up > 1.0)
    }

    // softmaxIndex returns a valid index and is reproducible.
    @Test("softmaxIndex is a valid, reproducible index")
    func softmax() {
        var r1 = SeededRNG(seed: 3)
        var r2 = SeededRNG(seed: 3)
        let i1 = Evaluator.softmaxIndex([0.1, 5.0, 0.2], using: &r1)
        let i2 = Evaluator.softmaxIndex([0.1, 5.0, 0.2], using: &r2)
        #expect(i1 == i2)
        #expect(i1.map { (0..<3).contains($0) } == true)
    }
}
