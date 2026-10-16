// Crazy Eights — Easy AI: random legal, but dump 8s early (R-CE-5.1).
//
// The Easy tier is meant to be beatable and fast (Tiers.swift: `.random`, near-instant budget). Its one
// piece of "character" comes straight from the rules doc's AI section: it "plays a random legal card and
// spends its 8s early" (Docs/Rules/crazy-eights.md → AI opponents). So:
//
//   • among the legal actions, if any PLAY an 8, Easy prefers to play one now (dumping the 8 early rather
//     than saving it) — it picks uniformly among the 8-plays via the injected RNG (R-AI-3.2); otherwise
//   • it plays a uniformly random legal action (a card play, a draw, or a pass).
//
// It reads only `context.legalActions` (decoded for inspection) and draws only from `context.rng`, so it
// respects the information barrier (R-AI-1.1) and is reproducible for a given seed (R-AI-3.2). It is
// effectively instant, so it never needs the deadline.

import AIKit
import EngineCore
import Foundation

/// The Easy Crazy Eights strategy: random legal play that dumps 8s early (R-CE-5.1).
public struct CrazyEightsEasyStrategy: AIStrategy {
    public init() {}

    public func decide(_ context: DecisionContext) async -> AnyGameAction? {
        var rng = context.rng
        let decoded = CrazyEightsAI.decodedActions(context.legalActions)
        guard !decoded.isEmpty else { return nil }

        // Dump 8s early: if any legal action plays an 8, choose uniformly among those (R-CE-5.1).
        let eightPlays = decoded.filter { CrazyEightsAI.playsEight($0.action) }
        if !eightPlays.isEmpty {
            let index = Int(rng.next() % UInt64(eightPlays.count))
            return eightPlays[index].erased
        }

        // Otherwise a uniformly random legal action (R-CE-5.1).
        let index = Int(rng.next() % UInt64(decoded.count))
        return decoded[index].erased
    }

    /// A plain-language hint for the Easy tier, reused by coach mode (R-AI-6.1, R-AI-6.2).
    public func hint(_ context: DecisionContext) async -> Hint? {
        guard let action = await decide(context) else { return nil }
        let decoded = (try? action.decode(as: CrazyEightsAction.self))
        let explanation: String
        if let decoded, CrazyEightsAI.playsEight(decoded) {
            explanation =
                "Play the eight now and pick a fresh suit — no reason to sit on a wild card."
        } else if let decoded, CrazyEightsAI.isDraw(decoded) {
            explanation = "Nothing matches, so draw a card."
        } else {
            explanation = "Play a matching card to shrink your hand."
        }
        return Hint(action: action, explanation: explanation)
    }
}
