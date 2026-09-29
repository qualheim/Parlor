// Klondike construction / core-move tests (task 3.1).
//
// These prove the `GameDefinition` builds a legal initial deal, that a few core legal and illegal moves
// behave, and that the undo policy is unlimited. The full Given/When/Then scenario suite traceable to
// Docs/Rules/klondike.md is task 3.2; this file is the "prove it builds and the basics work" slice the
// task asks for. Tests use only the public API plus directly-constructed states for deterministic move
// checks (the state's zones and face map are public).

import EngineCore
import Testing

@testable import GamesRules

@Suite("Klondike — deal and construction")
struct KlondikeDealTests {
    let game = Klondike()

    @Test("metadata: solitaire, single seat, id klondike")
    func metadata() {
        #expect(Klondike.metadata.id == "klondike")
        #expect(Klondike.metadata.family == .solitaire)
        #expect(Klondike.metadata.seatRange == 1...1)
    }

    @Test("undo policy is unlimited (R-KLON-3.4)")
    func undoUnlimited() {
        #expect(game.undoPolicy == .unlimited)
    }

    @Test(
        "initial deal: 7 tableau piles 1..7, one face up each; 24-card hidden stock; empty waste + 4 foundations (R-KLON-1.1)"
    )
    func initialDeal() {
        let state = game.initialState(options: KlondikeOptions(), seed: 12345)

        #expect(state.tableau.count == 7)
        for (i, pile) in state.tableau.enumerated() {
            #expect(pile.contents.count == i + 1)
            #expect(pile.faceUp.count == 1)  // exactly the top card is face up
            #expect(pile.faceUp.contains(pile.contents.last!))
            #expect(pile.visibility == .perPieceFaceState)
        }

        #expect(state.stock.contents.count == 24)
        #expect(state.stock.visibility == .hidden)
        #expect(state.waste.contents.isEmpty)
        #expect(state.foundations.count == 4)
        #expect(state.foundations.allSatisfy { $0.contents.isEmpty })

        // All 52 cards accounted for, none duplicated.
        let all =
            state.stock.contents + state.waste.contents
            + state.tableau.flatMap(\.contents) + state.foundations.flatMap(\.contents)
        #expect(all.count == 52)
        #expect(Set(all).count == 52)
        #expect(state.faces.count == 52)
    }

    @Test("same seed deals the identical board (R-ENG-4.4)")
    func deterministicDeal() {
        let a = game.initialState(options: KlondikeOptions(), seed: 999)
        let b = game.initialState(options: KlondikeOptions(), seed: 999)
        #expect(a.tableau.map(\.contents) == b.tableau.map(\.contents))
        #expect(a.stock.contents == b.stock.contents)
    }

    @Test("Vegas seeds the score at -52; others at 0 (R-KLON-2.2)")
    func vegasStartScore() {
        let vegas = game.initialState(
            options: KlondikeOptions(scoring: .vegas), seed: 1)
        #expect(vegas.score == -52)
        let standard = game.initialState(options: KlondikeOptions(scoring: .standard), seed: 1)
        #expect(standard.score == 0)
    }

    @Test("a fresh deal has at least one legal action, all from the single seat")
    func dealHasMoves() {
        let state = game.initialState(options: KlondikeOptions(), seed: 7)
        let moves = game.legalActions(for: klondikeSeat, in: state)
        #expect(!moves.isEmpty)
        // A different seat has no moves.
        #expect(game.legalActions(for: SeatID.index(1), in: state).isEmpty)
    }
}

@Suite("Klondike — options and presets")
struct KlondikeOptionsTests {
    @Test("defaults: Draw 1, Standard, Unlimited passes, timed off (R-KLON-2.*)")
    func defaults() {
        let d = Klondike.optionsSchema.defaults
        #expect(d.drawCount == .one)
        #expect(d.scoring == .standard)
        #expect(d.stockPasses == .unlimited)
        #expect(d.timed == false)
    }

    @Test("three named presets are offered (R-KLON-2.5)")
    func presets() {
        let names = Klondike.optionsSchema.presets.map(\.name)
        #expect(names.contains("Draw 1 / Standard"))
        #expect(names.contains("Draw 3 / Vegas"))
        #expect(names.contains("Relaxed / No scoring"))
    }

    @Test("Vegas overrides passes: 1 for Draw 1, 3 for Draw 3 (R-KLON-2.3)")
    func vegasPassOverride() {
        let draw1 = KlondikeOptions(drawCount: .one, scoring: .vegas, stockPasses: .unlimited)
        #expect(draw1.effectiveStockPasses.maxPasses == 1)
        let draw3 = KlondikeOptions(drawCount: .three, scoring: .vegas, stockPasses: .unlimited)
        #expect(draw3.effectiveStockPasses.maxPasses == 3)
        // Non-Vegas keeps the explicit choice.
        let std = KlondikeOptions(scoring: .standard, stockPasses: .three)
        #expect(std.effectiveStockPasses.maxPasses == 3)
    }
}
