// Crazy Eights options — the configurable variant/house-rule choices (R-CE-1, R-CE-2, R-CE-3, R-CE-4).
//
// Crazy Eights is game-specific modules only (design.md §11); this file is the "Rules/" options schema
// for the game. `CrazyEightsOptions` conforms to EngineCore's `GameOptions` marker (so it is `Codable &
// Sendable` and can ride in a save or a preset, R-ENG-8.5) and carries exactly the choices the
// requirements call out:
//
//   • player count — 2…5 (the local human plus 1–4 AI opponents) (R-CE-1.1);
//   • draw mode — draw until you can play (default) / draw one then pass (R-CE-2.3);
//   • stock-out behavior — reshuffle the discards except the top (default) / end the hand (R-CE-2.4);
//   • match target — the points a player must reach to win the match, default 100, configurable
//     (R-CE-3.2); and
//   • action cards — the livelier 2/Jack/Ace variant, off by default (R-CE-4.1).
//
// The match target (R-CE-3.2) is modeled here as an option even though a single `CrazyEights`
// `GameDefinition` models one HAND: the cross-hand accumulation to the target is the EngineCore
// Match/EndCondition machinery (Match.swift), which already exists. Carrying the target in the hand's
// options keeps the whole match configuration in one snapshotted value the host reads when it builds the
// match's end condition; the hand's `outcome` reports per-hand points and the match sums them.
//
// Defaults and named presets are declared in `CrazyEights.optionsSchema` (R-ENG-5.2) and documented
// one-for-one in `Docs/Rules/crazy-eights.md`. Every option here maps to a section of that doc so the
// scenario suite (task 4.6) can trace each rule/option back to prose (R-QA-1.1).

import EngineCore
import Foundation

/// What a player does when they cannot (or choose not to) play a matching card (R-CE-2.3).
public enum CrazyEightsDrawMode: String, Codable, Sendable, CaseIterable {
    /// Keep drawing from the stock until a playable card appears, then that draw ends the turn — the
    /// default (R-CE-2.3). See the Q-3 note in `Docs/Rules/crazy-eights.md` for the empty-stock cap.
    case drawUntilCanPlay
    /// Draw exactly one card and pass, whether or not it is playable (R-CE-2.3).
    case drawOneThenPass
}

/// What happens when the stock runs out mid-hand (R-CE-2.4).
public enum CrazyEightsStockOut: String, Codable, Sendable, CaseIterable {
    /// Reshuffle the discard pile (except its top card) back into a fresh stock — the default
    /// (R-CE-2.4).
    case reshuffleDiscards
    /// End the hand once no one can play, scoring the cards still in hand (R-CE-2.4).
    case endHand
}

/// The configurable choices for a game of Crazy Eights (R-CE-1…R-CE-4). Conforms to `GameOptions` so it
/// is `Codable & Sendable` and can be snapshotted into a save or carried in a preset (R-ENG-8.5).
public struct CrazyEightsOptions: GameOptions, Hashable {
    /// The number of players: the local human plus 1–4 AI, so 2…5 (R-CE-1.1). Clamped to 2…5 on init.
    public var playerCount: Int
    /// How a player who cannot/does not play proceeds (R-CE-2.3).
    public var drawMode: CrazyEightsDrawMode
    /// What happens when the stock is exhausted (R-CE-2.4).
    public var stockOut: CrazyEightsStockOut
    /// The match target — points to win the match; default 100, configurable (R-CE-3.2). This is used
    /// by the host's Match/EndCondition machinery for cross-hand accumulation; a single hand's
    /// `outcome` reports per-hand points.
    public var matchTarget: Int
    /// Whether the action-card variant is on: 2 → next draws two (and stacks), Jack → skip, Ace →
    /// reverse. Off by default (R-CE-4.1).
    public var actionCards: Bool

    /// The supported player-count range (R-CE-1.1).
    public static let playerRange = 2...5

    public init(
        playerCount: Int = 2,
        drawMode: CrazyEightsDrawMode = .drawUntilCanPlay,
        stockOut: CrazyEightsStockOut = .reshuffleDiscards,
        matchTarget: Int = 100,
        actionCards: Bool = false
    ) {
        self.playerCount = min(
            max(playerCount, Self.playerRange.lowerBound), Self.playerRange.upperBound)
        self.drawMode = drawMode
        self.stockOut = stockOut
        self.matchTarget = matchTarget
        self.actionCards = actionCards
    }

    /// The number of cards dealt to each player: 7 with 2 players, 5 with 3–5 (R-CE-1.2). Derived so the
    /// deal rule lives in one place and the scenario suite can prove it.
    public var handSize: Int {
        playerCount == 2 ? 7 : 5
    }

    // Decoding clamps `playerCount` to the supported range so a hand-edited or older save cannot seat an
    // out-of-range table (R-ENG-8.5).
    private enum CodingKeys: String, CodingKey {
        case playerCount, drawMode, stockOut, matchTarget, actionCards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawCount = try c.decode(Int.self, forKey: .playerCount)
        self.playerCount = min(
            max(rawCount, Self.playerRange.lowerBound), Self.playerRange.upperBound)
        self.drawMode = try c.decode(CrazyEightsDrawMode.self, forKey: .drawMode)
        self.stockOut = try c.decode(CrazyEightsStockOut.self, forKey: .stockOut)
        self.matchTarget = try c.decode(Int.self, forKey: .matchTarget)
        self.actionCards = try c.decode(Bool.self, forKey: .actionCards)
    }
}
