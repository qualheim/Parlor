// KlondikeTableController auto-resubmit regression tests — the headless guard for the "cards move
// themselves around" infinite-submit loop reported from a real session (os_log subsystem
// com.parlor.Parlor, category table).
//
// EVIDENCE THIS REPRODUCES: in the user's run, after a genuine stock draw the log showed an unbounded
// stream of `submitted/accepted tableauToTableau(fromPile: 2 … toPile: 5)` then `… toPile: 5 … toPile: 2`
// oscillating for the SAME card every ~13 ms, with NO preceding `tap:`/`drag-drop:` line — i.e. moves
// driven by SwiftUI view re-evaluation, not by the user. The feedback edge was the right-click
// "why can't I play this?" explainer (`TableInteractionModel.explanation(for:)`): its fallback path called
// `input.resolve(move)`, and `resolve` is a COMMITTING submission, not a dry run. SwiftUI eagerly builds
// `.contextMenu { whyNotMenu(piece) }` for every piece during body evaluation, so every reconcile rebuilt
// the menu, re-ran `explanation`, and submitted the smart move again — and the card's smart destination
// flips between two mutually-compatible tableau piles, so it oscillated forever.
//
// THE GUARD: a SINGLE discrete gesture must produce EXACTLY ONE submission. These tests drive the
// controller through one accepted move, then pump the exact re-evaluation the loop used (rebuild the
// interaction input and re-run the explainer, as the context menu does on every refresh) and assert
// `controller.submissionCount == 1`. Against the pre-fix code this FAILS (the explainer resubmits, count
// climbs); after the fix the explainer never submits, so the count stays at 1.
//
// XCUITest / GUI automation is deliberately NOT used (blocked here); this headless submission-count check
// plus the interaction logging are the observability. Mouse interaction itself still needs a human click.

import EngineCore
import GamesRules
import TableKit
import Testing

@testable import GamesUI

@MainActor
@Suite("KlondikeTableController — no auto-resubmit without a user gesture (Klondike flicker loop)")
struct KlondikeAutoResubmitTests {

    private func card(_ rank: Rank, _ suit: Suit, id: UInt64) -> Card {
        Card(id: PieceID(raw: id), face: .standard(rank, suit))
    }

    /// Build a KlondikeState from explicit piles (all tableau cards face-up), mirroring the adapter test
    /// helper so we can craft the exact oscillation board.
    private func state(
        stock: [Card] = [], waste: [Card] = [], tableau: [[Card]],
        foundations: [[Card]] = [[], [], [], []]
    ) -> KlondikeState {
        var faces: [PieceID: CardFace] = [:]
        func record(_ cards: [Card]) { for c in cards { faces[c.id] = c.face } }
        record(stock)
        record(waste)
        tableau.forEach(record)
        foundations.forEach(record)
        let stockZone = Zone(
            id: KlondikeZone.stockID, visibility: .hidden, contents: stock.map(\.id))
        let wasteZone = Zone(
            id: KlondikeZone.wasteID, visibility: .publicAll, contents: waste.map(\.id))
        let tableauZones = tableau.enumerated().map { (i, cards) in
            Zone(
                id: KlondikeZone.tableau(i), visibility: .perPieceFaceState,
                contents: cards.map(\.id), faceUp: Set(cards.map(\.id)))
        }
        let foundationZones = foundations.enumerated().map { (i, cards) in
            Zone(id: KlondikeZone.foundation(i), visibility: .publicAll, contents: cards.map(\.id))
        }
        return KlondikeState(
            stock: stockZone, waste: wasteZone, tableau: tableauZones,
            foundations: foundationZones, faces: faces, score: 0, passes: 1,
            options: KlondikeOptions())
    }

    /// The oscillation board the real log hit: a red card (6♥, id 41) that can legally build on EITHER of
    /// two black 7s sitting in different tableau piles, so its smart destination flips between those piles.
    /// Pile 2 holds 7♠, pile 5 holds 7♣; the 6♥ starts on pile 2 (atop 7♠). smartDestination(6♥) → pile 5
    /// (a non-empty legal build), and after moving to pile 5 it flips back to pile 2 — the exact 2↔5 loop.
    /// No foundation accepts the 6♥ (foundations are empty), so the smart target is the tableau build.
    private func oscillationState() -> KlondikeState {
        var piles: [[Card]] = Array(repeating: [], count: 7)
        piles[2] = [card(.seven, .spades, id: 71), card(.six, .hearts, id: 41)]
        piles[5] = [card(.seven, .clubs, id: 72)]
        // A King somewhere harmless so other piles are not all empty (not strictly required).
        piles[0] = [card(.king, .diamonds, id: 90)]
        // A non-empty stock so there is at least one unrelated legal action available too.
        let stock = [card(.two, .clubs, id: 20)]
        return state(stock: stock, waste: [], tableau: piles)
    }

    /// An offline controller (no host) over `state`: the shadow state is the sole authority, submissions
    /// advance it directly, and the render model reconciles to the derived view — the same resolve path the
    /// app uses, minus the autosave layer. Exactly how the DEBUG offline view-model wires it.
    private func makeOfflineController(_ initial: KlondikeState) -> KlondikeTableController {
        let game = Klondike()
        let initialView = game.redactedView(of: initial, for: .seat(klondikeSeat))
        let driver = AnimationDriver(
            model: TableRenderModel(playerView: initialView), settings: .minimal)
        // `submit` returns nil (offline), so the controller advances its OWN shadow and derives its own
        // view on the accepted path. `view` is only consulted on a resync (not exercised here); it reads
        // the controller's authoritative shadow via a late binding so it is always current if used.
        var controllerBox: KlondikeTableController?
        let controller = KlondikeTableController(
            initialState: initial,
            initialView: initialView,
            driver: driver,
            submit: { _ in nil },
            view: {
                let s = controllerBox?.latestState ?? initial
                return game.redactedView(of: s, for: .seat(klondikeSeat))
            })
        controllerBox = controller
        return controller
    }

    /// Drive the controller the way `TableInteractionView` does for a smart (double-click) move: build the
    /// interaction input for the CURRENT state, then run a `TableInteractionModel.smartMove`, awaiting the
    /// controller's quiescence. Returns the destination the smart move targeted (for assertions).
    private func performSmartMove(
        _ controller: KlondikeTableController, piece: PieceID, from source: ZoneID
    ) async -> ZoneID? {
        let input = controller.interactionInput
        var model = TableInteractionModel()
        _ = model.smartMove(.known(piece), from: source, using: input)
        await controller.awaitQuiescence()
        controller.fastForwardOrConfirm()
        return input.smartTarget(.known(piece))
    }

    /// Re-run the EXACT feedback edge the loop used: rebuild the interaction input for the current frame
    /// (as SwiftUI does every refresh) and run the right-click explainer for the moving piece, as
    /// `.contextMenu { whyNotMenu(piece) }` does when the view re-evaluates. In the pre-fix code this calls
    /// the committing `resolve` and resubmits; after the fix it must not submit anything.
    private func pumpExplainerReevaluation(
        _ controller: KlondikeTableController, piece: PieceID, from source: ZoneID, times: Int
    ) async {
        for _ in 0..<times {
            let input = controller.interactionInput
            let model = TableInteractionModel()
            _ = model.explanation(for: .known(piece), from: source, using: input)
            await controller.awaitQuiescence()
        }
    }

    @Test(
        "the right-click explainer never submits a move: one gesture ⇒ exactly one submission (no 2↔5 loop)"
    )
    func explainerDoesNotResubmit() async {
        let controller = makeOfflineController(oscillationState())

        // One genuine user gesture: smart-move the 6♥ (it has a legal tableau build → pile 5).
        let smartDest = await performSmartMove(
            controller, piece: PieceID(raw: 41), from: KlondikeZone.tableau(2))
        #expect(
            smartDest == KlondikeZone.tableau(5), "6♥ should smart-move to the other black-7 pile")
        #expect(controller.submissionCount == 1, "a single smart move must submit exactly once")

        // Now simulate many SwiftUI re-evaluations that build the context menu and probe the explainer for
        // the SAME card from its NEW pile — the loop's driver. After the fix this must add ZERO submissions.
        await pumpExplainerReevaluation(
            controller, piece: PieceID(raw: 41), from: KlondikeZone.tableau(5), times: 50)

        #expect(
            controller.submissionCount == 1,
            "the explainer re-evaluation resubmitted \(controller.submissionCount - 1) extra move(s) — the auto-resubmit loop is present"
        )
    }

    @Test("explaining a piece reports its smart destination without moving it")
    func explanationIsReadOnly() async {
        let controller = makeOfflineController(oscillationState())
        let before = TableRenderModel(playerView: controller.latestView)

        // Probe the explainer for the 6♥ (it CAN be played, so the explanation is nil), many times.
        await pumpExplainerReevaluation(
            controller, piece: PieceID(raw: 41), from: KlondikeZone.tableau(2), times: 25)

        #expect(controller.submissionCount == 0, "probing the explainer must never submit a move")
        #expect(
            TableRenderModel(playerView: controller.latestView) == before,
            "probing the explainer must not mutate the board")
    }
}
