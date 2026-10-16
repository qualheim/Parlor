import CoreGraphics
import EngineCore
import Foundation
import Testing

@testable import TableKit

// Tests for task 7.2 — keyboard-only play (R-A11Y-2.1). The NON-DRAG keyboard path is pure host-fed data
// plus pure resolution: `KeyboardActivation` picks which zone action a focused zone activates (Klondike
// stock draw/recycle, Crazy Eights draw/pass), `ChoicePrompt` models the keyboard-navigable suit choice
// after playing an 8, the interaction model captions a rejected zone action, and the layout resolver
// produces an anchor frame for an EMPTY pile so its focus ring can be drawn. All value-level, headless.

// MARK: - Fixtures

private func pid(_ n: UInt64) -> PieceID { PieceID(raw: n) }
private func key(_ n: UInt64) -> RenderKey { .known(pid(n)) }
private func zone(_ name: String, _ owner: SeatID? = nil) -> ZoneID {
    ZoneID(name: name, owner: owner)
}

// MARK: - Zone activation resolution (R-A11Y-2.1)

@Suite("KeyboardActivation resolves the zone action for a focused zone (R-A11Y-2.1)")
struct ZoneActivationTests {
    private let drawStock = ZoneAction(zone: ZoneID(name: "stock"), id: "draw", title: "Draw")
    private let recycleStock = ZoneAction(
        zone: ZoneID(name: "stock"), id: "recycle", title: "Recycle")
    private let pass = ZoneAction(zone: ZoneID(name: "hand"), id: "pass", title: "Pass")

    @Test("activating a focused zone returns that zone's action")
    func zoneActionForFocusedZone() {
        let actions = [drawStock, pass]
        let action = KeyboardActivation.action(for: .zone(zone("stock")), in: actions)
        #expect(action?.id == "draw")
        #expect(KeyboardActivation.hasAction(for: .zone(zone("stock")), in: actions))
    }

    @Test("a focused PIECE never activates a zone action (pieces use select/place)")
    func pieceNeverActivates() {
        let actions = [drawStock]
        #expect(
            KeyboardActivation.action(
                for: .piece(key(1), in: zone("stock")), in: actions) == nil)
        #expect(!KeyboardActivation.hasAction(for: .piece(key(1), in: zone("stock")), in: actions))
    }

    @Test("a focused zone with no matching action returns nil")
    func noMatchingAction() {
        #expect(KeyboardActivation.action(for: .zone(zone("waste")), in: [drawStock]) == nil)
        #expect(KeyboardActivation.action(for: .zone(zone("stock")), in: []) == nil)
    }

    @Test("when several actions target the focused zone, the FIRST (host priority) wins")
    func firstActionWinsByPriority() {
        // The host lists at most the applicable primary action first; ordering expresses priority.
        let action = KeyboardActivation.action(
            for: .zone(zone("stock")), in: [recycleStock, drawStock])
        #expect(action?.id == "recycle")
    }

    @Test("the seam's zoneAction(for:) query mirrors the resolver")
    func seamQueryMatches() {
        let input = TableInteractionInput(
            legalTargets: [],
            resolve: { _ in .success(()) },
            zoneActions: [drawStock, pass])
        #expect(input.zoneAction(for: zone("stock"))?.id == "draw")
        #expect(input.zoneAction(for: zone("hand"))?.id == "pass")
        #expect(input.zoneAction(for: zone("waste")) == nil)
    }
}

// MARK: - Zone action feedback through the interaction model (R-A11Y-2.1, R-TABLE-4.1)

@Suite("performZoneAction routes through the model with gentle feedback (R-A11Y-2.1)")
struct ZoneActionModelTests {
    @Test("a successful zone action clears selection and shows no caption")
    func successIsSilent() {
        let input = TableInteractionInput(
            legalTargets: [],
            resolve: { _ in .success(()) },
            zoneActions: [ZoneAction(zone: zone("stock"), id: "draw", title: "Draw")],
            performZoneAction: { _ in .success(()) })
        var model = TableInteractionModel()
        model.select(key(1), from: zone("waste"))
        let result = model.performZoneAction("draw", using: input)
        #expect((try? result.get()) != nil)  // success
        #expect(model.selection == nil)  // selection cleared
        #expect(model.feedback == nil)  // silent success (R-TABLE-4.1)
    }

    @Test("a rejected zone action captions the reason with NO spring-back piece (R-TABLE-4.1)")
    func rejectionCaptionsWithoutSpringBack() {
        let violation = RuleViolation(code: "empty-stock", reason: "The stock is empty.")
        let input = TableInteractionInput(
            legalTargets: [],
            resolve: { _ in .success(()) },
            zoneActions: [ZoneAction(zone: zone("stock"), id: "draw", title: "Draw")],
            performZoneAction: { _ in .failure(violation) })
        var model = TableInteractionModel()
        let result = model.performZoneAction("draw", using: input)
        guard case .failure(let returned) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(returned.code == "empty-stock")
        #expect(model.feedback?.caption == "The stock is empty.")
        #expect(model.feedback?.springBack == nil)  // no piece in flight for a zone action
        #expect(model.feedback?.code == "empty-stock")
    }
}

// MARK: - Choice selection (suit picker after an 8) (R-CE-2.*, R-A11Y-2.1)

@Suite("ChoicePrompt is a pure keyboard-navigable choice (R-A11Y-2.1)")
struct ChoicePromptTests {
    private func suits() -> ChoicePrompt {
        ChoicePrompt(options: [
            ChoiceOption(id: "clubs", title: "Clubs", shortcut: "C"),
            ChoiceOption(id: "diamonds", title: "Diamonds", shortcut: "D"),
            ChoiceOption(id: "hearts", title: "Hearts", shortcut: "H"),
            ChoiceOption(id: "spades", title: "Spades", shortcut: "S"),
        ])
    }

    @Test("a fresh prompt highlights the first option")
    func firstHighlighted() {
        #expect(suits().highlighted?.id == "clubs")
        #expect(suits().selected?.id == "clubs")
    }

    @Test("Right/Down advance and Left/Up retreat, wrapping around the ends")
    func navigationWraps() {
        var prompt = suits()
        prompt = prompt.moving(.right)
        #expect(prompt.highlighted?.id == "diamonds")
        prompt = prompt.moving(.down)
        #expect(prompt.highlighted?.id == "hearts")
        prompt = prompt.moving(.right).moving(.right)  // spades → wrap → clubs
        #expect(prompt.highlighted?.id == "clubs")
        prompt = prompt.moving(.left)  // wrap back to spades
        #expect(prompt.highlighted?.id == "spades")
        prompt = prompt.moving(.up)
        #expect(prompt.highlighted?.id == "hearts")
    }

    @Test("a shortcut key jumps straight to its option, case-insensitively")
    func shortcutJumps() {
        let prompt = suits()
        #expect(prompt.option(forShortcut: "h")?.id == "hearts")
        #expect(prompt.option(forShortcut: "H")?.id == "hearts")
        #expect(prompt.option(forShortcut: "s")?.id == "spades")
        #expect(prompt.option(forShortcut: "z") == nil)  // no such shortcut
    }

    @Test("selecting commits the currently highlighted option")
    func selectCommitsHighlight() {
        let prompt = suits().moving(.right).moving(.right)  // hearts
        #expect(prompt.selected?.id == "hearts")
    }

    @Test("an out-of-range start index is clamped into the options")
    func clampsStartIndex() {
        let clampedHigh = ChoicePrompt(
            options: [ChoiceOption(id: "a", title: "A")], highlightedIndex: 99)
        #expect(clampedHigh.highlightedIndex == 0)
        let clampedLow = ChoicePrompt(
            options: suits().options, highlightedIndex: -5)
        #expect(clampedLow.highlightedIndex == 0)
    }

    @Test("an empty prompt has no highlight and navigation is a no-op")
    func emptyPromptIsInert() {
        let empty = ChoicePrompt(options: [])
        #expect(empty.highlighted == nil)
        #expect(empty.selected == nil)
        #expect(empty.moving(.right).highlighted == nil)
        #expect(empty.option(forShortcut: "a") == nil)
    }
}

// MARK: - Empty-zone focus-ring anchor (R-A11Y-2.1, R-KLON-1.4)

@Suite("An empty pile resolves an anchor frame so its focus ring can be drawn (R-A11Y-2.1)")
struct EmptyZoneFocusFrameTests {
    @Test("zoneAnchorFrame returns the card slot for an empty placed zone")
    func emptyZoneHasAnchorFrame() {
        let emptyFoundation = zone("foundation-0")
        let layout = TableLayout(placements: [
            emptyFoundation: ZonePlacement(
                region: NormalizedRect(x: 0.5, y: 0.1, width: 0.072, height: 0.1),
                stacking: .stack())
        ])
        let resolver = LayoutResolver()
        let tableSize = CGSize(width: 1000, height: 700)
        let frame = resolver.zoneAnchorFrame(
            layout: layout, zone: emptyFoundation, tableSize: tableSize,
            ownerSeatIndex: nil, seatCount: 1)
        #expect(frame != nil)
        let expected = resolver.cardSize(in: tableSize)
        #expect(frame?.size == expected)  // a single card slot
        // Anchored at the region origin (x=0.5 of 1000, y=0.1 of 700).
        #expect(abs((frame?.minX ?? -1) - 500) < 0.5)
        #expect(abs((frame?.minY ?? -1) - 70) < 0.5)
    }

    @Test("a zone with no placement resolves no anchor frame")
    func unplacedZoneHasNoFrame() {
        let layout = TableLayout(placements: [:])
        let frame = LayoutResolver().zoneAnchorFrame(
            layout: layout, zone: zone("nowhere"), tableSize: CGSize(width: 800, height: 600),
            ownerSeatIndex: nil, seatCount: 1)
        #expect(frame == nil)
    }
}
