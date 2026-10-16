// Crazy Eights AI tiers + hint entry point — wire Easy/Medium/Hard to the shared toolkit (R-CE-5.1,
// R-CE-5.2, R-CE-5.3, R-AI-2.1, R-AI-6.1).
//
// R-AI-2.1 asks for Easy/Medium/Hard per game; this file is the one place that maps a `DifficultyTier`
// (EngineCore/Profiles.swift) to the concrete Crazy Eights strategy, so the session layer / catalog wires
// an opponent by tier without knowing the strategy types. The mapping mirrors AIKit's `Tiers` scaffolding
// (Tiers.swift): Easy → random-legal-ish, Medium → heuristic, Hard → determinized Monte Carlo.
//
// The HINT entry point (R-AI-6.1) reuses the very same strategies: a hint is just the Medium strategy's
// `hint(_:)` (a solid, explainable suggestion), so coach mode and the Hint button share the AIKit hint
// interface with no separate code path (R-AI-6.2).

import AIKit
import EngineCore
import Foundation

/// Factory mapping a difficulty tier to the Crazy Eights strategy that implements it (R-AI-2.1).
public enum CrazyEightsAITier {
    /// The strategy for `tier`, given the hand's public `options` (needed by Hard to build plausible full
    /// states) (R-CE-5.1, R-CE-5.2, R-CE-5.3).
    public static func strategy(
        for tier: DifficultyTier, options: CrazyEightsOptions
    ) -> any AIStrategy {
        switch tier {
        case .easy: return CrazyEightsEasyStrategy()
        case .medium: return CrazyEightsMediumStrategy()
        case .hard: return CrazyEightsHardStrategy(options: options)
        }
    }
    /// Run a bundled strategy against a redacted seat view. This small app-facing seam keeps AI context
    /// construction inside the rules/AI layer: the UI receives only the resulting type-erased legal action,
    /// never an authoritative state (R-AI-1.1, R-AI-3.1).
    public static func choose(
        for tier: DifficultyTier,
        options: CrazyEightsOptions,
        view: PlayerView,
        seat: SeatID
    ) async -> AnyGameAction? {
        let strategy = strategy(for: tier, options: options)
        let context = DecisionContext(
            view: view,
            publicLog: .empty,
            seat: seat,
            legalActions: view.legalActions,
            rng: SeededRNG(seed: 0),
            deadline: DecisionBudget.easyDefault.deadline())
        return await strategy.decide(context)
    }
}

// MARK: - Hint (R-AI-6.1, R-AI-6.2)

extension CrazyEights {
    /// A suggested move plus a short plain-language reason for the seat to move, built by reusing the
    /// Medium AI strategy through the AIKit hint interface (R-AI-6.1, R-AI-6.2).
    ///
    /// This is the same `hint(_:)` coach mode calls (R-AI-6.2): it decides with the Medium heuristic and
    /// explains it. `rng` is injected so the suggestion is reproducible (R-AI-3.2); `publicLog` lets the
    /// hint reason about opponent voids exactly as the AI does. Returns `nil` when the seat has no legal
    /// move to suggest.
    public func hint(
        for seat: SeatID, in state: CrazyEightsState, publicLog: PublicLog = .empty,
        rng: SeededRNG = SeededRNG(seed: 0)
    ) async -> Hint? {
        let legal = legalActions(for: seat, in: state).compactMap { try? AnyGameAction($0) }
        guard !legal.isEmpty else { return nil }
        let context = DecisionContext(
            view: redactedView(of: state, for: .seat(seat)),
            publicLog: publicLog,
            seat: seat,
            legalActions: legal,
            rng: rng,
            deadline: .never)
        return await CrazyEightsMediumStrategy().hint(context)
    }
}
