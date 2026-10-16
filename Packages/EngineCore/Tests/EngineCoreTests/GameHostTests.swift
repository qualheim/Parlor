import Foundation
import Testing

@testable import EngineCore

// Tests for the GameHost actor + Codable transport envelope (task 4.1; R-SESS-1, R-SESS-4).
//
// These drive the host end-to-end through the SAME boundary a network client would use (R-SESS-4.2): a
// `ClientMessage` in, a `HostMessage` out, over an `InProcessTransport`. They prove:
//   • the host vends an initial redacted view (R-ENG-8.2) and never raw State (R-SESS-1.2);
//   • a legal submit is accepted with the expected events + updated views, the log grows by one, and the
//     entry records a resulting state hash (R-SESS-4.1, R-ENG-7.1, R-ENG-4.4);
//   • an illegal submit is rejected with the RuleViolation and mutates nothing (R-SESS-1.2, R-SESS-4.1);
//   • the same seed + same action sequence yields identical resulting state hashes (R-ENG-4.4);
//   • the envelope types round-trip through JSON so a network transport ships them unchanged (R-SESS-4.1);
//   • a hidden-zone piece is tokenized in the vended view — no identity leaks (R-ENG-8.3).

// MARK: - Toy game with a hidden zone: "Flip"
//
// A two-seat toy the host can drive: seat-0 owns a face-down "hand" zone (visibility ownerOnly) holding one
// card, plus a public "discard". The only action is `.play`, which by seat-0 moves the card to discard
// face-up and ends the hand. Acting by the wrong seat, or after the card is played, is a typed
// RuleViolation. The hidden hand lets a host test assert redaction (the spectator sees a token, seat-0 sees
// the card). Self-contained, so it also proves the host runs a game with NO EngineCore edits (R-ENG-5.6).

private let flipSeat0 = SeatID.index(0)
private let flipSeat1 = SeatID.index(1)
private let flipCardID = PieceID(raw: 100)
private let flipCardFace = CardFace.standard(.ace, .spades)

private struct FlipState: GameState {
    /// The seat-0 hand zone (ownerOnly) and the public discard zone.
    var hand: Zone
    var discard: Zone
    /// Whether the card has been played (hand over).
    var played: Bool
}

private enum FlipAction: GameAction, Equatable {
    case play
}

private struct FlipOptions: GameOptions, Equatable {}

private struct Flip: GameDefinition {
    typealias State = FlipState
    typealias Action = FlipAction
    typealias Options = FlipOptions

    static let metadata = GameMetadata(
        id: "flip",
        name: "Flip",
        family: .shedding,
        seatRange: 2...2,
        typicalDuration: DurationRange(minMinutes: 1, maxMinutes: 1),
        complexity: .light)

    static let optionsSchema = OptionsSchema(defaults: FlipOptions())

    let undoPolicy: UndoPolicy = .none

    func initialState(options: FlipOptions, seed: UInt64) -> FlipState {
        FlipState(
            hand: Zone(
                id: ZoneID(name: "hand", owner: flipSeat0),
                visibility: .ownerOnly,
                contents: [flipCardID]),
            discard: Zone(id: ZoneID(name: "discard"), visibility: .publicAll, contents: []),
            played: false)
    }

    func phase(of state: FlipState) -> Phase {
        state.played ? Phase(rawValue: "done") : Phase(rawValue: "play")
    }

    func legalActions(for seat: SeatID, in state: FlipState) -> [FlipAction] {
        guard seat == flipSeat0, !state.played else { return [] }
        return [.play]
    }

    func apply(_ action: FlipAction, by seat: SeatID, to state: FlipState)
        -> Result<(FlipState, [GameEvent]), RuleViolation>
    {
        guard seat == flipSeat0 else {
            return .failure(
                RuleViolation(code: "not-your-turn", reason: "It is not your turn to play."))
        }
        guard !state.played else {
            return .failure(RuleViolation(code: "hand-over", reason: "The hand is already over."))
        }
        var next = state
        next.hand.contents.removeAll { $0 == flipCardID }
        next.discard.contents.append(flipCardID)
        next.discard.faceUp.insert(flipCardID)
        next.played = true
        let move = PieceMoveDescriptor(
            piece: flipCardID,
            from: next.hand.id,
            to: next.discard.id,
            toIndex: 0,
            faceUp: true)
        let events: [GameEvent] = [
            .pieceMoved(move),
            .handEnded(outcome(next)),
        ]
        return .success((next, events))
    }

    func isTerminal(_ state: FlipState) -> Bool { state.played }

    func outcome(_ state: FlipState) -> HandOutcome {
        state.played ? HandOutcome(winners: [flipSeat0], scores: [flipSeat0: 1]) : .draw
    }

    func redactedView(of state: FlipState, for viewer: Viewer) -> PlayerView {
        let tokenizer = ViewTokenizer(viewer: viewer, salt: 1)
        let zones = Redaction.zoneViews(
            of: [state.hand, state.discard],
            for: viewer,
            using: tokenizer,
            faceResolver: { id in
                id == flipCardID ? .card(Card(id: flipCardID, face: flipCardFace)) : nil
            })
        let legal = legalActions(for: seatOf(viewer) ?? flipSeat1, in: state)
        let erased = legal.compactMap { try? AnyGameAction($0) }
        return PlayerView(
            viewer: viewer,
            zones: zones,
            scores: [flipSeat0: state.played ? 1 : 0],
            phase: phase(of: state),
            legalActions: erased)
    }

    private func seatOf(_ viewer: Viewer) -> SeatID? {
        if case .seat(let s) = viewer { return s }
        return nil
    }
}

// MARK: - Helpers

private func makeHost() -> GameHost<Flip> {
    GameHost(
        game: Flip(),
        options: FlipOptions(),
        seats: [flipSeat0, flipSeat1],
        seed: 42)
}

/// The face revealed for `viewer` in the hand zone, or `nil` if it is tokenized/absent.
private func handFace(in view: PlayerView) -> CardFace? {
    guard let hand = view.zones.first(where: { $0.id.name == "hand" }) else { return nil }
    guard let first = hand.pieces.first else { return nil }
    if case .known(.card(let card)) = first { return card.face }
    return nil
}

/// Whether the hand zone's first piece is a hidden token (identity concealed).
private func handIsTokenized(in view: PlayerView) -> Bool {
    guard let hand = view.zones.first(where: { $0.id.name == "hand" }),
        let first = hand.pieces.first
    else { return false }
    if case .hidden = first { return true }
    return false
}

@Suite("GameHost actor + transport envelope (R-SESS-1, R-SESS-4)")
struct GameHostTests {

    // MARK: - Initial view (R-ENG-8.2, R-SESS-1.2)

    @Test("the host vends an initial redacted view for a viewer")
    func initialView() async {
        let host = makeHost()
        let view = await host.view(for: .seat(flipSeat0))
        #expect(view.viewer == .seat(flipSeat0))
        #expect(view.phase == Phase(rawValue: "play"))
        // seat-0 owns the hand, so it sees the real card.
        #expect(handFace(in: view) == flipCardFace)
        #expect(await host.logCount == 0)
    }

    // MARK: - Legal submit → accepted (R-SESS-4.1, R-ENG-7.1, R-ENG-4.4)

    @Test(
        "a legal action is accepted with the expected events and an updated view; the log grows by one"
    )
    func legalSubmitAccepted() async throws {
        let host = makeHost()
        let transport = InProcessTransport(host: host)

        let envelope = ActionEnvelope(seat: flipSeat0, action: try AnyGameAction(FlipAction.play))
        let reply = await transport.send(.submit(envelope))

        guard case .result(let result) = reply, case .accepted(let events, let views) = result
        else {
            Issue.record("expected an accepted result")
            return
        }
        // Expected events: the card moves to discard face-up, then the hand ends.
        #expect(
            events.contains(.handEnded(HandOutcome(winners: [flipSeat0], scores: [flipSeat0: 1]))))
        #expect(events.contains { if case .pieceMoved = $0 { return true } else { return false } })

        // A view was addressed to every seat + the spectator (2 + 1).
        #expect(views.count == 3)

        // State advanced — observed ONLY through a view, never raw State (R-SESS-1.2). The card is now in
        // discard, face-up, and the phase is done.
        let seat0View = await host.view(for: .seat(flipSeat0))
        #expect(seat0View.phase == Phase(rawValue: "done"))
        let discard = seat0View.zones.first { $0.id.name == "discard" }
        #expect(discard?.pieces.count == 1)

        // The log grew by exactly one entry, carrying a resulting state hash (R-ENG-7.1, R-ENG-4.4).
        #expect(await host.logCount == 1)
        #expect(await host.lastStateHash != nil)
    }

    // MARK: - Illegal submit → rejected (R-SESS-1.2, R-SESS-4.1)

    @Test("an illegal action is rejected with the RuleViolation and mutates nothing")
    func illegalSubmitRejected() async throws {
        let host = makeHost()
        let transport = InProcessTransport(host: host)

        let before = await host.view(for: .seat(flipSeat0))

        // Wrong seat submits — illegal.
        let envelope = ActionEnvelope(seat: flipSeat1, action: try AnyGameAction(FlipAction.play))
        let reply = await transport.send(.submit(envelope))

        guard case .result(let result) = reply, case .rejected(let violation) = result else {
            Issue.record("expected a rejected result")
            return
        }
        #expect(violation.code == "not-your-turn")
        #expect(!violation.reason.isEmpty)

        // State unchanged: view identical, log still empty (R-SESS-1.2).
        let after = await host.view(for: .seat(flipSeat0))
        #expect(after == before)
        #expect(await host.logCount == 0)
    }

    // MARK: - Determinism (R-ENG-4.4)

    @Test("same seed + same action sequence yields identical resulting state hashes")
    func determinismSameSeedSameHash() async throws {
        func runOnce() async throws -> StateHash? {
            let host = makeHost()
            let envelope = ActionEnvelope(
                seat: flipSeat0, action: try AnyGameAction(FlipAction.play))
            _ = await host.submit(envelope)
            return await host.lastStateHash
        }
        let a = try await runOnce()
        let b = try await runOnce()
        #expect(a != nil)
        #expect(a == b)
    }

    // MARK: - In-process transport round-trip + Codable envelopes (R-SESS-4.1, R-SESS-4.2)

    @Test("a requestView message round-trips through the transport to a HostMessage")
    func transportRequestViewRoundTrip() async {
        let host = makeHost()
        let transport = InProcessTransport(host: host)
        let reply = await transport.send(.requestView(.spectator))
        guard case .viewUpdate(let view) = reply else {
            Issue.record("expected a viewUpdate")
            return
        }
        #expect(view.viewer == .spectator)
    }

    @Test("ClientMessage round-trips through JSON (R-SESS-4.1)")
    func clientMessageCodableRoundTrip() throws {
        let submit = ClientMessage.submit(
            ActionEnvelope(seat: flipSeat0, action: try AnyGameAction(FlipAction.play)))
        let request = ClientMessage.requestView(.seat(flipSeat1))
        for message in [submit, request] {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)
            #expect(decoded == message)
        }
    }

    @Test("HostMessage round-trips through JSON (R-SESS-4.1)")
    func hostMessageCodableRoundTrip() throws {
        let accepted = HostMessage.result(
            .accepted(
                events: [.handEnded(HandOutcome(winners: [flipSeat0], scores: [flipSeat0: 1]))],
                views: []))
        let rejected = HostMessage.result(
            .rejected(RuleViolation(code: "not-your-turn", reason: "Not your turn.")))
        let update = HostMessage.viewUpdate(
            PlayerView(viewer: .spectator, scores: [:], phase: Phase(rawValue: "play")))
        for message in [accepted, rejected, update] {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(HostMessage.self, from: data)
            #expect(decoded == message)
        }
    }

    // MARK: - No-leak: hidden identity is tokenized in the vended view (R-ENG-8.3)

    @Test(
        "the host vends a tokenized hidden piece to a viewer who may not see it — no identity leak")
    func hiddenPieceTokenizedInVendedView() async {
        let host = makeHost()
        let transport = InProcessTransport(host: host)

        // The spectator may not see seat-0's ownerOnly hand: the host must tokenize it.
        let reply = await transport.send(.requestView(.spectator))
        guard case .viewUpdate(let spectatorView) = reply else {
            Issue.record("expected a viewUpdate")
            return
        }
        #expect(handIsTokenized(in: spectatorView))
        #expect(handFace(in: spectatorView) == nil)

        // The owner (seat-0) DOES see the real card, confirming redaction is per-viewer.
        let ownerView = await host.view(for: .seat(flipSeat0))
        #expect(handFace(in: ownerView) == flipCardFace)

        // The serialized spectator view contains no reference to the real card's identity.
        let json = try? JSONEncoder().encode(spectatorView)
        let text = json.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!text.contains("\"ace\""))
    }

    // MARK: - Restore by replay (R-PERS-1.2, R-ENG-7.2, R-QA-4.1)

    @Test("restoring replays a recorded log to the exact state hash the live host reached")
    func restoreReplaysToSameHash() async throws {
        // Run a hand live and capture its log + resulting hash.
        let live = makeHost()
        _ = await live.submit(
            ActionEnvelope(seat: flipSeat0, action: try AnyGameAction(FlipAction.play)))
        let liveHash = await live.lastStateHash
        let recordedLog = await live.actionLog.entries
        #expect(recordedLog.count == 1)

        // Rebuild a fresh host by replaying that log against the same seed.
        let restore = GameHost.restoring(
            game: Flip(),
            options: FlipOptions(),
            seats: [flipSeat0, flipSeat1],
            seed: 42,
            replaying: recordedLog)

        guard case .success(let restored) = restore else {
            Issue.record("expected a successful restore")
            return
        }
        // The restored host holds the same log and reached the same state hash (R-QA-4.1).
        #expect(await restored.logCount == 1)
        #expect(await restored.lastStateHash == liveHash)

        // Continuing from the restore behaves like the live host: the hand is over, so a further play is
        // rejected — not applied twice.
        let further = await restored.submit(
            ActionEnvelope(seat: flipSeat0, action: try AnyGameAction(FlipAction.play)))
        #expect(!further.isAccepted)
    }

    @Test("restoring a log whose recorded hash does not match fails cleanly, no crash")
    func restoreHashMismatchFails() async throws {
        // A recorded entry with a deliberately WRONG resulting hash — a corrupt/incompatible save.
        let bogusEntry = LogEntry(
            index: 0,
            seat: flipSeat0,
            action: try AnyGameAction(FlipAction.play),
            resultingStateHash: StateHash(bytes: Array(repeating: 0, count: 32)))

        let restore = GameHost.restoring(
            game: Flip(),
            options: FlipOptions(),
            seats: [flipSeat0, flipSeat1],
            seed: 42,
            replaying: [bogusEntry])

        guard case .failure(let error) = restore else {
            Issue.record("expected a restore failure")
            return
        }
        #expect(error == .hashMismatch(index: 0))
    }
}
