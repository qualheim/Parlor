// Tests for the match structure and action log (task 2.7; R-ENG-6, R-ENG-7).
//
// These cover the three groups task 2.7 introduces: the ordered `ActionLog` and its primitives, the
// `Match` bookkeeping (dealer rotation, cumulative scoring, hand summaries, end conditions), and the
// `UndoEngine` keyed to each `UndoPolicy`. Codable round-trips confirm no timestamp leaks into any
// authoritative-state-adjacent type — timestamps live only in `LogMetadata` (tech.md rule 8, R-ENG-7.1).

import Foundation
import Testing

@testable import EngineCore

// MARK: - Test helpers

/// A trivial `GameAction` used to build `AnyGameAction` values for log tests. Kept local to the tests so
/// EngineCore stays game-agnostic.
private struct TestAction: GameAction, Hashable {
    let move: String
}

/// Type-erase a labeled test action.
private func action(_ move: String) throws -> AnyGameAction {
    try AnyGameAction(TestAction(move: move))
}

/// A deterministic dummy hash for log entries (content is irrelevant to log-structure tests).
private func hash(_ label: String) -> StateHash {
    StateHash.of(Array(label.utf8))
}

private let seat0 = SeatID.index(0)
private let seat1 = SeatID.index(1)
private let seat2 = SeatID.index(2)

/// Round-trip a value through JSON and return the decoded copy.
private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - ActionLog (R-ENG-7.1, R-ENG-7.2)

@Suite("Action log")
struct ActionLogTests {
    @Test("append assigns sequential indices and preserves order")
    func appendOrdered() throws {
        var log = ActionLog()
        let a = log.append(seat: seat0, action: try action("a"), resultingStateHash: hash("a"))
        let b = log.append(seat: seat1, action: try action("b"), resultingStateHash: hash("b"))
        let c = log.append(seat: seat0, action: try action("c"), resultingStateHash: hash("c"))

        #expect(a.index == 0)
        #expect(b.index == 1)
        #expect(c.index == 2)
        #expect(log.count == 3)
        #expect(log.entries.map(\.index) == [0, 1, 2])
        #expect(log.last == c)
    }

    @Test("rewind truncates to a length and returns the dropped tail")
    func rewindDropsTail() throws {
        var log = ActionLog()
        log.append(seat: seat0, action: try action("a"), resultingStateHash: hash("a"))
        log.append(seat: seat1, action: try action("b"), resultingStateHash: hash("b"))
        log.append(seat: seat0, action: try action("c"), resultingStateHash: hash("c"))

        let dropped = log.rewind(to: 1)
        #expect(log.count == 1)
        #expect(dropped.map(\.index) == [1, 2])
        #expect(log.last?.index == 0)
    }

    @Test("rewind clamps out-of-range lengths")
    func rewindClamps() throws {
        var log = ActionLog()
        log.append(seat: seat0, action: try action("a"), resultingStateHash: hash("a"))

        #expect(log.rewind(to: 99).isEmpty)  // beyond end → no-op
        #expect(log.count == 1)
        let all = log.rewind(to: -5)  // below zero → full clear
        #expect(all.count == 1)
        #expect(log.isEmpty)
    }

    @Test("entries(since:) returns the tail from an index onward")
    func entriesSince() throws {
        var log = ActionLog()
        for label in ["a", "b", "c", "d"] {
            log.append(seat: seat0, action: try action(label), resultingStateHash: hash(label))
        }
        #expect(log.entries(since: 0).count == 4)
        #expect(log.entries(since: 2).map(\.index) == [2, 3])
        #expect(log.entries(since: 4).isEmpty)
        #expect(log.entries(since: 99).isEmpty)
    }

    @Test("append after rewind keeps indices contiguous")
    func appendAfterRewind() throws {
        var log = ActionLog()
        log.append(seat: seat0, action: try action("a"), resultingStateHash: hash("a"))
        log.append(seat: seat1, action: try action("b"), resultingStateHash: hash("b"))
        log.rewind(to: 1)
        let c = log.append(seat: seat0, action: try action("c"), resultingStateHash: hash("c"))
        #expect(c.index == 1)
        #expect(log.entries.map(\.index) == [0, 1])
    }
}

// MARK: - Codable round-trips and timestamp quarantine (R-ENG-7.1, R-ENG-8.5)

@Suite("Match Codable round-trips")
struct MatchCodableTests {
    @Test("LogMetadata round-trips and is the only place a timestamp lives")
    func logMetadataRoundTrip() throws {
        let meta = LogMetadata(createdAtUnix: 1_700_000_000, note: "resumed")
        let decoded = try roundTrip(meta)
        #expect(decoded == meta)
        #expect(decoded.createdAtUnix == 1_700_000_000)
    }

    @Test("LogEntry round-trips; its authoritative fields carry no timestamp")
    func logEntryRoundTrip() throws {
        let entry = LogEntry(
            index: 3,
            seat: seat1,
            action: try action("play"),
            resultingStateHash: hash("state"),
            metadata: LogMetadata(createdAtUnix: 42))
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)

        // The authoritative portion (everything but metadata) must not encode any time field: encode a
        // copy with empty metadata and confirm the JSON has no time-like key.
        let stripped = LogEntry(
            index: entry.index,
            seat: entry.seat,
            action: entry.action,
            resultingStateHash: entry.resultingStateHash,
            metadata: .none)
        let json = String(decoding: try JSONEncoder().encode(stripped), as: UTF8.self)
        #expect(!json.lowercased().contains("createdat"))
    }

    @Test("EndCondition encodes as { kind, value } per the save schema")
    func endConditionEncoding() throws {
        let target = EndCondition.targetScore(value: 100)
        let json = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
        #expect(json.contains("\"kind\""))
        #expect(json.contains("targetScore"))
        #expect(json.contains("100"))
        #expect(try roundTrip(target) == target)
        #expect(try roundTrip(EndCondition.handCount(value: 8)) == .handCount(value: 8))
        #expect(try roundTrip(EndCondition.openEnded) == .openEnded)
    }

    @Test("HandSummary and Match round-trip")
    func matchRoundTrip() throws {
        var match = Match(dealer: seat0, target: .targetScore(value: 50))
        match.applyHand(
            outcome: HandOutcome(winners: [seat1], scores: [seat0: 3, seat1: 10]),
            seed: 12345,
            order: [seat0, seat1])
        let decoded = try roundTrip(match)
        #expect(decoded == match)
        #expect(decoded.handSummaries.count == 1)
        #expect(decoded.handSeeds == [12345])
    }
}

// MARK: - Match: dealer rotation (R-ENG-6.2)

@Suite("Dealer rotation")
struct DealerRotationTests {
    @Test("dealer cycles through the seat order and wraps")
    func rotationWraps() {
        var match = Match(dealer: seat0, target: .openEnded)
        let order = [seat0, seat1, seat2]

        match.rotateDealer(order: order)
        #expect(match.dealer == seat1)
        match.rotateDealer(order: order)
        #expect(match.dealer == seat2)
        match.rotateDealer(order: order)
        #expect(match.dealer == seat0)  // wrapped
    }

    @Test("dealer not in order resets to the first seat")
    func rotationResetsWhenMissing() {
        var match = Match(dealer: SeatID.index(9), target: .openEnded)
        match.rotateDealer(order: [seat0, seat1])
        #expect(match.dealer == seat0)
    }

    @Test("empty seat order leaves the dealer unchanged")
    func rotationEmptyOrder() {
        var match = Match(dealer: seat0, target: .openEnded)
        match.rotateDealer(order: [])
        #expect(match.dealer == seat0)
    }
}

// MARK: - Match: cumulative scoring and summaries (R-ENG-6.2, R-ENG-6.3, R-ENG-4.3)

@Suite("Cumulative scoring")
struct CumulativeScoringTests {
    @Test("scores accumulate across hands and summaries grow one per hand")
    func accumulatesAcrossHands() {
        var match = Match(dealer: seat0, target: .targetScore(value: 100))
        let order = [seat0, seat1]

        match.applyHand(
            outcome: HandOutcome(winners: [seat0], scores: [seat0: 20, seat1: 5]),
            seed: 1, order: order)
        match.applyHand(
            outcome: HandOutcome(winners: [seat1], scores: [seat0: 4, seat1: 30]),
            seed: 2, order: order)

        #expect(match.cumulativeScores[seat0] == 24)
        #expect(match.cumulativeScores[seat1] == 35)
        #expect(match.handSummaries.count == 2)
        #expect(match.handSeeds == [1, 2])
        #expect(match.completedHandCount == 2)
    }

    @Test("dealer rotates by default after each hand, honoring recorded dealer per summary")
    func summaryRecordsDealerBeforeRotation() {
        var match = Match(dealer: seat0, target: .openEnded)
        let order = [seat0, seat1]

        match.applyHand(outcome: .draw, seed: 1, order: order)
        match.applyHand(outcome: .draw, seed: 2, order: order)

        #expect(match.handSummaries[0].dealer == seat0)  // dealt by seat0
        #expect(match.handSummaries[1].dealer == seat1)  // rotated to seat1
        #expect(match.dealer == seat0)  // rotated back for the next hand
    }

    @Test("advanceDealer:false leaves the dealer fixed")
    func noRotationWhenDisabled() {
        var match = Match(dealer: seat0, target: .openEnded)
        match.applyHand(outcome: .draw, seed: 1, order: [seat0, seat1], advanceDealer: false)
        #expect(match.dealer == seat0)
    }

    @Test("summary snapshots the cumulative score at that hand")
    func summarySnapshotsCumulative() {
        var match = Match(dealer: seat0, target: .openEnded)
        let order = [seat0, seat1]
        match.applyHand(outcome: HandOutcome(scores: [seat0: 10]), seed: 1, order: order)
        match.applyHand(outcome: HandOutcome(scores: [seat0: 5]), seed: 2, order: order)
        #expect(match.handSummaries[0].cumulativeScores[seat0] == 10)
        #expect(match.handSummaries[1].cumulativeScores[seat0] == 15)
    }
}

// MARK: - Match: end conditions (R-ENG-6.2)

@Suite("End conditions")
struct EndConditionTests {
    @Test("target-score reached ends the match; below it continues")
    func targetScore() {
        var match = Match(dealer: seat0, target: .targetScore(value: 100))
        let order = [seat0, seat1]

        match.applyHand(outcome: HandOutcome(scores: [seat0: 60]), seed: 1, order: order)
        #expect(!match.isMatchOver)  // 60 < 100

        match.applyHand(outcome: HandOutcome(scores: [seat0: 45]), seed: 2, order: order)
        #expect(match.isMatchOver)  // 105 >= 100
        #expect(match.leaders == [seat0])
    }

    @Test("hand-count condition ends after the set number of hands")
    func handCount() {
        var match = Match(dealer: seat0, target: .handCount(value: 2))
        let order = [seat0, seat1]
        match.applyHand(outcome: .draw, seed: 1, order: order)
        #expect(!match.isMatchOver)
        match.applyHand(outcome: .draw, seed: 2, order: order)
        #expect(match.isMatchOver)
    }

    @Test("open-ended never ends on its own")
    func openEnded() {
        var match = Match(dealer: seat0, target: .openEnded)
        match.applyHand(outcome: HandOutcome(scores: [seat0: 9999]), seed: 1, order: [seat0])
        #expect(!match.isMatchOver)
    }
}

// MARK: - Undo (R-ENG-7.3, R-ENG-7.4)

@Suite("Undo policies")
struct UndoTests {
    /// Build an undo engine seeded with `n` alternating human/AI-labelled actions.
    private func engine(policy: UndoPolicy, entries labels: [(SeatID, String)]) throws -> UndoEngine
    {
        var log = ActionLog()
        for (seat, label) in labels {
            log.append(seat: seat, action: try action(label), resultingStateHash: hash(label))
        }
        return UndoEngine(policy: policy, log: log)
    }

    @Test("unlimited allows undo then redo, replaying the retained entry")
    func unlimitedUndoRedo() throws {
        var undo = try engine(
            policy: .unlimited,
            entries: [(seat0, "a"), (seat0, "b"), (seat0, "c")])
        #expect(undo.canUndo)

        let undone = undo.undo()
        #expect(undone?.index == 2)
        #expect(undo.log.count == 2)
        #expect(undo.canRedo)

        let redone = undo.redo()
        #expect(redone?.index == 2)  // reassigned to the current end
        #expect(redone?.action == undone?.action)
        #expect(undo.log.count == 3)
        #expect(!undo.canRedo)
    }

    @Test("a diverging append clears the redo stack")
    func divergingAppendClearsRedo() throws {
        var undo = try engine(policy: .unlimited, entries: [(seat0, "a"), (seat0, "b")])
        undo.undo()
        #expect(undo.canRedo)
        undo.recordDivergingAppend()
        #expect(!undo.canRedo)
        #expect(undo.redo() == nil)
    }

    @Test("none disallows undo and redo")
    func noneDisallows() throws {
        var undo = try engine(policy: .none, entries: [(seat0, "a"), (seat1, "b")])
        #expect(!undo.canUndo)
        #expect(undo.undo() == nil)
        #expect(undo.redo() == nil)
        #expect(!undo.isExcludedFromStatistics)
    }

    @Test(
        "practiceMode computes the rewind index dropping trailing AI actions to the last human action"
    )
    func practiceModeRewind() throws {
        // Log: human(0), ai(1), human(2), ai(3), ai(4). seat1 and seat2 are AI.
        let undo = try engine(
            policy: .practiceMode,
            entries: [
                (seat0, "h0"), (seat1, "ai1"), (seat0, "h2"), (seat1, "ai3"), (seat2, "ai4"),
            ])
        let isAI: (SeatID) -> Bool = { $0 == seat1 || $0 == seat2 }
        // Rewinding to index 2 drops the last human action (h2) and the trailing AI actions (ai3, ai4).
        #expect(undo.rewindIndexForLastHumanUndo(isAI: isAI) == 2)
        #expect(undo.isExcludedFromStatistics)
    }

    @Test("practiceMode returns nil when there is no human action to undo")
    func practiceModeNoHuman() throws {
        let undo = try engine(policy: .practiceMode, entries: [(seat1, "ai0"), (seat2, "ai1")])
        let isAI: (SeatID) -> Bool = { _ in true }
        #expect(undo.rewindIndexForLastHumanUndo(isAI: isAI) == nil)
    }

    @Test("rewindIndexForLastHumanUndo is only valid for practiceMode")
    func rewindOnlyForPractice() throws {
        let undo = try engine(policy: .unlimited, entries: [(seat0, "h0")])
        #expect(undo.rewindIndexForLastHumanUndo(isAI: { _ in false }) == nil)
    }
}
