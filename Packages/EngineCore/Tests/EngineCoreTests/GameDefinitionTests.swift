import Foundation
import Testing

@testable import EngineCore

// Tests for the GameDefinition protocol and its supporting types (R-ENG-5), including a tiny toy game
// that proves the protocol is usable end-to-end with NO edits to EngineCore (R-ENG-5.6): a self-contained
// conformance driving initialState → legalActions → apply → events/violation → isTerminal → outcome, and
// exercising the typed RuleViolation path with a human-readable reason (R-ENG-5.4, R-NFR-QUAL.1).

// MARK: - Toy game: "count to three"
//
// A one-seat toy: state is a counter; the only legal action is `increment` until the counter reaches 3,
// at which point the hand is terminal and the seat wins. Attempting to increment past terminal — or
// acting on the wrong seat — is a typed RuleViolation. Deliberately minimal; its only job is to prove the
// protocol closes and is conformable outside EngineCore's own types.

private struct CountState: GameState, Equatable {
    var value: Int
}

private enum CountAction: GameAction, Equatable {
    case increment
}

private struct CountOptions: GameOptions, Equatable {
    /// The target the counter must reach to end the hand.
    var target: Int
}

private struct CountToThree: GameDefinition {
    typealias State = CountState
    typealias Action = CountAction
    typealias Options = CountOptions

    static let seat0 = SeatID.index(0)

    static let metadata = GameMetadata(
        id: "count-to-three",
        name: "Count to Three",
        family: .solitaire,
        seatRange: 1...1,
        typicalDuration: DurationRange(minMinutes: 1, maxMinutes: 1),
        complexity: .light
    )

    static let optionsSchema = OptionsSchema(
        defaults: CountOptions(target: 3),
        presets: [
            OptionsPreset(name: "Quick", options: CountOptions(target: 1)),
            OptionsPreset(name: "Standard", options: CountOptions(target: 3)),
        ]
    )

    let undoPolicy: UndoPolicy = .unlimited

    // The target is baked into the initial state's implicit contract; we store it via the counter's
    // ceiling. Keep it on the state for a self-contained toy.
    private let target: Int

    init(target: Int = 3) {
        self.target = target
    }

    func initialState(options: CountOptions, seed: UInt64) -> CountState {
        // Seed is unused by this toy (nothing to shuffle); it still honors the signature (R-ENG-5.3).
        CountState(value: 0)
    }

    func phase(of state: CountState) -> Phase {
        isTerminal(state) ? Phase(rawValue: "done") : Phase(rawValue: "counting")
    }

    func legalActions(for seat: SeatID, in state: CountState) -> [CountAction] {
        guard seat == Self.seat0, !isTerminal(state) else { return [] }
        return [.increment]
    }

    func apply(_ action: CountAction, by seat: SeatID, to state: CountState)
        -> Result<(CountState, [GameEvent]), RuleViolation>
    {
        guard seat == Self.seat0 else {
            return .failure(
                RuleViolation(code: "not-your-turn", reason: "It is not your turn to play."))
        }
        guard !isTerminal(state) else {
            return .failure(
                RuleViolation(code: "hand-over", reason: "The hand is already over."))
        }
        var next = state
        next.value += 1
        var events: [GameEvent] = [.scoreChanged(seat: seat, delta: 1, total: next.value)]
        if isTerminal(next) {
            events.append(.handEnded(outcome(next)))
        }
        return .success((next, events))
    }

    func isTerminal(_ state: CountState) -> Bool {
        state.value >= target
    }

    func outcome(_ state: CountState) -> HandOutcome {
        guard isTerminal(state) else { return .draw }
        return HandOutcome(winners: [Self.seat0], scores: [Self.seat0: state.value])
    }

    func redactedView(of state: CountState, for viewer: Viewer) -> PlayerView {
        PlayerView(
            viewer: viewer, scores: [Self.seat0: state.value], phase: phase(of: state))
    }
}

@Suite("GameDefinition protocol (R-ENG-5)")
struct GameDefinitionTests {

    // MARK: - Metadata (R-ENG-5.1)

    @Test("metadata exposes id, name, family, seat range, duration, complexity")
    func metadataFields() {
        let m = CountToThree.metadata
        #expect(m.id == "count-to-three")
        #expect(m.name == "Count to Three")
        #expect(m.family == .solitaire)
        #expect(m.seatRange == 1...1)
        #expect(m.typicalDuration.minMinutes == 1)
        #expect(m.complexity == .light)
    }

    @Test("metadata round-trips through Codable")
    func metadataCodableRoundTrip() throws {
        let m = CountToThree.metadata
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(GameMetadata.self, from: data)
        #expect(decoded == m)
    }

    @Test("a new family can be minted without editing EngineCore")
    func customFamily() {
        // R-ENG-5.6: GameFamily is open, so a game module can introduce its own family.
        let custom = GameFamily(rawValue: "dexterity")
        #expect(custom.rawValue == "dexterity")
        #expect(custom != .solitaire)
    }

    // MARK: - Options schema: defaults + presets (R-ENG-5.2)

    @Test("options schema exposes defaults and named presets")
    func optionsSchemaDefaultsAndPresets() {
        let schema = CountToThree.optionsSchema
        #expect(schema.defaults.target == 3)
        #expect(schema.presets.count == 2)
        #expect(schema.preset(named: "Quick")?.options.target == 1)
        #expect(schema.preset(named: "Missing") == nil)
    }

    @Test("options schema round-trips through Codable")
    func optionsSchemaCodableRoundTrip() throws {
        let schema = CountToThree.optionsSchema
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(OptionsSchema<CountOptions>.self, from: data)
        #expect(decoded.defaults == schema.defaults)
        #expect(decoded.presets.map(\.name) == ["Quick", "Standard"])
    }

    // MARK: - initialState / phase / legalActions (R-ENG-5.3)

    @Test("initialState builds the starting position from options and seed")
    func initialStateFromOptionsAndSeed() {
        let game = CountToThree()
        let state = game.initialState(options: CountToThree.optionsSchema.defaults, seed: 42)
        #expect(state.value == 0)
        #expect(game.phase(of: state) == Phase(rawValue: "counting"))
    }

    @Test("legalActions lists the move for the acting seat and is empty otherwise")
    func legalActionsPerSeat() {
        let game = CountToThree()
        let state = CountState(value: 0)
        #expect(game.legalActions(for: .index(0), in: state) == [.increment])
        // Wrong seat sees no actions.
        #expect(game.legalActions(for: .index(1), in: state).isEmpty)
    }

    @Test("legalActions is empty in a terminal state")
    func legalActionsEmptyAtTerminal() {
        let game = CountToThree()
        #expect(game.legalActions(for: .index(0), in: CountState(value: 3)).isEmpty)
    }

    // MARK: - apply → events (success path) (R-ENG-5.4)

    @Test("apply on a legal action returns the new state and ordered events")
    func applyLegalReturnsStateAndEvents() throws {
        let game = CountToThree()
        let result = game.apply(.increment, by: .index(0), to: CountState(value: 0))
        let (next, events) = try result.get()
        #expect(next.value == 1)
        #expect(events == [.scoreChanged(seat: .index(0), delta: 1, total: 1)])
    }

    @Test("the terminal transition also emits a handEnded event")
    func applyTerminalEmitsHandEnded() throws {
        let game = CountToThree()
        let (next, events) = try game.apply(.increment, by: .index(0), to: CountState(value: 2))
            .get()
        #expect(next.value == 3)
        #expect(game.isTerminal(next))
        #expect(
            events.contains(.handEnded(HandOutcome(winners: [.index(0)], scores: [.index(0): 3]))))
    }

    // MARK: - apply → RuleViolation (failure path) (R-ENG-5.4, R-NFR-QUAL.1)

    @Test("apply by the wrong seat returns a typed RuleViolation with a human-readable reason")
    func applyWrongSeatViolation() {
        let game = CountToThree()
        let result = game.apply(.increment, by: .index(1), to: CountState(value: 0))
        guard case .failure(let violation) = result else {
            Issue.record("expected a RuleViolation for the wrong seat")
            return
        }
        #expect(violation.code == "not-your-turn")
        #expect(!violation.reason.isEmpty)
    }

    @Test("apply past terminal returns a RuleViolation, not a crash")
    func applyPastTerminalViolation() {
        let game = CountToThree()
        let result = game.apply(.increment, by: .index(0), to: CountState(value: 3))
        guard case .failure(let violation) = result else {
            Issue.record("expected a RuleViolation past terminal")
            return
        }
        #expect(violation.code == "hand-over")
    }

    @Test("RuleViolation round-trips through Codable")
    func ruleViolationCodableRoundTrip() throws {
        let violation = RuleViolation(
            code: "wrong-color", reason: "Build down in alternating colors.")
        let data = try JSONEncoder().encode(violation)
        let decoded = try JSONDecoder().decode(RuleViolation.self, from: data)
        #expect(decoded == violation)
    }

    // MARK: - Terminal / outcome / redaction (R-ENG-5.5)

    @Test("isTerminal and outcome report the finished hand")
    func terminalAndOutcome() {
        let game = CountToThree()
        #expect(game.isTerminal(CountState(value: 3)))
        #expect(!game.isTerminal(CountState(value: 2)))

        let outcome = game.outcome(CountState(value: 3))
        #expect(outcome.winners == [.index(0)])
        #expect(outcome.scores[.index(0)] == 3)

        // A non-terminal state has no winner yet.
        #expect(game.outcome(CountState(value: 1)) == .draw)
    }

    @Test("redactedView returns a per-viewer snapshot")
    func redactedViewPerViewer() {
        let game = CountToThree()
        let view = game.redactedView(of: CountState(value: 2), for: .seat(.index(0)))
        #expect(view.viewer == .seat(.index(0)))
        #expect(view.scores[.index(0)] == 2)
        #expect(view.phase == Phase(rawValue: "counting"))
    }

    // MARK: - Full end-to-end drive (R-ENG-5.6)

    @Test("a self-contained GameDefinition plays a full hand end-to-end")
    func endToEndPlaythrough() throws {
        let game = CountToThree()
        var state = game.initialState(options: CountToThree.optionsSchema.defaults, seed: 7)
        var steps = 0
        while !game.isTerminal(state) {
            let legal = game.legalActions(for: .index(0), in: state)
            #expect(legal == [.increment])
            let (next, _) = try game.apply(legal[0], by: .index(0), to: state).get()
            state = next
            steps += 1
            #expect(steps <= 10, "guard against a runaway loop")
        }
        #expect(state.value == 3)
        #expect(game.outcome(state).winners == [.index(0)])
    }

    // MARK: - Undo policy (R-ENG-7.3) and boundary type round-trips (R-ENG-8.5)

    @Test("undoPolicy is declared by the game")
    func undoPolicyDeclared() {
        #expect(CountToThree().undoPolicy == .unlimited)
    }

    @Test(
        "UndoPolicy round-trips through Codable",
        arguments: [
            UndoPolicy.unlimited, .none, .practiceMode,
        ])
    func undoPolicyCodableRoundTrip(_ policy: UndoPolicy) throws {
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(UndoPolicy.self, from: data)
        #expect(decoded == policy)
    }

    @Test(
        "Viewer round-trips through Codable",
        arguments: [
            Viewer.seat(.index(0)), .spectator, .debugOmniscient,
        ])
    func viewerCodableRoundTrip(_ viewer: Viewer) throws {
        let data = try JSONEncoder().encode(viewer)
        let decoded = try JSONDecoder().decode(Viewer.self, from: data)
        #expect(decoded == viewer)
    }

    @Test("GameEvent round-trips through Codable")
    func gameEventCodableRoundTrip() throws {
        // Task 2.6 evolved the dealt/pieceMoved payloads to PieceMoveDescriptor; use the new shapes here.
        let move = PieceMoveDescriptor(
            piece: PieceID(raw: 3),
            from: ZoneID(name: "stock"),
            to: ZoneID(name: "hand", owner: .index(0)),
            toIndex: 0,
            faceUp: true)
        let events: [GameEvent] = [
            .dealt(pieces: [move]),
            .pieceMoved(move),
            .turnChanged(to: .index(1)),
            .scoreChanged(seat: .index(0), delta: 5, total: 5),
            .handEnded(HandOutcome(winners: [.index(0)], scores: [.index(0): 5])),
        ]
        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([GameEvent].self, from: data)
        #expect(decoded == events)
    }

    @Test("HandOutcome round-trips through Codable")
    func handOutcomeCodableRoundTrip() throws {
        let outcome = HandOutcome(winners: [.index(1)], scores: [.index(0): 3, .index(1): 8])
        let data = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(HandOutcome.self, from: data)
        #expect(decoded == outcome)
    }

    // MARK: - AnyGameAction type-erasure (log/views seam)

    @Test("AnyGameAction erases and recovers a concrete action")
    func anyGameActionRoundTrip() throws {
        let erased = try AnyGameAction(CountAction.increment)
        #expect(erased.typeName == "CountAction")
        let recovered = try erased.decode(as: CountAction.self)
        #expect(recovered == .increment)
    }

    @Test("AnyGameAction itself round-trips through Codable")
    func anyGameActionCodableRoundTrip() throws {
        let erased = try AnyGameAction(CountAction.increment)
        let data = try JSONEncoder().encode(erased)
        let decoded = try JSONDecoder().decode(AnyGameAction.self, from: data)
        #expect(decoded == erased)
        #expect(try decoded.decode(as: CountAction.self) == .increment)
    }
}
