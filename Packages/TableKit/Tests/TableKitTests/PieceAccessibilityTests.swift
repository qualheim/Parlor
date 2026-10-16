import EngineCore
import Foundation
import Testing

@testable import TableKit

// Tests for task 7.1 — the PURE VoiceOver derivation behind R-A11Y-1: per-piece label/value/hint
// (R-A11Y-1.1), pile/zone descriptions (R-A11Y-1.1), the custom rotor entry model (R-A11Y-1.2), and the
// announcement derivation for opponent actions/results (R-A11Y-1.2). Everything under test is value-level,
// so it runs headless with no running UI; the SwiftUI application lives in the table/HUD views.

// MARK: - Fixtures

private func pid(_ n: UInt64) -> PieceID { PieceID(raw: n) }
private func token(_ n: UInt64) -> ViewToken { ViewToken(opaque: n) }
private func card(_ n: UInt64, _ rank: Rank, _ suit: Suit) -> Card {
    Card(id: pid(n), face: .standard(rank, suit))
}
private func seat(_ i: Int) -> SeatID { .index(i) }
/// A display-name lookup for tests: turns `seat-1` into "Seat 1" for readable expectations.
private func names(_ seat: SeatID) -> String {
    "Seat " + seat.raw.replacingOccurrences(of: "seat-", with: "")
}

// MARK: - Suit / rank / tile vocabulary

@Suite struct PieceAccessibilityVocabularyTests {
    @Test func suitNames() {
        #expect(PieceAccessibility.suitName(.clubs) == "clubs")
        #expect(PieceAccessibility.suitName(.diamonds) == "diamonds")
        #expect(PieceAccessibility.suitName(.hearts) == "hearts")
        #expect(PieceAccessibility.suitName(.spades) == "spades")
    }

    @Test func rankNames() {
        #expect(PieceAccessibility.rankName(.ace) == "ace")
        #expect(PieceAccessibility.rankName(.ten) == "ten")
        #expect(PieceAccessibility.rankName(.queen) == "queen")
        #expect(PieceAccessibility.rankName(.king) == "king")
    }

    @Test func cardNameCapitalizesRankKeepsSuitLower() {
        #expect(PieceAccessibility.cardName(.standard(.queen, .clubs)) == "Queen of clubs")
        #expect(PieceAccessibility.cardName(.standard(.ten, .hearts)) == "Ten of hearts")
        #expect(PieceAccessibility.cardName(.joker(index: 0)) == "Joker")
    }

    @Test func tileName() {
        #expect(PieceAccessibility.tileName(.numbered(7, .red)) == "Red 7")
        #expect(PieceAccessibility.tileName(.joker(index: 1)) == "Joker")
    }
}

// MARK: - Per-piece descriptions (R-A11Y-1.1)

@Suite struct PieceAccessibilityDescriptionTests {
    @Test func plainCardHasLabelNoStateAndSelectHint() {
        let d = PieceAccessibility.card(.standard(.queen, .clubs))
        #expect(d.label == "Queen of clubs")
        #expect(d.value.isEmpty)
        #expect(d.combinedLabel == "Queen of clubs")
        #expect(d.hint == "Double-tap to select")
    }

    /// The requirement's headline example: "Queen of clubs, trump, playable".
    @Test func trumpPlayableMatchesRequirementExample() {
        let context = PieceAccessibilityContext(isPlayable: true, isTrump: true)
        let d = PieceAccessibility.card(.standard(.queen, .clubs), context: context)
        #expect(d.label == "Queen of clubs")
        #expect(d.value == "trump, playable")
        #expect(d.combinedLabel == "Queen of clubs, trump, playable")
        #expect(d.hint == "Double-tap to play")
    }

    @Test func notPlayableCardSaysSoAndHasNoPlayHint() {
        let d = PieceAccessibility.card(
            .standard(.two, .spades), context: PieceAccessibilityContext(isPlayable: false))
        #expect(d.value == "not playable")
        #expect(d.hint.isEmpty)
    }

    @Test func selectedCardValueAndDeselectHint() {
        let d = PieceAccessibility.card(
            .standard(.king, .hearts), context: PieceAccessibilityContext(isSelected: true))
        #expect(d.value == "selected")
        #expect(d.hint == "Double-tap to deselect")
    }

    @Test func positionAndContainerAppearInValue() {
        let context = PieceAccessibilityContext(
            containerName: "your hand", position: PiecePosition(index: 3, count: 7))
        let d = PieceAccessibility.card(.standard(.five, .diamonds), context: context)
        #expect(d.value == "card 3 of 7, in your hand")
    }

    @Test func faceDownCardNeverLeaksIdentity() {
        let d = PieceAccessibility.faceDown()
        #expect(d.label == "Face-down card")
        #expect(d.value.isEmpty)
        #expect(d.hint.isEmpty)
    }

    @Test func faceDownKeepsPositionalContextButDropsIdentityState() {
        let context = PieceAccessibilityContext(
            isPlayable: true, position: PiecePosition(index: 1, count: 12))
        let d = PieceAccessibility.faceDown(context: context)
        #expect(d.label == "Face-down card")
        // Position is kept; "playable" (which would hint at identity/state) is dropped.
        #expect(d.value == "card 1 of 12")
    }

    @Test func descriptionRoutesContentKinds() {
        #expect(
            PieceAccessibility.description(for: .card(.standard(.ace, .spades))).label
                == "Ace of spades")
        #expect(
            PieceAccessibility.description(for: .tile(.numbered(9, .blue))).label == "Blue 9")
        #expect(PieceAccessibility.description(for: .back).label == "Face-down card")
    }
}

// MARK: - Pile / zone descriptions (R-A11Y-1.1)

@Suite struct PileAccessibilityTests {
    @Test func emptyPile() {
        let d = PieceAccessibility.pile(name: "Discard", count: 0, visibility: .publicAll)
        #expect(d.label == "Discard, empty")
    }

    @Test func publicPileNamesTopCard() {
        let d = PieceAccessibility.pile(
            name: "Foundation", count: 3, visibility: .publicAll,
            topContent: .card(.standard(.king, .hearts)))
        #expect(d.label == "Foundation, 3 cards, top King of hearts")
    }

    @Test func singularCardWording() {
        let d = PieceAccessibility.pile(
            name: "Waste", count: 1, visibility: .publicAll,
            topContent: .card(.standard(.ace, .clubs)))
        #expect(d.label == "Waste, 1 card, top Ace of clubs")
    }

    @Test func hiddenPileReadsFaceDown() {
        let d = PieceAccessibility.pile(
            name: "Stock", count: 12, visibility: .hidden, topContent: .back)
        #expect(d.label == "Stock, 12 cards, face down")
    }

    @Test func fromZoneViewUsesRevealedTop() {
        let zone = ZoneView(
            id: ZoneID(name: "foundation"),
            visibility: .publicAll,
            pieces: [
                .known(.card(card(1, .queen, .hearts))),
                .known(.card(card(2, .king, .hearts))),
            ])
        let d = PieceAccessibility.pile(zone, name: "Foundation")
        #expect(d.label == "Foundation, 2 cards, top King of hearts")
    }

    @Test func fromHiddenZoneViewReadsFaceDown() {
        let zone = ZoneView(
            id: ZoneID(name: "stock"),
            visibility: .hidden,
            pieces: [.hidden(token(1)), .hidden(token(2))])
        let d = PieceAccessibility.pile(zone, name: "Stock")
        #expect(d.label == "Stock, 2 cards, face down")
    }
}

// MARK: - Rotor model (R-A11Y-1.2)

@Suite struct TableRotorModelTests {
    private func resolved(_ key: RenderKey, zone: String, owner: SeatID?, index: Int)
        -> ResolvedPiece
    {
        ResolvedPiece(
            key: key, zone: ZoneID(name: zone, owner: owner), index: index,
            frame: .zero, faceUp: true)
    }

    @Test func groupsHandAndPilesSkippingEmpty() {
        let handZone = ZoneID(name: "hand", owner: seat(0))
        let pieces = [
            resolved(.known(pid(1)), zone: "hand", owner: seat(0), index: 0),
            resolved(.known(pid(2)), zone: "hand", owner: seat(0), index: 1),
            resolved(.known(pid(3)), zone: "foundation", owner: nil, index: 0),
            resolved(.known(pid(4)), zone: "foundation", owner: nil, index: 1),
        ]
        let model = TableRotorModel.derive(
            pieces: pieces, handZones: [handZone],
            describe: { "piece-\($0.index)" })

        #expect(model.rotors.count == 2)
        #expect(model.rotors[0].name == "Hand")
        #expect(model.rotors[0].entries.count == 2)
        // The Piles rotor lists ONE entry per non-hand pile: the top (highest index) piece.
        #expect(model.rotors[1].name == "Piles")
        #expect(model.rotors[1].entries.count == 1)
        #expect(model.rotors[1].entries.first?.key == .known(pid(4)))
    }

    @Test func handOnlyOmitsPilesRotor() {
        let handZone = ZoneID(name: "hand", owner: seat(0))
        let pieces = [resolved(.known(pid(1)), zone: "hand", owner: seat(0), index: 0)]
        let model = TableRotorModel.derive(
            pieces: pieces, handZones: [handZone], describe: { _ in "x" })
        #expect(model.rotors.map(\.name) == ["Hand"])
    }

    @Test func labelsComeFromDescribeClosure() {
        let handZone = ZoneID(name: "hand", owner: seat(0))
        let pieces = [resolved(.known(pid(1)), zone: "hand", owner: seat(0), index: 0)]
        let model = TableRotorModel.derive(
            pieces: pieces, handZones: [handZone], describe: { _ in "Queen of clubs, playable" })
        #expect(model.rotors[0].entries[0].label == "Queen of clubs, playable")
    }
}

// MARK: - Announcements (R-A11Y-1.2)

@Suite struct AccessibilityAnnouncementTests {
    @Test func opponentActionAnnounced() {
        let a = AccessibilityAnnouncement.from(.trickWon(by: seat(1)), nameForSeat: names)
        #expect(a?.text == "Seat 1 won the trick")
        #expect(a?.isHighPriority == false)
    }

    @Test func handResultIsHighPriority() {
        let outcome = HandOutcome(winners: [seat(0)])
        let a = AccessibilityAnnouncement.from(.handEnded(outcome), nameForSeat: names)
        #expect(a?.isHighPriority == true)
        #expect(a?.text == "Hand won by Seat 0")
    }

    @Test func geometryEventsAreSilent() {
        #expect(
            AccessibilityAnnouncement.from(.pieceFlipped(pid(1), faceUp: true), nameForSeat: names)
                == nil)
        #expect(AccessibilityAnnouncement.from(.dealt(pieces: []), nameForSeat: names) == nil)
    }

    @Test func batchDropsSilentEvents() {
        let events: [GameEvent] = [
            .dealt(pieces: []),
            .turnChanged(to: seat(0)),
            .pieceFlipped(pid(2), faceUp: true),
            .trickWon(by: seat(1)),
        ]
        let out = AccessibilityAnnouncement.from(events: events, nameForSeat: names)
        #expect(out.map(\.text) == ["Seat 0 to play", "Seat 1 won the trick"])
    }
}
