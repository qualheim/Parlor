// Klondike core legal/illegal move tests (task 3.1).
//
// These build small, fully-known states so a single move's legality, resulting state, and events can be
// asserted precisely — the deterministic complement to the random-deal tests. Helpers below mint cards
// with stable IDs and assemble a `KlondikeState` directly from its public zones + face map.

import EngineCore
import Testing

@testable import GamesRules

/// Test helpers for building controlled Klondike positions.
private enum K {
    /// A card with a deterministic id derived from its face, for readable assertions.
    static func card(_ rank: Rank, _ suit: Suit, id: UInt64) -> Card {
        Card(id: PieceID(raw: id), face: .standard(rank, suit))
    }

    /// Build a state from explicit zone contents. Face-up sets default to "all listed cards face up"
    /// for tableau piles unless overridden.
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
}

@Suite("Klondike — core moves")
struct KlondikeMoveTests {
    let game = Klondike()

    // MARK: Draw / recycle (R-KLON-2.1, R-KLON-2.3)

    @Test("Draw 1 turns one card stock → waste")
    func drawOne() {
        let s = K.state(
            stock: [K.card(.five, .clubs, id: 1), K.card(.six, .hearts, id: 2)],
            tableau: Array(repeating: [], count: 7))
        let result = game.apply(.drawFromStock, by: klondikeSeat, to: s)
        let (next, _) = try! result.get()
        #expect(next.stock.contents.count == 1)
        #expect(next.waste.contents.count == 1)
        // Top of stock (last element) is drawn first.
        #expect(next.waste.contents.last == PieceID(raw: 2))
    }

    @Test("Draw 3 turns three cards")
    func drawThree() {
        let s = K.state(
            stock: [
                K.card(.two, .clubs, id: 1), K.card(.three, .hearts, id: 2),
                K.card(.four, .spades, id: 3), K.card(.five, .diamonds, id: 4),
            ],
            tableau: Array(repeating: [], count: 7),
            options: KlondikeOptions(drawCount: .three))
        let (next, _) = try! game.apply(.drawFromStock, by: klondikeSeat, to: s).get()
        #expect(next.waste.contents.count == 3)
        #expect(next.stock.contents.count == 1)
    }

    @Test("drawing an empty stock is rejected")
    func drawEmptyStockRejected() {
        let s = K.state(stock: [], tableau: Array(repeating: [], count: 7))
        let result = game.apply(.drawFromStock, by: klondikeSeat, to: s)
        #expect(throws: RuleViolation.self) { try result.get() }
    }

    @Test("recycle waste → stock consumes a pass; blocked past the limit (R-KLON-2.3)")
    func recycleConsumesPass() {
        // One-pass limit already at pass 1: recycling would begin pass 2, exceeding the limit → blocked.
        let blocked = K.state(
            stock: [], waste: [K.card(.two, .clubs, id: 1)],
            tableau: Array(repeating: [], count: 7),
            options: KlondikeOptions(stockPasses: .one), passes: 1)
        #expect(throws: RuleViolation.self) {
            try game.apply(.recycleWaste, by: klondikeSeat, to: blocked).get()
        }

        // Unlimited passes: recycle succeeds and increments the pass count.
        let ok = K.state(
            stock: [], waste: [K.card(.two, .clubs, id: 1), K.card(.three, .hearts, id: 2)],
            tableau: Array(repeating: [], count: 7),
            options: KlondikeOptions(stockPasses: .unlimited), passes: 1)
        let (next, _) = try! game.apply(.recycleWaste, by: klondikeSeat, to: ok).get()
        #expect(next.waste.contents.isEmpty)
        #expect(next.stock.contents.count == 2)
        #expect(next.passes == 2)
    }

    // MARK: Foundations (R-KLON-1.2)

    @Test("waste Ace → empty foundation is legal; a two onto empty is not (R-KLON-1.2)")
    func foundationTakesAceFirst() {
        let s = K.state(
            waste: [K.card(.ace, .spades, id: 1)],
            tableau: Array(repeating: [], count: 7))
        let (next, events) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s
        ).get()
        #expect(next.foundations[0].contents == [PieceID(raw: 1)])
        #expect(next.waste.contents.isEmpty)
        #expect(events.contains { if case .pieceMoved = $0 { return true } else { return false } })

        let bad = K.state(
            waste: [K.card(.two, .spades, id: 2)],
            tableau: Array(repeating: [], count: 7))
        #expect(throws: RuleViolation.self) {
            try game.apply(.wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: bad).get()
        }
    }

    @Test("foundation builds up in suit; wrong suit rejected (R-KLON-1.2)")
    func foundationBuildsUpBySuit() {
        // Foundation 0 holds Ace of spades; two of spades follows, two of hearts does not.
        let good = K.state(
            waste: [K.card(.two, .spades, id: 2)],
            tableau: Array(repeating: [], count: 7),
            foundations: [[K.card(.ace, .spades, id: 1)], [], [], []])
        let (next, _) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: good
        ).get()
        #expect(next.foundations[0].contents.count == 2)

        let wrongSuit = K.state(
            waste: [K.card(.two, .hearts, id: 3)],
            tableau: Array(repeating: [], count: 7),
            foundations: [[K.card(.ace, .spades, id: 1)], [], [], []])
        #expect(throws: RuleViolation.self) {
            try game.apply(.wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: wrongSuit)
                .get()
        }
    }

    // MARK: Tableau build-down (R-KLON-1.2, R-KLON-1.4)

    @Test("tableau builds down in alternating color; same color rejected (R-KLON-1.2)")
    func tableauAlternatingColor() {
        // Move red six of hearts (waste) onto black seven of spades (tableau 0 top): legal.
        var t: [[Card]] = Array(repeating: [], count: 7)
        t[0] = [K.card(.seven, .spades, id: 10)]
        let good = K.state(waste: [K.card(.six, .hearts, id: 1)], tableau: t)
        let (next, _) = try! game.apply(
            .wasteToTableau(toPile: 0), by: klondikeSeat, to: good
        ).get()
        #expect(next.tableau[0].contents.last == PieceID(raw: 1))

        // Red six onto red seven (diamonds): rejected (same color).
        var t2: [[Card]] = Array(repeating: [], count: 7)
        t2[0] = [K.card(.seven, .diamonds, id: 11)]
        let bad = K.state(waste: [K.card(.six, .hearts, id: 1)], tableau: t2)
        #expect(throws: RuleViolation.self) {
            try game.apply(.wasteToTableau(toPile: 0), by: klondikeSeat, to: bad).get()
        }
    }

    @Test("only a King may fill an empty tableau pile (R-KLON-1.4)")
    func kingToEmptyPile() {
        // King of clubs from waste onto empty pile 0: legal.
        let kingOK = K.state(
            waste: [K.card(.king, .clubs, id: 1)], tableau: Array(repeating: [], count: 7))
        let (next, _) = try! game.apply(
            .wasteToTableau(toPile: 0), by: klondikeSeat, to: kingOK
        ).get()
        #expect(next.tableau[0].contents == [PieceID(raw: 1)])

        // Queen onto empty pile: rejected.
        let queenBad = K.state(
            waste: [K.card(.queen, .clubs, id: 2)], tableau: Array(repeating: [], count: 7))
        let result = game.apply(.wasteToTableau(toPile: 0), by: klondikeSeat, to: queenBad)
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "empty-needs-king") }
    }

    @Test("a face-up sequence moves as a unit (R-KLON-1.3)")
    func sequenceMovesAsUnit() {
        // Pile 0: black-7♠, red-6♥, black-5♣ (a valid run). Pile 1: red-8♦.
        // Move the run led by 7♠ onto 8♦: 7♠ is one below 8♦ and opposite color → all three move.
        var t: [[Card]] = Array(repeating: [], count: 7)
        t[0] = [
            K.card(.seven, .spades, id: 1), K.card(.six, .hearts, id: 2),
            K.card(.five, .clubs, id: 3),
        ]
        t[1] = [K.card(.eight, .diamonds, id: 10)]
        let s = K.state(tableau: t)
        let (next, _) = try! game.apply(
            .tableauToTableau(fromPile: 0, card: PieceID(raw: 1), toPile: 1),
            by: klondikeSeat, to: s
        ).get()
        #expect(next.tableau[0].contents.isEmpty)
        #expect(
            next.tableau[1].contents == [
                PieceID(raw: 10), PieceID(raw: 1), PieceID(raw: 2), PieceID(raw: 3),
            ])
    }

    @Test("moving a run exposes and flips the new tableau top")
    func exposesFaceDownTopAfterMove() {
        // Pile 0: face-down 9♣ under a face-up King♠. Move the King to empty pile 1; 9♣ turns up.
        var t: [[Card]] = Array(repeating: [], count: 7)
        let hidden = K.card(.nine, .clubs, id: 1)
        let king = K.card(.king, .spades, id: 2)
        t[0] = [hidden, king]
        let faceUp: [Set<PieceID>] = [
            [king.id], [], [], [], [], [], [],
        ]
        let s = K.state(tableau: t, tableauFaceUp: faceUp)
        let (next, events) = try! game.apply(
            .tableauToTableau(fromPile: 0, card: king.id, toPile: 1),
            by: klondikeSeat, to: s
        ).get()
        #expect(next.tableau[0].contents == [hidden.id])
        #expect(next.tableau[0].isFaceUp(hidden.id))
        #expect(
            events.contains {
                if case .pieceFlipped(hidden.id, true) = $0 { return true } else { return false }
            })
    }

    // MARK: Foundation → tableau (R-KLON-1.5)

    @Test("a card may return from a foundation to the tableau (R-KLON-1.5)")
    func foundationBackToTableau() {
        // Foundation 0 top: red 5♥. Tableau 0 top: black 6♠. 5♥ returns onto 6♠ (down, alt color).
        var t: [[Card]] = Array(repeating: [], count: 7)
        t[0] = [K.card(.six, .spades, id: 10)]
        let s = K.state(
            tableau: t,
            foundations: [
                [
                    K.card(.ace, .hearts, id: 1), K.card(.two, .hearts, id: 2),
                    K.card(.three, .hearts, id: 3), K.card(.four, .hearts, id: 4),
                    K.card(.five, .hearts, id: 5),
                ], [], [], [],
            ])
        let (next, _) = try! game.apply(
            .foundationToTableau(fromFoundation: 0, toPile: 0), by: klondikeSeat, to: s
        ).get()
        #expect(next.foundations[0].contents.last == PieceID(raw: 4))
        #expect(next.tableau[0].contents.last == PieceID(raw: 5))
    }

    // MARK: Scoring + win

    @Test("Vegas adds +5 per card to a foundation (R-KLON-2.2)")
    func vegasScoring() {
        let s = K.state(
            waste: [K.card(.ace, .spades, id: 1)],
            tableau: Array(repeating: [], count: 7),
            options: KlondikeOptions(scoring: .vegas), score: -52)
        let (next, events) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s
        ).get()
        #expect(next.score == -47)
        #expect(
            events.contains {
                if case .scoreChanged(_, 5, -47) = $0 { return true } else { return false }
            })
    }

    @Test("None scoring keeps the score at zero (R-KLON-2.2)")
    func noneScoring() {
        let s = K.state(
            waste: [K.card(.ace, .spades, id: 1)],
            tableau: Array(repeating: [], count: 7),
            options: KlondikeOptions(scoring: .none))
        let (next, events) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s
        ).get()
        #expect(next.score == 0)
        #expect(
            !events.contains { if case .scoreChanged = $0 { return true } else { return false } })
    }

    @Test("the final card home wins the game and ends the hand (R-KLON-1.2)")
    func winOnLastCard() {
        // Foundations 0–3 hold Ace..Queen of each suit (48 cards). Four Kings sit one per waste/tableau;
        // place the last King to reach 52 and win. Build 3 foundations complete, 1 needs its King.
        func upTo(_ rank: Rank, _ suit: Suit, startID: UInt64) -> [Card] {
            (1...rank.rawValue).map { r in
                K.card(Rank(rawValue: r)!, suit, id: startID + UInt64(r))
            }
        }
        let f0 = upTo(.king, .clubs, startID: 100)
        let f1 = upTo(.king, .diamonds, startID: 200)
        let f2 = upTo(.king, .hearts, startID: 300)
        let f3 = upTo(.queen, .spades, startID: 400)  // missing King of spades
        let kingSpades = K.card(.king, .spades, id: 413)
        let s = K.state(
            waste: [kingSpades],
            tableau: Array(repeating: [], count: 7),
            foundations: [f0, f1, f2, f3])
        #expect(!game.isTerminal(s))
        let (next, events) = try! game.apply(
            .wasteToFoundation(toFoundation: 3), by: klondikeSeat, to: s
        ).get()
        #expect(game.isTerminal(next))
        #expect(game.outcome(next).winners == [klondikeSeat])
        #expect(events.contains { if case .handEnded = $0 { return true } else { return false } })
    }
}

@Suite("Klondike — redaction")
struct KlondikeRedactionTests {
    let game = Klondike()

    @Test(
        "stock cards are hidden from the seat; face-up tableau + foundations are visible (R-ENG-8.3)"
    )
    func stockHiddenInView() {
        let state = game.initialState(options: KlondikeOptions(), seed: 42)
        let view = game.redactedView(of: state, for: .seat(klondikeSeat))

        // The stock zone view: every piece hidden.
        let stockView = view.zones.first { $0.id == KlondikeZone.stockID }!
        #expect(
            stockView.pieces.allSatisfy {
                if case .hidden = $0 { return true } else { return false }
            })

        // Each tableau pile: exactly one visible (the face-up top), rest hidden.
        for i in 0..<7 {
            let pileView = view.zones.first { $0.id == KlondikeZone.tableau(i) }!
            let known = pileView.pieces.filter {
                if case .known = $0 { return true } else { return false }
            }
            #expect(known.count == 1)
        }
    }
}
