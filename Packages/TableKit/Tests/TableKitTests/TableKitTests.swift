import CoreGraphics
import EngineCore
import Testing

@testable import TableKit

// Tests for task 3.3 — the MINIMAL generic renderer's pure, testable core: layout resolution and the
// event-stream-driven render-model reduction. SwiftUI views are exercised only for compilation; the
// motion logic under test is all value-level (R-TABLE-1.1, R-TABLE-1.2).

@Suite("TableKit scaffold")
struct TableKitScaffoldTests {
    @Test("module is wired to DesignSystem and EngineCore")
    func wiredDependencies() {
        #expect(TableKit.moduleName == "TableKit")
        #expect(TableKit.designModuleName == "DesignSystem")
        #expect(TableKit.engineModuleName == "EngineCore")
    }
}

// MARK: - Fixtures

private func pid(_ n: UInt64) -> PieceID { PieceID(raw: n) }
private func token(_ n: UInt64) -> ViewToken { ViewToken(opaque: n) }
private func card(_ n: UInt64, _ rank: Rank = .ace, _ suit: Suit = .spades) -> Card {
    Card(id: pid(n), face: .standard(rank, suit))
}

// MARK: - NormalizedRect / scaling (R-APP-6.4)

@Suite("Normalized layout scales with table size")
struct NormalizedRectTests {
    @Test("a normalized rect resolves proportionally to the table size")
    func resolvesProportionally() {
        let rect = NormalizedRect(x: 0.25, y: 0.5, width: 0.1, height: 0.2)
        let small = rect.resolved(in: CGSize(width: 1000, height: 800))
        #expect(small.origin.x == 250)
        #expect(small.origin.y == 400)
        #expect(small.width == 100)
        #expect(small.height == 160)
    }

    @Test("the same layout scales up to a 6K-class table (R-APP-6.4)")
    func scalesToLargeDisplay() {
        let rect = NormalizedRect(x: 0.25, y: 0.5, width: 0.1, height: 0.2)
        let small = rect.resolved(in: CGSize(width: 1024, height: 700))
        let big = rect.resolved(in: CGSize(width: 6144, height: 4200))
        let ratio = big.origin.x / small.origin.x
        // Everything scales by the same width ratio.
        #expect(abs(big.width / small.width - ratio) < 1e-9)
        #expect(abs((6144.0 / 1024.0) - ratio) < 1e-9)
    }
}

// MARK: - Card sizing scales

@Suite("Card size scales with table")
struct CardSizeTests {
    @Test("card size grows linearly with table width and keeps aspect")
    func cardScales() {
        let resolver = LayoutResolver(cardWidthFraction: 0.072, cardAspect: 1.4)
        let a = resolver.cardSize(in: CGSize(width: 1000, height: 700))
        let b = resolver.cardSize(in: CGSize(width: 2000, height: 1400))
        #expect(abs(a.width - 72) < 1e-9)
        #expect(abs(a.height - 72 * 1.4) < 1e-9)
        #expect(abs(b.width - 2 * a.width) < 1e-9)  // linear in table width
    }
}

// MARK: - Stacking styles

@Suite("Stacking styles produce expected offsets")
struct StackingStyleTests {
    @Test("fanRight steps a piece right by spacing × index, no vertical offset")
    func fanRight() {
        let style = StackingStyle.fanRight(spacing: 0.3)
        #expect(style.offsetFraction(index: 0, count: 3, faceUp: true) == .zero)
        let o2 = style.offsetFraction(index: 2, count: 3, faceUp: true)
        #expect(abs(o2.width - 0.6) < 1e-9)
        #expect(o2.height == 0)
    }

    @Test("stack nudges both axes slightly per index")
    func stack() {
        let style = StackingStyle.stack(dx: 0.01, dy: 0.02)
        let o3 = style.offsetFraction(index: 3, count: 4, faceUp: false)
        #expect(abs(o3.width - 0.03) < 1e-9)
        #expect(abs(o3.height - 0.06) < 1e-9)
    }

    @Test("pile jitter is deterministic (same index → same offset)")
    func pileDeterministic() {
        let style = StackingStyle.pile(magnitude: 0.02)
        let a = style.offsetFraction(index: 5, count: 10, faceUp: true)
        let b = style.offsetFraction(index: 5, count: 10, faceUp: true)
        #expect(a == b)
    }
}

// MARK: - Seat arrangement (1–9)

@Suite("Seat arrangement places 1–9 seats (R-TABLE-1.1)")
struct SeatArrangementTests {
    @Test("local seat (index 0) is bottom-center for any seat count")
    func localSeatBottomCenter() {
        let seating = SeatArrangement(edgeInset: 0.86)
        for count in 1...9 {
            let anchor = seating.anchor(seatIndex: 0, count: count)
            #expect(abs(anchor.x - 0.5) < 1e-9)  // horizontally centered
            #expect(anchor.y > 0.5)  // below center (bottom half)
        }
    }

    @Test("a two-seat table puts the opponent opposite (top-center)")
    func twoSeatsOpposite() {
        let seating = SeatArrangement(edgeInset: 0.8)
        let opponent = seating.anchor(seatIndex: 1, count: 2)
        #expect(abs(opponent.x - 0.5) < 1e-6)  // centered horizontally
        #expect(opponent.y < 0.5)  // above center (top half)
    }

    @Test("all 1–9 seats are placed within the normalized table bounds")
    func seatsWithinBounds() {
        let seating = SeatArrangement()
        for count in 1...9 {
            for seat in 0..<count {
                let a = seating.anchor(seatIndex: seat, count: count)
                #expect(a.x >= 0 && a.x <= 1)
                #expect(a.y >= 0 && a.y <= 1)
            }
        }
    }

    @Test("seats are distinct positions (no two seats collide) for 3–9 seats")
    func seatsDistinct() {
        let seating = SeatArrangement()
        for count in 3...9 {
            var seen: [CGPoint] = []
            for seat in 0..<count {
                let a = seating.anchor(seatIndex: seat, count: count)
                for prev in seen {
                    let dx = a.x - prev.x
                    let dy = a.y - prev.y
                    #expect((dx * dx + dy * dy) > 1e-6)  // meaningfully apart
                }
                seen.append(a)
            }
        }
    }
}

// MARK: - Layout resolution (R-TABLE-1.1)

@Suite("Layout resolution maps zones to concrete frames")
struct LayoutResolutionTests {
    private func viewZone(_ name: String, cards: [Card]) -> ZoneView {
        ZoneView(
            id: ZoneID(name: name),
            visibility: .publicAll,
            pieces: cards.map { .known(.card($0)) }
        )
    }

    @Test("a zone's first piece lands at the zone region's resolved origin")
    func firstPieceAtRegionOrigin() {
        let layout = TableLayout.example()
        let resolver = LayoutResolver()
        let size = CGSize(width: 1000, height: 800)
        let zones = [viewZone("stock", cards: [card(1)])]
        let resolved = resolver.resolve(
            layout: layout, zones: zones, tableSize: size, seatCount: 1,
            seatIndexForOwner: { _ in nil })
        #expect(resolved.count == 1)
        // "stock" region origin is (0.04, 0.06) in the example layout.
        let expected = NormalizedRect(x: 0.04, y: 0.06, width: 0.10, height: 0.18)
            .resolved(in: size).origin
        #expect(abs(resolved[0].frame.origin.x - expected.x) < 1e-6)
        #expect(abs(resolved[0].frame.origin.y - expected.y) < 1e-6)
    }

    @Test("fanRight stacking offsets successive pieces to the right (waste)")
    func fanRightOffsetsApplied() {
        let layout = TableLayout.example()
        let resolver = LayoutResolver()
        let size = CGSize(width: 1000, height: 800)
        let zones = [viewZone("waste", cards: [card(1), card(2), card(3)])]
        let resolved = resolver.resolve(
            layout: layout, zones: zones, tableSize: size, seatCount: 1,
            seatIndexForOwner: { _ in nil }
        ).sorted { $0.index < $1.index }
        #expect(resolved.count == 3)
        // Each successive card is to the right of the previous, same y.
        #expect(resolved[1].frame.origin.x > resolved[0].frame.origin.x)
        #expect(resolved[2].frame.origin.x > resolved[1].frame.origin.x)
        #expect(abs(resolved[0].frame.origin.y - resolved[2].frame.origin.y) < 1e-9)
    }

    @Test("spreadDown stacking offsets successive pieces downward (tableau)")
    func spreadDownOffsetsApplied() {
        let layout = TableLayout.example()
        let resolver = LayoutResolver()
        let size = CGSize(width: 1000, height: 800)
        let zones = [viewZone("tableau-0", cards: [card(1), card(2), card(3)])]
        let resolved = resolver.resolve(
            layout: layout, zones: zones, tableSize: size, seatCount: 1,
            seatIndexForOwner: { _ in nil }
        ).sorted { $0.index < $1.index }
        #expect(resolved[1].frame.origin.y > resolved[0].frame.origin.y)
        #expect(resolved[2].frame.origin.y > resolved[1].frame.origin.y)
        #expect(abs(resolved[0].frame.origin.x - resolved[2].frame.origin.x) < 1e-9)
    }

    @Test("resolved frames scale with the table size (R-APP-6.4)")
    func resolvedFramesScale() {
        let layout = TableLayout.example()
        let resolver = LayoutResolver()
        let zones = [viewZone("waste", cards: [card(1), card(2)])]
        let small = resolver.resolve(
            layout: layout, zones: zones, tableSize: CGSize(width: 1000, height: 800),
            seatCount: 1, seatIndexForOwner: { _ in nil }
        ).sorted { $0.index < $1.index }
        let big = resolver.resolve(
            layout: layout, zones: zones, tableSize: CGSize(width: 2000, height: 1600),
            seatCount: 1, seatIndexForOwner: { _ in nil }
        ).sorted { $0.index < $1.index }
        // Doubling the table doubles positions and card size.
        #expect(abs(big[1].frame.origin.x - 2 * small[1].frame.origin.x) < 1e-6)
        #expect(abs(big[0].frame.width - 2 * small[0].frame.width) < 1e-6)
    }

    @Test("an owned zone with no explicit placement falls back to its seat anchor")
    func ownedZoneUsesSeatAnchor() {
        // Empty fixed placements; the resolver's fallback should place a seat-owned hand at the seat.
        let layout = TableLayout(placements: [:])
        let resolver = LayoutResolver()
        let size = CGSize(width: 1000, height: 800)
        let seat = SeatID.index(0)
        let hand = ZoneView(
            id: ZoneID(name: "hand", owner: seat),
            visibility: .ownerOnly,
            pieces: [.known(.card(card(1)))]
        )
        let resolved = resolver.resolve(
            layout: layout, zones: [hand], tableSize: size, seatCount: 2,
            seatIndexForOwner: { $0 == seat ? 0 : nil }
        )
        #expect(resolved.count == 1)
        // Seat 0 is bottom-center → the piece should be in the lower half, near horizontal center.
        #expect(resolved[0].frame.midY > size.height * 0.5)
    }

    @Test("hidden pieces resolve face-down, known pieces face-up")
    func faceStateFromViewPiece() {
        let layout = TableLayout.example()
        let resolver = LayoutResolver()
        let size = CGSize(width: 1000, height: 800)
        let zone = ZoneView(
            id: ZoneID(name: "stock"),
            visibility: .hidden,
            pieces: [.hidden(token(9)), .known(.card(card(1)))]
        )
        let resolved = resolver.resolve(
            layout: layout, zones: [zone], tableSize: size, seatCount: 1,
            seatIndexForOwner: { _ in nil }
        ).sorted { $0.index < $1.index }
        #expect(resolved[0].faceUp == false)
        if case .hidden = resolved[0].key {} else { Issue.record("expected hidden key") }
        #expect(resolved[1].faceUp == true)
        if case .known = resolved[1].key {} else { Issue.record("expected known key") }
    }
}

// MARK: - Event → render-state reduction (R-TABLE-1.2)

@Suite("Render model reduces game events (R-TABLE-1.2)")
struct RenderModelReductionTests {
    private func makeView(zones: [ZoneView]) -> PlayerView {
        PlayerView(
            viewer: .seat(.index(0)), zones: zones, scores: [:], phase: Phase(rawValue: "play"))
    }

    @Test("initial model mirrors the player view's zones and face state")
    func initialModelFromView() {
        let view = makeView(zones: [
            ZoneView(
                id: ZoneID(name: "waste"), visibility: .publicAll,
                pieces: [.known(.card(card(1)))]),
            ZoneView(
                id: ZoneID(name: "stock"), visibility: .hidden, pieces: [.hidden(token(7))]),
        ])
        let model = TableRenderModel(playerView: view)
        #expect(model.nodes.count == 2)
        #expect(model.nodes[.known(pid(1))]?.faceUp == true)
        #expect(model.nodes[.known(pid(1))]?.zone == ZoneID(name: "waste"))
        #expect(model.nodes[.hidden(token(7))]?.faceUp == false)
    }

    @Test("dealt places pieces into their target zones")
    func dealtPlacesPieces() {
        var model = TableRenderModel()
        let deal = GameEvent.dealt(pieces: [
            PieceMoveDescriptor(
                piece: pid(1), from: nil, to: ZoneID(name: "tableau-0"), toIndex: 0, faceUp: false),
            PieceMoveDescriptor(
                piece: pid(2), from: nil, to: ZoneID(name: "tableau-0"), toIndex: 1, faceUp: true),
        ])
        model.apply(deal)
        #expect(model.nodes.count == 2)
        #expect(model.nodes[.known(pid(1))]?.zone == ZoneID(name: "tableau-0"))
        #expect(model.nodes[.known(pid(1))]?.faceUp == false)
        #expect(model.nodes[.known(pid(2))]?.faceUp == true)
        #expect(model.nodes[.known(pid(2))]?.index == 1)
    }

    @Test("pieceMoved retargets a piece's zone and index (move animation)")
    func moveRetargets() {
        var model = TableRenderModel()
        model.apply(
            .dealt(pieces: [
                PieceMoveDescriptor(
                    piece: pid(1), from: nil, to: ZoneID(name: "stock"), toIndex: 0, faceUp: false)
            ]))
        model.apply(
            .pieceMoved(
                PieceMoveDescriptor(
                    piece: pid(1), from: ZoneID(name: "stock"), to: ZoneID(name: "waste"),
                    toIndex: 0, faceUp: true)))
        let node = model.nodes[.known(pid(1))]
        #expect(node?.zone == ZoneID(name: "waste"))
        #expect(node?.faceUp == true)
    }

    @Test("pieceFlipped toggles a known piece's face-up state in place")
    func flipToggles() {
        var model = TableRenderModel()
        model.apply(
            .dealt(pieces: [
                PieceMoveDescriptor(
                    piece: pid(1), from: nil, to: ZoneID(name: "tableau-0"), toIndex: 0,
                    faceUp: false)
            ]))
        #expect(model.nodes[.known(pid(1))]?.faceUp == false)
        model.apply(.pieceFlipped(pid(1), faceUp: true))
        #expect(model.nodes[.known(pid(1))]?.faceUp == true)
        // The piece did not move zones — a flip is in place.
        #expect(model.nodes[.known(pid(1))]?.zone == ZoneID(name: "tableau-0"))
    }

    @Test("pieceRevealed rebinds a hidden token to its real identity, preserving position")
    func revealRebindsToken() {
        // Start with a hidden token in the stock.
        let view = makeView(zones: [
            ZoneView(id: ZoneID(name: "stock"), visibility: .hidden, pieces: [.hidden(token(42))])
        ])
        var model = TableRenderModel(playerView: view)
        let hiddenNode = model.nodes[.hidden(token(42))]
        #expect(hiddenNode?.faceUp == false)
        #expect(hiddenNode?.identity == nil)
        let zoneBefore = hiddenNode?.zone
        let indexBefore = hiddenNode?.index

        model.apply(.pieceRevealed(token: token(42), identity: pid(99)))

        // The token node is gone; a known node for the identity took its place at the same spot.
        #expect(model.nodes[.hidden(token(42))] == nil)
        let known = model.nodes[.known(pid(99))]
        #expect(known != nil)
        #expect(known?.faceUp == true)  // a reveal shows the face
        #expect(known?.identity == pid(99))
        #expect(known?.zone == zoneBefore)  // continuity: same zone
        #expect(known?.index == indexBefore)  // continuity: same index
    }

    @Test("informational events leave piece geometry untouched")
    func informationalEventsNoOp() {
        var model = TableRenderModel()
        model.apply(
            .dealt(pieces: [
                PieceMoveDescriptor(
                    piece: pid(1), from: nil, to: ZoneID(name: "stock"), toIndex: 0, faceUp: false)
            ]))
        let before = model
        model.apply(.turnChanged(to: .index(1)))
        model.apply(.scoreChanged(seat: .index(0), delta: 10, total: 10))
        model.apply(.trickWon(by: .index(0)))
        model.apply(.captioned(LocalizedKey("caption.test")))
        #expect(model == before)
    }

    @Test("applying is pure — `applying(_:)` does not mutate the receiver")
    func applyingIsPure() {
        let model = TableRenderModel()
        let next = model.applying(
            .dealt(pieces: [
                PieceMoveDescriptor(
                    piece: pid(1), from: nil, to: ZoneID(name: "stock"), toIndex: 0, faceUp: false)
            ]))
        #expect(model.nodes.isEmpty)  // original untouched
        #expect(next.nodes.count == 1)
    }
}

// MARK: - Model → zones projection feeds the resolver end-to-end

@Suite("End-to-end: events + example layout produce frames with no game code (R-TABLE-1.2)")
struct EndToEndTests {
    @Test("a deal then a move re-resolves to the moved piece's new zone frame")
    func dealThenMoveResolves() {
        let layout = TableLayout.example()
        let resolver = LayoutResolver()
        let size = CGSize(width: 1200, height: 900)

        var model = TableRenderModel()
        model.apply(
            .dealt(pieces: [
                PieceMoveDescriptor(
                    piece: pid(1), from: nil, to: ZoneID(name: "stock"), toIndex: 0, faceUp: false)
            ]))

        let beforeFrame = resolver.resolve(
            layout: layout, zones: model.zoneViews(), tableSize: size, seatCount: 1,
            seatIndexForOwner: { _ in nil })[0].frame

        model.apply(
            .pieceMoved(
                PieceMoveDescriptor(
                    piece: pid(1), from: ZoneID(name: "stock"), to: ZoneID(name: "waste"),
                    toIndex: 0, faceUp: true)))

        let afterFrame = resolver.resolve(
            layout: layout, zones: model.zoneViews(), tableSize: size, seatCount: 1,
            seatIndexForOwner: { _ in nil })[0].frame

        // The piece's frame changed because its zone changed — motion is derived generically.
        #expect(beforeFrame.origin.x != afterFrame.origin.x)
    }
}

// MARK: - Piece label helpers

@Suite("Piece labels format faces")
struct PieceLabelTests {
    @Test("card labels combine rank glyph and suit glyph")
    func cardLabels() {
        #expect(PieceView.cardLabel(.standard(.ace, .spades)) == "A\u{2660}")
        #expect(PieceView.cardLabel(.standard(.ten, .hearts)) == "10\u{2665}")
        #expect(PieceView.cardLabel(.standard(.king, .clubs)) == "K\u{2663}")
        #expect(PieceView.cardLabel(.joker(index: 0)) == "Jkr")
    }

    @Test("tile labels show the number or a joker mark")
    func tileLabels() {
        #expect(PieceView.tileLabel(.numbered(7, .blue)) == "7")
        #expect(PieceView.tileLabel(.numbered(13, .red)) == "13")
        #expect(PieceView.tileLabel(.joker(index: 0)) == "J")
    }
}
