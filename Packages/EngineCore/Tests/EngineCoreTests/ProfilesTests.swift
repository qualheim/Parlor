import Foundation
import Testing

@testable import EngineCore

// Tests for player profiles, AI personas, and concurrent independent sessions (task 4.3;
// R-SESS-5.1, R-SESS-5.2, R-SESS-6.1).
//
// These prove:
//   • PlayerProfile / AIPersona (and their id/style/avatar value types) round-trip through JSON, so they
//     save and cross the host boundary unchanged (R-SESS-5.1, R-ENG-8.5);
//   • the bundled persona set exists, is non-trivial, spans the difficulty tiers, and carries the small
//     documented style params (aggression, riskTolerance) clamped to 0...1 (R-SESS-5.2, R-AI-5.1; A-6);
//   • two independent `GameHost` instances run fully concurrently with NO shared/static state: driven
//     differently, their logs, hashes, and views diverge and neither affects the other (R-SESS-6.1).

// MARK: - Codable round-trip: profiles and personas (R-SESS-5.1, R-ENG-8.5)

@Suite("Player profiles & AI personas (R-SESS-5.1, R-SESS-5.2)")
struct ProfilesTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("a local-human PlayerProfile round-trips through JSON unchanged")
    func humanProfileRoundTrip() throws {
        let profile = PlayerProfile(
            id: ProfileID(raw: "profile-abc"),
            displayName: "Ada",
            avatar: .namedPlaceholder("avatar-01"),
            controllerKind: .localHuman)
        #expect(try roundTrip(profile) == profile)
    }

    @Test("an AI-controlled PlayerProfile (generated-glyph avatar) round-trips unchanged")
    func aiProfileRoundTrip() throws {
        let profile = PlayerProfile(
            id: ProfileID(raw: "profile-xyz"),
            displayName: "The Shark",
            avatar: .generatedGlyph(symbol: "bolt.fill", tint: "#C92A2A"),
            controllerKind: .ai(persona: PersonaID(raw: "persona-shark")))
        #expect(try roundTrip(profile) == profile)
    }

    @Test("an AIPersona round-trips through JSON unchanged")
    func personaRoundTrip() throws {
        let persona = AIPersona(
            id: PersonaID(raw: "persona-test"),
            name: "Tester",
            avatar: .generatedGlyph(symbol: "gearshape.fill", tint: "#000000"),
            tier: .hard,
            style: PersonaStyle(aggression: 0.6, riskTolerance: 0.4))
        #expect(try roundTrip(persona) == persona)
    }

    @Test("the default local human profile is a UI-driven human with a non-empty name")
    func defaultLocalHuman() {
        let profile = PlayerProfile.defaultLocalHuman()
        #expect(profile.controllerKind == .localHuman)
        #expect(!profile.displayName.isEmpty)
    }

    @Test("ProfileID.generate() mints distinct ids")
    func profileIDGenerateIsUnique() {
        #expect(ProfileID.generate() != ProfileID.generate())
    }

    // MARK: - PersonaStyle clamping (A-6)

    @Test("PersonaStyle clamps both parameters into 0...1")
    func personaStyleClamps() {
        let low = PersonaStyle(aggression: -5, riskTolerance: -0.001)
        #expect(low.aggression == 0.0)
        #expect(low.riskTolerance == 0.0)
        let high = PersonaStyle(aggression: 2.0, riskTolerance: 42)
        #expect(high.aggression == 1.0)
        #expect(high.riskTolerance == 1.0)
        let mid = PersonaStyle(aggression: 0.5, riskTolerance: 0.25)
        #expect(mid.aggression == 0.5)
        #expect(mid.riskTolerance == 0.25)
    }

    // MARK: - Bundled personas (R-SESS-5.2)

    @Test("the bundled persona set is non-empty and every persona has a unique id and a name")
    func bundledPersonasWellFormed() {
        let personas = AIPersona.bundled
        #expect(personas.count >= 3)
        let ids = Set(personas.map(\.id))
        #expect(ids.count == personas.count)  // ids unique
        #expect(personas.allSatisfy { !$0.name.isEmpty })
    }

    @Test("bundled personas carry documented style params in range and span the difficulty tiers")
    func bundledPersonasStyleAndTiers() {
        let personas = AIPersona.bundled
        // Every persona's documented style params are within the clamped range (A-6, R-AI-5.1).
        for persona in personas {
            #expect(persona.style.aggression >= 0.0 && persona.style.aggression <= 1.0)
            #expect(persona.style.riskTolerance >= 0.0 && persona.style.riskTolerance <= 1.0)
        }
        // The roster spans all difficulty tiers (R-AI-2.1).
        let tiers = Set(personas.map(\.tier))
        #expect(tiers == Set(DifficultyTier.allCases))
    }

    @Test("bundled(withID:) resolves a known persona and returns nil for an unknown one")
    func bundledLookup() {
        let known = AIPersona.bundled.first!
        #expect(AIPersona.bundled(withID: known.id) == known)
        #expect(AIPersona.bundled(withID: PersonaID(raw: "persona-does-not-exist")) == nil)
    }

    @Test("an AIPersona vends a matching AI-driven profile")
    func personaProfile() {
        let persona = AIPersona.bundled.first!
        let profile = persona.profile
        #expect(profile.displayName == persona.name)
        #expect(profile.avatar == persona.avatar)
        #expect(profile.controllerKind == .ai(persona: persona.id))
    }
}

// MARK: - Toy game "Counter" for the concurrency test
//
// A one-seat toy the host can drive an arbitrary number of times: the only action is `.increment`,
// which bumps a counter and appends a `scoreChanged` event. Because each accepted increment grows the
// log and changes the state hash, two hosts driven a DIFFERENT number of times must end with divergent
// logs/hashes/views — exactly what proves the two sessions share no state (R-SESS-6.1). Self-contained,
// so it also confirms the host runs a game with NO EngineCore edits (R-ENG-5.6).

private let counterSeat = SeatID.index(0)

private struct CounterState: GameState {
    var count: Int
}

private enum CounterAction: GameAction, Equatable {
    case increment
}

private struct CounterOptions: GameOptions, Equatable {}

private struct Counter: GameDefinition {
    typealias State = CounterState
    typealias Action = CounterAction
    typealias Options = CounterOptions

    static let metadata = GameMetadata(
        id: "counter",
        name: "Counter",
        family: .solitaire,
        seatRange: 1...1,
        typicalDuration: DurationRange(minMinutes: 1, maxMinutes: 1),
        complexity: .light)

    static let optionsSchema = OptionsSchema(defaults: CounterOptions())

    let undoPolicy: UndoPolicy = .none

    func initialState(options: CounterOptions, seed: UInt64) -> CounterState {
        CounterState(count: 0)
    }

    func phase(of state: CounterState) -> Phase { Phase(rawValue: "play") }

    func legalActions(for seat: SeatID, in state: CounterState) -> [CounterAction] {
        seat == counterSeat ? [.increment] : []
    }

    func apply(_ action: CounterAction, by seat: SeatID, to state: CounterState)
        -> Result<(CounterState, [GameEvent]), RuleViolation>
    {
        guard seat == counterSeat else {
            return .failure(RuleViolation(code: "not-your-turn", reason: "Not your turn."))
        }
        var next = state
        next.count += 1
        return .success(
            (next, [.scoreChanged(seat: counterSeat, delta: 1, total: next.count)]))
    }

    func isTerminal(_ state: CounterState) -> Bool { false }

    func outcome(_ state: CounterState) -> HandOutcome {
        HandOutcome(winners: [counterSeat], scores: [counterSeat: state.count])
    }

    func redactedView(of state: CounterState, for viewer: Viewer) -> PlayerView {
        PlayerView(
            viewer: viewer,
            scores: [counterSeat: state.count],
            phase: phase(of: state))
    }
}

private func makeCounterHost(seed: UInt64) -> GameHost<Counter> {
    GameHost(game: Counter(), options: CounterOptions(), seats: [counterSeat], seed: seed)
}

private func increment(_ host: GameHost<Counter>) async throws -> ResultEnvelope {
    let envelope = ActionEnvelope(
        seat: counterSeat, action: try AnyGameAction(CounterAction.increment))
    return await host.submit(envelope)
}

/// The counter value seat-0 observes in a host's view (drawn from the score map).
private func observedCount(_ host: GameHost<Counter>) async -> Int {
    let view = await host.view(for: .seat(counterSeat))
    return view.scores[counterSeat] ?? -1
}

// MARK: - Two independent concurrent sessions (R-SESS-6.1)

@Suite("Concurrent independent GameHost sessions (R-SESS-6.1)")
struct ConcurrentSessionsTests {

    @Test("two hosts driven a different number of times end with divergent logs, hashes, and views")
    func twoHostsDivergeWhenDrivenDifferently() async throws {
        // Two independent sessions (think: two windows). Same game, same seed — so any divergence is due
        // to different play, NOT different starting state. If state were shared/static, driving one would
        // corrupt the other.
        let hostA = makeCounterHost(seed: 7)
        let hostB = makeCounterHost(seed: 7)

        // Drive them a DIFFERENT number of times, concurrently, so their timelines interleave.
        async let driveA: Void = {
            for _ in 0..<5 { _ = try await increment(hostA) }
        }()
        async let driveB: Void = {
            for _ in 0..<2 { _ = try await increment(hostB) }
        }()
        _ = try await (driveA, driveB)

        // Each host reflects only its OWN actions — no cross-contamination.
        #expect(await hostA.logCount == 5)
        #expect(await hostB.logCount == 2)
        #expect(await observedCount(hostA) == 5)
        #expect(await observedCount(hostB) == 2)

        // Different amounts of play ⇒ different resulting state hashes (R-ENG-4.4 applied per session).
        let hashA = await hostA.lastStateHash
        let hashB = await hostB.lastStateHash
        #expect(hashA != nil)
        #expect(hashB != nil)
        #expect(hashA != hashB)
    }

    @Test("two hosts driven identically stay independent yet agree (same seed ⇒ same hash)")
    func twoHostsIdenticalDriveAgree() async throws {
        // Same seed, same number of actions: independent instances must converge to the SAME hash — the
        // determinism contract holds per session, and running two at once does not perturb either.
        let hostA = makeCounterHost(seed: 99)
        let hostB = makeCounterHost(seed: 99)

        async let driveA: Void = {
            for _ in 0..<4 { _ = try await increment(hostA) }
        }()
        async let driveB: Void = {
            for _ in 0..<4 { _ = try await increment(hostB) }
        }()
        _ = try await (driveA, driveB)

        #expect(await hostA.logCount == 4)
        #expect(await hostB.logCount == 4)
        #expect(await hostA.lastStateHash == hostB.lastStateHash)
        #expect(await hostA.lastStateHash != nil)
    }

    @Test("mutating one host never mutates the other (isolation)")
    func mutatingOneDoesNotAffectTheOther() async throws {
        let hostA = makeCounterHost(seed: 1)
        let hostB = makeCounterHost(seed: 1)

        // Drive only A; B is left untouched.
        for _ in 0..<3 { _ = try await increment(hostA) }

        #expect(await hostA.logCount == 3)
        #expect(await observedCount(hostA) == 3)
        // B saw none of A's actions.
        #expect(await hostB.logCount == 0)
        #expect(await observedCount(hostB) == 0)
        #expect(await hostB.lastStateHash == nil)
    }
}
