// Difficulty tiers → toolkit configuration (R-AI-2.1, R-AI-3.3).
//
// R-AI-2.1 requires Easy / Medium / Hard tiers per game (where the game has opponents). The concrete tier
// strategies for a specific game are that game's job (Crazy Eights is task 4.6); AIKit provides the
// SCAFFOLDING — a mapping from `DifficultyTier` (EngineCore/Profiles.swift) to which toolkit technique to
// use and what compute budget to run under. A game reads this to wire its Easy/Medium/Hard to the shared
// toolkit consistently:
//
//   • Easy   — a shallow choice: random-legal or a light heuristic, near-instant budget. Meant to be
//     beatable and fast.
//   • Medium — bounded determinized Monte Carlo (short rollouts) under a small budget.
//   • Hard   — the strongest technique (ISMCTS / determinized Monte Carlo) under the full p95 budget
//     (≤ 1.0 s; ≤ 1.5 s for poker & Tile Rummy — R-AI-3.3).
//
// The budget is data, so a game that needs the relaxed poker/Tile-Rummy Hard budget selects it explicitly
// via `hardConfig(pokerOrTileRummy:)` rather than the toolkit hardcoding a game (R-AI-3.3).

import Foundation
import EngineCore

// MARK: - Technique (R-AI-2.1)

/// Which toolkit technique a tier uses (R-AI-2.1).
///
/// A game maps this onto the concrete toolkit call: `.random` → pick a legal move via the RNG;
/// `.heuristic` → the game's own light evaluator; `.monteCarlo` → `MonteCarlo` rollouts; `.ismcts` →
/// `ISMCTS`. Kept as a small enum so the tier→technique choice is explicit and testable, and so a game can
/// switch a tier's technique without touching AIKit.
public enum Technique: String, Sendable, Hashable, Codable, CaseIterable {
    /// Pick uniformly among legal moves (Easy baseline).
    case random
    /// Use the game's light heuristic evaluator (a stronger Easy / simple Medium).
    case heuristic
    /// Determinized Monte Carlo rollouts (Medium / a Hard fallback).
    case monteCarlo
    /// Information Set Monte Carlo Tree Search (Hard).
    case ismcts
}

// MARK: - TierConfig (R-AI-2.1, R-AI-3.3)

/// The toolkit configuration for one tier: which technique to run and under what compute budget
/// (R-AI-2.1, R-AI-3.3).
///
/// Pure data a game reads to wire a tier. `Sendable` so it can ride in a strategy configuration across
/// the concurrency boundary.
public struct TierConfig: Sendable, Hashable {
    /// The tier this configures.
    public let tier: DifficultyTier
    /// The technique this tier uses (R-AI-2.1).
    public let technique: Technique
    /// The compute budget this tier runs under, excluding cosmetic pacing (R-AI-3.3).
    public let budget: DecisionBudget

    public init(tier: DifficultyTier, technique: Technique, budget: DecisionBudget) {
        self.tier = tier
        self.technique = technique
        self.budget = budget
    }
}

// MARK: - Tiers (R-AI-2.1)

/// The default tier→configuration mapping games use to wire Easy/Medium/Hard to the shared toolkit
/// (R-AI-2.1, R-AI-3.3).
///
/// Games may take these as-is or adjust (e.g. select the relaxed Hard budget for poker/Tile Rummy). The
/// mapping is the scaffolding; the concrete per-game strategies are task 4.6.
public enum Tiers {
    /// The default configuration for `tier` (R-AI-2.1).
    ///
    /// Easy → random-legal, near-instant; Medium → bounded Monte Carlo, short budget; Hard → ISMCTS at the
    /// standard p95 budget (R-AI-3.3). Use `hardConfig(pokerOrTileRummy:)` to opt into the relaxed Hard
    /// budget where the requirement allows it.
    public static func config(for tier: DifficultyTier) -> TierConfig {
        switch tier {
        case .easy:
            return TierConfig(tier: .easy, technique: .random, budget: .easyDefault)
        case .medium:
            return TierConfig(tier: .medium, technique: .monteCarlo, budget: .mediumDefault)
        case .hard:
            return TierConfig(tier: .hard, technique: .ismcts, budget: .hardDefault)
        }
    }

    /// The Hard-tier configuration, choosing the standard (≤ 1.0 s) or the relaxed poker/Tile-Rummy
    /// (≤ 1.5 s) p95 budget (R-AI-3.3).
    ///
    /// A game that is poker or Tile Rummy passes `pokerOrTileRummy: true` to claim the relaxed budget the
    /// requirement grants it; every other game uses the standard budget. Keeping this a parameter (not a
    /// hardcoded game id) is what keeps the toolkit game-agnostic (R-AI-3.3).
    public static func hardConfig(pokerOrTileRummy: Bool) -> TierConfig {
        TierConfig(
            tier: .hard,
            technique: .ismcts,
            budget: pokerOrTileRummy ? .hardPokerOrTileRummy : .hardDefault)
    }
}
