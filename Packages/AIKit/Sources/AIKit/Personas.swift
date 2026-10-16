// Personas → strategy configuration (R-AI-5.1, R-AI-2.1, R-AI-4.1).
//
// `AIPersona` (EngineCore/Profiles.swift) already exists: a named opponent with an avatar, a
// `DifficultyTier`, and a small `PersonaStyle` (aggression, riskTolerance). AIKit does NOT redefine it —
// it CONSUMES one to build a `StrategyConfig` a game AI runs from:
//
//   • the persona's `tier` selects the `TierConfig` (technique + compute budget) via `Tiers` (R-AI-2.1,
//     R-AI-3.3), and
//   • the persona's `style` is carried through so the game's evaluator can bias its choice
//     (`Evaluator.styleBias`), giving the persona its character in play (R-AI-5.1).
//
// Pacing (R-AI-4.1) is a separate, cosmetic setting the player controls; it is included in the config for
// convenience but stays independent of the compute budget (see Pacing.swift). This file is the one seam a
// game AI uses to turn "play as The Shark" into "run ISMCTS at the Hard budget, biasing the evaluator by
// The Shark's style, and pause with Normal pacing".

import Foundation
import EngineCore

// MARK: - StrategyConfig (R-AI-5.1, R-AI-2.1)

/// Everything a game AI needs to play as a persona: the tier's toolkit config, the persona's style, and
/// the cosmetic pacing (R-AI-5.1, R-AI-2.1).
///
/// Built from an `AIPersona` by `PersonaWiring`. `tierConfig` gives the technique + compute budget;
/// `style` biases the evaluator (R-AI-5.1); `pacing` is the cosmetic delay, kept out of the budget
/// (R-AI-3.3). Pure `Sendable` data a strategy reads.
public struct StrategyConfig: Sendable, Hashable {
    /// The persona this configuration was built from (its id/name/avatar for presentation).
    public let personaID: PersonaID
    /// The tier's technique + compute budget (R-AI-2.1, R-AI-3.3).
    public let tierConfig: TierConfig
    /// The persona's style knobs the evaluator biases on (R-AI-5.1).
    public let style: PersonaStyle
    /// The cosmetic thinking-delay setting (independent of the compute budget — R-AI-4.2).
    public let pacing: AIPacing

    public init(
        personaID: PersonaID,
        tierConfig: TierConfig,
        style: PersonaStyle,
        pacing: AIPacing
    ) {
        self.personaID = personaID
        self.tierConfig = tierConfig
        self.style = style
        self.pacing = pacing
    }
}

// MARK: - PersonaWiring (R-AI-5.1)

/// Builds a `StrategyConfig` from an `AIPersona` — the persona→strategy seam (R-AI-5.1, R-AI-2.1).
///
/// Consumes (never redefines) the EngineCore `AIPersona`: its `tier` picks the toolkit config, its `style`
/// flows through to the evaluator. Pacing is supplied separately because it is a cosmetic player setting,
/// not a property of the persona (R-AI-4.1, R-AI-4.2).
public enum PersonaWiring {
    /// Build the strategy configuration for `persona` (R-AI-5.1).
    ///
    /// The tier maps through `Tiers.config(for:)` to a technique + budget; the persona's style is carried
    /// for evaluator bias; `pacing` (default: `.normal`) is the cosmetic delay. `pokerOrTileRummy` selects
    /// the relaxed Hard budget where the requirement allows it (R-AI-3.3) — it only affects the Hard tier.
    public static func config(
        for persona: AIPersona,
        pacing: AIPacing = .default,
        pokerOrTileRummy: Bool = false
    ) -> StrategyConfig {
        let tierConfig: TierConfig
        if persona.tier == .hard {
            tierConfig = Tiers.hardConfig(pokerOrTileRummy: pokerOrTileRummy)
        } else {
            tierConfig = Tiers.config(for: persona.tier)
        }
        return StrategyConfig(
            personaID: persona.id,
            tierConfig: tierConfig,
            style: persona.style,
            pacing: pacing)
    }
}
