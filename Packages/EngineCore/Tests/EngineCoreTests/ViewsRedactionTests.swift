import Foundation
import Testing

@testable import EngineCore

// Tests for the events / views / redaction / token layer (task 2.6, R-ENG-8). They prove the mechanism
// with targeted cases; the full randomized view-leak property test is task 2.8 (R-QA-3.1).
//
// Coverage:
//   • every GameEvent case Codable round-trips (R-ENG-8.1, R-ENG-8.5);
//   • the supporting boundary types (PieceMoveDescriptor, ViewToken, ViewPiece, ZoneView, PlayerView)
//     round-trip, and PlayerView is schema-versioned and tolerant of an absent version (R-ENG-8.5);
//   • redaction applies each Visibility policy correctly (R-ENG-3.3, R-ENG-8.2, R-ENG-8.3);
//   • the per-view token permutation is a consistent bijection within a view and uncorrelated across
//     views/salts (R-ENG-8.3, R-QA-3.1); and
//   • pieceRevealed carries the token the viewer's own view assigned (R-ENG-8.4).

// MARK: - Fixtures

/// A tiny face resolver over a fixed set of cards, standing in for a game's PieceID → face map.
private struct Decklet {
    let cards: [PieceID: Card]

    init(_ faces: [(UInt64, CardFace)]) {
        var map: [PieceID: Card] = [:]
        for (raw, face) in faces {
            let id = PieceID(raw: raw)
            map[id] = Card(id: id, face: face)
        }
        self.cards = map
    }

    func resolve(_ id: PieceID) -> KnownPiece? {
        guard let card = cards[id] else { return nil }
        return .card(card)
    }
}

private let seat0 = SeatID.index(0)
private let seat1 = SeatID.index(1)

@Suite("Events, views, redaction and tokens (R-ENG-8)")
struct ViewsRedactionTests {

    // MARK: - GameEvent Codable round-trip (R-ENG-8.1, R-ENG-8.5)

    @Test("every GameEvent case round-trips through Codable")
    func gameEventFullSetRoundTrip() throws {
        let move = PieceMoveDescriptor(
            piece: PieceID(raw: 7),
            from: ZoneID(name: "stock"),
            to: ZoneID(name: "discard"),
            toIndex: 2,
            faceUp: true)
        let events: [GameEvent] = [
            .dealt(pieces: [move, move]),
            .pieceMoved(move),
            .pieceRevealed(token: ViewToken(opaque: 0xDEAD_BEEF), identity: PieceID(raw: 7)),
            .pieceFlipped(PieceID(raw: 3), faceUp: false),
            .turnChanged(to: seat1),
            .trickWon(by: seat0),
            .scoreChanged(seat: seat0, delta: 3, total: 12),
            .handEnded(HandOutcome(winners: [seat0], scores: [seat0: 12])),
            .suitNamed(.hearts, by: seat1),
            .captioned(LocalizedKey("caption.trickWon", arguments: ["North"])),
        ]
        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([GameEvent].self, from: data)
        #expect(decoded == events)
    }

    @Test("PieceMoveDescriptor round-trips, including a nil source zone")
    func pieceMoveDescriptorRoundTrip() throws {
        let dealt = PieceMoveDescriptor(
            piece: PieceID(raw: 1), from: nil, to: ZoneID(name: "hand", owner: seat0),
            toIndex: 0, faceUp: false)
        let data = try JSONEncoder().encode(dealt)
        let decoded = try JSONDecoder().decode(PieceMoveDescriptor.self, from: data)
        #expect(decoded == dealt)
        #expect(decoded.from == nil)
    }

    // MARK: - View boundary types round-trip (R-ENG-8.5)

    @Test("ViewPiece round-trips for both known (card and tile) and hidden")
    func viewPieceRoundTrip() throws {
        let card = ViewPiece.known(
            .card(Card(id: PieceID(raw: 5), face: .standard(.queen, .spades))))
        let tile = ViewPiece.known(.tile(Tile(id: PieceID(raw: 6), face: .numbered(9, .red))))
        let hidden = ViewPiece.hidden(ViewToken(opaque: 42))
        for piece in [card, tile, hidden] {
            let data = try JSONEncoder().encode(piece)
            let decoded = try JSONDecoder().decode(ViewPiece.self, from: data)
            #expect(decoded == piece)
        }
    }

    @Test("PlayerView round-trips with zones and legal actions")
    func playerViewRoundTrip() throws {
        let zone = ZoneView(
            id: ZoneID(name: "hand", owner: seat0),
            visibility: .ownerOnly,
            pieces: [
                .known(.card(Card(id: PieceID(raw: 1), face: .standard(.ace, .clubs)))),
                .hidden(ViewToken(opaque: 99)),
            ])
        let view = PlayerView(
            viewer: .seat(seat0),
            zones: [zone],
            scores: [seat0: 5, seat1: 2],
            phase: Phase(rawValue: "play"),
            legalActions: [])
        let data = try JSONEncoder().encode(view)
        let decoded = try JSONDecoder().decode(PlayerView.self, from: data)
        #expect(decoded == view)
        #expect(decoded.schemaVersion == PlayerView.currentSchemaVersion)
    }

    @Test("PlayerView decodes an encoding that predates schemaVersion (defaults to 1)")
    func playerViewToleratesMissingSchemaVersion() throws {
        // Build a real encoding, then strip the version/zones/legalActions keys to model an older or
        // inline producer that omitted them, and confirm decoding still succeeds with the defaults.
        let full = PlayerView(
            viewer: .spectator, zones: [], scores: [seat0: 4], phase: Phase(rawValue: "deal"),
            legalActions: [])
        let data = try JSONEncoder().encode(full)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "schemaVersion")
        object.removeValue(forKey: "zones")
        object.removeValue(forKey: "legalActions")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PlayerView.self, from: stripped)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.zones.isEmpty)
        #expect(decoded.legalActions.isEmpty)
        #expect(decoded.scores[seat0] == 4)
        #expect(decoded.phase == Phase(rawValue: "deal"))
    }

    // MARK: - Visibility policy redaction (R-ENG-3.3, R-ENG-8.2, R-ENG-8.3)

    /// Helper: the faces revealed to `viewer` for `zone`, in order. `nil` marks a hidden (tokenized) slot.
    private func revealedFaces(
        _ zone: Zone, to viewer: Viewer, deck: Decklet, salt: UInt64 = 1
    ) -> [CardFace?] {
        let views = Redaction.zoneViews(
            of: [zone], for: viewer, salt: salt, faceResolver: deck.resolve)
        return views[0].pieces.map { piece in
            switch piece {
            case .known(.card(let c)): return c.face
            case .known(.tile): return nil
            case .hidden: return nil
            }
        }
    }

    @Test("hidden policy → all pieces are tokens for every non-debug viewer")
    func hiddenPolicyRedactsAll() {
        let deck = Decklet([(1, .standard(.ace, .spades)), (2, .standard(.two, .spades))])
        let stock = Zone(
            id: ZoneID(name: "stock"), visibility: .hidden,
            contents: [PieceID(raw: 1), PieceID(raw: 2)])
        #expect(revealedFaces(stock, to: .seat(seat0), deck: deck) == [nil, nil])
        #expect(revealedFaces(stock, to: .spectator, deck: deck) == [nil, nil])
        // debugOmniscient bypasses policy and sees everything (debug-only path).
        #expect(
            revealedFaces(stock, to: .debugOmniscient, deck: deck)
                == [.standard(.ace, .spades), .standard(.two, .spades)])
    }

    @Test("ownerOnly policy → owner sees faces, others see tokens")
    func ownerOnlyPolicy() {
        let deck = Decklet([(1, .standard(.king, .hearts)), (2, .standard(.queen, .hearts))])
        let hand = Zone(
            id: ZoneID(name: "hand", owner: seat0),
            visibility: .ownerOnly,
            contents: [PieceID(raw: 1), PieceID(raw: 2)])
        #expect(
            revealedFaces(hand, to: .seat(seat0), deck: deck)
                == [.standard(.king, .hearts), .standard(.queen, .hearts)])
        #expect(revealedFaces(hand, to: .seat(seat1), deck: deck) == [nil, nil])
        #expect(revealedFaces(hand, to: .spectator, deck: deck) == [nil, nil])
    }

    @Test("ownerOnly with no owner is hidden from everyone (except debug)")
    func ownerOnlyNoOwner() {
        let deck = Decklet([(1, .standard(.king, .hearts))])
        let orphan = Zone(
            id: ZoneID(name: "mystery"), visibility: .ownerOnly, contents: [PieceID(raw: 1)])
        #expect(revealedFaces(orphan, to: .seat(seat0), deck: deck) == [nil])
    }

    @Test("publicAll policy → everyone sees every face")
    func publicAllPolicy() {
        let deck = Decklet([(1, .standard(.ace, .diamonds)), (2, .standard(.two, .diamonds))])
        let discard = Zone(
            id: ZoneID(name: "discard"),
            visibility: .publicAll,
            contents: [PieceID(raw: 1), PieceID(raw: 2)])
        let expected: [CardFace?] = [.standard(.ace, .diamonds), .standard(.two, .diamonds)]
        #expect(revealedFaces(discard, to: .seat(seat0), deck: deck) == expected)
        #expect(revealedFaces(discard, to: .spectator, deck: deck) == expected)
    }

    @Test("topCardOnly policy → only the top (last) piece is known")
    func topCardOnlyPolicy() {
        let deck = Decklet([
            (1, .standard(.three, .clubs)), (2, .standard(.four, .clubs)),
            (3, .standard(.five, .clubs)),
        ])
        let pile = Zone(
            id: ZoneID(name: "discard"),
            visibility: .topCardOnly,
            contents: [PieceID(raw: 1), PieceID(raw: 2), PieceID(raw: 3)])
        // Last element is the top; only it is revealed.
        #expect(
            revealedFaces(pile, to: .spectator, deck: deck) == [nil, nil, .standard(.five, .clubs)])
    }

    @Test("perPieceFaceState policy → only faceUp pieces are known")
    func perPieceFaceStatePolicy() {
        let deck = Decklet([
            (1, .standard(.six, .spades)), (2, .standard(.seven, .spades)),
            (3, .standard(.eight, .spades)),
        ])
        let column = Zone(
            id: ZoneID(name: "tableau", owner: seat0),
            visibility: .perPieceFaceState,
            contents: [PieceID(raw: 1), PieceID(raw: 2), PieceID(raw: 3)],
            faceUp: [PieceID(raw: 1), PieceID(raw: 3)])
        // Pieces 1 and 3 are face-up (known); piece 2 is face-down (token), for everyone.
        let expected: [CardFace?] = [.standard(.six, .spades), nil, .standard(.eight, .spades)]
        #expect(revealedFaces(column, to: .spectator, deck: deck) == expected)
        #expect(revealedFaces(column, to: .seat(seat0), deck: deck) == expected)
    }

    @Test("a visible piece whose face cannot be resolved is conservatively tokenized")
    func unresolvableVisiblePieceIsHidden() {
        let deck = Decklet([])  // resolver returns nil for everything
        let discard = Zone(
            id: ZoneID(name: "discard"), visibility: .publicAll, contents: [PieceID(raw: 1)])
        let views = Redaction.zoneViews(
            of: [discard], for: .spectator, salt: 1, faceResolver: deck.resolve)
        guard case .hidden = views[0].pieces[0] else {
            Issue.record("expected an unresolvable public piece to be tokenized, not revealed")
            return
        }
    }

    @Test("redaction preserves zone and piece order")
    func redactionPreservesOrder() {
        let deck = Decklet([(1, .standard(.ace, .clubs)), (2, .standard(.two, .clubs))])
        let a = Zone(id: ZoneID(name: "a"), visibility: .publicAll, contents: [PieceID(raw: 1)])
        let b = Zone(id: ZoneID(name: "b"), visibility: .hidden, contents: [PieceID(raw: 2)])
        let views = Redaction.zoneViews(
            of: [a, b], for: .spectator, salt: 1, faceResolver: deck.resolve)
        #expect(views.map(\.id.name) == ["a", "b"])
        #expect(views[0].pieces.count == 1)
        #expect(views[1].pieces.count == 1)
    }

    // MARK: - Token permutation: consistency within a view (R-ENG-8.3)

    @Test("within one view the same PieceID always maps to the same token")
    func tokenConsistentWithinView() {
        let tokenizer = ViewTokenizer(viewer: .seat(seat0), salt: 12345)
        let a1 = tokenizer.token(for: PieceID(raw: 10))
        let a2 = tokenizer.token(for: PieceID(raw: 10))
        #expect(a1 == a2)
    }

    @Test("within one view distinct PieceIDs map to distinct tokens (a bijection)")
    func tokenBijectiveWithinView() {
        let tokenizer = ViewTokenizer(viewer: .spectator, salt: 999)
        var seen: Set<UInt64> = []
        for raw in UInt64(0)..<500 {
            let token = tokenizer.token(for: PieceID(raw: raw))
            #expect(!seen.contains(token.opaque), "token collision within a single view")
            seen.insert(token.opaque)
        }
        #expect(seen.count == 500)
    }

    // MARK: - Token permutation: uncorrelated across views (R-ENG-8.3, R-QA-3.1)

    @Test("the same PieceID gets a different token under a different salt")
    func tokenDiffersAcrossSalts() {
        let piece = PieceID(raw: 77)
        let viewA = ViewTokenizer(viewer: .seat(seat0), salt: 1).token(for: piece)
        let viewB = ViewTokenizer(viewer: .seat(seat0), salt: 2).token(for: piece)
        #expect(viewA != viewB)
    }

    @Test("the same PieceID gets a different token under a different viewer")
    func tokenDiffersAcrossViewers() {
        let piece = PieceID(raw: 77)
        let asSeat0 = ViewTokenizer(viewer: .seat(seat0), salt: 5).token(for: piece)
        let asSeat1 = ViewTokenizer(viewer: .seat(seat1), salt: 5).token(for: piece)
        let asSpectator = ViewTokenizer(viewer: .spectator, salt: 5).token(for: piece)
        #expect(asSeat0 != asSeat1)
        #expect(asSeat0 != asSpectator)
        #expect(asSeat1 != asSpectator)
    }

    @Test("tokens cannot be correlated: no shared token for the same pieces across two salts")
    func tokensUncorrelatedAcrossViews() {
        // Model an attacker joining two views by token value: for the SAME set of hidden pieces under two
        // different salts, no piece keeps its token, so the two token sets are disjoint and cannot be
        // aligned to recover identities (R-QA-3.1).
        let pieces = (UInt64(0)..<64).map { PieceID(raw: $0) }
        let viewA = ViewTokenizer(viewer: .seat(seat0), salt: 0xAAAA)
        let viewB = ViewTokenizer(viewer: .seat(seat0), salt: 0xBBBB)
        var tokensA: Set<UInt64> = []
        var tokensB: Set<UInt64> = []
        for p in pieces {
            tokensA.insert(viewA.token(for: p).opaque)
            tokensB.insert(viewB.token(for: p).opaque)
        }
        #expect(tokensA.isDisjoint(with: tokensB))
    }

    @Test("a fresh tokenizer with the same key reproduces the same tokens (deterministic)")
    func tokenizerDeterministic() {
        let piece = PieceID(raw: 314)
        let first = ViewTokenizer(viewer: .seat(seat1), salt: 271_828).token(for: piece)
        let second = ViewTokenizer(viewer: .seat(seat1), salt: 271_828).token(for: piece)
        #expect(first == second)
    }

    // MARK: - pieceRevealed binding (R-ENG-8.4)

    @Test("pieceRevealed carries the token the viewer's own view assigned to the piece")
    func pieceRevealedBindsMatchingToken() {
        let deck = Decklet([(1, .standard(.jack, .spades))])
        let viewer = Viewer.seat(seat0)
        let salt: UInt64 = 20250607

        // The piece is hidden in the stock, so the viewer's view shows it as a token.
        let stock = Zone(
            id: ZoneID(name: "stock"), visibility: .hidden, contents: [PieceID(raw: 1)])
        let views = Redaction.zoneViews(
            of: [stock], for: viewer, salt: salt, faceResolver: deck.resolve)
        guard case .hidden(let shownToken) = views[0].pieces[0] else {
            Issue.record("expected the hidden stock piece to be shown as a token")
            return
        }

        // When it is revealed, the host derives the reveal token with the same (viewer, salt); it must
        // equal what the viewer already saw so the client can rebind (R-ENG-8.4).
        let revealToken = Redaction.tokenForReveal(
            piece: PieceID(raw: 1), seenBy: viewer, salt: salt)
        #expect(revealToken == shownToken)

        let event = GameEvent.pieceRevealed(token: revealToken, identity: PieceID(raw: 1))
        if case .pieceRevealed(let token, let identity) = event {
            #expect(token == shownToken)
            #expect(identity == PieceID(raw: 1))
        } else {
            Issue.record("expected a pieceRevealed event")
        }
    }

    @Test("isVisible matches the policy semantics used by zoneViews")
    func isVisibleMatchesPolicies() {
        let hand = Zone(
            id: ZoneID(name: "hand", owner: seat0), visibility: .ownerOnly,
            contents: [PieceID(raw: 1)])
        #expect(Redaction.isVisible(piece: PieceID(raw: 1), in: hand, to: .seat(seat0)))
        #expect(!Redaction.isVisible(piece: PieceID(raw: 1), in: hand, to: .seat(seat1)))
        #expect(Redaction.isVisible(piece: PieceID(raw: 1), in: hand, to: .debugOmniscient))
    }
}
