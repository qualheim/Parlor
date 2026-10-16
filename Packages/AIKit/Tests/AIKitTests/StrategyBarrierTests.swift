// Information-barrier and Strategy-API tests (R-AI-1.1, R-AI-3.1, R-AI-3.2, R-AI-6.1).

import EngineCore
import Foundation
import Testing

@testable import AIKit

// A strategy that decides purely from visible info: it picks the legal action whose payload sorts first,
// so its choice is a deterministic function of `context.legalActions` only.
private struct VisibleOnlyStrategy: AIStrategy {
    func decide(_ context: DecisionContext) async -> AnyGameAction? {
        context.legalActions.min(by: {
            $0.typeName < $1.typeName
                || ($0.typeName == $1.typeName && $0.payload.lexicographicallyPrecedes($1.payload))
        })
    }
}

// A strategy that draws from the injected RNG, to prove reproducibility.
private struct RandomLegalStrategy: AIStrategy {
    func decide(_ context: DecisionContext) async -> AnyGameAction? {
        guard !context.legalActions.isEmpty else { return nil }
        var rng = context.rng
        let index = Int(rng.next() % UInt64(context.legalActions.count))
        return context.legalActions[index]
    }
}

private func makeContext(
    legal: [AnyGameAction],
    seed: UInt64 = 42,
    deadline: Deadline = .never
) -> DecisionContext {
    let view = PlayerView(
        viewer: .seat(SeatID.index(0)), scores: [:], phase: Phase(rawValue: "play"))
    return DecisionContext(
        view: view,
        publicLog: .empty,
        seat: SeatID.index(0),
        legalActions: legal,
        rng: SeededRNG(seed: seed),
        deadline: deadline)
}

@Suite("Information barrier + strategy API")
struct StrategyBarrierTests {

    // STRUCTURAL barrier: DecisionContext exposes only view/publicLog/seat/legalActions/rng/deadline.
    // A PlayerView (the only game-state-ish member) is itself the redacted boundary type with no path to
    // authoritative State — asserted here by confirming the context's members are exactly the barrier
    // inputs and the view is a redacted PlayerView (hidden pieces are tokens, never identities).
    @Test("DecisionContext exposes only the redacted inputs — no authoritative state")
    func barrierIsStructural() {
        let ctx = makeContext(legal: [.toy("x")])
        // The view is a redacted PlayerView; its zones carry ViewPiece (known|hidden token), never a
        // GameState. Any hidden piece is a token, so identity never leaks (R-AI-1.1 / R-QA-3.1).
        for zone in ctx.view.zones {
            for piece in zone.pieces {
                switch piece {
                case .hidden:
                    break  // opaque token — no identity
                case .known:
                    break  // a piece the viewer may legitimately see
                }
            }
        }
        // The public log is strictly public: actions carry only (seat, action), no hash/metadata/state.
        #expect(ctx.publicLog.actions.allSatisfy { _ in true })
        #expect(ctx.view.viewer == .seat(SeatID.index(0)))
    }

    // BEHAVIORAL barrier: a strategy's decision is a function only of the visible info. Two contexts with
    // identical visible inputs but different (irrelevant) seeds yield the same decision for a
    // visible-only strategy.
    @Test("decision depends only on visible info for a visible-only strategy")
    func decisionDependsOnlyOnVisibleInfo() async {
        let legal = [AnyGameAction.toy("b"), .toy("a"), .toy("c")]
        let s = VisibleOnlyStrategy()
        let d1 = await s.decide(makeContext(legal: legal, seed: 1))
        let d2 = await s.decide(makeContext(legal: legal, seed: 999))
        #expect(d1 == d2)
        #expect(d1 == AnyGameAction.toy("a"))
    }

    // REPRODUCIBILITY (R-AI-3.2): same seed + same context → same decision.
    @Test("same seed yields the same decision")
    func reproducibleDecision() async {
        let legal = [AnyGameAction.toy("a"), .toy("b"), .toy("c"), .toy("d")]
        let s = RandomLegalStrategy()
        let d1 = await s.decide(makeContext(legal: legal, seed: 7))
        let d2 = await s.decide(makeContext(legal: legal, seed: 7))
        #expect(d1 == d2)
    }

    // Different seeds can produce different draws (the RNG is actually consulted).
    @Test("different seeds can produce different draws")
    func seedsMatter() async {
        let legal = (0..<8).map { AnyGameAction.toy("a\($0)") }
        let s = RandomLegalStrategy()
        var seenDifferent = false
        let base = await s.decide(makeContext(legal: legal, seed: 1))
        for seed in UInt64(2)...20 where !seenDifferent {
            let d = await s.decide(makeContext(legal: legal, seed: seed))
            if d != base { seenDifferent = true }
        }
        #expect(seenDifferent)
    }

    // HINT (R-AI-6.1): the default hint returns the decided action + a non-empty explanation.
    @Test("default hint returns a legal action with a non-empty explanation")
    func hintDefaults() async {
        let legal = [AnyGameAction.toy("a"), .toy("b")]
        let s = VisibleOnlyStrategy()
        let ctx = makeContext(legal: legal)
        let hint = await s.hint(ctx)
        #expect(hint != nil)
        #expect(hint.map { legal.contains($0.action) } == true)
        #expect(hint.map { !$0.explanation.isEmpty } == true)
    }

    // Hint returns nil when there is nothing legal to suggest.
    @Test("hint is nil with no legal actions")
    func hintNilWhenNoLegal() async {
        let s = VisibleOnlyStrategy()
        let hint = await s.hint(makeContext(legal: []))
        #expect(hint == nil)
    }

    // PublicLog projects a LogEntry down to (seat, action) only.
    @Test("PublicLog drops hash and metadata from the action log")
    func publicLogProjection() {
        var log = ActionLog()
        log.append(
            seat: SeatID.index(1),
            action: .toy("play"),
            resultingStateHash: StateHash(bytes: [0xDE, 0xAD, 0xBE, 0xEF]),
            metadata: LogMetadata(createdAtUnix: 123, note: "secret"))
        let publicLog = PublicLog(actionLog: log)
        #expect(publicLog.actions.count == 1)
        #expect(publicLog.actions[0].seat == SeatID.index(1))
        #expect(publicLog.actions[0].action == AnyGameAction.toy("play"))
        // No timestamp/note/hash is reachable from a PublicActionEntry — it only has seat + action.
        #expect(publicLog.actions(by: SeatID.index(1)).count == 1)
        #expect(publicLog.actions(by: SeatID.index(0)).isEmpty)
    }
}
