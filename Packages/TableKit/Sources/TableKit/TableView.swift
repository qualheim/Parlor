// TableView — the generic SwiftUI table: a thin layer over the pure render model (R-TABLE-1.1/1.2).
//
// This view renders the table for ANY game with no game-specific code: it takes a game's declarative
// `TableLayout` plus a `TableRenderModel` (built from a `PlayerView` and advanced by a stream of
// `GameEvent`s) and derives every piece position and every motion from those inputs (R-TABLE-1.1).
// Deal/move/flip/collect animate generically because each event is reduced into `TableRenderModel`
// (owned by the host/parent), the model is re-resolved into frames by `LayoutResolver`, and the piece
// views carry `matchedGeometryEffect` keyed by their stable `RenderKey` — so a piece changing zones
// interpolates from its old frame to its new one, and a `pieceRevealed` rebind keeps a flip continuous
// (design.md §6; R-ENG-8.4). No game writes any of this (R-TABLE-1.2).
//
// DESIGN NOTE — state ownership. The view is intentionally STATELESS: it renders whatever
// `TableRenderModel` it is handed. The parent owns the model (advancing it with `TableRenderModel.apply`
// inside `withAnimation`) and owns the matched-geometry `Namespace.ID`. Keeping the model and namespace
// out of the view avoids SwiftUI property-wrapper macros in this package and keeps the animated core a
// plain, testable value; the SwiftUI shell that hosts the table (App/GamesUI) supplies both.
//
// The animation here is intentionally MINIMAL — the parent wraps model changes in a single
// `withAnimation`. The full animation QUEUE (speed setting, click/keypress fast-forward, reduce-motion)
// is task 5.5; the seam is `AnimationSettings` (see `TableRenderModel.swift`).

import EngineCore
import SwiftUI

/// A generic, event-stream-driven table view (R-TABLE-1.1). Thin over `TableRenderModel` +
/// `LayoutResolver`; no per-game motion code (R-TABLE-1.2).
public struct TableView: View {
    private let model: TableRenderModel
    private let layout: TableLayout
    private let resolver: LayoutResolver
    private let seatCount: Int
    private let seatIndexForOwner: (SeatID) -> Int?
    private let faceContent: (RenderKey) -> PieceFaceContent
    private let namespace: Namespace.ID

    /// Create a table view over a render model.
    ///
    /// - Parameters:
    ///   - model: the current render model (built from a `PlayerView`, advanced by events by the parent).
    ///   - layout: the game's declarative layout (Klondike supplies its own in task 3.4).
    ///   - namespace: the matched-geometry namespace, owned by the SwiftUI parent (an `@Namespace`).
    ///   - resolver: the layout resolver (card sizing); defaults to the standard resolver.
    ///   - seatCount: number of seats (1–9) for seat arrangement.
    ///   - seatIndexForOwner: maps a zone owner to a seat index (0 = local viewer). Defaults to none.
    ///   - faceContent: how to draw a given render key (known face vs back).
    public init(
        model: TableRenderModel,
        layout: TableLayout,
        namespace: Namespace.ID,
        resolver: LayoutResolver = LayoutResolver(),
        seatCount: Int = 1,
        seatIndexForOwner: @escaping (SeatID) -> Int? = { _ in nil },
        faceContent: @escaping (RenderKey) -> PieceFaceContent
    ) {
        self.model = model
        self.layout = layout
        self.namespace = namespace
        self.resolver = resolver
        self.seatCount = seatCount
        self.seatIndexForOwner = seatIndexForOwner
        self.faceContent = faceContent
    }

    public var body: some View {
        GeometryReader { proxy in
            let tableSize = proxy.size
            let cardSize = resolver.cardSize(in: tableSize)
            let pieces = resolver.resolve(
                layout: layout,
                zones: model.zoneViews(),
                tableSize: tableSize,
                seatCount: seatCount,
                seatIndexForOwner: seatIndexForOwner
            )
            ZStack(alignment: .topLeading) {
                ForEach(pieces, id: \.key) { piece in
                    PieceView(content: contentFor(piece), size: cardSize)
                        .matchedGeometryEffect(id: piece.key, in: namespace)
                        .position(x: piece.frame.midX, y: piece.frame.midY)
                        .zIndex(Double(piece.index))
                }
            }
            .frame(width: tableSize.width, height: tableSize.height)
        }
    }

    private func contentFor(_ piece: ResolvedPiece) -> PieceFaceContent {
        piece.faceUp ? faceContent(piece.key) : .back
    }
}
