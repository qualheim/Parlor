import CoreGraphics
import EngineCore
import Foundation
import Testing

@testable import TableKit

// Tests for task 5.6 — the PURE HUD state/layout logic behind the six HUD components: seat plates
// (avatar/name/score/dealer/role/active-glow/thinking), the scoreboard, the caption/history narration,
// the toolbar/pause-menu action models, and the reserved-chrome layout that keeps the HUD off the cards
// (R-TABLE-6.1, R-TABLE-6.2, R-TABLE-6.3). Everything under test is value-level, so it runs headless with
// no running UI; the SwiftUI views in `HUDView.swift` are exercised only for compilation.

// MARK: - Fixtures

private func seat(_ i: Int) -> SeatID { .index(i) }

private func humanProfile(_ name: String) -> PlayerProfile {
    PlayerProfile(
        id: ProfileID(raw: "p-\(name)"),
        displayName: name,
        avatar: .generatedGlyph(symbol: "person.crop.circle.fill", tint: "#4C6EF5"),
        controllerKind: .localHuman)
}

private func aiProfile(_ name: String) -> PlayerProfile {
    PlayerProfile(
        id: ProfileID(raw: "p-\(name)"),
        displayName: name,
        avatar: .generatedGlyph(symbol: "bolt.fill", tint: "#C92A2A"),
        controllerKind: .ai(persona: PersonaID(raw: "persona-\(name)")))
}

/// A match with the given dealer, target, and cumulative scores.
private func match(
    dealer: SeatID,
    scores: [SeatID: Int] = [:],
    target: EndCondition = .targetScore(value: 100),
    hands: Int = 0
) -> Match {
    var m = Match(dealer: dealer, target: target, cumulativeScores: scores)
    // Fabricate completed-hand summaries so `completedHandCount` reflects `hands`.
    for i in 0..<hands {
        m.handSummaries.append(
            HandSummary(
                handIndex: i,
                dealer: dealer,
                seed: UInt64(i),
                outcome: HandOutcome(),
                cumulativeScores: scores))
    }
    return m
}

// MARK: - Seat plate state (R-TABLE-6.2)

@Suite("HUD seat plates (R-TABLE-6.2)")
struct SeatPlateTests {
    @Test("a plate carries avatar, name, score, dealer, active-turn glow, and roles")
    func plateFields() {
        let m = match(dealer: seat(0), scores: [seat(0): 30, seat(1): 10])
        let plate = HUDModel.seatPlate(
            seat: seat(0),
            profile: humanProfile("Ada"),
            match: m,
            activeSeat: seat(0))

        #expect(plate.profile.displayName == "Ada")
        #expect(plate.score == 30)
        #expect(plate.isDealer)  // dealer is seat 0
        #expect(plate.isActiveTurn)  // it's seat 0's turn
        #expect(plate.roles.contains(.leader))  // seat 0 leads 30 vs 10
    }

    @Test("a seat with no recorded score shows zero")
    func missingScoreIsZero() {
        let m = match(dealer: seat(1))
        let plate = HUDModel.seatPlate(
            seat: seat(0), profile: humanProfile("Ada"), match: m, activeSeat: nil)
        #expect(plate.score == 0)
        #expect(!plate.isDealer)
        #expect(!plate.isActiveTurn)
    }

    @Test("the thinking indicator shows only for an AI seat that is deciding")
    func thinkingOnlyForAI() {
        let m = match(dealer: seat(0))
        let ai = HUDModel.seatPlate(
            seat: seat(1),
            profile: aiProfile("Rex"),
            match: m,
            activeSeat: seat(1),
            thinkingSeats: [seat(1)])
        #expect(ai.isAI)
        #expect(ai.isThinking)

        // A human seat in the thinking set never shows the indicator (it's meaningless for a human).
        let human = HUDModel.seatPlate(
            seat: seat(0),
            profile: humanProfile("Ada"),
            match: m,
            activeSeat: seat(0),
            thinkingSeats: [seat(0)])
        #expect(!human.isAI)
        #expect(!human.isThinking)
    }

    @Test("no leader role before any scores exist")
    func noLeaderRoleWithoutScores() {
        let m = match(dealer: seat(0))  // empty cumulativeScores
        let plate = HUDModel.seatPlate(
            seat: seat(0), profile: humanProfile("Ada"), match: m, activeSeat: nil)
        #expect(!plate.roles.contains(.leader))
    }

    @Test("game-supplied extra roles are preserved and not duplicated")
    func extraRoles() {
        let m = match(dealer: seat(0), scores: [seat(0): 5])
        let plate = HUDModel.seatPlate(
            seat: seat(0),
            profile: humanProfile("Ada"),
            match: m,
            activeSeat: nil,
            extraRoles: [.custom("Picker")])
        #expect(plate.roles.contains(.custom("Picker")))
        #expect(plate.roles.contains(.leader))  // leader added on top
        // Leader appears exactly once even if the caller already passed it.
        let plate2 = HUDModel.seatPlate(
            seat: seat(0),
            profile: humanProfile("Ada"),
            match: m,
            activeSeat: nil,
            extraRoles: [.leader])
        #expect(plate2.roles.filter { $0 == .leader }.count == 1)
    }

    @Test("accessibility summary reflects all shown state (R-A11Y-1.2)")
    func accessibilitySummary() {
        let m = match(dealer: seat(1), scores: [seat(1): 40])
        let plate = HUDModel.seatPlate(
            seat: seat(1),
            profile: aiProfile("Even Steven"),
            match: m,
            activeSeat: seat(1),
            thinkingSeats: [seat(1)])
        let summary = plate.accessibilitySummary
        #expect(summary.contains("Even Steven"))
        #expect(summary.contains("40 points"))
        #expect(summary.contains("dealer"))
        #expect(summary.contains("to play"))
        #expect(summary.contains("thinking"))
    }

    @Test("seatPlates skips seats without a profile and preserves order")
    func seatPlatesOrdering() {
        let m = match(dealer: seat(0), scores: [seat(0): 1, seat(2): 2])
        let profiles: [SeatID: PlayerProfile] = [
            seat(0): humanProfile("Ada"),
            seat(2): aiProfile("Rex"),
            // seat(1) intentionally missing
        ]
        let plates = HUDModel.seatPlates(
            seatOrder: [seat(0), seat(1), seat(2)],
            profiles: profiles,
            match: m,
            activeSeat: seat(2))
        #expect(plates.map(\.seat) == [seat(0), seat(2)])
        #expect(plates[1].isActiveTurn)
    }
}

// MARK: - Seat ring positioning (R-TABLE-6.2)

@Suite("HUD seat ring (R-TABLE-6.2)")
struct SeatRingTests {
    @Test("local player (seat index 0) sits bottom-center")
    func localBottomCenter() {
        let anchor = HUDModel.seatAnchor(seatIndex: 0, seatCount: 4)
        #expect(abs(anchor.x - 0.5) < 1e-9)  // horizontally centered
        #expect(anchor.y > 0.5)  // below center (bottom)
    }

    @Test("other seats are distributed away from the bottom-center anchor")
    func othersDistributed() {
        let count = 4
        let local = HUDModel.seatAnchor(seatIndex: 0, seatCount: count)
        for i in 1..<count {
            let other = HUDModel.seatAnchor(seatIndex: i, seatCount: count)
            let dx = other.x - local.x
            let dy = other.y - local.y
            #expect((dx * dx + dy * dy) > 0.01)  // meaningfully separated from local seat
        }
    }

    @Test("the seat after local goes clockwise (to the local player's left, i.e. +x)")
    func clockwiseFromBottom() {
        // With seat 0 at bottom-center, sweeping clockwise in screen space (y grows downward) first moves
        // toward the +x (right) side. Seat 1 should therefore sit right-of-center.
        let s1 = HUDModel.seatAnchor(seatIndex: 1, seatCount: 4)
        #expect(s1.x > 0.5)
    }
}

// MARK: - Scoreboard (R-TABLE-6.1)

@Suite("HUD scoreboard (R-TABLE-6.1)")
struct ScoreboardTests {
    @Test("rows sort by score descending, leader flagged")
    func sortAndLeader() {
        let m = match(
            dealer: seat(0),
            scores: [seat(0): 10, seat(1): 40, seat(2): 25],
            hands: 3)
        let profiles: [SeatID: PlayerProfile] = [
            seat(0): humanProfile("Ada"),
            seat(1): aiProfile("Rex"),
            seat(2): aiProfile("Steven"),
        ]
        let board = HUDModel.scoreboard(
            seatOrder: [seat(0), seat(1), seat(2)], profiles: profiles, match: m)

        #expect(board.rows.map(\.score) == [40, 25, 10])  // descending
        #expect(board.rows.first?.seat == seat(1))
        #expect(board.rows.first?.isLeader == true)
        #expect(board.rows.dropFirst().allSatisfy { !$0.isLeader })
        #expect(board.handsPlayed == 3)
        #expect(!board.isMatchOver)
    }

    @Test("ties are broken by seat id for a stable order and share leader flag")
    func tieBreak() {
        let m = match(dealer: seat(0), scores: [seat(0): 20, seat(1): 20])
        let profiles: [SeatID: PlayerProfile] = [
            seat(0): humanProfile("Ada"), seat(1): humanProfile("Bo"),
        ]
        let board = HUDModel.scoreboard(
            seatOrder: [seat(1), seat(0)], profiles: profiles, match: m)
        // Both tied at the top → both leaders; stable order by seat id.
        #expect(board.rows.allSatisfy { $0.isLeader })
        #expect(board.rows.map(\.seat) == [seat(0), seat(1)])
    }

    @Test("match-over is surfaced when the target score is reached")
    func matchOver() {
        let m = match(
            dealer: seat(0), scores: [seat(0): 100], target: .targetScore(value: 100), hands: 5)
        let board = HUDModel.scoreboard(
            seatOrder: [seat(0)], profiles: [seat(0): humanProfile("Ada")], match: m)
        #expect(board.isMatchOver)
    }

    @Test("a seat missing a profile falls back to its raw id and zero score")
    func missingProfileFallback() {
        let m = match(dealer: seat(0))
        let board = HUDModel.scoreboard(seatOrder: [seat(0)], profiles: [:], match: m)
        #expect(board.rows.first?.name == seat(0).raw)
        #expect(board.rows.first?.score == 0)
        #expect(board.rows.first?.isLeader == false)  // no scores → nobody leads
    }
}

// MARK: - Narration / history (R-TABLE-6.1)

@Suite("HUD history narration (R-TABLE-6.1)")
struct HistoryTests {
    private func names(_ s: SeatID) -> String {
        switch s.raw {
        case "seat-0": return "Ada"
        case "seat-1": return "Rex"
        default: return s.raw
        }
    }

    @Test("informational events narrate; pure-geometry events do not")
    func narrateSelectivity() {
        #expect(HUDModel.narrate(.turnChanged(to: seat(1)), nameForSeat: names) == "Rex to play")
        #expect(
            HUDModel.narrate(.trickWon(by: seat(0)), nameForSeat: names) == "Ada won the trick")
        #expect(
            HUDModel.narrate(.suitNamed(.hearts, by: seat(0)), nameForSeat: names)
                == "Ada named Hearts")
        // Geometry-only events say nothing (they drive animation, not history).
        #expect(
            HUDModel.narrate(.pieceFlipped(PieceID(raw: 1), faceUp: true), nameForSeat: names)
                == nil)
        #expect(HUDModel.narrate(.dealt(pieces: []), nameForSeat: names) == nil)
    }

    @Test("score changes narrate with sign and running total")
    func scoreNarration() {
        #expect(
            HUDModel.narrate(
                .scoreChanged(seat: seat(0), delta: 5, total: 25), nameForSeat: names)
                == "Ada +5 (25)")
        #expect(
            HUDModel.narrate(
                .scoreChanged(seat: seat(1), delta: -3, total: 12), nameForSeat: names)
                == "Rex -3 (12)")
    }

    @Test("hand-ended narrates winners or a draw")
    func handEndedNarration() {
        let win = GameEvent.handEnded(HandOutcome(winners: [seat(0)], scores: [seat(0): 10]))
        #expect(HUDModel.narrate(win, nameForSeat: names) == "Hand won by Ada")
        let draw = GameEvent.handEnded(HandOutcome(winners: [], scores: [:]))
        #expect(HUDModel.narrate(draw, nameForSeat: names) == "Hand ended in a draw")
    }

    @Test("history indexes narrated events in stream order and drops the silent ones")
    func historyBuild() {
        let events: [GameEvent] = [
            .dealt(pieces: []),  // silent
            .turnChanged(to: seat(0)),
            .pieceFlipped(PieceID(raw: 2), faceUp: true),  // silent
            .trickWon(by: seat(1)),
        ]
        let entries = HUDModel.history(events: events, nameForSeat: names)
        #expect(entries.map(\.text) == ["Ada to play", "Rex won the trick"])
        #expect(entries.map(\.index) == [0, 1])  // contiguous
    }
}

// MARK: - HUD chrome layout (R-TABLE-6.3)

@Suite("HUD chrome layout keeps clear of the play zones (R-TABLE-6.3)")
struct HUDLayoutTests {
    @Test("the play region never overlaps the top or bottom chrome bands")
    func playRegionClearOfBands() {
        let layout = HUDLayout.standard()
        #expect(!HUDLayout.overlaps(layout.playRegion, layout.topBand))
        #expect(!HUDLayout.overlaps(layout.playRegion, layout.bottomBand))
    }

    @Test("when the history drawer is open the play region shrinks to clear the right rail")
    func playRegionClearOfRail() {
        let closed = HUDLayout.standard(historyOpen: false)
        let open = HUDLayout.standard(historyOpen: true)
        #expect(open.rightRail.width > 0)
        #expect(closed.rightRail.width == 0)
        #expect(!HUDLayout.overlaps(open.playRegion, open.rightRail))
        // Opening the drawer narrows the play region.
        #expect(open.playRegion.width < closed.playRegion.width)
    }

    @Test("bands are clamped so the play region always keeps a non-empty area")
    func bandsClamped() {
        // Absurd thicknesses must not eat the whole table.
        let layout = HUDLayout.standard(
            topBandHeight: 5, bottomBandHeight: 5, rightRailWidth: 5, historyOpen: true)
        #expect(layout.playRegion.height >= 0.05)
        #expect(layout.playRegion.width > 0)
        #expect(!HUDLayout.overlaps(layout.playRegion, layout.topBand))
        #expect(!HUDLayout.overlaps(layout.playRegion, layout.bottomBand))
    }

    @Test("overlaps treats touching edges as non-overlapping")
    func touchingEdges() {
        let a = NormalizedRect(x: 0, y: 0, width: 1, height: 0.2)
        let b = NormalizedRect(x: 0, y: 0.2, width: 1, height: 0.8)  // starts exactly where a ends
        #expect(!HUDLayout.overlaps(a, b))
        let c = NormalizedRect(x: 0, y: 0.1, width: 1, height: 0.8)  // truly overlaps a
        #expect(HUDLayout.overlaps(a, c))
    }
}

// MARK: - Toolbar & pause menu action models (R-TABLE-6.1)

@Suite("HUD toolbar & pause-menu models (R-TABLE-6.1)")
struct HUDActionModelTests {
    @Test("the toolbar offers exactly New, Undo, Hint, Rules, Menu in order")
    func toolbarActions() {
        #expect(ToolbarAction.allCases == [.new, .undo, .hint, .rules, .menu])
        #expect(ToolbarAction.allCases.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
    }

    @Test("the standard pause menu lists the expected items with titles and symbols")
    func pauseMenuStandard() {
        let ids = PauseMenuItem.standard.map(\.id)
        #expect(ids == ["resume", "restart", "newGame", "settings", "rules", "quitToLibrary"])
        #expect(
            PauseMenuItem.standard.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
    }

    @Test("a custom pause-menu item carries its own id, title, and symbol")
    func customPauseItem() {
        let item = PauseMenuItem.custom(id: "surrender", title: "Surrender", systemImage: "flag")
        #expect(item.id == "custom.surrender")
        #expect(item.title == "Surrender")
        #expect(item.systemImage == "flag")
    }
}
