// Klondike scenario suite — the exhaustive, doc-traceable Given/When/Then coverage (task 3.2, R-QA-1.1).
//
// Docs/Rules/klondike.md is the single source of truth. Every rule and every option in that document has
// a Given/When/Then scenario test HERE, one-for-one. Each test names the exact doc section and/or the
// R-KLON-… rule id it proves, so the mapping from prose → test is explicit and auditable (R-QA-1.1, per
// product.md Definition of Done).
//
// This file EXTENDS the task-3.1 slice in KlondikeTests.swift / KlondikeMoveTests.swift; it does not
// duplicate their core-move checks. Where 3.1 already proved a fact (e.g. the unlimited undo policy),
// this suite re-states the doc section it belongs to and asserts the same public contract so the doc's
// section is covered here too, without relying on the other file's private helpers.
//
// Conventions:
//   • Given/When/Then is spelled out in a leading comment on each test so the doc mapping is obvious.
//   • Deterministic, hand-built states (the `KS` helper below) are used for precise assertions; the
//     seeded `initialState` is used only for the deal-facts scenarios.
//   • Q-1 (Standard scoring magnitudes) is PROVISIONAL: those tests assert against the
//     `KlondikeStandardScoring` named constants, never hardcoded magic numbers, so the test proves the
//     wiring/structure and survives a confirmed Q-1 table. Each such test carries a `// Q-1` note.
//   • Swift Testing (@Suite/@Test/#expect); pure rules layer, no UI frameworks.

import EngineCore
import Testing

@testable import GamesRules

// MARK: - Scenario test helpers

/// Builders for controlled Klondike positions, local to this file (the 3.1 `K` helper is file-private to
/// KlondikeMoveTests). Mirrors that builder's shape so the two suites read alike.
private enum KS {
    /// A card with a deterministic id derived by the caller, for readable assertions.
    static func card(_ rank: Rank, _ suit: Suit, id: UInt64) -> Card {
        Card(id: PieceID(raw: id), face: .standard(rank, suit))
    }

    /// Build a state from explicit zone contents. Tableau face-up sets default to "all listed cards face
    /// up" unless overridden via `tableauFaceUp`.
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

    /// Seven empty tableau piles — the common scaffold for waste-only scenarios.
    static var emptyTableau: [[Card]] { Array(repeating: [], count: 7) }

    /// A complete A→K foundation for `suit`, ids `startID+1 … startID+13`.
    static func fullFoundation(_ suit: Suit, startID: UInt64) -> [Card] {
        (1...13).map { r in card(Rank(rawValue: r)!, suit, id: startID + UInt64(r)) }
    }

    /// An A→`rank` foundation for `suit`, ids `startID+1 … startID+rank`.
    static func foundationUpTo(_ rank: Rank, _ suit: Suit, startID: UInt64) -> [Card] {
        (1...rank.rawValue).map { r in card(Rank(rawValue: r)!, suit, id: startID + UInt64(r)) }
    }

    /// Extract the first `scoreChanged` delta from an event list, if any.
    static func scoreDelta(in events: [GameEvent]) -> Int? {
        for e in events {
            if case .scoreChanged(_, let delta, _) = e { return delta }
        }
        return nil
    }

    /// Whether the events contain any `scoreChanged`.
    static func hasScoreChange(_ events: [GameEvent]) -> Bool {
        events.contains { if case .scoreChanged = $0 { return true } else { return false } }
    }

    /// Whether the events contain a `pieceFlipped(id, faceUp: true)`.
    static func hasFlip(of id: PieceID, in events: [GameEvent]) -> Bool {
        events.contains {
            if case .pieceFlipped(id, true) = $0 { return true } else { return false }
        }
    }
}

// MARK: - Objective / win condition

@Suite("Klondike doc: Objective (R-KLON-1.2 / win)")
struct KlondikeObjectiveScenarios {
    let game = Klondike()

    // Doc §Objective, R-KLON-1.2/win: "the game is over and won the moment all four foundations are
    // complete (13 cards each, 52 in total)."
    @Test("R-KLON-1.2/win — all 52 cards on foundations ⇒ terminal and won")
    func allFiftyTwoHomeWins() {
        // Given: three complete foundations and one at Queen (spades missing its King), King of spades on
        //   the waste — 51 cards home, one to go.
        let f0 = KS.fullFoundation(.clubs, startID: 100)
        let f1 = KS.fullFoundation(.diamonds, startID: 200)
        let f2 = KS.fullFoundation(.hearts, startID: 300)
        let f3 = KS.foundationUpTo(.queen, .spades, startID: 400)
        let kingSpades = KS.card(.king, .spades, id: 413)
        let s = KS.state(
            waste: [kingSpades], tableau: KS.emptyTableau, foundations: [f0, f1, f2, f3])
        // Given: with 51 home the game is not yet won.
        #expect(!game.isTerminal(s))

        // When: the final King is sent to its foundation.
        let (next, events) = try! game.apply(
            .wasteToFoundation(toFoundation: 3), by: klondikeSeat, to: s
        ).get()

        // Then: all 52 are home, the game is terminal and won, and the hand ends.
        #expect(next.foundations.reduce(0) { $0 + $1.contents.count } == 52)
        #expect(game.isTerminal(next))
        #expect(game.outcome(next).winners == [klondikeSeat])
        #expect(events.contains { if case .handEnded = $0 { return true } else { return false } })
    }

    // Doc §Objective: a game still short of 52 home is not terminal (the boundary just below the win).
    @Test("R-KLON-1.2/win — 51 cards home is not yet a win")
    func fiftyOneIsNotWon() {
        // Given: 51 cards home (three suits complete, spades to the Queen).
        let f0 = KS.fullFoundation(.clubs, startID: 100)
        let f1 = KS.fullFoundation(.diamonds, startID: 200)
        let f2 = KS.fullFoundation(.hearts, startID: 300)
        let f3 = KS.foundationUpTo(.queen, .spades, startID: 400)
        // When: we inspect terminality.
        let s = KS.state(tableau: KS.emptyTableau, foundations: [f0, f1, f2, f3])
        // Then: not terminal; the outcome reports no winner yet.
        #expect(!game.isTerminal(s))
        #expect(game.outcome(s).winners.isEmpty)
    }
}

// MARK: - The deal and the board (R-KLON-1.1)

@Suite("Klondike doc: The deal and the board (R-KLON-1.1)")
struct KlondikeDealScenarios {
    let game = Klondike()

    // Doc §"The deal and the board", R-KLON-1.1: seven columns hold 1,2,3,4,5,6,7 cards — 28 in all.
    @Test("R-KLON-1.1 — seven columns hold 1…7 cards, 28 total")
    func columnsHoldOneThroughSeven() {
        // Given/When: a fresh seeded deal.
        let s = game.initialState(options: KlondikeOptions(), seed: 20240601)
        // Then: pile i holds i+1 cards, summing to 28.
        #expect(s.tableau.count == 7)
        for (i, pile) in s.tableau.enumerated() {
            #expect(pile.contents.count == i + 1)
        }
        #expect(s.tableau.reduce(0) { $0 + $1.contents.count } == 28)
    }

    // Doc §"The deal and the board", R-KLON-1.1: exactly one card per column is face up (its top).
    @Test("R-KLON-1.1 — exactly one card per column is face up (the top)")
    func oneFaceUpPerColumn() {
        // Given/When: a fresh seeded deal.
        let s = game.initialState(options: KlondikeOptions(), seed: 20240601)
        // Then: each pile has exactly one face-up card, and it is the top card.
        for pile in s.tableau {
            #expect(pile.faceUp.count == 1)
            #expect(pile.faceUp.contains(pile.contents.last!))
        }
    }

    // Doc §"The deal and the board", R-KLON-1.1: the stock holds twenty-four cards, all face down.
    @Test("R-KLON-1.1 — stock holds 24 cards, all face down (hidden)")
    func stockHoldsTwentyFourHidden() {
        // Given/When: a fresh seeded deal.
        let s = game.initialState(options: KlondikeOptions(), seed: 20240601)
        // Then: 24 cards in the stock, and its visibility is hidden with nothing turned up.
        #expect(s.stock.contents.count == 24)
        #expect(s.stock.visibility == .hidden)
        #expect(s.stock.faceUp.isEmpty)
    }

    // Doc §"The deal and the board", R-KLON-1.1: the waste starts empty; all four foundations start empty.
    @Test("R-KLON-1.1 — waste starts empty; four foundations start empty")
    func wasteAndFoundationsStartEmpty() {
        // Given/When: a fresh seeded deal.
        let s = game.initialState(options: KlondikeOptions(), seed: 20240601)
        // Then: waste empty, exactly four foundations, all empty.
        #expect(s.waste.contents.isEmpty)
        #expect(s.foundations.count == 4)
        #expect(s.foundations.allSatisfy { $0.contents.isEmpty })
    }

    // Doc §"The deal and the board", R-KLON-1.1: a single standard 52-card pack, no duplicates.
    @Test("R-KLON-1.1 — one standard 52-card pack, no card lost or duplicated")
    func fullPackDealtOnce() {
        // Given/When: a fresh seeded deal.
        let s = game.initialState(options: KlondikeOptions(), seed: 20240601)
        // Then: 52 distinct cards spread across all zones, each with a known face.
        let all =
            s.stock.contents + s.waste.contents + s.tableau.flatMap(\.contents)
            + s.foundations.flatMap(\.contents)
        #expect(all.count == 52)
        #expect(Set(all).count == 52)
        #expect(s.faces.count == 52)
    }
}

// MARK: - Foundations build up by suit (R-KLON-1.2)

@Suite("Klondike doc: Foundations build up by suit (R-KLON-1.2)")
struct KlondikeFoundationScenarios {
    let game = Klondike()

    // Doc §"Foundations build up by suit", R-KLON-1.2: an empty foundation accepts an Ace.
    @Test("R-KLON-1.2 — an empty foundation accepts an Ace")
    func emptyFoundationTakesAce() {
        // Given: an Ace of spades on the waste and an empty foundation 0.
        let s = KS.state(waste: [KS.card(.ace, .spades, id: 1)], tableau: KS.emptyTableau)
        // When: the Ace is sent to foundation 0.
        let (next, _) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the foundation now holds the Ace.
        #expect(next.foundations[0].contents == [PieceID(raw: 1)])
    }

    // Doc §"Foundations build up by suit", R-KLON-1.2: an empty foundation rejects a non-Ace.
    @Test("R-KLON-1.2 — an empty foundation rejects a non-Ace (a two)")
    func emptyFoundationRejectsNonAce() {
        // Given: a two of spades on the waste and an empty foundation 0.
        let s = KS.state(waste: [KS.card(.two, .spades, id: 1)], tableau: KS.emptyTableau)
        // When: we try to send the two onto the empty foundation.
        let result = game.apply(.wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s)
        // Then: it is rejected with the foundation-build violation.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "wrong-foundation-build") }
    }

    // Doc §"Foundations build up by suit", R-KLON-1.2: same suit, exactly one rank higher, succeeds.
    @Test("R-KLON-1.2 — same suit, next rank up, is accepted")
    func nextRankSameSuitAccepted() {
        // Given: foundation 0 holds Ace of spades; two of spades is on the waste.
        let s = KS.state(
            waste: [KS.card(.two, .spades, id: 2)], tableau: KS.emptyTableau,
            foundations: [[KS.card(.ace, .spades, id: 1)], [], [], []])
        // When: the two of spades is sent to foundation 0.
        let (next, _) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the foundation now holds A,2 of spades.
        #expect(next.foundations[0].contents == [PieceID(raw: 1), PieceID(raw: 2)])
    }

    // Doc §"Foundations build up by suit", R-KLON-1.2: wrong suit is rejected.
    @Test("R-KLON-1.2 — wrong suit onto a foundation is rejected")
    func wrongSuitRejected() {
        // Given: foundation 0 holds Ace of spades; two of hearts (wrong suit) is on the waste.
        let s = KS.state(
            waste: [KS.card(.two, .hearts, id: 2)], tableau: KS.emptyTableau,
            foundations: [[KS.card(.ace, .spades, id: 1)], [], [], []])
        // When: we try to send the wrong-suit two.
        let result = game.apply(.wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s)
        // Then: rejected with the foundation-build violation.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "wrong-foundation-build") }
    }

    // Doc §"Foundations build up by suit", R-KLON-1.2: wrong rank (a skip) is rejected.
    @Test("R-KLON-1.2 — wrong rank (skipping a rank) onto a foundation is rejected")
    func wrongRankRejected() {
        // Given: foundation 0 holds Ace of spades; three of spades (skips the two) is on the waste.
        let s = KS.state(
            waste: [KS.card(.three, .spades, id: 3)], tableau: KS.emptyTableau,
            foundations: [[KS.card(.ace, .spades, id: 1)], [], [], []])
        // When: we try to send the three onto A of the same suit.
        let result = game.apply(.wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s)
        // Then: rejected — foundations advance exactly one rank at a time.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "wrong-foundation-build") }
    }
}

// MARK: - The tableau builds down in alternating colors (R-KLON-1.2)

@Suite("Klondike doc: Tableau builds down, alternating colors (R-KLON-1.2)")
struct KlondikeTableauBuildScenarios {
    let game = Klondike()

    // Doc §"The tableau builds down in alternating colors", R-KLON-1.2: red six sits on black seven.
    @Test("R-KLON-1.2 — one rank lower + opposite color is accepted")
    func downAlternatingAccepted() {
        // Given: black 7♠ on pile 0's top; red 6♥ on the waste.
        var t = KS.emptyTableau
        t[0] = [KS.card(.seven, .spades, id: 10)]
        let s = KS.state(waste: [KS.card(.six, .hearts, id: 1)], tableau: t)
        // When: the red six is placed on the black seven.
        let (next, _) = try! game.apply(
            .wasteToTableau(toPile: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the six lands on the pile.
        #expect(next.tableau[0].contents.last == PieceID(raw: 1))
    }

    // Doc §"The tableau builds down in alternating colors", R-KLON-1.2: same color is rejected.
    @Test("R-KLON-1.2 — same color onto the tableau is rejected")
    func sameColorRejected() {
        // Given: red 7♦ on pile 0's top; red 6♥ on the waste (same color).
        var t = KS.emptyTableau
        t[0] = [KS.card(.seven, .diamonds, id: 11)]
        let s = KS.state(waste: [KS.card(.six, .hearts, id: 1)], tableau: t)
        // When: we try to place the red six on the red seven.
        let result = game.apply(.wasteToTableau(toPile: 0), by: klondikeSeat, to: s)
        // Then: rejected with the tableau-build violation.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "wrong-tableau-build") }
    }

    // Doc §"The tableau builds down in alternating colors", R-KLON-1.2: wrong rank is rejected.
    @Test("R-KLON-1.2 — wrong rank (not one lower) onto the tableau is rejected")
    func wrongRankRejected() {
        // Given: black 7♠ on pile 0's top; red 5♥ on the waste (two ranks lower, opposite color).
        var t = KS.emptyTableau
        t[0] = [KS.card(.seven, .spades, id: 10)]
        let s = KS.state(waste: [KS.card(.five, .hearts, id: 1)], tableau: t)
        // When: we try to place the red five on the black seven.
        let result = game.apply(.wasteToTableau(toPile: 0), by: klondikeSeat, to: s)
        // Then: rejected — the moving card must be exactly one rank below the target.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "wrong-tableau-build") }
    }
}

// MARK: - Face-up sequences move as a unit (R-KLON-1.3)

@Suite("Klondike doc: Face-up sequences move as a unit (R-KLON-1.3)")
struct KlondikeSequenceScenarios {
    let game = Klondike()

    // Doc §"Face-up sequences move as a unit", R-KLON-1.3: a proper run moves together onto a legal top.
    @Test("R-KLON-1.3 — a descending alternating run moves as one unit")
    func validRunMovesTogether() {
        // Given: pile 0 = black 7♠, red 6♥, black 5♣ (a valid run); pile 1 top = red 8♦.
        var t = KS.emptyTableau
        t[0] = [
            KS.card(.seven, .spades, id: 1), KS.card(.six, .hearts, id: 2),
            KS.card(.five, .clubs, id: 3),
        ]
        t[1] = [KS.card(.eight, .diamonds, id: 10)]
        let s = KS.state(tableau: t)
        // When: the run led by 7♠ moves onto 8♦ (one lower, opposite color).
        let (next, _) = try! game.apply(
            .tableauToTableau(fromPile: 0, card: PieceID(raw: 1), toPile: 1),
            by: klondikeSeat, to: s
        ).get()
        // Then: all three cards move as a unit; the source empties.
        #expect(next.tableau[0].contents.isEmpty)
        #expect(
            next.tableau[1].contents == [
                PieceID(raw: 10), PieceID(raw: 1), PieceID(raw: 2), PieceID(raw: 3),
            ])
    }

    // Doc §"Face-up sequences move as a unit", R-KLON-1.3: a non-sequence run is rejected.
    @Test("R-KLON-1.3 — a non-sequence run is rejected as not movable")
    func invalidRunRejected() {
        // Given: pile 0 = black 7♠ then red 5♥ (a gap — not a valid run), both face up; pile 1 = red 8♦.
        var t = KS.emptyTableau
        t[0] = [KS.card(.seven, .spades, id: 1), KS.card(.five, .hearts, id: 2)]
        t[1] = [KS.card(.eight, .diamonds, id: 10)]
        let s = KS.state(tableau: t)
        // When: we try to move the run led by 7♠ (which drags the non-following 5♥).
        let result = game.apply(
            .tableauToTableau(fromPile: 0, card: PieceID(raw: 1), toPile: 1),
            by: klondikeSeat, to: s)
        // Then: rejected — the picked-up cards are not a proper sequence.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "not-a-sequence") }
    }

    // Doc §"Face-up sequences move as a unit", R-KLON-1.3: the run's LEAD must legally place on the dest.
    @Test("R-KLON-1.3 — a valid run whose lead cannot legally place is rejected")
    func runLeadMustPlaceLegally() {
        // Given: pile 0 = red 6♥, black 5♣ (a valid run led by 6♥); pile 1 top = red 8♦.
        //   6♥ onto 8♦ is not one-lower, so the whole run has nowhere legal to land here.
        var t = KS.emptyTableau
        t[0] = [KS.card(.six, .hearts, id: 1), KS.card(.five, .clubs, id: 2)]
        t[1] = [KS.card(.eight, .diamonds, id: 10)]
        let s = KS.state(tableau: t)
        // When: we try to move the run led by 6♥ onto 8♦.
        let result = game.apply(
            .tableauToTableau(fromPile: 0, card: PieceID(raw: 1), toPile: 1),
            by: klondikeSeat, to: s)
        // Then: rejected on the tableau-build rule — the lead card does not follow the destination top.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "wrong-tableau-build") }
    }
}

// MARK: - Only a King fills an empty column (R-KLON-1.4)

@Suite("Klondike doc: Only a King fills an empty column (R-KLON-1.4)")
struct KlondikeEmptyColumnScenarios {
    let game = Klondike()

    // Doc §"Only a King fills an empty column", R-KLON-1.4: a lone King may enter an empty column.
    @Test("R-KLON-1.4 — a King may fill an empty column")
    func kingFillsEmptyColumn() {
        // Given: King of clubs on the waste; pile 0 empty.
        let s = KS.state(waste: [KS.card(.king, .clubs, id: 1)], tableau: KS.emptyTableau)
        // When: the King is placed on the empty pile 0.
        let (next, _) = try! game.apply(
            .wasteToTableau(toPile: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the King occupies the pile.
        #expect(next.tableau[0].contents == [PieceID(raw: 1)])
    }

    // Doc §"Only a King fills an empty column", R-KLON-1.4: a non-King is rejected with the King code.
    @Test("R-KLON-1.4 — a non-King into an empty column is rejected (empty-needs-king)")
    func nonKingRejectedFromEmptyColumn() {
        // Given: a Queen of clubs on the waste; pile 0 empty.
        let s = KS.state(waste: [KS.card(.queen, .clubs, id: 1)], tableau: KS.emptyTableau)
        // When: we try to place the Queen on the empty pile.
        let result = game.apply(.wasteToTableau(toPile: 0), by: klondikeSeat, to: s)
        // Then: rejected specifically with the empty-needs-king reason.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "empty-needs-king") }
    }

    // Doc §"Only a King fills an empty column", R-KLON-1.4: a King-LED run may fill an empty column.
    @Test("R-KLON-1.4 — a run led by a King may fill an empty column")
    func kingLedRunFillsEmptyColumn() {
        // Given: pile 0 = black K♠, red Q♥ (a valid King-led run); pile 1 empty.
        var t = KS.emptyTableau
        t[0] = [KS.card(.king, .spades, id: 1), KS.card(.queen, .hearts, id: 2)]
        let s = KS.state(tableau: t)
        // When: the King-led run moves into the empty pile 1.
        let (next, _) = try! game.apply(
            .tableauToTableau(fromPile: 0, card: PieceID(raw: 1), toPile: 1),
            by: klondikeSeat, to: s
        ).get()
        // Then: both cards move into the previously empty column.
        #expect(next.tableau[0].contents.isEmpty)
        #expect(next.tableau[1].contents == [PieceID(raw: 1), PieceID(raw: 2)])
    }

    // Doc §"Only a King fills an empty column", R-KLON-1.4: a non-King-led run is rejected.
    @Test("R-KLON-1.4 — a run NOT led by a King cannot fill an empty column")
    func nonKingLedRunRejected() {
        // Given: pile 0 = red Q♥, black J♠ (a valid run led by Q♥, but not a King); pile 1 empty.
        var t = KS.emptyTableau
        t[0] = [KS.card(.queen, .hearts, id: 1), KS.card(.jack, .spades, id: 2)]
        let s = KS.state(tableau: t)
        // When: we try to move the Queen-led run into the empty pile 1.
        let result = game.apply(
            .tableauToTableau(fromPile: 0, card: PieceID(raw: 1), toPile: 1),
            by: klondikeSeat, to: s)
        // Then: rejected with the empty-needs-king reason.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "empty-needs-king") }
    }
}

// MARK: - Cards may come back from a foundation (R-KLON-1.5)

@Suite("Klondike doc: Cards may come back from a foundation (R-KLON-1.5)")
struct KlondikeFoundationReturnScenarios {
    let game = Klondike()

    // Doc §"Cards may come back from a foundation", R-KLON-1.5: a foundation top returns onto a legal top.
    @Test("R-KLON-1.5 — a foundation top may return to a legal tableau spot")
    func foundationReturnsToTableau() {
        // Given: foundation 0 = A..5♥ (top red 5♥); pile 0 top = black 6♠.
        var t = KS.emptyTableau
        t[0] = [KS.card(.six, .spades, id: 10)]
        let s = KS.state(
            tableau: t,
            foundations: [KS.foundationUpTo(.five, .hearts, startID: 0), [], [], []])
        // When: the 5♥ is moved back from the foundation onto the 6♠.
        let (next, _) = try! game.apply(
            .foundationToTableau(fromFoundation: 0, toPile: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the foundation drops to 4♥ and the tableau top is now 5♥.
        #expect(next.foundations[0].contents.last == PieceID(raw: 4))
        #expect(next.tableau[0].contents.last == PieceID(raw: 5))
    }

    // Doc §"Cards may come back from a foundation", R-KLON-1.5: the return is subject to the build-down.
    @Test("R-KLON-1.5 — a foundation return that breaks the build-down rule is rejected")
    func foundationReturnMustBeLegal() {
        // Given: foundation 0 = A..5♥ (top red 5♥); pile 0 top = red 6♦ (same color — illegal target).
        var t = KS.emptyTableau
        t[0] = [KS.card(.six, .diamonds, id: 10)]
        let s = KS.state(
            tableau: t,
            foundations: [KS.foundationUpTo(.five, .hearts, startID: 0), [], [], []])
        // When: we try to return 5♥ onto the same-color 6♦.
        let result = game.apply(
            .foundationToTableau(fromFoundation: 0, toPile: 0), by: klondikeSeat, to: s)
        // Then: rejected on the tableau-build rule.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "wrong-tableau-build") }
    }
}

// MARK: - Turning the stock exposes a fresh column top (exposed-top flip rule)

@Suite("Klondike doc: Exposed tableau top turns face up")
struct KlondikeExposedTopScenarios {
    let game = Klondike()

    // Doc §"Turning the stock exposes a fresh column top": when a move clears the face-up cards off a
    // column, the newly exposed face-down top turns up and becomes playable.
    @Test("exposed-top rule — a face-down top turns up after the run above it leaves")
    func exposedTopFlipsUp() {
        // Given: pile 0 = face-down 9♣ under a face-up K♠; pile 1 empty.
        var t = KS.emptyTableau
        let hidden = KS.card(.nine, .clubs, id: 1)
        let king = KS.card(.king, .spades, id: 2)
        t[0] = [hidden, king]
        let faceUp: [Set<PieceID>] = [[king.id], [], [], [], [], [], []]
        let s = KS.state(tableau: t, tableauFaceUp: faceUp)
        // When: the King moves to the empty pile 1, exposing the 9♣.
        let (next, events) = try! game.apply(
            .tableauToTableau(fromPile: 0, card: king.id, toPile: 1),
            by: klondikeSeat, to: s
        ).get()
        // Then: the 9♣ is now the top of pile 0 and is face up, with a pieceFlipped event emitted.
        #expect(next.tableau[0].contents == [hidden.id])
        #expect(next.tableau[0].isFaceUp(hidden.id))
        #expect(KS.hasFlip(of: hidden.id, in: events))
    }

    // Doc §exposed-top: a newly exposed top that is ALREADY face up is not re-flipped (no spurious
    // event) — the rule only turns up a face-DOWN exposed top.
    @Test("exposed-top rule — an already-face-up new top is not re-flipped")
    func alreadyFaceUpTopNotReflipped() {
        // Given: pile 0 = red 6♥ then black 5♣, BOTH face up; pile 1 top = red 8♦. Moving only the top
        //   5♣ (a single-card run) exposes 6♥, which is already face up.
        var t = KS.emptyTableau
        let six = KS.card(.six, .hearts, id: 1)
        let five = KS.card(.five, .clubs, id: 2)
        t[0] = [six, five]
        t[1] = [KS.card(.eight, .diamonds, id: 10)]
        // 5♣ does not follow 8♦ (not one lower), so move it instead onto a red 6? Use pile 2 = red 6♦
        //   so the single black 5♣ can land there, leaving 6♥ exposed on pile 0.
        t[2] = [KS.card(.six, .diamonds, id: 20)]
        let s = KS.state(tableau: t)
        // When: only the top 5♣ moves onto 6♦ (one lower, opposite color), exposing the face-up 6♥.
        let (next, events) = try! game.apply(
            .tableauToTableau(fromPile: 0, card: five.id, toPile: 2),
            by: klondikeSeat, to: s
        ).get()
        // Then: 6♥ is the exposed top of pile 0, still face up, and NO new pieceFlipped event fired.
        #expect(next.tableau[0].contents == [six.id])
        #expect(next.tableau[0].isFaceUp(six.id))
        #expect(
            !events.contains { if case .pieceFlipped = $0 { return true } else { return false } })
    }
}

// MARK: - Option: Draw count (R-KLON-2.1)

@Suite("Klondike doc: Option — Draw count (R-KLON-2.1)")
struct KlondikeDrawCountScenarios {
    let game = Klondike()

    // Doc §"Draw count", R-KLON-2.1 default: Draw 1 turns one card at a time.
    @Test("R-KLON-2.1 — Draw 1 (default) turns exactly one card stock → waste")
    func drawOneTurnsOne() {
        // Given: default options (Draw 1) with two cards in the stock.
        let s = KS.state(
            stock: [KS.card(.five, .clubs, id: 1), KS.card(.six, .hearts, id: 2)],
            tableau: KS.emptyTableau)
        #expect(s.options.drawCount == .one)  // default per doc
        // When: we draw.
        let (next, _) = try! game.apply(.drawFromStock, by: klondikeSeat, to: s).get()
        // Then: exactly one card moved; the top of the stock (id 2) is now on the waste.
        #expect(next.waste.contents.count == 1)
        #expect(next.stock.contents.count == 1)
        #expect(next.waste.contents.last == PieceID(raw: 2))
    }

    // Doc §"Draw count", R-KLON-2.1: Draw 3 turns three at a time; only the top of the three is playable.
    @Test("R-KLON-2.1 — Draw 3 turns three cards; the last drawn is on top")
    func drawThreeTurnsThree() {
        // Given: Draw 3 options with four cards in the stock.
        let s = KS.state(
            stock: [
                KS.card(.two, .clubs, id: 1), KS.card(.three, .hearts, id: 2),
                KS.card(.four, .spades, id: 3), KS.card(.five, .diamonds, id: 4),
            ],
            tableau: KS.emptyTableau, options: KlondikeOptions(drawCount: .three))
        // When: we draw.
        let (next, _) = try! game.apply(.drawFromStock, by: klondikeSeat, to: s).get()
        // Then: three cards on the waste. The stock top (id 4) is drawn first, so after turning three
        //   the LAST one turned (id 2) sits on the waste top and is the immediately playable card.
        #expect(next.waste.contents.count == 3)
        #expect(next.stock.contents.count == 1)
        #expect(next.waste.contents.last == PieceID(raw: 2))
    }

    // Doc §"Draw count", R-KLON-2.1: a partial stock draws only what remains under Draw 3.
    @Test("R-KLON-2.1 — Draw 3 with fewer than three cards draws the remainder")
    func drawThreePartial() {
        // Given: Draw 3 with only two cards in the stock.
        let s = KS.state(
            stock: [KS.card(.two, .clubs, id: 1), KS.card(.three, .hearts, id: 2)],
            tableau: KS.emptyTableau, options: KlondikeOptions(drawCount: .three))
        // When: we draw.
        let (next, _) = try! game.apply(.drawFromStock, by: klondikeSeat, to: s).get()
        // Then: both remaining cards move; the stock empties.
        #expect(next.waste.contents.count == 2)
        #expect(next.stock.contents.isEmpty)
    }
}

// MARK: - Option: Scoring choice (R-KLON-2.2)

@Suite("Klondike doc: Option — Scoring (R-KLON-2.2)")
struct KlondikeScoringOptionScenarios {
    // Doc §"Scoring", R-KLON-2.2 default: Standard.
    @Test("R-KLON-2.2 — the default scoring scheme is Standard")
    func scoringDefaultStandard() {
        // Given/When: the schema defaults.
        // Then: Standard is the default choice.
        #expect(Klondike.optionsSchema.defaults.scoring == .standard)
    }

    // Doc §"Scoring", R-KLON-2.2: all three schemes are selectable.
    @Test("R-KLON-2.2 — Standard, Vegas, and None are all selectable")
    func scoringOptionsExist() {
        // Given/When: the enumerated scoring cases.
        // Then: exactly the three documented schemes exist.
        #expect(Set(KlondikeScoring.allCases) == [.standard, .vegas, .none])
    }
}

// MARK: - Option: Stock passes (R-KLON-2.3)

@Suite("Klondike doc: Option — Stock passes (R-KLON-2.3)")
struct KlondikeStockPassesScenarios {
    let game = Klondike()

    // Doc §"Stock passes", R-KLON-2.3 default: Unlimited.
    @Test("R-KLON-2.3 — the default stock-passes choice is Unlimited")
    func passesDefaultUnlimited() {
        // Given/When: the schema defaults.
        // Then: Unlimited is the default (no cap).
        #expect(Klondike.optionsSchema.defaults.stockPasses == .unlimited)
        #expect(KlondikeStockPasses.unlimited.maxPasses == nil)
    }

    // Doc §"Stock passes", R-KLON-2.3: recycling the empty stock from the waste consumes a pass.
    @Test("R-KLON-2.3 — recycling the waste consumes a pass (Unlimited)")
    func recycleConsumesPass() {
        // Given: empty stock, two cards on the waste, Unlimited passes, currently on pass 1.
        let s = KS.state(
            stock: [], waste: [KS.card(.two, .clubs, id: 1), KS.card(.three, .hearts, id: 2)],
            tableau: KS.emptyTableau, options: KlondikeOptions(stockPasses: .unlimited), passes: 1)
        // When: we recycle the waste back into the stock.
        let (next, _) = try! game.apply(.recycleWaste, by: klondikeSeat, to: s).get()
        // Then: waste empties, cards return to the stock face-down, and the pass count advances.
        #expect(next.waste.contents.isEmpty)
        #expect(next.stock.contents.count == 2)
        #expect(next.passes == 2)
    }

    // Doc §"Stock passes", R-KLON-2.3: One pass means no recycling — recycle is blocked past the limit.
    @Test("R-KLON-2.3 — One pass blocks recycling past the limit")
    func onePassBlocksRecycle() {
        // Given: One-pass limit, already on pass 1 (the deal-down). Recycling would begin pass 2.
        let s = KS.state(
            stock: [], waste: [KS.card(.two, .clubs, id: 1)],
            tableau: KS.emptyTableau, options: KlondikeOptions(stockPasses: .one), passes: 1)
        // When: we try to recycle.
        let result = game.apply(.recycleWaste, by: klondikeSeat, to: s)
        // Then: blocked with the no-passes-left reason; recycle is not offered as a legal action either.
        #expect(throws: RuleViolation.self) { try result.get() }
        if case .failure(let v) = result { #expect(v.code == "no-passes-left") }
        #expect(!game.legalActions(for: klondikeSeat, in: s).contains(.recycleWaste))
    }

    // Doc §"Stock passes", R-KLON-2.3: Three passes permits two recycles then blocks the third.
    @Test("R-KLON-2.3 — Three passes permits two recycles, then blocks")
    func threePassesBlockAfterTwoRecycles() {
        // Given: Three-pass limit, currently on the last allowed pass (3). A further recycle → pass 4.
        let atLimit = KS.state(
            stock: [], waste: [KS.card(.two, .clubs, id: 1)],
            tableau: KS.emptyTableau, options: KlondikeOptions(stockPasses: .three), passes: 3)
        // When/Then: recycling at pass 3 is blocked.
        let blocked = game.apply(.recycleWaste, by: klondikeSeat, to: atLimit)
        #expect(throws: RuleViolation.self) { try blocked.get() }

        // Given: on pass 2 (below the limit) — a recycle is still allowed.
        let allowed = KS.state(
            stock: [], waste: [KS.card(.two, .clubs, id: 1)],
            tableau: KS.emptyTableau, options: KlondikeOptions(stockPasses: .three), passes: 2)
        // When: we recycle.
        let (next, _) = try! game.apply(.recycleWaste, by: klondikeSeat, to: allowed).get()
        // Then: it succeeds and advances to pass 3.
        #expect(next.passes == 3)
    }

    // Doc §"Stock passes", R-KLON-2.3 Vegas override: passes default to ONE with Draw 1.
    @Test("R-KLON-2.3 — Vegas override: Draw 1 forces a single pass")
    func vegasOverrideDrawOne() {
        // Given: Vegas + Draw 1, even with Unlimited chosen explicitly.
        let o = KlondikeOptions(drawCount: .one, scoring: .vegas, stockPasses: .unlimited)
        // When/Then: the effective limit is one pass, overriding the explicit Unlimited.
        #expect(o.effectiveStockPasses.maxPasses == 1)
    }

    // Doc §"Stock passes", R-KLON-2.3 Vegas override: passes default to THREE with Draw 3.
    @Test("R-KLON-2.3 — Vegas override: Draw 3 forces three passes")
    func vegasOverrideDrawThree() {
        // Given: Vegas + Draw 3, even with Unlimited chosen explicitly.
        let o = KlondikeOptions(drawCount: .three, scoring: .vegas, stockPasses: .unlimited)
        // When/Then: the effective limit is three passes.
        #expect(o.effectiveStockPasses.maxPasses == 3)
    }

    // Doc §"Stock passes", R-KLON-2.3: for non-Vegas the explicit choice is honored as-is.
    @Test("R-KLON-2.3 — non-Vegas honors the explicit passes choice")
    func nonVegasHonorsChoice() {
        // Given: Standard scoring with an explicit three-pass choice.
        let o = KlondikeOptions(scoring: .standard, stockPasses: .three)
        // When/Then: the effective limit is the chosen three (no override).
        #expect(o.effectiveStockPasses.maxPasses == 3)
    }
}

// MARK: - Option: Timed scoring (R-KLON-2.4)

@Suite("Klondike doc: Option — Timed scoring (R-KLON-2.4)")
struct KlondikeTimedScenarios {
    let game = Klondike()

    // Doc §"Timed scoring", R-KLON-2.4 default: Off.
    @Test("R-KLON-2.4 — timed scoring defaults to Off")
    func timedDefaultOff() {
        // Given/When: the schema defaults.
        // Then: timed is off by default.
        #expect(Klondike.optionsSchema.defaults.timed == false)
    }

    // Doc §"Timed scoring", R-KLON-2.4: the flag is represented and honored in the dealt state. (The
    // clock/bonus itself is later work; the option must be modeled now — Q-1 time bonus formula pending.)
    @Test("R-KLON-2.4 — the timed flag is carried through into the dealt state")
    func timedFlagRepresented() {
        // Given: timed-on options.
        let on = KlondikeOptions(timed: true)
        // When: a game is dealt with them.
        let s = game.initialState(options: on, seed: 5)
        // Then: the state records the timed choice; the off default is likewise represented.
        #expect(s.options.timed == true)
        let off = game.initialState(options: KlondikeOptions(timed: false), seed: 5)
        #expect(off.options.timed == false)
    }
}

// MARK: - Option: Vegas cumulative bankroll (R-KLON-2.2)

@Suite("Klondike doc: Option — Vegas cumulative bankroll (R-KLON-2.2)")
struct KlondikeVegasCumulativeScenarios {
    let game = Klondike()

    // Doc §"Vegas cumulative bankroll", R-KLON-2.2 default: Off (each Vegas game starts fresh at −52).
    @Test("R-KLON-2.2 — Vegas cumulative defaults to Off")
    func cumulativeDefaultOff() {
        // Given/When: the schema defaults.
        // Then: the cumulative flag is off by default.
        #expect(Klondike.optionsSchema.defaults.vegasCumulative == false)
    }

    // Doc §"Vegas cumulative bankroll", R-KLON-2.2 (Q-2 NEEDS REVIEW): only the on/off choice is modeled
    // now; the dealt Vegas game still starts at −52 regardless of the flag (persistence is deferred).
    @Test(
        "R-KLON-2.2 — the cumulative flag is modeled; a fresh Vegas deal still starts at −52 (Q-2)")
    func cumulativeFlagModeledStartsAtMinus52() {
        // Given: Vegas with cumulative on, and Vegas with cumulative off.
        let onDeal = game.initialState(
            options: KlondikeOptions(scoring: .vegas, vegasCumulative: true), seed: 3)
        let offDeal = game.initialState(
            options: KlondikeOptions(scoring: .vegas, vegasCumulative: false), seed: 3)
        // When/Then: the flag is carried, and both fresh deals start at −52 (carry-across is a later,
        //   Q-2, persistence concern, not a rules concern).
        #expect(onDeal.options.vegasCumulative == true)
        #expect(offDeal.options.vegasCumulative == false)
        #expect(onDeal.score == -52)
        #expect(offDeal.score == -52)
    }
}

// MARK: - Presets (R-KLON-2.5)

@Suite("Klondike doc: Presets (R-KLON-2.5)")
struct KlondikePresetScenarios {
    /// Look up a preset by name.
    private func preset(_ name: String) -> KlondikeOptions? {
        Klondike.optionsSchema.presets.first { $0.name == name }?.options
    }

    // Doc §"Presets", R-KLON-2.5: "Draw 1 / Standard" — the classic default game.
    @Test("R-KLON-2.5 — preset 'Draw 1 / Standard' = Draw 1, Standard, Unlimited, timer off")
    func presetDraw1Standard() {
        // Given/When: the named preset.
        let o = preset("Draw 1 / Standard")
        // Then: it selects the classic default combination.
        #expect(o?.drawCount == .one)
        #expect(o?.scoring == .standard)
        #expect(o?.stockPasses == .unlimited)
        #expect(o?.timed == false)
    }

    // Doc §"Presets", R-KLON-2.5: "Draw 3 / Vegas" — passes follow the Vegas override (three).
    @Test("R-KLON-2.5 — preset 'Draw 3 / Vegas' = Draw 3, Vegas; passes resolve to three")
    func presetDraw3Vegas() {
        // Given/When: the named preset.
        let o = preset("Draw 3 / Vegas")
        // Then: Draw 3 + Vegas, and the effective passes resolve to three via the override.
        #expect(o?.drawCount == .three)
        #expect(o?.scoring == .vegas)
        #expect(o?.effectiveStockPasses.maxPasses == 3)
    }

    // Doc §"Presets", R-KLON-2.5: "Relaxed / No scoring" — Draw 1, no score, Unlimited passes.
    @Test("R-KLON-2.5 — preset 'Relaxed / No scoring' = Draw 1, None, Unlimited")
    func presetRelaxed() {
        // Given/When: the named preset.
        let o = preset("Relaxed / No scoring")
        // Then: a low-pressure Draw 1 game with no scoring and unlimited passes.
        #expect(o?.drawCount == .one)
        #expect(o?.scoring == KlondikeScoring.none)
        #expect(o?.stockPasses == .unlimited)
    }

    // Doc §"Presets", R-KLON-2.5: exactly the three documented presets are offered, in order.
    @Test("R-KLON-2.5 — exactly the three documented presets are offered")
    func presetsListed() {
        // Given/When: the preset names.
        let names = Klondike.optionsSchema.presets.map(\.name)
        // Then: the three doc presets are present.
        #expect(names == ["Draw 1 / Standard", "Draw 3 / Vegas", "Relaxed / No scoring"])
    }
}

// MARK: - Scoring: Standard (Q-1 provisional — assert against the named constants)

@Suite("Klondike doc: Scoring — Standard (Q-1 provisional)")
struct KlondikeStandardScoringScenarios {
    let game = Klondike()
    private var standard: KlondikeOptions { KlondikeOptions(scoring: .standard) }

    // Doc §"Scoring → Standard" (Q-1): a waste card played onto the tableau adds `wasteToTableau`.
    @Test("Standard — waste → tableau adds KlondikeStandardScoring.wasteToTableau (Q-1)")
    func standardWasteToTableau() {
        // Q-1: assert against the named constant, not a hardcoded value.
        // Given: black 7♠ on pile 0; red 6♥ on the waste; Standard scoring at 0.
        var t = KS.emptyTableau
        t[0] = [KS.card(.seven, .spades, id: 10)]
        let s = KS.state(waste: [KS.card(.six, .hearts, id: 1)], tableau: t, options: standard)
        // When: the waste card is played onto the tableau.
        let (next, events) = try! game.apply(
            .wasteToTableau(toPile: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the score increases by exactly the provisional wasteToTableau constant, with an event.
        #expect(next.score == KlondikeStandardScoring.wasteToTableau)
        #expect(KS.scoreDelta(in: events) == KlondikeStandardScoring.wasteToTableau)
    }

    // Doc §"Scoring → Standard" (Q-1): a card sent to a foundation adds `cardToFoundation`.
    @Test("Standard — card → foundation adds KlondikeStandardScoring.cardToFoundation (Q-1)")
    func standardCardToFoundation() {
        // Q-1: assert against the named constant.
        // Given: an Ace of spades on the waste; empty foundations; Standard scoring at 0.
        let s = KS.state(
            waste: [KS.card(.ace, .spades, id: 1)], tableau: KS.emptyTableau, options: standard)
        // When: the Ace goes to a foundation.
        let (next, events) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the score increases by exactly the provisional cardToFoundation constant.
        #expect(next.score == KlondikeStandardScoring.cardToFoundation)
        #expect(KS.scoreDelta(in: events) == KlondikeStandardScoring.cardToFoundation)
    }

    // Doc §"Scoring → Standard" (Q-1): turning a face-down tableau card up adds `tableauCardFlipped`.
    @Test("Standard — a flip adds KlondikeStandardScoring.tableauCardFlipped (Q-1)")
    func standardFlipScores() {
        // Q-1: assert against the named constant.
        // Given: pile 0 = face-down 9♣ under a face-up K♠; pile 1 empty; Standard scoring at 0.
        var t = KS.emptyTableau
        let hidden = KS.card(.nine, .clubs, id: 1)
        let king = KS.card(.king, .spades, id: 2)
        t[0] = [hidden, king]
        let faceUp: [Set<PieceID>] = [[king.id], [], [], [], [], [], []]
        let s = KS.state(tableau: t, tableauFaceUp: faceUp, options: standard)
        // When: the King moves off, exposing and flipping the 9♣.
        let (next, events) = try! game.apply(
            .tableauToTableau(fromPile: 0, card: king.id, toPile: 1),
            by: klondikeSeat, to: s
        ).get()
        // Then: the only scoring move here is the flip; the score equals the flip constant.
        #expect(next.score == KlondikeStandardScoring.tableauCardFlipped)
        #expect(KS.hasFlip(of: hidden.id, in: events))
        #expect(KS.scoreDelta(in: events) == KlondikeStandardScoring.tableauCardFlipped)
    }

    // Doc §"Scoring → Standard" (Q-1): moving a card back from a foundation applies `foundationToTableau`
    // (a negative delta).
    @Test(
        "Standard — foundation → tableau applies KlondikeStandardScoring.foundationToTableau (Q-1)")
    func standardFoundationRetreat() {
        // Q-1: assert against the named constant (a penalty).
        // Given: foundation 0 = A..5♥ (top 5♥); pile 0 top = black 6♠; Standard scoring at 0.
        var t = KS.emptyTableau
        t[0] = [KS.card(.six, .spades, id: 10)]
        let s = KS.state(
            tableau: t, foundations: [KS.foundationUpTo(.five, .hearts, startID: 0), [], [], []],
            options: standard)
        // When: the 5♥ returns to the tableau.
        let (next, events) = try! game.apply(
            .foundationToTableau(fromFoundation: 0, toPile: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the score changes by exactly the provisional (negative) foundationToTableau constant.
        #expect(next.score == KlondikeStandardScoring.foundationToTableau)
        #expect(KS.scoreDelta(in: events) == KlondikeStandardScoring.foundationToTableau)
    }

    // Doc §"Scoring → Standard" (Q-1): recycling the waste applies `wasteRecyclePenalty`.
    @Test("Standard — recycle applies KlondikeStandardScoring.wasteRecyclePenalty (Q-1)")
    func standardRecyclePenalty() {
        // Q-1: assert against the named constant (a penalty). Unlimited passes so recycle is allowed.
        // Given: empty stock, one card on the waste, Standard + Unlimited passes, score 0.
        let s = KS.state(
            stock: [], waste: [KS.card(.two, .clubs, id: 1)], tableau: KS.emptyTableau,
            options: KlondikeOptions(scoring: .standard, stockPasses: .unlimited), passes: 1)
        // When: we recycle the waste.
        let (next, events) = try! game.apply(.recycleWaste, by: klondikeSeat, to: s).get()
        // Then: the score changes by exactly the provisional recycle penalty constant.
        #expect(next.score == KlondikeStandardScoring.wasteRecyclePenalty)
        #expect(KS.scoreDelta(in: events) == KlondikeStandardScoring.wasteRecyclePenalty)
    }
}

// MARK: - Scoring: Vegas (R-KLON-2.2)

@Suite("Klondike doc: Scoring — Vegas (R-KLON-2.2)")
struct KlondikeVegasScoringScenarios {
    let game = Klondike()

    // Doc §"Scoring → Vegas", R-KLON-2.2: a new Vegas game's score starts at exactly −52.
    @Test("R-KLON-2.2 — a fresh Vegas game starts at exactly −52")
    func vegasStartsAtMinus52() {
        // Given/When: a fresh Vegas deal.
        let s = game.initialState(options: KlondikeOptions(scoring: .vegas), seed: 11)
        // Then: the bankroll starts at −52.
        #expect(s.score == -52)
    }

    // Doc §"Scoring → Vegas", R-KLON-2.2: sending any card to a foundation increases the score by 5.
    @Test("R-KLON-2.2 — each card sent to a foundation adds exactly +5 (Vegas)")
    func vegasFoundationAddsFive() {
        // Given: an Ace of spades on the waste; Vegas scoring at −52.
        let s = KS.state(
            waste: [KS.card(.ace, .spades, id: 1)], tableau: KS.emptyTableau,
            options: KlondikeOptions(scoring: .vegas), score: -52)
        // When: the Ace goes to a foundation.
        let (next, events) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the score rises by exactly 5, from −52 to −47, with a matching event.
        #expect(next.score == -47)
        #expect(KS.scoreDelta(in: events) == 5)
    }

    // Doc §"Scoring → Vegas", R-KLON-2.2: moving a card back off a foundation does NOT refund.
    @Test("R-KLON-2.2 — retreating a foundation card does not refund (Vegas)")
    func vegasNoRefundOnRetreat() {
        // Given: foundation 0 = A..5♥ (top 5♥); pile 0 top = black 6♠; Vegas score at some value.
        var t = KS.emptyTableau
        t[0] = [KS.card(.six, .spades, id: 10)]
        let s = KS.state(
            tableau: t, foundations: [KS.foundationUpTo(.five, .hearts, startID: 0), [], [], []],
            options: KlondikeOptions(scoring: .vegas), score: -30)
        // When: the 5♥ returns to the tableau.
        let (next, events) = try! game.apply(
            .foundationToTableau(fromFoundation: 0, toPile: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the score is unchanged (Vegas scores only cards *sent* home), no scoreChanged event.
        #expect(next.score == -30)
        #expect(!KS.hasScoreChange(events))
    }
}

// MARK: - Scoring: None (R-KLON-2.2)

@Suite("Klondike doc: Scoring — None (R-KLON-2.2)")
struct KlondikeNoneScoringScenarios {
    let game = Klondike()
    private var none: KlondikeOptions { KlondikeOptions(scoring: .none) }

    // Doc §"Scoring → None", R-KLON-2.2: the score reads zero throughout; no scoreChanged events.
    @Test(
        "R-KLON-2.2 — None keeps the score at zero across scoring moves, with no scoreChanged events"
    )
    func noneKeepsZero() {
        // Given: an Ace on the waste; None scoring at 0.
        let s = KS.state(
            waste: [KS.card(.ace, .spades, id: 1)], tableau: KS.emptyTableau, options: none)
        // When: the Ace goes to a foundation (a move that would score under Standard/Vegas).
        let (next, events) = try! game.apply(
            .wasteToFoundation(toFoundation: 0), by: klondikeSeat, to: s
        ).get()
        // Then: the score stays 0 and no scoreChanged event is emitted.
        #expect(next.score == 0)
        #expect(!KS.hasScoreChange(events))
    }

    // Doc §"Scoring → None", R-KLON-2.2: the outcome reports zero even after a completed game.
    @Test("R-KLON-2.2 — None reports a zero outcome score on a won game")
    func noneOutcomeZero() {
        // Given: 51 cards home under None; the last King on the waste.
        let f0 = KS.fullFoundation(.clubs, startID: 100)
        let f1 = KS.fullFoundation(.diamonds, startID: 200)
        let f2 = KS.fullFoundation(.hearts, startID: 300)
        let f3 = KS.foundationUpTo(.queen, .spades, startID: 400)
        let s = KS.state(
            waste: [KS.card(.king, .spades, id: 413)], tableau: KS.emptyTableau,
            foundations: [f0, f1, f2, f3], options: none)
        // When: the final King goes home, winning the game.
        let (next, _) = try! game.apply(
            .wasteToFoundation(toFoundation: 3), by: klondikeSeat, to: s
        ).get()
        // Then: the game is won but the reported score is zero.
        #expect(game.isTerminal(next))
        #expect(game.outcome(next).scores[klondikeSeat] == 0)
    }
}

// MARK: - Undo (R-KLON-3.4)

@Suite("Klondike doc: Undo (R-KLON-3.4)")
struct KlondikeUndoScenarios {
    let game = Klondike()

    // Doc §"Undo", R-KLON-3.4: Klondike declares unlimited undo/redo. (The engine provides the machinery;
    // the game's declaration is what this suite pins to the doc section. Core undo behavior is 3.1.)
    @Test("R-KLON-3.4 — the game declares an unlimited undo policy")
    func undoUnlimited() {
        // Given/When: the game's declared undo policy.
        // Then: it is unlimited.
        #expect(game.undoPolicy == .unlimited)
    }
}
