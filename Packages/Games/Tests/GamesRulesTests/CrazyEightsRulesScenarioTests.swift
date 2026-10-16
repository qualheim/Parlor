// Crazy Eights rules scenario suite — doc-traceable Given/When/Then coverage of the move rules, the
// action-card option, save encoding, and the AI tiers' edge paths (R-CE-2, R-CE-4.1, R-CE-5, R-ENG-8.5,
// R-QA-1.1, R-QA-7.1).
//
// Docs/Rules/crazy-eights.md is the source of truth. Each scenario names the rule it proves:
//
//   • rejected moves carry a typed `RuleViolation` (not your turn, hand over, card not in hand, an 8
//     needs a named suit, only an 8 names a suit, no match, cannot draw, cannot pass) (R-CE-2.1…2.4);
//   • the action-card variant: Ace reverses, Jack skips, 2 makes the next seat draw two and 2s stack,
//     a pending draw can only be paid or stacked (R-CE-4.1);
//   • the documented defaults for the open action-card questions: 2-player Jack/Ace, 8 never an action
//     card, starter action card has no effect (Q-4, Q-5 — NEEDS REVIEW);
//   • a state and its options survive a save round-trip, with the player count clamped (R-ENG-8.5);
//   • every tier's hint explains each kind of move, Hard falls back to a legal heuristic move when no
//     full deal fits the public information, and the shared AI readers handle sparse views (R-CE-5,
//     R-AI-6.1, R-AI-3.1).
//
// Positions are hand-built and every random choice comes from a fixed `SeededRNG`, so each assertion
// is deterministic (R-AI-3.2). Swift Testing (@Suite/@Test/#expect); pure rules layer, no UI frameworks.

import AIKit
import EngineCore
import Foundation
import Testing

@testable import GamesRules

// MARK: - Scenario helpers

/// Builders for controlled Crazy Eights positions and barrier-safe decision contexts.
private enum C8 {
    static func card(_ rank: Rank, _ suit: Suit, id: UInt64) -> Card {
        Card(id: PieceID(raw: id), face: .standard(rank, suit))
    }

    static func seat(_ index: Int) -> SeatID { CrazyEightsState.seat(index) }

    /// A position where `hands[i]` is seat i's hand, `discard` is the discard pile bottom→top (the last
    /// card is the top), and `stock` is the stock bottom→top. The active suit defaults to the top's suit.
    static func state(
        hands: [[Card]],
        discard: [Card],
        activeSuit: Suit? = nil,
        stock: [Card] = [],
        turn: Int = 0,
        options: CrazyEightsOptions = CrazyEightsOptions(),
        pendingDraw: Int = 0,
        direction: CrazyEightsDirection = .clockwise
    ) -> CrazyEightsState {
        var faces: [PieceID: CardFace] = [:]
        for card in hands.flatMap({ $0 }) + discard + stock { faces[card.id] = card.face }
        let handZones = hands.enumerated().map { index, cards in
            Zone(id: CrazyEightsZone.hand(index), visibility: .ownerOnly, contents: cards.map(\.id))
        }
        let top = Set(discard.suffix(1).map(\.id))
        return CrazyEightsState(
            hands: handZones,
            stock: Zone(
                id: CrazyEightsZone.stockID, visibility: .hidden, contents: stock.map(\.id)),
            discard: Zone(
                id: CrazyEightsZone.discardID, visibility: .topCardOnly,
                contents: discard.map(\.id), faceUp: top),
            faces: faces,
            activeSuit: activeSuit ?? discard.last.flatMap { CrazyEightsCard.suit($0.face) }
                ?? .clubs,
            turn: seat(turn), direction: direction, pendingDraw: pendingDraw, options: options)
    }

    /// The seat's redacted view + legal actions, a public log, and a fixed RNG (R-AI-1.1, R-AI-3.2).
    static func context(
        _ state: CrazyEightsState, seat index: Int, log: PublicLog = .empty, seed: UInt64 = 42
    ) -> DecisionContext {
        let game = CrazyEights()
        let seatID = seat(index)
        let legal = game.legalActions(for: seatID, in: state).compactMap { try? AnyGameAction($0) }
        return DecisionContext(
            view: game.redactedView(of: state, for: .seat(seatID)), publicLog: log, seat: seatID,
            legalActions: legal, rng: SeededRNG(seed: seed), deadline: .never)
    }

    static func decode(_ action: AnyGameAction?) -> CrazyEightsAction? {
        guard let action else { return nil }
        return try? action.decode(as: CrazyEightsAction.self)
    }

    /// The violation code `apply` returned, or `nil` if the move was accepted.
    static func violation(
        _ action: CrazyEightsAction, by seatIndex: Int, in state: CrazyEightsState
    ) -> String? {
        if case .failure(let violation) = CrazyEights().apply(
            action, by: seat(seatIndex), to: state)
        {
            return violation.code
        }
        return nil
    }

    /// The accepted next state, or `nil` (with a recorded issue) if the move was rejected.
    static func applied(
        _ action: CrazyEightsAction, by seatIndex: Int, in state: CrazyEightsState
    ) -> CrazyEightsState? {
        switch CrazyEights().apply(action, by: seat(seatIndex), to: state) {
        case .success(let (next, _)):
            return next
        case .failure(let violation):
            Issue.record("Move \(action) was rejected: \(violation.code)")
            return nil
        }
    }

    static func entry(_ seatIndex: Int, _ action: CrazyEightsAction) -> PublicActionEntry {
        PublicActionEntry(seat: seat(seatIndex), action: try! AnyGameAction(action))
    }
}

/// A non-trivial three-seat table with the nine of hearts on top and a one-card stock.
private enum Table {
    static let top = C8.card(.nine, .hearts, id: 90)
    static let stockCard = C8.card(.four, .diamonds, id: 80)
    static let seat1 = [C8.card(.king, .spades, id: 11), C8.card(.two, .hearts, id: 12)]
    static let seat2 = [C8.card(.queen, .clubs, id: 21), C8.card(.five, .spades, id: 22)]
}

// MARK: - Rejected moves (R-CE-2.1 … R-CE-2.4)

@Suite("Crazy Eights doc: illegal moves are rejected with a reason (R-CE-2)")
struct CrazyEightsViolationScenarios {
    @Test("Given it is seat 0's turn, When seat 1 plays, Then the move is rejected (not-your-turn)")
    func notYourTurn() {
        let state = C8.state(
            hands: [[C8.card(.three, .hearts, id: 1)], Table.seat1], discard: [Table.top])
        #expect(C8.violation(.play(card: PieceID(raw: 12)), by: 1, in: state) == "not-your-turn")
    }

    @Test("Given a seat has gone out, When anyone moves, Then the move is rejected (hand-over)")
    func handOver() {
        let state = C8.state(hands: [[], Table.seat1], discard: [Table.top], turn: 1)
        #expect(C8.violation(.draw, by: 1, in: state) == "hand-over")
    }

    @Test(
        "Given a card not in hand, When it is played or played as an 8, Then not-in-hand (R-CE-2.1)"
    )
    func cardNotInHand() {
        let state = C8.state(
            hands: [[C8.card(.three, .hearts, id: 1)], Table.seat1], discard: [Table.top])
        let opponentsCard = PieceID(raw: 11)
        #expect(C8.violation(.play(card: opponentsCard), by: 0, in: state) == "not-in-hand")
        #expect(
            C8.violation(.playEight(card: opponentsCard, namedSuit: .clubs), by: 0, in: state)
                == "not-in-hand")
    }

    @Test(
        "Given an 8 in hand, When it is played without naming a suit, Then eight-needs-suit (R-CE-2.2)"
    )
    func eightNeedsSuit() {
        let state = C8.state(
            hands: [
                [C8.card(.eight, .clubs, id: 1), C8.card(.three, .hearts, id: 2)], Table.seat1,
            ],
            discard: [Table.top])
        #expect(C8.violation(.play(card: PieceID(raw: 1)), by: 0, in: state) == "eight-needs-suit")
    }

    @Test("Given a non-8, When it is played naming a suit, Then not-an-eight (R-CE-2.2)")
    func onlyAnEightNamesASuit() {
        let state = C8.state(
            hands: [
                [C8.card(.three, .hearts, id: 1), C8.card(.four, .hearts, id: 2)], Table.seat1,
            ],
            discard: [Table.top])
        #expect(
            C8.violation(.playEight(card: PieceID(raw: 1), namedSuit: .spades), by: 0, in: state)
                == "not-an-eight")
    }

    @Test(
        "Given a card matching neither suit nor rank, When it is played, Then no-match (R-CE-2.1)")
    func noMatch() {
        let state = C8.state(
            hands: [
                [C8.card(.king, .clubs, id: 1), C8.card(.three, .hearts, id: 2)], Table.seat1,
            ],
            discard: [Table.top])
        #expect(C8.violation(.play(card: PieceID(raw: 1)), by: 0, in: state) == "no-match")
        #expect(!CrazyEights.matchViolation(activeSuit: .hearts).reason.isEmpty)
    }

    @Test(
        "Given an empty stock and nothing to recycle, When the player draws, Then cannot-draw (R-CE-2.4)"
    )
    func cannotDraw() {
        let state = C8.state(
            hands: [
                [C8.card(.king, .clubs, id: 1), C8.card(.three, .hearts, id: 2)], Table.seat1,
            ],
            discard: [Table.top])
        #expect(C8.violation(.draw, by: 0, in: state) == "cannot-draw")
    }

    @Test("Given the stock can still be drawn, When the player passes, Then must-act (R-CE-2.4)")
    func cannotPassWhileDrawIsPossible() {
        let state = C8.state(
            hands: [[C8.card(.king, .clubs, id: 1), C8.card(.queen, .clubs, id: 2)], Table.seat1],
            discard: [Table.top], stock: [Table.stockCard])
        #expect(C8.violation(.pass, by: 0, in: state) == "must-act")
    }

    @Test("Given a playable card and no draw, When the player passes, Then must-play (R-CE-2.4)")
    func cannotPassHoldingAPlay() {
        let state = C8.state(
            hands: [
                [C8.card(.three, .hearts, id: 1), C8.card(.queen, .clubs, id: 2)], Table.seat1,
            ],
            discard: [Table.top])
        #expect(C8.violation(.pass, by: 0, in: state) == "must-play")
    }

    @Test(
        "Given no play and no draw, When the player passes, Then the turn moves on (R-CE-2.4, Q-3)")
    func passIsLegalWhenStuck() {
        // GIVEN no card matches and the stock is empty with nothing to recycle.
        let state = C8.state(
            hands: [[C8.card(.king, .clubs, id: 1), C8.card(.queen, .clubs, id: 2)], Table.seat1],
            discard: [Table.top])
        #expect(CrazyEights().legalActions(for: C8.seat(0), in: state) == [.pass])
        // WHEN seat 0 passes. THEN it is seat 1's turn and nothing else changed.
        let next = C8.applied(.pass, by: 0, in: state)
        #expect(next?.turn == C8.seat(1))
        #expect(next?.hands.map(\.contents) == state.hands.map(\.contents))
    }
}

// MARK: - Action cards (R-CE-4.1)

@Suite(
    "Crazy Eights doc: action cards — Ace reverses, Jack skips, 2s make the next seat draw (R-CE-4.1)"
)
struct CrazyEightsActionCardScenarios {
    let actionOptions = CrazyEightsOptions(playerCount: 3, actionCards: true)

    @Test(
        "Given action cards on, When an Ace is played, Then direction reverses and play goes back")
    func aceReverses() {
        // GIVEN three seats, clockwise, seat 0 to move holding the Ace of hearts.
        let state = C8.state(
            hands: [
                [C8.card(.ace, .hearts, id: 1), C8.card(.six, .clubs, id: 2)], Table.seat1,
                Table.seat2,
            ],
            discard: [Table.top], options: actionOptions)
        // WHEN seat 0 plays the Ace.
        let next = C8.applied(.play(card: PieceID(raw: 1)), by: 0, in: state)
        // THEN play runs counter-clockwise, so seat 2 (not seat 1) moves next.
        #expect(next?.direction == .counterClockwise)
        #expect(next?.turn == C8.seat(2))
        #expect(CrazyEightsDirection.counterClockwise.reversed == .clockwise)
    }

    @Test("Given action cards on, When a Jack is played, Then the next seat is skipped")
    func jackSkips() {
        let state = C8.state(
            hands: [
                [C8.card(.jack, .hearts, id: 1), C8.card(.six, .clubs, id: 2)], Table.seat1,
                Table.seat2,
            ],
            discard: [Table.top], options: actionOptions)
        let next = C8.applied(.play(card: PieceID(raw: 1)), by: 0, in: state)
        #expect(next?.turn == C8.seat(2))
        #expect(next?.direction == .clockwise)
    }

    @Test("Given action cards on, When an ordinary card is played, Then the turn passes normally")
    func ordinaryCardAdvances() {
        let state = C8.state(
            hands: [
                [C8.card(.six, .hearts, id: 1), C8.card(.six, .clubs, id: 2)], Table.seat1,
                Table.seat2,
            ],
            discard: [Table.top], options: actionOptions)
        let next = C8.applied(.play(card: PieceID(raw: 1)), by: 0, in: state)
        #expect(next?.turn == C8.seat(1))
        #expect(next?.pendingDraw == 0)
    }

    @Test(
        "Given action cards on, When a 2 is played, Then the next seat owes two and may only draw or stack"
    )
    func twoForcesDrawOrStack() {
        // GIVEN seat 0 holds the 2 of hearts; seat 1 holds a matching King of hearts and the 2 of spades.
        let seat1 = [C8.card(.king, .hearts, id: 11), C8.card(.two, .spades, id: 12)]
        let state = C8.state(
            hands: [
                [C8.card(.two, .hearts, id: 1), C8.card(.six, .clubs, id: 2)], seat1, Table.seat2,
            ],
            discard: [Table.top], stock: [Table.stockCard], options: actionOptions)
        // WHEN seat 0 plays its 2.
        guard let next = C8.applied(.play(card: PieceID(raw: 1)), by: 0, in: state) else { return }
        // THEN seat 1 owes two cards and its only legal moves are paying the draw or stacking its 2 —
        // even though the King of hearts would otherwise match.
        #expect(next.pendingDraw == 2)
        #expect(next.turn == C8.seat(1))
        #expect(
            CrazyEights().legalActions(for: C8.seat(1), in: next)
                == [.draw, .play(card: PieceID(raw: 12))])
        #expect(C8.violation(.play(card: PieceID(raw: 11)), by: 1, in: next) == "must-cover-draw")
    }

    @Test("Given a pending draw, When the next seat stacks a 2, Then the debt grows to four")
    func twosStack() {
        let seat1 = [C8.card(.king, .hearts, id: 11), C8.card(.two, .spades, id: 12)]
        let state = C8.state(
            hands: [[C8.card(.six, .clubs, id: 2)], seat1, Table.seat2],
            discard: [C8.card(.two, .hearts, id: 1)], turn: 1, options: actionOptions,
            pendingDraw: 2)
        let next = C8.applied(.play(card: PieceID(raw: 12)), by: 1, in: state)
        #expect(next?.pendingDraw == 4)
        #expect(next?.turn == C8.seat(2))
    }

    @Test("Given a pending draw, When the seat tries to cover it with an 8, Then must-cover-draw")
    func eightCannotCoverADraw() {
        let seat1 = [C8.card(.eight, .clubs, id: 11), C8.card(.king, .hearts, id: 12)]
        let state = C8.state(
            hands: [[C8.card(.six, .clubs, id: 2)], seat1, Table.seat2],
            discard: [C8.card(.two, .hearts, id: 1)], turn: 1, options: actionOptions,
            pendingDraw: 2)
        #expect(
            C8.violation(.playEight(card: PieceID(raw: 11), namedSuit: .spades), by: 1, in: state)
                == "must-cover-draw")
    }

    @Test(
        "Given a debt larger than the stock, When the seat pays it, Then it draws what it can and play moves on"
    )
    func payingADrawStopsWhenTheStockRunsOut() {
        // GIVEN seat 1 owes two cards but only one card is left and the hand cannot be recycled.
        let options = CrazyEightsOptions(playerCount: 3, stockOut: .endHand, actionCards: true)
        let state = C8.state(
            hands: [[C8.card(.six, .clubs, id: 2)], Table.seat1, Table.seat2],
            discard: [C8.card(.two, .hearts, id: 1)], stock: [Table.stockCard], turn: 1,
            options: options, pendingDraw: 2)
        // WHEN seat 1 draws.
        let next = C8.applied(.draw, by: 1, in: state)
        // THEN it takes the single remaining card, the debt is cleared, and seat 2 is up.
        #expect(next?.hand(of: C8.seat(1))?.contents.count == Table.seat1.count + 1)
        #expect(next?.stock.contents.isEmpty == true)
        #expect(next?.pendingDraw == 0)
        #expect(next?.turn == C8.seat(2))
    }
}

// MARK: - Action-card edge cases (Q-4, Q-5 — NEEDS REVIEW; pins the documented current behavior)

@Suite("Crazy Eights doc: action-card edge cases — Q-4 / Q-5 current behavior (R-CE-4.1)")
struct CrazyEightsActionCardEdgeScenarios {
    let twoSeatActions = CrazyEightsOptions(playerCount: 2, actionCards: true)
    let opponent = [C8.card(.king, .spades, id: 11), C8.card(.five, .clubs, id: 12)]

    @Test("Q-4: Given two players, When a Jack is played, Then the same player moves again")
    func twoPlayerJackReturnsTheTurn() {
        let state = C8.state(
            hands: [[C8.card(.jack, .hearts, id: 1), C8.card(.six, .clubs, id: 2)], opponent],
            discard: [Table.top], options: twoSeatActions)
        let next = C8.applied(.play(card: PieceID(raw: 1)), by: 0, in: state)
        #expect(next?.turn == C8.seat(0))
    }

    @Test(
        "Q-4: Given two players, When an Ace is played, Then direction flips and the opponent moves"
    )
    func twoPlayerAcePassesToTheOpponent() {
        let state = C8.state(
            hands: [[C8.card(.ace, .hearts, id: 1), C8.card(.six, .clubs, id: 2)], opponent],
            discard: [Table.top], options: twoSeatActions)
        let next = C8.applied(.play(card: PieceID(raw: 1)), by: 0, in: state)
        #expect(next?.direction == .counterClockwise)
        #expect(next?.turn == C8.seat(1))
    }

    @Test("Q-4: Given action cards on, When an 8 is played, Then it has no action effect")
    func eightIsOnlyWild() {
        let state = C8.state(
            hands: [
                [C8.card(.eight, .clubs, id: 1), C8.card(.six, .clubs, id: 2)], Table.seat1,
                Table.seat2,
            ],
            discard: [Table.top], options: CrazyEightsOptions(playerCount: 3, actionCards: true))
        let next = C8.applied(
            .playEight(card: PieceID(raw: 1), namedSuit: .spades), by: 0, in: state)
        #expect(next?.turn == C8.seat(1))
        #expect(next?.direction == .clockwise)
        #expect(next?.pendingDraw == 0)
    }

    @Test(
        "Q-5: Given action cards on and a 2, Jack, or Ace starter, When the hand begins, Then no starter effect applies"
    )
    func starterActionCardHasNoEffect() {
        let game = CrazyEights()
        let options = CrazyEightsOptions(playerCount: 3, actionCards: true)
        var seen: Set<Rank> = []
        for seed in UInt64(0)..<400 where seen.count < 3 {
            let state = game.initialState(options: options, seed: seed)
            guard case .standard(let rank, _)? = state.topDiscardFace,
                [.two, .jack, .ace].contains(rank)
            else { continue }
            seen.insert(rank)
            #expect(state.turn == C8.seat(0))
            #expect(state.direction == .clockwise)
            #expect(state.pendingDraw == 0)
        }
        #expect(seen == [.two, .jack, .ace])
    }
}

// MARK: - Save encoding (R-ENG-8.5)

@Suite("Crazy Eights: state and options survive a save round-trip (R-ENG-8.5)")
struct CrazyEightsEncodingScenarios {
    @Test("Given a mid-hand state, When it is encoded and decoded, Then it is unchanged")
    func stateRoundTrips() throws {
        let options = CrazyEightsOptions(
            playerCount: 3, drawMode: .drawOneThenPass, stockOut: .endHand, matchTarget: 50,
            actionCards: true)
        let state = C8.state(
            hands: [[C8.card(.six, .clubs, id: 2)], Table.seat1, Table.seat2],
            discard: [C8.card(.two, .hearts, id: 1)], activeSuit: .spades, stock: [Table.stockCard],
            turn: 2, options: options, pendingDraw: 2, direction: .counterClockwise)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(CrazyEightsState.self, from: data)
        // Every field survives, and re-encoding the decoded state reproduces the same bytes.
        #expect(decoded.hands.map(\.contents) == state.hands.map(\.contents))
        #expect(decoded.stock.contents == state.stock.contents)
        #expect(decoded.discard.contents == state.discard.contents)
        #expect(decoded.faces == state.faces)
        #expect(decoded.activeSuit == .spades)
        #expect(decoded.turn == C8.seat(2))
        #expect(decoded.direction == .counterClockwise)
        #expect(decoded.pendingDraw == 2)
        #expect(decoded.options == options)
        #expect(try encoder.encode(decoded) == data)
    }

    @Test(
        "Given a save with an out-of-range player count, When options decode, Then the count is clamped"
    )
    func optionsDecodeClampsPlayerCount() throws {
        let json = Data(
            #"{"playerCount":9,"drawMode":"drawOneThenPass","stockOut":"endHand","matchTarget":75,"actionCards":true}"#
                .utf8)
        let options = try JSONDecoder().decode(CrazyEightsOptions.self, from: json)
        #expect(options.playerCount == 5)
        #expect(options.drawMode == .drawOneThenPass)
        #expect(options.stockOut == .endHand)
        #expect(options.matchTarget == 75)
        #expect(options.actionCards)
    }
}

// MARK: - AI hints for every kind of move (R-AI-6.1, R-CE-5)

@Suite("Crazy Eights doc: AI — each tier explains every kind of move (R-AI-6.1)")
struct CrazyEightsTierHintScenarios {
    /// Seat 0 holds only an 8; nothing can be drawn, so the only legal moves are the four `playEight`s.
    static let eightOnly = C8.state(
        hands: [[C8.card(.eight, .clubs, id: 1)], Table.seat1], discard: [Table.top])
    /// Seat 0 holds two hearts; nothing can be drawn.
    static let twoPlays = C8.state(
        hands: [[C8.card(.three, .hearts, id: 1), C8.card(.king, .hearts, id: 2)], Table.seat1],
        discard: [Table.top])
    /// Seat 0 has no match but can draw.
    static let drawOnly = C8.state(
        hands: [[C8.card(.king, .clubs, id: 1)], Table.seat1], discard: [Table.top],
        stock: [Table.stockCard])
    /// Seat 0 has no match and nothing to draw.
    static let passOnly = C8.state(
        hands: [[C8.card(.king, .clubs, id: 1)], Table.seat1], discard: [Table.top])

    @Test("Given each kind of position, When Easy hints, Then it suggests that move with a reason")
    func easyHints() async {
        let easy = CrazyEightsEasyStrategy()
        let eight = await easy.hint(C8.context(Self.eightOnly, seat: 0))
        let play = await easy.hint(C8.context(Self.twoPlays, seat: 0))
        let draw = await easy.hint(C8.context(Self.drawOnly, seat: 0))
        guard case .playEight = C8.decode(eight?.action) else {
            Issue.record("Easy did not suggest the eight: \(String(describing: eight))")
            return
        }
        guard case .play = C8.decode(play?.action) else {
            Issue.record("Easy did not suggest a play: \(String(describing: play))")
            return
        }
        #expect(C8.decode(draw?.action) == .draw)
        let reasons = [eight, play, draw].compactMap { $0?.explanation }
        #expect(reasons.count == 3 && reasons.allSatisfy { !$0.isEmpty })
        #expect(Set(reasons).count == 3)  // each kind of move gets its own explanation
    }

    @Test(
        "Given each kind of position, When Medium hints, Then it suggests that move with a reason")
    func mediumHints() async {
        let medium = CrazyEightsMediumStrategy()
        let eight = await medium.hint(C8.context(Self.eightOnly, seat: 0))
        let draw = await medium.hint(C8.context(Self.drawOnly, seat: 0))
        let pass = await medium.hint(C8.context(Self.passOnly, seat: 0))
        guard case .playEight = C8.decode(eight?.action) else {
            Issue.record("Medium did not suggest the eight: \(String(describing: eight))")
            return
        }
        #expect(C8.decode(draw?.action) == .draw)
        #expect(C8.decode(pass?.action) == .pass)
        let reasons = [eight, draw, pass].compactMap { $0?.explanation }
        #expect(reasons.count == 3 && Set(reasons).count == 3)
    }

    @Test(
        "Given each kind of position, When Hard hints, Then it suggests a legal move with a reason")
    func hardHints() async {
        let hard = CrazyEightsHardStrategy(
            options: CrazyEightsOptions(), worlds: 2, rolloutsPerCandidate: 4)
        let eight = await hard.hint(C8.context(Self.eightOnly, seat: 0))
        let play = await hard.hint(C8.context(Self.twoPlays, seat: 0))
        let draw = await hard.hint(C8.context(Self.drawOnly, seat: 0))
        let pass = await hard.hint(C8.context(Self.passOnly, seat: 0))
        guard case .playEight = C8.decode(eight?.action) else {
            Issue.record("Hard did not suggest the eight: \(String(describing: eight))")
            return
        }
        guard case .play = C8.decode(play?.action) else {
            Issue.record("Hard did not suggest a play: \(String(describing: play))")
            return
        }
        #expect(C8.decode(draw?.action) == .draw)
        #expect(C8.decode(pass?.action) == .pass)
        let reasons = [eight, play, draw, pass].compactMap { $0?.explanation }
        #expect(reasons.count == 4 && Set(reasons).count == 4)
    }

    @Test("Given no legal actions, When any tier hints, Then there is no hint")
    func noLegalActionsMeansNoHint() async {
        // Seat 1 is not on turn, so its context carries no legal actions.
        let context = C8.context(Self.twoPlays, seat: 1)
        #expect(context.legalActions.isEmpty)
        let easy = await CrazyEightsEasyStrategy().hint(context)
        let medium = await CrazyEightsMediumStrategy().hint(context)
        let hard = await CrazyEightsHardStrategy(options: CrazyEightsOptions()).hint(context)
        #expect(easy == nil)
        #expect(medium == nil)
        #expect(hard == nil)
    }
}

// MARK: - Hard fallback + shared AI readers (R-CE-5.3, R-AI-3.1, R-AI-2.2)

@Suite("Crazy Eights doc: AI — Hard stays legal when no deal fits; shared readers (R-CE-5.3)")
struct CrazyEightsAIEdgeScenarios {
    @Test(
        "Given a log that voids the opponent in every suit, When Hard decides, Then it falls back to a legal heuristic move"
    )
    func hardFallsBackWhenNoDealFits() async {
        // GIVEN a real deal, and a public log in which seat 1 drew under each of the four suits — so it is
        // inferred void in all of them, which no assignment of its 7 hidden cards can satisfy.
        let game = CrazyEights()
        let options = CrazyEightsOptions(playerCount: 2)
        let state = game.initialState(options: options, seed: 2024)
        let start = state.activeSuit
        let others = Suit.allCases.filter { $0 != start }
        var entries = [C8.entry(1, .draw)]
        for (offset, suit) in others.enumerated() {
            entries.append(
                C8.entry(0, .playEight(card: PieceID(raw: UInt64(900 + offset)), namedSuit: suit)))
            entries.append(C8.entry(1, .draw))
        }
        let log = PublicLog(actions: entries)
        let voids = CrazyEightsAI.inferredVoids(from: log, startingSuit: start)
        #expect(voids[C8.seat(1)] == Set(Suit.allCases))
        let context = C8.context(state, seat: 0, log: log)
        var rng = SeededRNG(seed: 3)
        let world = CrazyEightsDeterminizer(options: options).makeState(
            view: context.view, seat: C8.seat(0), log: log, rng: &rng)
        #expect(world == nil)
        // WHEN Hard decides. THEN it still returns a legal move: a non-8 play when it has one.
        let legal = game.legalActions(for: C8.seat(0), in: state)
        let chosen = C8.decode(
            await CrazyEightsHardStrategy(options: options, worlds: 2, rolloutsPerCandidate: 4)
                .decide(context))
        #expect(chosen.map { legal.contains($0) } == true)
        if legal.contains(where: { CrazyEightsAI.playsCard($0) }) {
            #expect(chosen.map { CrazyEightsAI.playsCard($0) } == true)
        }
    }

    @Test(
        "Given log entries that are plays or not Crazy Eights moves, When voids are read, Then they are ignored"
    )
    func voidReaderIgnoresPlaysAndForeignActions() {
        let foreign = PublicActionEntry(
            seat: C8.seat(1), action: try! AnyGameAction(KlondikeAction.drawFromStock))
        let log = PublicLog(actions: [
            foreign, C8.entry(1, .play(card: PieceID(raw: 5))), C8.entry(1, .pass),
        ])
        let voids = CrazyEightsAI.inferredVoids(from: log, startingSuit: .diamonds)
        #expect(voids == [C8.seat(1): [.diamonds]])
    }

    @Test(
        "Given a view whose phase names no suit, When the active suit is read, Then it falls back to the top discard, then clubs"
    )
    func activeSuitFallsBack() {
        let state = C8.state(
            hands: [[C8.card(.three, .hearts, id: 1)], Table.seat1],
            discard: [C8.card(.nine, .diamonds, id: 90)], activeSuit: .spades)
        let view = CrazyEights().redactedView(of: state, for: .seat(C8.seat(0)))
        #expect(CrazyEightsAI.activeSuit(in: view) == .spades)  // the phase carries the named suit
        let noSuit = PlayerView(
            viewer: view.viewer, zones: view.zones, scores: view.scores,
            phase: Phase(rawValue: "play"),
            legalActions: view.legalActions)
        #expect(CrazyEightsAI.topDiscardFace(in: noSuit) == .standard(.nine, .diamonds))
        #expect(CrazyEightsAI.activeSuit(in: noSuit) == .diamonds)
        let empty = PlayerView(
            viewer: view.viewer, zones: [], scores: [:], phase: Phase(rawValue: "play"),
            legalActions: [])
        #expect(CrazyEightsAI.topDiscardFace(in: empty) == nil)
        #expect(CrazyEightsAI.activeSuit(in: empty) == .clubs)
    }

    @Test(
        "Given a hand, When its longest suit is chosen, Then 8s are ignored and ties break reproducibly"
    )
    func longestSuitIgnoresEightsAndBreaksTies() {
        var rng = SeededRNG(seed: 11)
        let clubsHeavy: [CardFace] = [
            .standard(.king, .clubs), .standard(.two, .clubs), .standard(.eight, .hearts),
            .standard(.eight, .spades), .standard(.four, .diamonds),
        ]
        #expect(CrazyEightsAI.longestSuit(in: clubsHeavy, fallback: .spades, using: &rng) == .clubs)
        let onlyEights: [CardFace] = [.standard(.eight, .hearts), .standard(.eight, .spades)]
        #expect(
            CrazyEightsAI.longestSuit(in: onlyEights, fallback: .spades, using: &rng) == .spades)
        let tied: [CardFace] = [.standard(.king, .clubs), .standard(.four, .diamonds)]
        var a = SeededRNG(seed: 21)
        var b = SeededRNG(seed: 21)
        let first = CrazyEightsAI.longestSuit(in: tied, fallback: .spades, using: &a)
        #expect([Suit.clubs, .diamonds].contains(first))
        #expect(CrazyEightsAI.longestSuit(in: tied, fallback: .spades, using: &b) == first)
    }

    @Test(
        "Given a live and a finished hand, When the playout asks who moves, Then it is the seat on turn, then nobody"
    )
    func simulationCurrentPlayer() {
        let simulation = CrazyEightsSimulation()
        let live = C8.state(
            hands: [[C8.card(.three, .hearts, id: 1)], Table.seat1], discard: [Table.top], turn: 1)
        #expect(simulation.currentPlayer(in: live) == SimSeat(raw: C8.seat(1).raw))
        let finished = C8.state(hands: [[], Table.seat1], discard: [Table.top])
        #expect(simulation.currentPlayer(in: finished) == nil)
    }
}
