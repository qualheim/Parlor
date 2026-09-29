import CoreGraphics
import EngineCore
import Foundation
import Testing

@testable import TableKit

// Tests for task 3.4 — the PURE interaction/focus logic behind the three input paths, keyboard nav,
// the "why can't I play this?" explainer, legal-target highlighting, and the gentle illegal-move
// feedback (R-TABLE-3.1–3.6, R-TABLE-4.1, R-A11Y-2). SwiftUI views are exercised only for compilation;
// everything under test is value-level, so it runs headless with no running UI.

// MARK: - Fixtures

private func pid(_ n: UInt64) -> PieceID { PieceID(raw: n) }
private func key(_ n: UInt64) -> RenderKey { .known(pid(n)) }
private func zone(_ name: String, _ owner: SeatID? = nil) -> ZoneID {
    ZoneID(name: name, owner: owner)
}

/// A tiny thread-safe flag so a `@Sendable` seam closure can record that it was invoked without tripping
/// strict-concurrency captured-var rules.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func mark() {
        lock.lock()
        called = true
        lock.unlock()
    }

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }
}

/// A convenience seam builder: legal targets plus a resolve that accepts exactly the moves whose
/// destination is in `accepting` (for the piece), and rejects everything else with the given violation.
private func makeInput(
    legal: [MoveTarget],
    accepting: Set<ZoneID> = [],
    rejection: RuleViolation = RuleViolation(code: "illegal", reason: "That move isn't allowed."),
    smart: [RenderKey: ZoneID] = [:],
    explain: [RenderKey: RuleViolation] = [:]
) -> TableInteractionInput {
    let resolve: @Sendable (TableMove) -> MoveResult = { move in
        if accepting.contains(move.destination) {
            return .success(())
        } else {
            return .failure(rejection)
        }
    }
    let explainClosure: @Sendable (RenderKey) -> RuleViolation? = { renderKey in explain[renderKey]
    }
    let explainHook: (@Sendable (RenderKey) -> RuleViolation?)? =
        explain.isEmpty ? nil : explainClosure
    return TableInteractionInput(
        legalTargets: legal,
        resolve: resolve,
        smartTarget: { (renderKey: RenderKey) in smart[renderKey] },
        explain: explainHook
    )
}

// MARK: - Legal-target highlighting (R-TABLE-3.6)

@Suite("Legal-target highlighting comes straight from the seam (R-TABLE-3.6)")
struct LegalTargetHighlightTests {
    @Test("legalTargets(for:) returns exactly the destinations the provided moves allow")
    func exactTargets() {
        let input = makeInput(legal: [
            MoveTarget(piece: key(1), destination: zone("foundation-0")),
            MoveTarget(piece: key(1), destination: zone("tableau-3")),
            MoveTarget(piece: key(2), destination: zone("tableau-4")),
        ])
        let targets = Set(input.legalTargets(for: key(1)))
        #expect(targets == [zone("foundation-0"), zone("tableau-3")])
        // A different piece sees only its own targets.
        #expect(input.legalTargets(for: key(2)) == [zone("tableau-4")])
        // A piece with no legal moves highlights nothing.
        #expect(input.legalTargets(for: key(9)).isEmpty)
    }

    @Test("highlightedTargets reflects the current selection only")
    func highlightFollowsSelection() {
        let input = makeInput(legal: [
            MoveTarget(piece: key(1), destination: zone("foundation-0"))
        ])
        var model = TableInteractionModel()
        #expect(model.highlightedTargets(input).isEmpty)  // nothing selected
        model.select(key(1), from: zone("waste"))
        #expect(model.highlightedTargets(input) == [zone("foundation-0")])
        model.deselect()
        #expect(model.highlightedTargets(input).isEmpty)
    }

    @Test("isLegalTarget answers membership for a specific destination")
    func isLegalTarget() {
        let input = makeInput(legal: [
            MoveTarget(piece: key(1), destination: zone("foundation-0"))
        ])
        #expect(input.isLegalTarget(zone("foundation-0"), for: key(1)))
        #expect(!input.isLegalTarget(zone("tableau-0"), for: key(1)))
        #expect(!input.isLegalTarget(zone("foundation-0"), for: key(2)))
    }
}

// MARK: - Selection + click-to-place (R-TABLE-3.2, R-TABLE-4.1)

@Suite("Selection and click-to-place (R-TABLE-3.2, R-TABLE-4.1)")
struct SelectionPlacementTests {
    @Test(
        "select then place on a legal target produces the intended TableMove and clears selection")
    func placeOnLegalTarget() {
        let input = makeInput(
            legal: [MoveTarget(piece: key(1), destination: zone("foundation-0"))],
            accepting: [zone("foundation-0")]
        )
        var model = TableInteractionModel()
        model.select(key(1), from: zone("waste"))
        let outcome = model.place(on: zone("foundation-0"), using: input)
        guard case .accepted(let move) = outcome else {
            Issue.record("expected accepted")
            return
        }
        #expect(
            move
                == TableMove(
                    piece: key(1), source: zone("waste"), destination: zone("foundation-0")))
        #expect(model.selection == nil)  // success clears selection
        #expect(model.feedback == nil)  // success is silent — no caption (R-TABLE-4.1)
    }

    @Test("place on a non-target zone does not call the host and keeps the selection")
    func placeOnNonTarget() {
        let resolveCalled = CallFlag()
        let input = TableInteractionInput(
            legalTargets: [MoveTarget(piece: key(1), destination: zone("foundation-0"))],
            resolve: { _ in
                resolveCalled.mark()
                return .success(())
            }
        )
        var model = TableInteractionModel()
        model.select(key(1), from: zone("waste"))
        let outcome = model.place(on: zone("tableau-2"), using: input)
        #expect(outcome == .noAttempt)
        #expect(!resolveCalled.wasCalled)  // a click on a non-target must not bother the host
        #expect(model.selection?.piece == key(1))  // selection retained
        #expect(model.feedback == nil)  // no caption for a non-target click
    }

    @Test("place with nothing selected is a no-op")
    func placeWithoutSelection() {
        let input = makeInput(legal: [])
        var model = TableInteractionModel()
        #expect(model.place(on: zone("foundation-0"), using: input) == .noAttempt)
    }

    @Test(
        "a rejected legal-looking move springs back and captions the reason; no modal (R-TABLE-4.1)"
    )
    func rejectedMoveFeedback() {
        let violation = RuleViolation(
            code: "wrong-color", reason: "Build down in alternating colors.")
        // The target is advertised as legal but the host rejects it at apply-time.
        let input = makeInput(
            legal: [MoveTarget(piece: key(1), destination: zone("tableau-0"))],
            accepting: [],  // reject everything
            rejection: violation
        )
        var model = TableInteractionModel()
        model.select(key(1), from: zone("waste"))
        let outcome = model.place(on: zone("tableau-0"), using: input)
        guard case .rejected(let feedback) = outcome else {
            Issue.record("expected rejected")
            return
        }
        #expect(feedback.springBack == key(1))
        #expect(feedback.caption == violation.reason)  // caption text == reason (R-TABLE-4.1)
        #expect(feedback.code == "wrong-color")
        #expect(model.feedback == feedback)  // stored on the model for the view to render
        #expect(model.selection?.piece == key(1))  // selection retained so the player can retry
    }

    @Test("selecting a new piece clears prior feedback; clearFeedback keeps the selection")
    func feedbackLifecycle() {
        let violation = RuleViolation(code: "x", reason: "no")
        let input = makeInput(
            legal: [MoveTarget(piece: key(1), destination: zone("tableau-0"))],
            accepting: [], rejection: violation)
        var model = TableInteractionModel()
        model.select(key(1), from: zone("waste"))
        _ = model.place(on: zone("tableau-0"), using: input)
        #expect(model.feedback != nil)
        model.clearFeedback()
        #expect(model.feedback == nil)
        #expect(model.selection?.piece == key(1))  // clearFeedback keeps selection

        // Re-trigger, then select a different piece → feedback clears.
        _ = model.place(on: zone("tableau-0"), using: input)
        #expect(model.feedback != nil)
        model.select(key(2), from: zone("tableau-5"))
        #expect(model.feedback == nil)
        #expect(model.selection?.piece == key(2))
    }

    @Test("deselect clears both selection and feedback")
    func deselectClears() {
        let violation = RuleViolation(code: "x", reason: "no")
        let input = makeInput(
            legal: [MoveTarget(piece: key(1), destination: zone("tableau-0"))],
            accepting: [], rejection: violation)
        var model = TableInteractionModel()
        model.select(key(1), from: zone("waste"))
        _ = model.place(on: zone("tableau-0"), using: input)
        model.deselect()
        #expect(model.selection == nil)
        #expect(model.feedback == nil)
    }
}

// MARK: - Drag & drop (R-TABLE-3.1)

@Suite("Drag and drop shares the place code path (R-TABLE-3.1)")
struct DragDropTests {
    @Test("beginDrag flags the selection as dragging; drop on a legal target accepts")
    func dragThenDrop() {
        let input = makeInput(
            legal: [MoveTarget(piece: key(1), destination: zone("foundation-0"))],
            accepting: [zone("foundation-0")])
        var model = TableInteractionModel()
        model.beginDrag(key(1), from: zone("waste"))
        #expect(model.selection?.isDragging == true)
        let outcome = model.drop(on: zone("foundation-0"), using: input)
        guard case .accepted(let move) = outcome else {
            Issue.record("expected accepted")
            return
        }
        #expect(move.destination == zone("foundation-0"))
        #expect(model.selection == nil)
    }

    @Test("dropping on an illegal-looking (non-target) zone is a no-op that keeps the drag")
    func dropOnNonTarget() {
        let input = makeInput(
            legal: [MoveTarget(piece: key(1), destination: zone("foundation-0"))])
        var model = TableInteractionModel()
        model.beginDrag(key(1), from: zone("waste"))
        #expect(model.drop(on: zone("tableau-1"), using: input) == .noAttempt)
        #expect(model.selection?.piece == key(1))
    }
}

// MARK: - Smart move (R-TABLE-3.3)

@Suite("Double-click smart move (R-TABLE-3.3)")
struct SmartMoveTests {
    @Test("with a smart target, smartMove yields the smart TableMove and accepts")
    func smartMoveWithTarget() {
        let input = makeInput(
            legal: [MoveTarget(piece: key(1), destination: zone("foundation-0"))],
            accepting: [zone("foundation-0")],
            smart: [key(1): zone("foundation-0")])
        var model = TableInteractionModel()
        let outcome = model.smartMove(key(1), from: zone("waste"), using: input)
        guard case .accepted(let move) = outcome else {
            Issue.record("expected accepted")
            return
        }
        #expect(
            move
                == TableMove(
                    piece: key(1), source: zone("waste"), destination: zone("foundation-0")))
    }

    @Test("with no smart target, smartMove is a no-op (R-TABLE-3.3)")
    func smartMoveNoTarget() {
        let input = makeInput(legal: [], smart: [:])
        var model = TableInteractionModel()
        #expect(model.smartMove(key(1), from: zone("waste"), using: input) == .noAttempt)
        #expect(model.selection == nil)
    }

    @Test("a rejected smart move still springs back + captions (R-TABLE-4.1)")
    func smartMoveRejected() {
        let violation = RuleViolation(
            code: "blocked", reason: "The foundation isn't ready for that.")
        let input = makeInput(
            legal: [], accepting: [], rejection: violation, smart: [key(1): zone("foundation-0")])
        var model = TableInteractionModel()
        let outcome = model.smartMove(key(1), from: zone("waste"), using: input)
        guard case .rejected(let feedback) = outcome else {
            Issue.record("expected rejected")
            return
        }
        #expect(feedback.caption == violation.reason)
        #expect(model.feedback?.springBack == key(1))
    }
}

// MARK: - Why can't I play this? (R-TABLE-3.5)

@Suite("Why can't I play this? explanation (R-TABLE-3.5)")
struct WhyNotTests {
    @Test("prefers the host's dedicated explain hook")
    func usesExplainHook() {
        let violation = RuleViolation(code: "not-your-turn", reason: "It isn't your turn yet.")
        let input = makeInput(legal: [], explain: [key(1): violation])
        let model = TableInteractionModel()
        let explanation = model.explanation(for: key(1), from: zone("hand"), using: input)
        #expect(explanation?.reason == "It isn't your turn yet.")
    }

    @Test("falls back to probing the smart move for its RuleViolation reason")
    func fallsBackToProbe() {
        let violation = RuleViolation(code: "wrong-suit", reason: "Foundations build up by suit.")
        // No explain hook; a smart target exists but the host rejects the move.
        let input = makeInput(
            legal: [], accepting: [], rejection: violation, smart: [key(1): zone("foundation-0")])
        let model = TableInteractionModel()
        let explanation = model.explanation(for: key(1), from: zone("waste"), using: input)
        #expect(explanation?.reason == violation.reason)
    }

    @Test("returns nil when the piece can actually be played (probe succeeds)")
    func nilWhenPlayable() {
        let input = makeInput(
            legal: [MoveTarget(piece: key(1), destination: zone("foundation-0"))],
            accepting: [zone("foundation-0")],  // resolve succeeds → nothing to explain
            smart: [key(1): zone("foundation-0")])
        let model = TableInteractionModel()
        #expect(model.explanation(for: key(1), from: zone("waste"), using: input) == nil)
    }

    @Test("returns nil when there is no intended move to evaluate (no smart target, no hook)")
    func nilWhenNothingToProbe() {
        let input = makeInput(legal: [], smart: [:])
        let model = TableInteractionModel()
        #expect(model.explanation(for: key(1), from: zone("waste"), using: input) == nil)
    }

    @Test("explanation does not mutate selection or feedback (pure query)")
    func explanationIsPure() {
        let violation = RuleViolation(code: "x", reason: "no")
        let input = makeInput(
            legal: [], accepting: [], rejection: violation, smart: [key(1): zone("foundation-0")])
        var model = TableInteractionModel()
        model.select(key(2), from: zone("hand"))
        _ = model.explanation(for: key(1), from: zone("waste"), using: input)
        #expect(model.selection?.piece == key(2))  // unchanged
        #expect(model.feedback == nil)  // the probe did not set feedback
    }
}

// MARK: - Keyboard focus movement (R-TABLE-3.4, R-A11Y-2)

@Suite("Keyboard focus movement is pure and predictable (R-TABLE-3.4, R-A11Y-2)")
struct FocusMovementTests {
    /// A small topology: three zones in a ring, the middle one holding two pieces.
    private func topology() -> FocusTopology {
        FocusTopology(
            zoneOrder: [zone("stock"), zone("waste"), zone("foundation-0")],
            piecesByZone: [
                zone("stock"): [],
                zone("waste"): [key(1), key(2)],
                zone("foundation-0"): [key(3)],
            ])
    }

    @Test("initial focus is the first zone")
    func initial() {
        #expect(TableFocusModel.initialFocus(topology()) == .zone(zone("stock")))
        #expect(
            TableFocusModel.initialFocus(FocusTopology(zoneOrder: [], piecesByZone: [:])) == nil)
    }

    @Test("Right/Left move between zones and wrap around the ends")
    func horizontalWrap() {
        let topo = topology()
        var f: FocusTarget = .zone(zone("stock"))
        f = TableFocusModel.next(from: f, direction: .right, in: topo)
        #expect(f == .zone(zone("waste")))
        f = TableFocusModel.next(from: f, direction: .right, in: topo)
        #expect(f == .zone(zone("foundation-0")))
        f = TableFocusModel.next(from: f, direction: .right, in: topo)
        #expect(f == .zone(zone("stock")))  // wrapped
        f = TableFocusModel.next(from: f, direction: .left, in: topo)
        #expect(f == .zone(zone("foundation-0")))  // wrapped back
    }

    @Test("moving to a new zone lands on the whole zone, not a piece")
    func landsOnZone() {
        let topo = topology()
        let f = TableFocusModel.next(
            from: .piece(key(1), in: zone("waste")), direction: .right, in: topo)
        #expect(f == .zone(zone("foundation-0")))
    }

    @Test("Down enters the first piece then advances, clamping at the top piece")
    func descendClamps() {
        let topo = topology()
        var f: FocusTarget = .zone(zone("waste"))
        f = TableFocusModel.next(from: f, direction: .down, in: topo)
        #expect(f == .piece(key(1), in: zone("waste")))  // entered bottom piece
        f = TableFocusModel.next(from: f, direction: .down, in: topo)
        #expect(f == .piece(key(2), in: zone("waste")))  // advanced to top piece
        f = TableFocusModel.next(from: f, direction: .down, in: topo)
        #expect(f == .piece(key(2), in: zone("waste")))  // clamped at the top
    }

    @Test("Up steps back through pieces and returns to the zone above the bottom piece")
    func ascendReturnsToZone() {
        let topo = topology()
        var f: FocusTarget = .piece(key(2), in: zone("waste"))
        f = TableFocusModel.next(from: f, direction: .up, in: topo)
        #expect(f == .piece(key(1), in: zone("waste")))
        f = TableFocusModel.next(from: f, direction: .up, in: topo)
        #expect(f == .zone(zone("waste")))  // above the bottom piece → back to the zone
        f = TableFocusModel.next(from: f, direction: .up, in: topo)
        #expect(f == .zone(zone("waste")))  // clamp on the zone
    }

    @Test("Down/Up on an empty zone leave focus on the zone")
    func emptyZoneVertical() {
        let topo = topology()
        var f: FocusTarget = .zone(zone("stock"))  // empty
        f = TableFocusModel.next(from: f, direction: .down, in: topo)
        #expect(f == .zone(zone("stock")))
        f = TableFocusModel.next(from: f, direction: .up, in: topo)
        #expect(f == .zone(zone("stock")))
    }

    @Test("a stale focus (zone not in topology) resets to the initial focus")
    func staleFocusResets() {
        let topo = topology()
        let f = TableFocusModel.next(
            from: .zone(zone("gone")), direction: .right, in: topo)
        #expect(f == .zone(zone("stock")))
    }

    @Test("FocusTopology.from orders pieces bottom→top and keeps empty ordered zones focusable")
    func topologyFromResolved() {
        let resolved = [
            ResolvedPiece(
                key: key(2), zone: zone("waste"), index: 1,
                frame: .zero, faceUp: true),
            ResolvedPiece(
                key: key(1), zone: zone("waste"), index: 0,
                frame: .zero, faceUp: true),
        ]
        let topo = FocusTopology.from(
            resolved: resolved, zoneOrder: [zone("stock"), zone("waste")])
        #expect(topo.pieces(in: zone("waste")) == [key(1), key(2)])  // sorted by index
        #expect(topo.pieces(in: zone("stock")) == [])  // empty but present
        #expect(topo.zoneOrder == [zone("stock"), zone("waste")])
    }
}

// MARK: - FocusTarget helpers

@Suite("FocusTarget reports its zone")
struct FocusTargetTests {
    @Test("zone accessor returns the owning zone for both cases")
    func zoneAccessor() {
        #expect(FocusTarget.zone(zone("stock")).zone == zone("stock"))
        #expect(FocusTarget.piece(key(1), in: zone("waste")).zone == zone("waste"))
    }
}
