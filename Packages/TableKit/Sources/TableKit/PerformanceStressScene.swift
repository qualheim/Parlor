// PerformanceStressScene — the 104-card TableKit profiling harness (R-TABLE-7.2).
//
// The fixture deliberately uses the same declarative layout, render model, event reducer, animation
// queue, and SwiftUI TableView as a production table. It is kept in TableKit rather than in an app test
// target so headless performance tests can profile layout/reduction and the macOS app can expose the exact
// same scene for XCTest UI metrics.

import DesignSystem
import EngineCore
import Foundation
import SwiftUI

/// The deterministic 104-card renderer fixture used by performance tests and the debug profiling route.
///
/// It models a Spider-sized double deck in ten tableau columns. Every piece has a stable `PieceID`, every
/// column has a declarative `ZonePlacement`, and the deal is one semantic `.dealt` event, matching the
/// generic renderer contract rather than introducing a stress-only rendering path (R-TABLE-1.1/1.2,
/// R-TABLE-7.2).
public enum PerformanceStressScene {
    /// The number of physical cards in the Spider double-deck stress scene (R-TABLE-7.2).
    public static let cardCount = DeckDefinition.spider104.count

    /// The number of columns in the stress layout.
    public static let columnCount = 10

    /// Materialized Spider cards with stable IDs for the lifetime of a fixture build.
    public static func cards() -> [Card] {
        DeckDefinition.spider104.makeCards(startingAt: 1)
    }

    /// A public, known-face view containing every card in its stress column.
    public static func playerView() -> PlayerView {
        let cards = cards()
        let zones = (0..<columnCount).map { column in
            let pieces = cards.enumerated().compactMap { index, card -> ViewPiece? in
                guard index % columnCount == column else { return nil }
                return .known(.card(card))
            }
            return ZoneView(
                id: columnID(column), visibility: .publicAll, pieces: pieces)
        }
        return PlayerView(
            viewer: .spectator,
            zones: zones,
            scores: [:],
            phase: Phase(rawValue: "performance-stress"))
    }

    /// The same declarative ten-column layout used by the SwiftUI and headless profiles.
    public static func layout() -> TableLayout {
        var placements: [ZoneID: ZonePlacement] = [:]
        for column in 0..<columnCount {
            let x = 0.015 + CGFloat(column) * 0.098
            placements[columnID(column)] = ZonePlacement(
                region: NormalizedRect(x: x, y: 0.06, width: 0.08, height: 0.88),
                stacking: .spreadDown(spacing: 0.11, faceDownSpacing: 0.09))
        }
        return TableLayout(placements: placements)
    }

    /// The initial model used by headless tests and previews.
    public static func model() -> TableRenderModel {
        TableRenderModel(playerView: playerView())
    }

    /// A single semantic deal event carrying all 104 cards.
    public static func dealEvent() -> GameEvent {
        let descriptors = cards().enumerated().map { index, card in
            let column = index % columnCount
            let row = index / columnCount
            return PieceMoveDescriptor(
                piece: card.id,
                from: nil,
                to: columnID(column),
                toIndex: row,
                faceUp: true)
        }
        return .dealt(pieces: descriptors)
    }

    /// Deal plus a short sequence of real geometry changes used to keep the stress animation active long
    /// enough for a display-frame profile. Every event still goes through `AnimationQueue` and
    /// `TableRenderModel`; no test-only animation implementation is involved.
    public static func animationEvents() -> [GameEvent] {
        let cards = cards()
        let moves = (0..<5).map { index -> GameEvent in
            let fromColumn = index % columnCount
            let toColumn = (fromColumn + 1) % columnCount
            let from = columnID(fromColumn)
            let to = columnID(toColumn)
            return .pieceMoved(
                PieceMoveDescriptor(
                    piece: cards[index].id,
                    from: from,
                    to: to,
                    toIndex: 0,
                    faceUp: true))
        }
        return [.dealt(pieces: dealDescriptors())] + moves
    }

    /// A map suitable for `TableView`'s face-content closure.
    public static func faceContentMap() -> [RenderKey: PieceFaceContent] {
        Dictionary(
            uniqueKeysWithValues: cards().map { card in
                (.known(card.id), .card(card.face))
            })
    }

    /// The stable zone id for a stress column.
    public static func columnID(_ column: Int) -> ZoneID {
        ZoneID(name: "stress-column-\(column)")
    }

    private static func dealDescriptors() -> [PieceMoveDescriptor] {
        cards().enumerated().map { index, card in
            let column = index % columnCount
            let row = index / columnCount
            return PieceMoveDescriptor(
                piece: card.id,
                from: nil,
                to: columnID(column),
                toIndex: row,
                faceUp: true)
        }
    }
}

/// A SwiftUI profiling surface for the deterministic 104-card fixture.
///
/// The app's debug performance route renders this view with the real `TableView`, `TableSurface`,
/// `AnimationDriver`, and event queue. It publishes a compact status label containing the measured deal
/// interval and observed display-frame rate so an XCTest UI profile can check the 60 fps budget without
/// relying on a private renderer implementation.
public struct PerformanceStressSceneView: View {
    private let faceContent: [RenderKey: PieceFaceContent]
    private let layout: TableLayout
    @State private var driver: AnimationDriver
    @State private var status = "stress.deal.pending"
    @State private var frameCount = 0
    @State private var started = false
    @Namespace private var namespace

    /// Create the profiling surface. Normal speed keeps the animation in the documented 150–350 ms band.
    public init(settings: AnimationSettings = AnimationSettings(speed: .normal)) {
        faceContent = PerformanceStressScene.faceContentMap()
        layout = PerformanceStressScene.layout()
        _driver = State(
            initialValue: AnimationDriver(
                model: TableRenderModel(), settings: settings))
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            TableSurface(theme: .default)
                .ignoresSafeArea()
            TableView(
                model: driver.model,
                layout: layout,
                namespace: namespace,
                faceContent: { faceContent[$0] ?? .back })
            VStack(alignment: .leading, spacing: 4) {
                Text("104-card stress scene")
                    .font(.headline)
                Text(status)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("performance.stress.status")
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
            FrameProbe(isActive: driver.isAnimating, frameCount: $frameCount)
        }
        .accessibilityIdentifier("performance.stress.scene")
        .task { await startDealIfNeeded() }
    }

    @MainActor
    private func startDealIfNeeded() async {
        guard !started else { return }
        started = true
        frameCount = 0
        status = "stress.deal.running"
        let start = Date()
        driver.enqueue(PerformanceStressScene.animationEvents())
        do {
            while driver.isAnimating {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            return
        }
        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        let framesPerSecond = Double(frameCount) / elapsed
        status = String(
            format: "stress.deal.complete fps=%.1f frames=%d elapsed_ms=%.1f",
            framesPerSecond,
            frameCount,
            elapsed * 1_000)
    }
}

/// A display-driven frame counter used only by the profiling surface.
private struct FrameProbe: View {
    let isActive: Bool
    @Binding var frameCount: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !isActive)) { timeline in
            Color.clear
                .frame(width: 1, height: 1)
                .onChange(of: timeline.date) { _, _ in
                    if isActive { frameCount += 1 }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
