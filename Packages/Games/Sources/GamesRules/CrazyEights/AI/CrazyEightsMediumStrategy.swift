// Crazy Eights — Medium AI: hoard 8s, name the longest suit, track opponent voids (R-CE-5.2).
//
// The Medium tier plays the honest heuristic a decent human uses (Docs/Rules/crazy-eights.md → AI
// opponents): it keeps its wild 8s in reserve for when nothing else matches, and when it must play one it
// names the suit it holds the most of (so its follow-up is most likely legal). It also watches the public
// log for opponents who drew — a seat that drew is inferred void in the then-active suit — and it lightly
// prefers naming a suit an opponent is known void in. It reads only the view + public log + legal actions
// and draws only from the injected RNG, so it honors the barrier (R-AI-1.1) and is reproducible
// (R-AI-3.2).
//
// DECISION ORDER (R-CE-5.2):
//   1. If a NON-8 card can be played, play one — hoarding the 8s (prefer ditching the highest point value
//      so a surprise "go out" by an opponent costs less, R-CE-3.1).
//   2. Else if only an 8 can be played, play it and NAME the longest suit in hand (R-CE-5.2), lightly
//      favoring a suit opponents are inferred void in.
//   3. Else draw (or pass when the rules force it).
//
// It is a shallow heuristic (no rollouts), so it is well within any budget and never consults the
// deadline.

import AIKit
import EngineCore
import Foundation

/// The Medium Crazy Eights strategy: hoard 8s, name the longest suit, track opponent voids (R-CE-5.2).
public struct CrazyEightsMediumStrategy: AIStrategy {
    public init() {}

    public func decide(_ context: DecisionContext) async -> AnyGameAction? {
        var rng = context.rng
        return choose(context, rng: &rng)?.erased
    }

    public func hint(_ context: DecisionContext) async -> Hint? {
        var rng = context.rng
        guard let chosen = choose(context, rng: &rng) else { return nil }
        let explanation: String
        switch chosen.action {
        case .playEight:
            explanation =
                "Save the eight until you need it, then name the suit you hold the most of."
        case .play:
            explanation = "Play a matching card and keep your wild eights in reserve."
        case .draw:
            explanation = "No safe match — draw rather than waste an eight."
        case .pass:
            explanation = "Nothing to play and nothing to draw, so pass."
        }
        return Hint(action: chosen.erased, explanation: explanation)
    }

    // MARK: - Core heuristic (R-CE-5.2)

    /// Choose the Medium action from the barrier-safe inputs (R-CE-5.2). Pure but for the injected `rng`.
    private func choose(_ context: DecisionContext, rng: inout SeededRNG)
        -> DecodedCrazyEightsAction?
    {
        let decoded = CrazyEightsAI.decodedActions(context.legalActions)
        guard !decoded.isEmpty else { return nil }

        let handFaces = CrazyEightsAI.handFaces(in: context.view, seat: context.seat)
        let faceTable = CrazyEightsAI.handFaceTable(in: context.view, seat: context.seat)

        // 1) Prefer a non-8 play, hoarding 8s (R-CE-5.2). Among non-8 plays, ditch the highest-value card
        //    so a loss costs fewer points (R-CE-3.1).
        let nonEightPlays = decoded.filter { CrazyEightsAI.playsCard($0.action) }
        if !nonEightPlays.isEmpty {
            return highestValuePlay(nonEightPlays, faceTable: faceTable, using: &rng)
        }

        // 2) Only an 8 can be played: play it and name the longest suit (R-CE-5.2).
        let eightPlays = decoded.filter { CrazyEightsAI.playsEight($0.action) }
        if !eightPlays.isEmpty {
            let active = CrazyEightsAI.activeSuit(in: context.view)
            let preferred = preferredNamedSuit(
                handFaces: handFaces, fallback: active, log: context.publicLog,
                startingSuit: active, using: &rng)
            if let match = eightPlays.first(where: { namedSuit(of: $0.action) == preferred }) {
                return match
            }
            let index = Int(rng.next() % UInt64(eightPlays.count))
            return eightPlays[index]
        }

        // 3) No play at all: draw if we can, else pass (the rules only offer one of these).
        if let draw = decoded.first(where: { CrazyEightsAI.isDraw($0.action) }) { return draw }
        return decoded.first
    }

    /// Among non-8 plays, the one that discards the highest-point card (R-CE-3.1), ties broken by RNG.
    private func highestValuePlay(
        _ plays: [DecodedCrazyEightsAction], faceTable: [PieceID: CardFace],
        using rng: inout SeededRNG
    ) -> DecodedCrazyEightsAction? {
        Evaluator.argMax(
            plays,
            score: { play in
                guard let card = CrazyEightsAI.playedCard(play.action), let face = faceTable[card]
                else { return 0 }
                return Double(CrazyEightsCard.points(face))
            },
            using: &rng)
    }

    /// The suit a Medium AI names when playing an 8: the longest suit in hand, lightly favoring a suit an
    /// opponent is inferred void in (R-CE-5.2). Ties broken by RNG.
    private func preferredNamedSuit(
        handFaces: [CardFace], fallback: Suit, log: PublicLog, startingSuit: Suit,
        using rng: inout SeededRNG
    ) -> Suit {
        let counts = CrazyEightsAI.suitCounts(of: handFaces)
        guard !counts.isEmpty else { return fallback }

        let voids = CrazyEightsAI.inferredVoids(from: log, startingSuit: startingSuit)
        let voidedSuits = Set(voids.values.flatMap { $0 })

        let suits = counts.keys.sorted { $0.rawValue < $1.rawValue }
        let best = Evaluator.argMax(
            suits,
            score: { suit in
                let own = Double(counts[suit] ?? 0)
                let voidBonus = voidedSuits.contains(suit) ? 0.5 : 0
                return own + voidBonus
            },
            using: &rng)
        return best ?? fallback
    }

    /// The named suit of a `playEight` action, or `nil` for anything else.
    private func namedSuit(of action: CrazyEightsAction) -> Suit? {
        if case .playEight(_, let suit) = action { return suit }
        return nil
    }
}
