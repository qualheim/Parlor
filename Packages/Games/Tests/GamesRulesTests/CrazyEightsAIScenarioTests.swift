// Crazy Eights AI scenario suite — doc-traceable Given/When/Then coverage of the three tiers + hint
// (task 4.6, R-CE-5.1, R-CE-5.2, R-CE-5.3, R-QA-1.1).
//
// Docs/Rules/crazy-eights.md → "AI opponents" is the single source of truth for how each tier plays.
// Every rule in that section has a Given/When/Then scenario HERE, named after the rule it proves, so the
// mapping prose → test is explicit and auditable (R-QA-1.1, per product.md Definition of Done):
//
//   • Easy   — "plays a random legal card and spends its 8s early" (R-CE-5.1);
//   • Medium — "holds 8s for when they are needed, names its longest suit when it does play one, and
//     tracks suits opponents have failed to follow" (R-CE-5.2);
//   • Hard   — "uses determinized Monte Carlo search from the shared AI toolkit" (R-CE-5.3); and
//   • the shared HINT interface returns a legal suggested move with a plain-language reason (R-AI-6.1).
//
// The tiers see only a redacted `PlayerView` + `PublicLog` + legal actions (the AI information barrier,
// R-AI-1.1); these tests drive them exactly that way — they build a controlled `CrazyEightsState`, ask
// the game for the seat's redacted view + legal actions, and assert on the tier's chosen action. All
// randomness is a fixed, injected `SeededRNG`, so every assertion is deterministic (R-AI-3.2).
//
// Swift Testing (@Suite/@Test/#expect); pure rules layer, no UI frameworks.

import AIKit
import EngineCore
import Testing

@testable import GamesRules

// MARK: - Scenario helpers

/// Builders for controlled Crazy Eights positions + the barrier-safe `DecisionContext` a tier consumes.
private enum CE {
    /// A card with a deterministic id, for readable assertions.
    static func card(_ rank: Rank, _ suit: Suit, id: UInt64) -> Card {
        Card(id: PieceID(raw: id), face: .standard(rank, suit))
    }

    /// Build a state where `handsBySeat[i]` is seat i's hand, the discard's top is `top`, and `activeSuit`
    /// is the suit that must be matched (defaults to the top's suit). The stock holds `stock`. It is
    /// seat 0's turn by default.
    static func state(
        hands: [[Card]],
        top: Card,
        activeSuit: Suit? = nil,
        stock: [Card] = [],
        turn: Int = 0,
        options: CrazyEightsOptions = CrazyEightsOptions(),
        pendingDraw: Int = 0,
        direction: CrazyEightsDirection = .clockwise
    ) -> CrazyEightsState {
        var faces: [PieceID: CardFace] = [:]
        func record(_ cards: [Card]) { for c in cards { faces[c.id] = c.face } }
        hands.forEach(record)
        record(stock)
        record([top])

        let handZones = hands.enumerated().map { (i, cards) in
            Zone(
                id: CrazyEightsZone.hand(i), visibility: .ownerOnly, contents: cards.map(\.id))
        }
        let stockZone = Zone(
            id: CrazyEightsZone.stockID, visibility: .hidden, contents: stock.map(\.id))
        let discardZone = Zone(
            id: CrazyEightsZone.discardID, visibility: .topCardOnly, contents: [top.id],
            faceUp: [top.id])

        return CrazyEightsState(
            hands: handZones, stock: stockZone, discard: discardZone, faces: faces,
            activeSuit: activeSuit ?? (CrazyEightsCard.suit(top.face) ?? .clubs),
            turn: CrazyEightsState.seat(turn), direction: direction, pendingDraw: pendingDraw,
            options: options)
    }

    /// The barrier-safe decision context for `seat`: the seat's redacted view + legal actions from the
    /// game, an empty public log unless supplied, and a fixed injected RNG (R-AI-1.1, R-AI-3.2).
    static func context(
        _ game: CrazyEights, _ state: CrazyEightsState, seat: Int, log: PublicLog = .empty,
        seed: UInt64 = 42
    ) -> DecisionContext {
        let seatID = CrazyEightsState.seat(seat)
        let legal = game.legalActions(for: seatID, in: state).compactMap { try? AnyGameAction($0) }
        return DecisionContext(
            view: game.redactedView(of: state, for: .seat(seatID)),
            publicLog: log, seat: seatID, legalActions: legal, rng: SeededRNG(seed: seed),
            deadline: .never)
    }

    /// Decode a tier's chosen action back to a `CrazyEightsAction` for assertions.
    static func decode(_ action: AnyGameAction?) -> CrazyEightsAction? {
        guard let action else { return nil }
        return try? action.decode(as: CrazyEightsAction.self)
    }
}

// MARK: - Easy: random legal + dump 8s early (R-CE-5.1)

@Suite("Crazy Eights doc: AI — Easy plays random legal and dumps 8s early (R-CE-5.1)")
struct CrazyEightsEasyScenarios {
    let game = CrazyEights()
    let easy = CrazyEightsEasyStrategy()

    @Test("Given an eight is playable, When Easy decides, Then it plays the eight early (R-CE-5.1)")
    func easyDumpsEightEarly() async {
        // GIVEN seat 0 holds an 8 (playable, wild) alongside an ordinary matching card.
        let hand = [
            CE.card(.eight, .spades, id: 1),  // wild — always playable
            CE.card(.three, .hearts, id: 2),  // matches the top's heart suit
        ]
        let top = CE.card(.nine, .hearts, id: 90)
        let state = CE.state(hands: [hand, [CE.card(.king, .clubs, id: 3)]], top: top)

        // WHEN Easy decides.
        let chosen = CE.decode(await easy.decide(CE.context(game, state, seat: 0)))

        // THEN it spends the 8 early (plays it) rather than saving it (R-CE-5.1).
        guard case .playEight = chosen else {
            Issue.record("Easy did not dump its eight early: \(String(describing: chosen))")
            return
        }
    }

    @Test("Given no eight in hand, When Easy decides, Then it picks a legal action (R-CE-5.1)")
    func easyPlaysLegalWhenNoEight() async {
        // GIVEN a hand with no 8, one matching card and one not.
        let hand = [CE.card(.three, .hearts, id: 2), CE.card(.king, .clubs, id: 4)]
        let top = CE.card(.nine, .hearts, id: 90)
        let state = CE.state(
            hands: [hand, [CE.card(.two, .clubs, id: 5)]], top: top,
            stock: [CE.card(.four, .diamonds, id: 6)])

        // WHEN Easy decides.
        let action = await easy.decide(CE.context(game, state, seat: 0))

        // THEN it returns one of the legal actions (R-CE-5.1 — random *legal*).
        let legal = game.legalActions(for: CrazyEightsState.seat(0), in: state)
        #expect(CE.decode(action).map { legal.contains($0) } == true)
    }

    @Test("Given a fixed seed, When Easy decides twice, Then the choice is identical (R-AI-3.2)")
    func easyIsReproducible() async {
        let hand = [CE.card(.three, .hearts, id: 2), CE.card(.four, .hearts, id: 7)]
        let top = CE.card(.nine, .hearts, id: 90)
        let state = CE.state(hands: [hand, [CE.card(.king, .clubs, id: 3)]], top: top)

        let a = await easy.decide(CE.context(game, state, seat: 0, seed: 99))
        let b = await easy.decide(CE.context(game, state, seat: 0, seed: 99))
        #expect(a == b)
    }
}

// MARK: - Medium: hoard 8s, name longest suit, track voids (R-CE-5.2)

@Suite("Crazy Eights doc: AI — Medium hoards 8s, names its longest suit, tracks voids (R-CE-5.2)")
struct CrazyEightsMediumScenarios {
    let game = CrazyEights()
    let medium = CrazyEightsMediumStrategy()

    @Test(
        "Given a non-8 match and an 8 both playable, When Medium decides, Then it hoards the 8 (R-CE-5.2)"
    )
    func mediumHoardsEights() async {
        // GIVEN seat 0 can play either an ordinary heart or a wild 8.
        let hand = [
            CE.card(.eight, .spades, id: 1),  // wild
            CE.card(.three, .hearts, id: 2),  // ordinary match on the heart suit
        ]
        let top = CE.card(.nine, .hearts, id: 90)
        let state = CE.state(hands: [hand, [CE.card(.king, .clubs, id: 3)]], top: top)

        // WHEN Medium decides.
        let chosen = CE.decode(await medium.decide(CE.context(game, state, seat: 0)))

        // THEN it plays the ordinary card and keeps the 8 in reserve (R-CE-5.2).
        guard case .play(let card) = chosen else {
            Issue.record("Medium did not hoard its eight: \(String(describing: chosen))")
            return
        }
        #expect(card == PieceID(raw: 2))
    }

    @Test(
        "Given only an 8 is playable, When Medium plays it, Then it names its longest suit (R-CE-5.2)"
    )
    func mediumNamesLongestSuit() async {
        // GIVEN nothing matches the active suit except the 8; the hand is longest in clubs.
        let hand = [
            CE.card(.eight, .spades, id: 1),  // wild — the only legal play
            CE.card(.king, .clubs, id: 2),
            CE.card(.queen, .clubs, id: 3),
            CE.card(.four, .clubs, id: 4),
            CE.card(.two, .diamonds, id: 5),
        ]
        // Active suit hearts, top rank nine — none of the non-8 cards match.
        let top = CE.card(.nine, .hearts, id: 90)
        let state = CE.state(
            hands: [hand, [CE.card(.king, .diamonds, id: 6)]], top: top, activeSuit: .hearts)

        // WHEN Medium decides (only `playEight` variants + maybe draw are legal).
        let chosen = CE.decode(await medium.decide(CE.context(game, state, seat: 0)))

        // THEN it plays the 8 and names clubs — the suit it holds the most of (R-CE-5.2).
        guard case .playEight(_, let named) = chosen else {
            Issue.record("Medium did not play its only legal eight: \(String(describing: chosen))")
            return
        }
        #expect(named == .clubs)
    }

    @Test(
        "Given an opponent drew off a suit, When Medium reads the log, Then that void is inferred (R-CE-5.2)"
    )
    func mediumTracksOpponentVoids() {
        // GIVEN a public log in which seat 1 drew while spades was the named/active suit — so seat 1 is
        // inferred void in spades (R-CE-5.2). We build the log from a played 8 that named spades, then a
        // draw by seat 1.
        let eight = CE.card(.eight, .clubs, id: 10)
        let namedSpades = try! AnyGameAction(
            CrazyEightsAction.playEight(card: eight.id, namedSuit: .spades))
        let seat1Draw = try! AnyGameAction(CrazyEightsAction.draw)
        let log = PublicLog(actions: [
            PublicActionEntry(seat: CrazyEightsState.seat(0), action: namedSpades),
            PublicActionEntry(seat: CrazyEightsState.seat(1), action: seat1Draw),
        ])

        // WHEN Medium's shared reader infers voids from the log (starting suit clubs).
        let voids = CrazyEightsAI.inferredVoids(from: log, startingSuit: .clubs)

        // THEN seat 1 is recorded void in spades — the suit active when it drew (R-CE-5.2).
        #expect(voids[CrazyEightsState.seat(1)]?.contains(.spades) == true)
    }

    @Test("Given a fixed seed, When Medium decides twice, Then the choice is identical (R-AI-3.2)")
    func mediumIsReproducible() async {
        let hand = [CE.card(.three, .hearts, id: 2), CE.card(.four, .hearts, id: 7)]
        let top = CE.card(.nine, .hearts, id: 90)
        let state = CE.state(hands: [hand, [CE.card(.king, .clubs, id: 3)]], top: top)

        let a = await medium.decide(CE.context(game, state, seat: 0, seed: 7))
        let b = await medium.decide(CE.context(game, state, seat: 0, seed: 7))
        #expect(a == b)
    }
}

// MARK: - Hard: determinized Monte Carlo (R-CE-5.3)

@Suite("Crazy Eights doc: AI — Hard uses determinized Monte Carlo (R-CE-5.3)")
struct CrazyEightsHardScenarios {
    let game = CrazyEights()

    @Test("Given a full deal, When Hard decides, Then it returns a legal move (R-CE-5.3)")
    func hardReturnsLegalMove() async {
        // GIVEN a real seeded deal (hidden opponent hand + stock — the case Hard must determinize).
        let options = CrazyEightsOptions(playerCount: 2)
        let state = game.initialState(options: options, seed: 2024)
        let hard = CrazyEightsHardStrategy(options: options, worlds: 4, rolloutsPerCandidate: 16)

        // WHEN Hard decides for the seat to move.
        let seat = state.turn
        let seatIndex = state.seatIndex(of: seat) ?? 0
        let action = await hard.decide(CE.context(game, state, seat: seatIndex))

        // THEN it returns one of the seat's legal actions (R-CE-5.3) — never nil for a live turn.
        let legal = game.legalActions(for: seat, in: state)
        #expect(CE.decode(action).map { legal.contains($0) } == true)
    }

    @Test("Given only one legal move, When Hard decides, Then it returns that move (R-CE-5.3)")
    func hardReturnsForcedMove() async {
        // GIVEN a position with a single legal action: a hand that can only draw (no match, no 8).
        let hand = [CE.card(.king, .clubs, id: 2)]  // clubs king; active suit hearts, top rank nine
        let top = CE.card(.nine, .hearts, id: 90)
        let state = CE.state(
            hands: [hand, [CE.card(.two, .clubs, id: 5)]], top: top, activeSuit: .hearts,
            stock: [CE.card(.four, .diamonds, id: 6)])
        let hard = CrazyEightsHardStrategy(
            options: state.options, worlds: 4, rolloutsPerCandidate: 16)

        let legal = game.legalActions(for: CrazyEightsState.seat(0), in: state)
        #expect(legal.count == 1)  // only `.draw`

        // WHEN Hard decides. THEN it returns the one legal move (R-CE-5.3).
        let chosen = CE.decode(await hard.decide(CE.context(game, state, seat: 0)))
        #expect(chosen == legal.first)
    }

    @Test("Given a fixed seed, When Hard decides twice, Then the choice is identical (R-AI-3.2)")
    func hardIsReproducible() async {
        let options = CrazyEightsOptions(playerCount: 2)
        let state = game.initialState(options: options, seed: 555)
        let hard = CrazyEightsHardStrategy(options: options, worlds: 4, rolloutsPerCandidate: 16)
        let seatIndex = state.seatIndex(of: state.turn) ?? 0

        let a = await hard.decide(CE.context(game, state, seat: seatIndex, seed: 123))
        let b = await hard.decide(CE.context(game, state, seat: seatIndex, seed: 123))
        #expect(a == b)
    }

    @Test(
        "Given a redacted view, When Hard determinizes, Then it builds a full plausible hand (R-CE-5.3)"
    )
    func hardDeterminizerBuildsFullState() {
        // GIVEN a seeded 3-player deal and seat 0's redacted view (opponents hidden).
        let options = CrazyEightsOptions(playerCount: 3)
        let state = game.initialState(options: options, seed: 77)
        let view = game.redactedView(of: state, for: .seat(CrazyEightsState.seat(0)))
        var rng = SeededRNG(seed: 1)

        // WHEN the determinizer reconstructs a full state from that view alone.
        let determinizer = CrazyEightsDeterminizer(options: options)
        let full = determinizer.makeState(
            view: view, seat: CrazyEightsState.seat(0), log: .empty, rng: &rng)

        // THEN every hidden count is honored and no card is duplicated across the reconstructed hand.
        guard let full else {
            Issue.record("Determinizer failed to build a full state")
            return
        }
        // 3 players → 5 cards each; the stock + buried discard hold the rest of the 52.
        #expect(full.hands.count == 3)
        for hand in full.hands { #expect(hand.contents.count == 5) }
        let allIDs =
            full.hands.flatMap { $0.contents } + full.stock.contents + full.discard.contents
        #expect(Set(allIDs).count == allIDs.count)  // no duplicates
        #expect(allIDs.count == 52)  // whole pack accounted for
    }
}

// MARK: - Hint interface (R-AI-6.1, R-AI-6.2)

@Suite("Crazy Eights doc: AI — hint suggests a legal move with a reason (R-AI-6.1)")
struct CrazyEightsHintScenarios {
    let game = CrazyEights()

    @Test(
        "Given a live turn, When a hint is requested, Then it suggests a legal move with a reason (R-AI-6.1)"
    )
    func hintSuggestsLegalMoveWithReason() async {
        // GIVEN a real seeded deal.
        let options = CrazyEightsOptions(playerCount: 2)
        let state = game.initialState(options: options, seed: 2025)
        let seat = state.turn

        // WHEN a hint is requested for the seat to move.
        let hint = await game.hint(for: seat, in: state)

        // THEN the hint suggests one of the legal actions and carries a non-empty explanation (R-AI-6.1).
        guard let hint else {
            Issue.record("No hint produced for a live turn")
            return
        }
        let legal = game.legalActions(for: seat, in: state)
        #expect(CE.decode(hint.action).map { legal.contains($0) } == true)
        #expect(!hint.explanation.isEmpty)
    }

    @Test("Given a fixed seed, When a hint is requested twice, Then it is identical (R-AI-3.2)")
    func hintIsReproducible() async {
        let options = CrazyEightsOptions(playerCount: 2)
        let state = game.initialState(options: options, seed: 2026)
        let seat = state.turn

        let a = await game.hint(for: seat, in: state, rng: SeededRNG(seed: 5))
        let b = await game.hint(for: seat, in: state, rng: SeededRNG(seed: 5))
        #expect(a?.action == b?.action)
    }
}
