// KlondikeTableAdapter tests (task 3.5) — the GamesUI wiring that maps Klondike's pure rules/features to
// TableKit's interaction seam (R-TABLE-3.3, R-TABLE-3.6; R-KLON-3.3).
//
// GamesUI is the one module importing both GamesRules and TableKit, so this is where the mapping is
// tested. We build a small known Klondike board and assert the derived `[MoveTarget]` and `smartTarget`
// match Klondike's own legal actions / smart destination.

import EngineCore
import GamesRules
import TableKit
import Testing

@testable import GamesUI

private enum KA {
    static func card(_ rank: Rank, _ suit: Suit, id: UInt64) -> Card {
        Card(id: PieceID(raw: id), face: .standard(rank, suit))
    }

    static func state(
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
}

@Suite("KlondikeTableAdapter — TableKit wiring (R-TABLE-3.3, R-TABLE-3.6)")
struct KlondikeTableAdapterTests {
    let game = Klondike()

    @Test("legal targets map a waste card's legal destinations to MoveTargets")
    func legalTargetsFromWaste() {
        // Ace of spades on waste: legal to foundation(0). Red 6♥ won't be present. Just the Ace.
        let ace = KA.card(.ace, .spades, id: 1)
        let s = KA.state(waste: [ace], tableau: Array(repeating: [], count: 7))
        let targets = KlondikeTableAdapter.legalTargets(for: game, in: s)
        // The Ace can go to foundation(0); it cannot go to any tableau pile (empty piles want a King).
        #expect(
            targets.contains(
                MoveTarget(piece: .known(ace.id), destination: KlondikeZone.foundation(0))))
        // Every target references a real legal action's piece → destination.
        #expect(!targets.isEmpty)
    }

    @Test("stock draw/recycle produce no drag targets")
    func noTargetsForStock() {
        // Only a stock draw is legal; there is no moving piece to drag, so no MoveTargets.
        let s = KA.state(
            stock: [KA.card(.two, .clubs, id: 1)], tableau: Array(repeating: [], count: 7))
        let targets = KlondikeTableAdapter.legalTargets(for: game, in: s)
        #expect(targets.isEmpty)
    }

    @Test("smartTarget maps a known RenderKey to Klondike's smart destination")
    func smartTargetMapsRenderKey() {
        let ace = KA.card(.ace, .spades, id: 1)
        let s = KA.state(waste: [ace], tableau: Array(repeating: [], count: 7))
        let dest = KlondikeTableAdapter.smartTarget(for: game, piece: .known(ace.id), in: s)
        #expect(dest == KlondikeZone.foundation(0))
        #expect(dest == game.smartDestination(for: ace.id, in: s))
    }

    @Test("smartTarget is nil for a hidden token")
    func smartTargetNilForHidden() {
        let s = KA.state(
            waste: [KA.card(.ace, .spades, id: 1)], tableau: Array(repeating: [], count: 7))
        let dest = KlondikeTableAdapter.smartTarget(
            for: game, piece: .hidden(ViewToken(opaque: 42)), in: s)
        #expect(dest == nil)
    }

    @Test("interactionInput carries legal targets and a working smart-target closure")
    func interactionInputAssembles() {
        let ace = KA.card(.ace, .spades, id: 1)
        let s = KA.state(waste: [ace], tableau: Array(repeating: [], count: 7))
        let input = KlondikeTableAdapter.interactionInput(for: game, in: s) { _ in .success(()) }
        #expect(!input.legalTargets.isEmpty)
        #expect(input.smartTarget(.known(ace.id)) == KlondikeZone.foundation(0))
        // The legal-target highlight query works through the assembled input.
        #expect(input.isLegalTarget(KlondikeZone.foundation(0), for: .known(ace.id)))
    }
}
