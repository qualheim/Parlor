// Klondike feature tests (task 3.5) — exhaustive on the pure logic behind auto-move, smart move,
// auto-complete, no-moves detection, numbered deals, the move counter/timer session model, and hints
// (R-KLON-3.1, R-KLON-3.2, R-KLON-3.3, R-KLON-3.5, R-KLON-3.6, R-KLON-3.7, R-KLON-3.8).
//
// These build small, fully-known boards so each feature's decision can be asserted precisely. The `KF`
// helper mints stable-id cards and assembles a `KlondikeState` from explicit zones, mirroring the
// existing move-test helper but local to this file.

import EngineCore
import Testing

@testable import GamesRules

/// Test helpers for building controlled Klondike positions for the feature suite.
private enum KF {
    static func card(_ rank: Rank, _ suit: Suit, id: UInt64) -> Card {
        Card(id: PieceID(raw: id), face: .standard(rank, suit))
    }

    /// Build a state from explicit zone contents. Tableau piles default to "all listed cards face up".
    static func state(
        stock: [Card] = [],
        waste: [Card] = [],
        tableau: [[Card]],
        tableauFaceUp: [Set<PieceID>]? = nil,
        foundations: [[Card]] = [[], [], [], []],
        options: KlondikeOptions = KlondikeOptions(),
        score: Int = 0,
        passes: Int = 1
    ) -> KlondikeState {
        var faces: [PieceID: CardFace] = [:]
        func record(_ cards: [Card]) { for c in cards { faces[c.id] = c.face } }
        record(stock)
        record(waste)
        tableau.forEach(record)
        foundations.forEach(record)

        let stockZone = Zone(
            id: KlondikeZone.stockID, visibility: .hidden, contents: stock.map(\.id))
        let wasteZone = Zone(
            id: KlondikeZone.wasteID, visibility: .publicAll, contents: waste.map(\.id))
        let tableauZones = tableau.enumerated().map { (i, cards) -> Zone in
            let faceUp = tableauFaceUp?[i] ?? Set(cards.map(\.id))
            return Zone(
                id: KlondikeZone.tableau(i), visibility: .perPieceFaceState,
                contents: cards.map(\.id), faceUp: faceUp)
        }
        let foundationZones = foundations.enumerated().map { (i, cards) in
            Zone(id: KlondikeZone.foundation(i), visibility: .publicAll, contents: cards.map(\.id))
        }
        return KlondikeState(
            stock: stockZone, waste: wasteZone, tableau: tableauZones,
            foundations: foundationZones, faces: faces, score: score, passes: passes,
            options: options)
    }

    static func empty7() -> [[Card]] { Array(repeating: [], count: 7) }

    /// All cards Ace..`rank` of `suit` with deterministic ids, for building foundations.
    static func upTo(_ rank: Rank, _ suit: Suit, startID: UInt64) -> [Card] {
        (1...rank.rawValue).map { r in card(Rank(rawValue: r)!, suit, id: startID + UInt64(r)) }
    }
}

// MARK: - Auto-move to foundations (R-KLON-3.2)

@Suite("Klondike — auto-move to foundations (R-KLON-3.2)")
struct KlondikeAutoMoveTests {
    let game = Klondike()

    @Test("off plays nothing")
    func offPlaysNothing() {
        // An Ace sits on the waste — always a legal foundation move — but off must return nothing.
        let s = KF.state(
            waste: [KF.card(.ace, .spades, id: 1)],
            tableau: KF.empty7(),
            options: KlondikeOptions(autoMove: .off))
        #expect(game.autoMoves(in: s).isEmpty)
    }

    @Test("safeOnly plays aces and twos")
    func safeOnlyPlaysAcesAndTwos() {
        // Ace of spades on the waste, two of hearts on tableau 0 top (foundation 1 holds A♥).
        var t = KF.empty7()
        t[0] = [KF.card(.two, .hearts, id: 2)]
        let s = KF.state(
            waste: [KF.card(.ace, .spades, id: 1)],
            tableau: t,
            foundations: [[], [KF.card(.ace, .hearts, id: 10)], [], []],
            options: KlondikeOptions(autoMove: .safeOnly))
        let moves = game.autoMoves(in: s)
        // Ace from waste and two from tableau are both safe.
        #expect(moves.contains(.wasteToFoundation(toFoundation: 0)))
        #expect(moves.contains(.tableauToFoundation(fromPile: 0, toFoundation: 1)))
    }

    @Test(
        "safeOnly plays a safe rank-N card only when both opposite-color foundations are at >= N-1")
    func safeOnlyRespectsHeuristic() {
        // A black six (6♠) is safe iff both RED foundations (hearts, diamonds) are at >= 5.
        // Build foundation 0 = clubs up to 5 (so 6♠ has a home... actually 6♠ needs a spade foundation).
        // Set: foundation for spades holds A..5♠ (top 5♠), so 6♠ can go up. 6♠ black → opposite red.
        let fSpades = KF.upTo(.five, .spades, startID: 100)  // top 5♠
        let sixSpades = KF.card(.six, .spades, id: 6)

        // Case A: both red foundations at >= 5 → safe → auto-moved.
        let safeState = KF.state(
            waste: [sixSpades],
            tableau: KF.empty7(),
            foundations: [
                fSpades,
                KF.upTo(.five, .hearts, startID: 200),  // 5♥
                KF.upTo(.five, .diamonds, startID: 300),  // 5♦
                [],
            ],
            options: KlondikeOptions(autoMove: .safeOnly))
        #expect(game.autoMoves(in: safeState).contains(.wasteToFoundation(toFoundation: 0)))

        // Case B: one red foundation only at 4 → NOT safe → not auto-moved (but IS a legal move).
        let unsafeState = KF.state(
            waste: [sixSpades],
            tableau: KF.empty7(),
            foundations: [
                fSpades,
                KF.upTo(.five, .hearts, startID: 200),  // 5♥
                KF.upTo(.four, .diamonds, startID: 300),  // 4♦ (below 5)
                [],
            ],
            options: KlondikeOptions(autoMove: .safeOnly))
        #expect(!game.autoMoves(in: unsafeState).contains(.wasteToFoundation(toFoundation: 0)))
        // Confirm it really is a legal move (so the exclusion is the safe gate, not illegality).
        #expect(
            game.legalActions(for: klondikeSeat, in: unsafeState).contains(
                .wasteToFoundation(toFoundation: 0)))
    }

    @Test("always plays any legal foundation move (even unsafe)")
    func alwaysPlaysAny() {
        let fSpades = KF.upTo(.five, .spades, startID: 100)
        let sixSpades = KF.card(.six, .spades, id: 6)
        let unsafeState = KF.state(
            waste: [sixSpades],
            tableau: KF.empty7(),
            foundations: [
                fSpades,
                KF.upTo(.five, .hearts, startID: 200),
                KF.upTo(.four, .diamonds, startID: 300),  // below 5 → unsafe
                [],
            ],
            options: KlondikeOptions(autoMove: .always))
        #expect(game.autoMoves(in: unsafeState).contains(.wasteToFoundation(toFoundation: 0)))
    }

    @Test("every produced auto-move is accepted by apply")
    func autoMovesAreLegal() {
        var t = KF.empty7()
        t[0] = [KF.card(.two, .hearts, id: 2)]
        let s = KF.state(
            waste: [KF.card(.ace, .spades, id: 1)],
            tableau: t,
            foundations: [[], [KF.card(.ace, .hearts, id: 10)], [], []],
            options: KlondikeOptions(autoMove: .safeOnly))
        for move in game.autoMoves(in: s) {
            #expect((try? game.apply(move, by: klondikeSeat, to: s).get()) != nil)
        }
    }
}

// MARK: - Smart destination (R-KLON-3.3)

@Suite("Klondike — smart destination (R-KLON-3.3)")
struct KlondikeSmartMoveTests {
    let game = Klondike()

    @Test("prefers a foundation when a legal send exists")
    func prefersFoundation() {
        // Ace of spades on waste; both a foundation and (no) tableau target — foundation wins.
        let ace = KF.card(.ace, .spades, id: 1)
        let s = KF.state(waste: [ace], tableau: KF.empty7())
        #expect(game.smartDestination(for: ace.id, in: s) == KlondikeZone.foundation(0))
    }

    @Test("falls back to a legal tableau build when no foundation applies")
    func fallsBackToTableau() {
        // Red six on waste; no foundation accepts it (foundations empty want an Ace). Black 7♠ on
        // tableau 0 accepts it.
        var t = KF.empty7()
        t[0] = [KF.card(.seven, .spades, id: 10)]
        let six = KF.card(.six, .hearts, id: 1)
        let s = KF.state(waste: [six], tableau: t)
        #expect(game.smartDestination(for: six.id, in: s) == KlondikeZone.tableau(0))
    }

    @Test("prefers a non-empty tableau build over an empty column")
    func prefersNonEmptyPile() {
        // King of clubs: could fill empty pile 1, or build onto... nothing above a King. So a King only
        // has empty destinations. Use a Queen instead to test non-empty preference: red Q♥ can go onto
        // black K♠ (pile 0) OR into empty pile 1 — prefer the non-empty build.
        var t = KF.empty7()
        t[0] = [KF.card(.king, .spades, id: 10)]  // non-empty, accepts Q♥
        // pile 1 empty
        let queen = KF.card(.queen, .hearts, id: 1)
        let s = KF.state(waste: [queen], tableau: t)
        #expect(game.smartDestination(for: queen.id, in: s) == KlondikeZone.tableau(0))
    }

    @Test("a King smart-moves into an empty column when nothing else applies")
    func kingToEmpty() {
        // pile 0 empty; king on waste
        let king = KF.card(.king, .clubs, id: 1)
        let s = KF.state(waste: [king], tableau: KF.empty7())
        #expect(game.smartDestination(for: king.id, in: s) == KlondikeZone.tableau(0))
    }

    @Test("returns nil for an unmovable piece")
    func nilForNoMove() {
        // A lone red 6♥ on the waste with no black 7 anywhere and no foundation → no destination.
        let six = KF.card(.six, .hearts, id: 1)
        let s = KF.state(waste: [six], tableau: KF.empty7())
        #expect(game.smartDestination(for: six.id, in: s) == nil)
    }

    @Test("returns nil for a buried / face-down card")
    func nilForBuried() {
        // Pile 0: face-down 9♣ under a face-up K♠. The buried 9♣ is not a smart source.
        var t = KF.empty7()
        let hidden = KF.card(.nine, .clubs, id: 1)
        let king = KF.card(.king, .spades, id: 2)
        t[0] = [hidden, king]
        let faceUp: [Set<PieceID>] = [[king.id], [], [], [], [], [], []]
        let s = KF.state(tableau: t, tableauFaceUp: faceUp)
        #expect(game.smartDestination(for: hidden.id, in: s) == nil)
    }
}

// MARK: - Auto-complete (R-KLON-3.3)

@Suite("Klondike — auto-complete (R-KLON-3.3)")
struct KlondikeAutoCompleteTests {
    let game = Klondike()

    /// A solved-but-not-terminal board: stock/waste empty, all tableau cards face up, foundations nearly
    /// full. Here foundations hold A..K for three suits and A..Q for spades (51 home); the King of spades
    /// sits alone face-up on tableau 0 → one greedy move finishes.
    private func nearlyDone() -> KlondikeState {
        var t = KF.empty7()
        t[0] = [KF.card(.king, .spades, id: 413)]
        return KF.state(
            tableau: t,
            foundations: [
                KF.upTo(.king, .clubs, startID: 100),
                KF.upTo(.king, .diamonds, startID: 200),
                KF.upTo(.king, .hearts, startID: 300),
                KF.upTo(.queen, .spades, startID: 400),
            ])
    }

    @Test("canAutoComplete is true on a solved-but-not-terminal board")
    func trueWhenSolvable() {
        #expect(game.canAutoComplete(nearlyDone()))
    }

    @Test("canAutoComplete is false when face-down cards remain")
    func falseWhenFaceDown() {
        // Two cards in pile 0, the bottom face-down: cannot auto-complete.
        var t = KF.empty7()
        let hidden = KF.card(.two, .clubs, id: 1)
        let up = KF.card(.king, .spades, id: 2)
        t[0] = [hidden, up]
        let faceUp: [Set<PieceID>] = [[up.id], [], [], [], [], [], []]
        let s = KF.state(tableau: t, tableauFaceUp: faceUp)
        #expect(!game.canAutoComplete(s))
    }

    @Test("canAutoComplete is false when the stock or waste is non-empty")
    func falseWhenStockOrWaste() {
        var t = KF.empty7()
        t[0] = [KF.card(.king, .spades, id: 413)]
        let withStock = KF.state(
            stock: [KF.card(.two, .clubs, id: 500)],
            tableau: t,
            foundations: [
                KF.upTo(.king, .clubs, startID: 100),
                KF.upTo(.king, .diamonds, startID: 200),
                KF.upTo(.king, .hearts, startID: 300),
                KF.upTo(.queen, .spades, startID: 400),
            ])
        #expect(!game.canAutoComplete(withStock))
    }

    @Test("canAutoComplete is false on a terminal board")
    func falseWhenTerminal() {
        let won = KF.state(
            tableau: KF.empty7(),
            foundations: [
                KF.upTo(.king, .clubs, startID: 100),
                KF.upTo(.king, .diamonds, startID: 200),
                KF.upTo(.king, .hearts, startID: 300),
                KF.upTo(.king, .spades, startID: 400),
            ])
        #expect(game.isTerminal(won))
        #expect(!game.canAutoComplete(won))
    }

    @Test("the produced sequence actually finishes the game when applied")
    func sequenceFinishes() {
        // Foundations at A..J for all four suits (44 home). Each suit's Q and K sit on the tableau so the
        // greedy loop lifts them home in order: a Q (a pile top, foundation top is J → Q is next) then
        // its K. Queens and Kings are laid out so every needed card is a pile top when its turn comes.
        var t = KF.empty7()
        t[0] = [KF.card(.queen, .clubs, id: 12)]
        t[1] = [KF.card(.king, .clubs, id: 13)]
        t[2] = [KF.card(.queen, .diamonds, id: 22)]
        t[3] = [KF.card(.king, .diamonds, id: 23)]
        t[4] = [KF.card(.queen, .hearts, id: 32)]
        t[5] = [KF.card(.king, .hearts, id: 33)]
        // Spades Q and K stacked with Q on top: Q is the pile top (playable first), K beneath it becomes
        // the top after Q leaves.
        t[6] = [KF.card(.king, .spades, id: 43), KF.card(.queen, .spades, id: 42)]
        let good = KF.state(
            tableau: t,
            foundations: [
                KF.upTo(.jack, .clubs, startID: 100),
                KF.upTo(.jack, .diamonds, startID: 200),
                KF.upTo(.jack, .hearts, startID: 300),
                KF.upTo(.jack, .spades, startID: 400),
            ])
        #expect(game.canAutoComplete(good))
        let seq = game.autoCompleteSequence(from: good)
        #expect(seq != nil)

        // Apply every move; the game must end won.
        var current = good
        for move in seq ?? [] {
            current = try! game.apply(move, by: klondikeSeat, to: current).get().0
        }
        #expect(game.isTerminal(current))
    }
}

// MARK: - No-moves detection (R-KLON-3.6)

@Suite("Klondike — no-moves detection (R-KLON-3.6)")
struct KlondikeNoMovesTests {
    let game = Klondike()

    @Test("hasNoMoves is true on a constructed dead board")
    func trueOnDeadBoard() {
        // Empty stock, empty waste, no legal move: seven piles each a single face-up card that cannot
        // stack on any other and cannot go to a foundation (no aces, no valid builds). Use all Kings +
        // mismatched: seven cards, none buildable on each other (all same rank), no foundation move.
        var t = KF.empty7()
        // Seven face-up cards, all rank 5, colors chosen so none can stack (same rank never stacks) and
        // none is an Ace (foundations empty want Aces). No empty pile (all seven occupied) so no King
        // move matters. Stock and waste empty → no draw/recycle.
        let fives: [Card] = [
            KF.card(.five, .clubs, id: 1), KF.card(.five, .spades, id: 2),
            KF.card(.five, .hearts, id: 3), KF.card(.five, .diamonds, id: 4),
            KF.card(.five, .clubs, id: 5), KF.card(.five, .spades, id: 6),
            KF.card(.five, .hearts, id: 7),
        ]
        for i in 0..<7 { t[i] = [fives[i]] }
        let s = KF.state(stock: [], waste: [], tableau: t)
        #expect(game.legalActions(for: klondikeSeat, in: s).isEmpty)
        #expect(game.hasNoMoves(s))
    }

    @Test("hasNoMoves is false when a stock draw is available")
    func falseWithStockDraw() {
        let s = KF.state(stock: [KF.card(.two, .clubs, id: 1)], tableau: KF.empty7())
        #expect(!game.hasNoMoves(s))
    }

    @Test("hasNoMoves is false when a recycle is available")
    func falseWithRecycle() {
        // Stock empty, waste non-empty, unlimited passes → recycle is legal.
        let s = KF.state(
            stock: [], waste: [KF.card(.five, .clubs, id: 1)],
            tableau: {
                var t = KF.empty7()
                // Fill all piles so the waste 5♣ can't build; only recycle keeps a move alive.
                let blockers: [Card] = [
                    KF.card(.five, .spades, id: 11), KF.card(.five, .hearts, id: 12),
                    KF.card(.five, .diamonds, id: 13), KF.card(.five, .clubs, id: 14),
                    KF.card(.five, .spades, id: 15), KF.card(.five, .hearts, id: 16),
                    KF.card(.five, .diamonds, id: 17),
                ]
                for i in 0..<7 { t[i] = [blockers[i]] }
                return t
            }(),
            options: KlondikeOptions(stockPasses: .unlimited))
        #expect(!game.hasNoMoves(s))
    }

    @Test("hasNoMoves is false on a terminal board (game won, not stuck)")
    func falseWhenWon() {
        let won = KF.state(
            tableau: KF.empty7(),
            foundations: [
                KF.upTo(.king, .clubs, startID: 100),
                KF.upTo(.king, .diamonds, startID: 200),
                KF.upTo(.king, .hearts, startID: 300),
                KF.upTo(.king, .spades, startID: 400),
            ])
        #expect(!game.hasNoMoves(won))
    }

    @Test("the banner state offers undo, restart, and new game")
    func bannerOffersRecovery() {
        let opts = KlondikeNoMovesOptions(canUndo: true)
        let banner = KlondikeBannerState.noMoves(offering: opts)
        guard case .noMoves(let offering) = banner else {
            Issue.record("expected noMoves banner")
            return
        }
        #expect(offering.canUndo)
        #expect(offering.canRestart)
        #expect(offering.canNewGame)
    }
}

// MARK: - Numbered deals (R-KLON-3.7)

@Suite("Klondike — numbered deals (R-KLON-3.7)")
struct KlondikeDealNumberTests {
    let game = Klondike()

    @Test("seed(forDealNumber:) is deterministic and stable")
    func deterministic() {
        #expect(Klondike.seed(forDealNumber: 1) == Klondike.seed(forDealNumber: 1))
        #expect(Klondike.seed(forDealNumber: 42) == Klondike.seed(forDealNumber: 42))
        // The mix is a fixed bijection, so distinct numbers give distinct seeds.
        #expect(Klondike.seed(forDealNumber: 1) != Klondike.seed(forDealNumber: 2))
    }

    @Test("the same deal number deals the same game")
    func sameNumberSameDeal() {
        let a = game.initialState(options: KlondikeOptions(), dealNumber: 7)
        let b = game.initialState(options: KlondikeOptions(), dealNumber: 7)
        // Same tableau layout (by piece order) proves the deal is identical.
        for i in 0..<7 {
            #expect(a.tableau[i].contents == b.tableau[i].contents)
        }
        #expect(a.stock.contents == b.stock.contents)
    }

    @Test("different deal numbers almost always deal different games")
    func differentNumbersDifferentDeals() {
        var distinct = 0
        let base = game.initialState(options: KlondikeOptions(), dealNumber: 1).stock.contents
        for n in 2...20 {
            let other = game.initialState(options: KlondikeOptions(), dealNumber: n).stock.contents
            if other != base { distinct += 1 }
        }
        // All 19 should differ from deal #1's stock order.
        #expect(distinct == 19)
    }

    @Test("restarting the same deal reproduces the initial board")
    func restartSameDeal() {
        let opts = KlondikeOptions(scoring: .vegas)
        let first = game.initialState(options: opts, dealNumber: 99)
        // "Restart" = re-deal the same number + options.
        let restart = game.initialState(options: opts, dealNumber: 99)
        #expect(first.stock.contents == restart.stock.contents)
        #expect(first.score == restart.score)
    }
}

// MARK: - Session: move counter + timer (R-KLON-3.8)

@Suite("Klondike — session move counter + timer (R-KLON-3.8)")
struct KlondikeSessionTests {
    let game = Klondike()

    @Test("move counter increments per accepted player move")
    func moveCounterIncrements() {
        var session = KlondikeSession(dealNumber: 1)
        #expect(session.moveCount == 0)
        session.recordPlayerMove()
        session.recordPlayerMove()
        #expect(session.moveCount == 2)
    }

    @Test("move counter and timer live outside KlondikeState (determinism unaffected)")
    func sessionOutsideState() throws {
        // The move counter and timer are fields of `KlondikeSession`, NOT `KlondikeState` — so advancing a
        // session can never change the authoritative board. Two identical deals produce structurally
        // identical states (same zone contents, faces, score, passes), and a session that ticks alongside
        // does not touch that state value.
        let s = game.initialState(options: KlondikeOptions(), seed: 123)
        let s2 = game.initialState(options: KlondikeOptions(), seed: 123)
        // Structural determinism of the authoritative state.
        #expect(s.stock.contents == s2.stock.contents)
        #expect(s.tableau.map(\.contents) == s2.tableau.map(\.contents))
        #expect(s.faces == s2.faces)
        #expect(s.score == s2.score)
        #expect(s.passes == s2.passes)

        // Advancing a session is a wholly separate value; the state is a `let` and cannot be mutated by it.
        var session = KlondikeSession(dealNumber: 1)
        session.recordPlayerMove()
        session.startTimer(now: 0)
        #expect(session.moveCount == 1)
        // The state is untouched — still equal to a fresh identical deal.
        #expect(
            s.stock.contents
                == game.initialState(options: KlondikeOptions(), seed: 123).stock.contents)
    }

    @Test("timer accumulates elapsed time across start/pause")
    func timerAccumulates() {
        var session = KlondikeSession(dealNumber: 1)
        session.startTimer(now: 100)
        #expect(session.elapsed(at: 105) == 5)
        session.pauseTimer(now: 110)  // +10 accumulated
        #expect(session.elapsed(at: 999) == 10)  // paused → frozen at 10
        session.startTimer(now: 200)
        #expect(session.elapsed(at: 203) == 13)  // 10 + 3
    }

    @Test("start is idempotent while running; pause is idempotent while paused")
    func timerIdempotent() {
        var session = KlondikeSession(dealNumber: 1)
        session.startTimer(now: 0)
        session.startTimer(now: 50)  // ignored — already running since 0
        #expect(session.elapsed(at: 10) == 10)
        session.pauseTimer(now: 10)
        session.pauseTimer(now: 100)  // ignored — already paused
        #expect(session.elapsed(at: 500) == 10)
    }
}

// MARK: - Heuristic hints (R-KLON-3.5)

@Suite("Klondike — heuristic hints (R-KLON-3.5)")
struct KlondikeHintTests {
    let game = Klondike()

    @Test("hint prefers a move that exposes a face-down card")
    func prefersExposing() {
        // Pile 0: face-down 9♣ under a face-up K♠. Pile 1 empty. Moving K♠ to pile 1 exposes 9♣.
        // Also give a trivial foundation option (Ace on waste) to prove exposing is preferred over it.
        var t = KF.empty7()
        let hidden = KF.card(.nine, .clubs, id: 1)
        let king = KF.card(.king, .spades, id: 2)
        t[0] = [hidden, king]
        let faceUp: [Set<PieceID>] = [[king.id], [], [], [], [], [], []]
        let s = KF.state(
            waste: [KF.card(.ace, .hearts, id: 3)],
            tableau: t, tableauFaceUp: faceUp)
        let hint = game.hint(s)
        #expect(hint == .tableauToTableau(fromPile: 0, card: king.id, toPile: 1))
    }

    @Test("hint advances a foundation safely when no exposing/emptying move exists")
    func advancesFoundation() {
        // Only move available: Ace of spades from waste to foundation (always safe). No tableau builds.
        let s = KF.state(
            waste: [KF.card(.ace, .spades, id: 1)],
            tableau: KF.empty7())
        #expect(game.hint(s) == .wasteToFoundation(toFoundation: 0))
    }

    @Test("hint falls back to any legal move")
    func fallsBackToAny() {
        // Only a stock draw is available.
        let s = KF.state(stock: [KF.card(.two, .clubs, id: 1)], tableau: KF.empty7())
        #expect(game.hint(s) == .drawFromStock)
    }

    @Test("hint is nil when no move exists")
    func nilWhenNoMoves() {
        var t = KF.empty7()
        let fives: [Card] = [
            KF.card(.five, .clubs, id: 1), KF.card(.five, .spades, id: 2),
            KF.card(.five, .hearts, id: 3), KF.card(.five, .diamonds, id: 4),
            KF.card(.five, .clubs, id: 5), KF.card(.five, .spades, id: 6),
            KF.card(.five, .hearts, id: 7),
        ]
        for i in 0..<7 { t[i] = [fives[i]] }
        let s = KF.state(stock: [], waste: [], tableau: t)
        #expect(game.hint(s) == nil)
    }

    @Test("the suggested hint is always a legal action")
    func hintIsLegal() {
        let s = game.initialState(options: KlondikeOptions(), seed: 7)
        if let hint = game.hint(s) {
            #expect(game.legalActions(for: klondikeSeat, in: s).contains(hint))
        }
    }
}
