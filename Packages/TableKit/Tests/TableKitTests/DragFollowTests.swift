import EngineCore
import Foundation
import Testing

@testable import TableKit

// Tests for the drag-follow polish (task 3.4 + 5.5 supporting): the pure rule that decides WHICH pieces
// follow the cursor during a live drag, and the invariant that a reconcile to a fresh view only disturbs
// the pieces that actually changed. The 1:1 cursor tracking and the smoothness of the drop slide are
// visual and need human confirmation on `make run`; what is testable headless — the offset-scoping rule
// and the reconcile change-scope — is asserted here (R-TABLE-3.1, R-TABLE-5.1; design.md §2.8/§6).

// MARK: - Fixtures

private func pid(_ n: UInt64) -> PieceID { PieceID(raw: n) }
private func key(_ n: UInt64) -> RenderKey { .known(pid(n)) }
private func token(_ n: UInt64) -> ViewToken { ViewToken(opaque: n) }
private func zone(_ name: String) -> ZoneID { ZoneID(name: name) }
private func card(_ n: UInt64, _ rank: Rank = .ace, _ suit: Suit = .spades) -> Card {
    Card(id: pid(n), face: .standard(rank, suit))
}
private func view(_ zones: [ZoneView]) -> PlayerView {
    PlayerView(viewer: .seat(.index(0)), zones: zones, scores: [:], phase: Phase(rawValue: "play"))
}
private func drag(
    _ key: RenderKey, zone: ZoneID, index: Int, by translation: CGSize, released: Bool = false
) -> TableInteractionView.LiveDrag {
    TableInteractionView.LiveDrag(
        key: key, zone: zone, index: index, translation: translation, released: released)
}

// MARK: - Live-follow offset scoping (R-TABLE-3.1)

@Suite("Drag follows the cursor — offset scoping")
struct DragFollowOffsetTests {
    private let delta = CGSize(width: 40, height: -25)

    @Test("no drag → every piece's offset is zero")
    func noDragNoOffset() {
        let offset = TableInteractionView.followOffset(
            for: key(1), zone: zone("tableau-0"), index: 3, drag: nil)
        #expect(offset == .zero)
    }

    @Test("the dragged lead piece follows the cursor 1:1")
    func leadFollows() {
        let d = drag(key(1), zone: zone("tableau-0"), index: 2, by: delta)
        let offset = TableInteractionView.followOffset(
            for: key(1), zone: zone("tableau-0"), index: 2, drag: d)
        #expect(offset == delta)
    }

    @Test("a piece stacked ABOVE the lead in the same zone follows (the grabbed run)")
    func runAboveFollows() {
        let d = drag(key(1), zone: zone("tableau-0"), index: 2, by: delta)
        // index 3 and 4 are stacked on top of the lead at index 2 — they move with it.
        let above = TableInteractionView.followOffset(
            for: key(5), zone: zone("tableau-0"), index: 3, drag: d)
        let higher = TableInteractionView.followOffset(
            for: key(6), zone: zone("tableau-0"), index: 4, drag: d)
        #expect(above == delta)
        #expect(higher == delta)
    }

    @Test("a piece BELOW the lead in the same zone stays put")
    func belowStaysPut() {
        let d = drag(key(1), zone: zone("tableau-0"), index: 2, by: delta)
        let below = TableInteractionView.followOffset(
            for: key(9), zone: zone("tableau-0"), index: 1, drag: d)
        #expect(below == .zero)
    }

    @Test("a piece in a DIFFERENT zone never follows, even at a higher index")
    func otherZoneStaysPut() {
        let d = drag(key(1), zone: zone("tableau-0"), index: 2, by: delta)
        let other = TableInteractionView.followOffset(
            for: key(10), zone: zone("tableau-1"), index: 9, drag: d)
        #expect(other == .zero)
    }

    @Test("a released drag still holds its offset until the model reconciles")
    func releasedStillHolds() {
        let d = drag(key(1), zone: zone("tableau-0"), index: 0, by: delta, released: true)
        let offset = TableInteractionView.followOffset(
            for: key(1), zone: zone("tableau-0"), index: 0, drag: d)
        #expect(offset == delta)
    }
}

// MARK: - Reconcile change-scope (design.md §2.8/§6)

@Suite("Reconcile only disturbs the pieces that changed")
struct ReconcileChangeScopeTests {
    /// A board with two tableau piles; moving one card from pile A to pile B must leave every OTHER
    /// piece's node (key, zone, index, faceUp) byte-for-byte identical, so matched geometry animates only
    /// the moved card and the untouched cards do not re-lay-out or re-animate.
    @Test("moving one card leaves all other piece nodes identical (keys preserved)")
    func onlyMovedPieceDiffers() {
        let before = view([
            ZoneView(
                id: zone("tableau-0"), visibility: .publicAll,
                pieces: [.known(.card(card(1))), .known(.card(card(2)))]),
            ZoneView(
                id: zone("tableau-1"), visibility: .publicAll,
                pieces: [.known(.card(card(3)))]),
            ZoneView(
                id: zone("stock"), visibility: .hidden, pieces: [.hidden(token(99))]),
        ])
        // Card 2 moves from tableau-0 (top) onto tableau-1.
        let after = view([
            ZoneView(
                id: zone("tableau-0"), visibility: .publicAll,
                pieces: [.known(.card(card(1)))]),
            ZoneView(
                id: zone("tableau-1"), visibility: .publicAll,
                pieces: [.known(.card(card(3))), .known(.card(card(2)))]),
            ZoneView(
                id: zone("stock"), visibility: .hidden, pieces: [.hidden(token(99))]),
        ])

        var model = TableRenderModel(playerView: before)
        model.reconcile(to: after)

        // Every surviving piece keeps its RenderKey (continuity for matched geometry).
        #expect(model.nodes[key(1)] != nil)
        #expect(model.nodes[key(2)] != nil)
        #expect(model.nodes[key(3)] != nil)
        #expect(model.nodes[.hidden(token(99))] != nil)

        // Only the MOVED card (2) changed. Every other node is untouched.
        let baseline = TableRenderModel(playerView: before)
        // Untouched pieces are byte-identical: card 1 at tableau-0 i0, card 3 at tableau-1 i0, stock hidden.
        #expect(model.nodes[key(1)] == baseline.nodes[key(1)])
        #expect(model.nodes[key(3)] == baseline.nodes[key(3)])
        #expect(model.nodes[.hidden(token(99))] == baseline.nodes[.hidden(token(99))])

        // The moved card did change (zone + index), so it will animate.
        #expect(model.nodes[key(2)] != baseline.nodes[key(2)])
        #expect(model.nodes[key(2)]?.zone == zone("tableau-1"))
        #expect(model.nodes[key(2)]?.index == 1)
    }

    @Test("reconciling to an identical view changes nothing (no spurious re-animation)")
    func identicalViewNoChange() {
        let board = view([
            ZoneView(
                id: zone("tableau-0"), visibility: .publicAll,
                pieces: [.known(.card(card(1))), .known(.card(card(2)))]),
            ZoneView(id: zone("stock"), visibility: .hidden, pieces: [.hidden(token(7))]),
        ])
        var model = TableRenderModel(playerView: board)
        let before = model
        model.reconcile(to: board)
        #expect(model == before)
    }
}
