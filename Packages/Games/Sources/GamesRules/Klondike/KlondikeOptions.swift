// Klondike options — the configurable variant/house-rule choices (R-KLON-2).
//
// Klondike is game-specific modules only (design.md §11); this file is the "Rules/" options schema for
// the game. `KlondikeOptions` conforms to EngineCore's `GameOptions` marker (so it is `Codable &
// Sendable` and can ride in a save or a preset, R-ENG-8.5) and carries exactly the choices the
// requirements call out:
//
//   • draw count — Draw 1 (default) or Draw 3 (R-KLON-2.1);
//   • scoring — Standard / Vegas / None (R-KLON-2.2);
//   • stock passes — Unlimited (default) / three / one (R-KLON-2.3);
//   • timed scoring — on/off (R-KLON-2.4);
//   • Vegas cumulative bankroll — on/off (R-KLON-2.2 "optionally cumulative across games");
//   • auto-flip toggle — on/off, default on (R-KLON-3.1); and
//   • auto-move-to-foundation — Off / Safe only (default) / Always (R-KLON-3.2).
//
// AUTO-FLIP RECONCILIATION (R-KLON-3.1): task 3.1 already turns a newly exposed face-down tableau top
// face-up as a *rule* inside `apply` (emitting `pieceFlipped`); that turn is intrinsic and part of legal
// Klondike — it must happen for the game to be playable, so it satisfies R-KLON-3.1's core requirement.
// The `autoFlip` flag here is the distinct *feature toggle* the design calls for: it records whether the
// UI reveals that exposed top automatically (on) vs. leaves it to a tap (off). It deliberately does NOT
// gate the authoritative rule — the state stays correct and legal either way — so determinism and save
// replay are unaffected. See Docs/Rules/klondike.md for the player-facing wording.
//
// Defaults and named presets are declared in `Klondike.optionsSchema` (R-ENG-5.2, R-KLON-2.5) and are
// documented one-for-one in `Docs/Rules/klondike.md`. Every option here maps to a section of that doc so
// the scenario suite (task 3.2) can trace each rule/option back to prose (R-QA-1.1).
//
// OPEN QUESTION Q-2 (NEEDS REVIEW, flagged in Docs/Rules/klondike.md): the `vegasCumulative` flag models
// the *option* to carry a Vegas bankroll across games, but the persistence behavior (persist across app
// launches? reset on demand?) is deferred to the persistence phase. Only the flag is modeled here; the
// engine applies the −52 start / +5-per-foundation-card scoring the same way regardless, and whether the
// running total is seeded from a prior game is a host/persistence concern, not a rules concern.

import EngineCore
import Foundation

/// How many cards are turned from the stock to the waste per draw (R-KLON-2.1).
public enum KlondikeDrawCount: Int, Codable, Sendable, CaseIterable {
    /// Turn one card at a time — the default (R-KLON-2.1).
    case one = 1
    /// Turn three cards at a time (R-KLON-2.1).
    case three = 3
}

/// The scoring scheme applied over a game (R-KLON-2.2).
///
/// `standard` uses the classic Windows-Solitaire-style point table documented in
/// `Docs/Rules/klondike.md`; the precise per-move values there are flagged NEEDS REVIEW (Q-1) and live
/// behind a single adjustable table (`KlondikeStandardScoring`) so they can be confirmed without touching
/// the move logic. `vegas` starts a bankroll at −52 and adds +5 for each card sent to a foundation.
/// `none` keeps no score.
public enum KlondikeScoring: String, Codable, Sendable, CaseIterable {
    /// Classic point scoring (values documented in the rules doc; Q-1 NEEDS REVIEW) (R-KLON-2.2).
    case standard
    /// Vegas money scoring: start −52, +5 per card to a foundation (R-KLON-2.2).
    case vegas
    /// No scoring kept (R-KLON-2.2).
    case none
}

/// The auto-move-to-foundation policy the host applies after each accepted player move (R-KLON-3.2).
///
/// This governs the *feature* that sends cards home for you; it is not a rule (any of these policies
/// plays a legal game). `safeOnly` is the default: it only sends a card home when it can never be needed
/// to receive an opposite-color card later — the standard "safe autoplay" heuristic (see
/// `Klondike.autoMoves(in:)` and `Docs/Rules/klondike.md`).
public enum KlondikeAutoMove: String, Codable, Sendable, CaseIterable {
    /// Never auto-play a card to a foundation (R-KLON-3.2).
    case off
    /// Auto-play only cards that are "safe" under the safe-autoplay heuristic — the default (R-KLON-3.2).
    case safeOnly
    /// Auto-play any card that legally can go to a foundation (R-KLON-3.2).
    case always
}

/// How many times the stock may be run through — recycling the waste back into the stock (R-KLON-2.3).
public enum KlondikeStockPasses: Codable, Sendable, Hashable {
    /// Recycle the waste as many times as you like — the default (R-KLON-2.3).
    case unlimited
    /// A fixed number of passes through the stock (R-KLON-2.3); Klondike uses three or one.
    case limited(Int)

    /// The three-pass limit (R-KLON-2.3).
    public static let three = KlondikeStockPasses.limited(3)
    /// The one-pass limit (R-KLON-2.3).
    public static let one = KlondikeStockPasses.limited(1)

    /// The maximum number of times the stock may be turned over, or `nil` for unlimited.
    ///
    /// "Passes" counts full run-throughs of the stock: the initial deal-down is pass 1, so a limit of
    /// `n` permits `n − 1` recycles of the waste back into the stock. Unlimited returns `nil`.
    public var maxPasses: Int? {
        switch self {
        case .unlimited: return nil
        case .limited(let n): return n
        }
    }
}

/// The configurable choices for a game of Klondike (R-KLON-2). Conforms to `GameOptions` so it is
/// `Codable & Sendable` and can be snapshotted into a save or carried in a preset (R-ENG-8.5).
public struct KlondikeOptions: GameOptions, Hashable {
    /// Cards turned per draw: Draw 1 (default) or Draw 3 (R-KLON-2.1).
    public var drawCount: KlondikeDrawCount
    /// The scoring scheme: Standard / Vegas / None (R-KLON-2.2).
    public var scoring: KlondikeScoring
    /// How many passes through the stock are allowed (R-KLON-2.3).
    public var stockPasses: KlondikeStockPasses
    /// Whether timed scoring is on (R-KLON-2.4). The clock/bonus itself is a feature of task 3.5/5.8;
    /// this flag records the player's choice so scoring and the HUD can honor it.
    public var timed: Bool
    /// Whether a Vegas bankroll is carried cumulatively across games (R-KLON-2.2). Q-2 NEEDS REVIEW:
    /// the persistence behavior is deferred to the persistence phase (see Docs/Rules/klondike.md).
    public var vegasCumulative: Bool
    /// The auto-flip *toggle* — default on (R-KLON-3.1). See the reconciliation note below: this governs
    /// the UI presentation of turning a newly exposed tableau top face-up, NOT the authoritative rule
    /// (the exposed top always becomes face-up in `apply`, which keeps every state legal and playable).
    public var autoFlip: Bool
    /// The auto-move-to-foundation policy — default `safeOnly` (R-KLON-3.2). Applied by the host after
    /// each accepted player move; see `Klondike.autoMoves(in:)`.
    public var autoMove: KlondikeAutoMove

    public init(
        drawCount: KlondikeDrawCount = .one,
        scoring: KlondikeScoring = .standard,
        stockPasses: KlondikeStockPasses = .unlimited,
        timed: Bool = false,
        vegasCumulative: Bool = false,
        autoFlip: Bool = true,
        autoMove: KlondikeAutoMove = .safeOnly
    ) {
        self.drawCount = drawCount
        self.scoring = scoring
        self.stockPasses = stockPasses
        self.timed = timed
        self.vegasCumulative = vegasCumulative
        self.autoFlip = autoFlip
        self.autoMove = autoMove
    }

    /// The passes limit that applies given the scoring scheme (R-KLON-2.3).
    ///
    /// Vegas overrides the default passes: it defaults to **1** pass for Draw 1 and **3** passes for
    /// Draw 3 (R-KLON-2.3). For every other scheme the player's `stockPasses` choice applies as-is.
    /// This is derived (not stored) so the rule stays in one place and the scenario suite can prove it.
    public var effectiveStockPasses: KlondikeStockPasses {
        guard scoring == .vegas else { return stockPasses }
        switch drawCount {
        case .one: return .one
        case .three: return .three
        }
    }
}
