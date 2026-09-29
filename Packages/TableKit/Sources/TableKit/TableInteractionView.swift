// TableInteractionView — the thin SwiftUI shell over the pure interaction/focus models (R-TABLE-3, 4.1).
//
// This is the interaction LAYER of the generic table: it renders the same resolved pieces `TableView`
// draws, but adds the three input paths (drag-drop, click-to-select-then-place, double-click smart move),
// full keyboard navigation with a visible focus ring, the right-click "why can't I play this?" menu, and
// the gentle spring-back + caption on an illegal move — all game-agnostically (R-TABLE-3.1–3.6, 4.1;
// R-A11Y-2). It is intentionally THIN: every decision lives in the pure value types
// (`TableInteractionModel`, `TableFocusModel`) so this file holds only SwiftUI plumbing — state, gestures,
// focus wiring, and visual affordances. The host supplies rules purely as data via `TableInteractionInput`
// (the seam), so no per-game input code is written here or by a game (R-TABLE-1.2 spirit; R-SESS-1.2).
//
// State ownership: unlike the stateless `TableView`, this view OWNS its interaction state (@State model,
// @FocusState focus) because it must react to gestures and keys. It composes the same
// `LayoutResolver`→frames pipeline so highlights, focus rings, and spring-back animate over the exact
// frames the renderer uses.

import EngineCore
import SwiftUI

/// A generic, interactive table view: renders resolved pieces and drives all input paths through the pure
/// interaction/focus models (R-TABLE-3, R-TABLE-4.1). Thin over `TableInteractionModel` +
/// `TableFocusModel`; no per-game input code.
public struct TableInteractionView: View {
    private let model: TableRenderModel
    private let layout: TableLayout
    private let input: TableInteractionInput
    private let zoneOrder: [ZoneID]
    private let resolver: LayoutResolver
    private let seatCount: Int
    private let seatIndexForOwner: (SeatID) -> Int?
    private let faceContent: (RenderKey) -> PieceFaceContent

    @State private var interaction = TableInteractionModel()
    @FocusState private var keyboardFocused: Bool
    @State private var focus: FocusTarget?
    @Namespace private var namespace

    /// Create an interactive table.
    ///
    /// - Parameters:
    ///   - model: the current render model (built from a `PlayerView`, advanced by events by the parent).
    ///   - layout: the game's declarative layout.
    ///   - input: the host seam — legal targets, resolve/smartTarget/explain closures (R-TABLE-3).
    ///   - zoneOrder: the left→right keyboard-navigation order of zones (R-TABLE-3.4).
    ///   - resolver: the layout resolver (card sizing); defaults to the standard resolver.
    ///   - seatCount: number of seats (1–9) for seat arrangement.
    ///   - seatIndexForOwner: maps a zone owner to a seat index (0 = local viewer). Defaults to none.
    ///   - faceContent: how to draw a given render key (known face vs back).
    public init(
        model: TableRenderModel,
        layout: TableLayout,
        input: TableInteractionInput,
        zoneOrder: [ZoneID] = [],
        resolver: LayoutResolver = LayoutResolver(),
        seatCount: Int = 1,
        seatIndexForOwner: @escaping (SeatID) -> Int? = { _ in nil },
        faceContent: @escaping (RenderKey) -> PieceFaceContent
    ) {
        self.model = model
        self.layout = layout
        self.input = input
        self.zoneOrder = zoneOrder
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
            let anchors = zoneAnchors(pieces)
            let topology = FocusTopology.from(resolved: pieces, zoneOrder: orderedZones(anchors))
            let highlighted = Set(interaction.highlightedTargets(input))

            ZStack(alignment: .topLeading) {
                // Legal-target highlights sit under the pieces (R-TABLE-3.6).
                ForEach(anchors, id: \.zone) { anchor in
                    if highlighted.contains(anchor.zone) {
                        legalTargetHighlight(at: anchor.frame)
                    }
                }

                // The pieces themselves, each interactive.
                ForEach(pieces, id: \.key) { piece in
                    pieceView(piece, cardSize: cardSize, highlighted: highlighted, anchors: anchors)
                }

                // The transient illegal-move caption (non-blocking, no modal — R-TABLE-4.1).
                if let feedback = interaction.feedback {
                    captionBar(feedback.caption)
                        .position(
                            x: tableSize.width / 2, y: tableSize.height - cardSize.height * 0.4)
                }
            }
            .frame(width: tableSize.width, height: tableSize.height)
            .contentShape(Rectangle())
            .onTapGesture {
                // A tap on empty felt deselects (R-TABLE-3.2).
                interaction.deselect()
            }
            .focusable()
            .focused($keyboardFocused)
            .focusEffectDisabled()
            .onKeyPress { press in handleKey(press, topology: topology) }
            .onAppear {
                if focus == nil { focus = TableFocusModel.initialFocus(topology) }
                keyboardFocused = true
            }
        }
    }

    // MARK: - Piece rendering + gestures

    @ViewBuilder
    private func pieceView(
        _ piece: ResolvedPiece, cardSize: CGSize, highlighted: Set<ZoneID>,
        anchors: [(zone: ZoneID, frame: CGRect)]
    ) -> some View {
        let content: PieceFaceContent = piece.faceUp ? faceContent(piece.key) : .back
        let isSelected = interaction.selection?.piece == piece.key
        let isFocused = focus.map { isFocusOn($0, piece) } ?? false
        let springing = interaction.feedback?.springBack == piece.key

        PieceView(content: content, size: cardSize)
            .overlay(selectionOverlay(isSelected: isSelected, size: cardSize))
            .overlay(focusRing(isFocused: isFocused, size: cardSize))
            .modifier(ShakeEffect(shaking: springing))
            .matchedGeometryEffect(id: piece.key, in: namespace)
            .position(x: piece.frame.midX, y: piece.frame.midY)
            .zIndex(Double(piece.index) + (isSelected || springing ? 1000 : 0))
            // Click-to-select then click-to-place (R-TABLE-3.2); a click on a selected-and-legal piece's
            // zone places, otherwise selects.
            .onTapGesture(count: 2) { smartMove(piece) }  // double-click smart move (R-TABLE-3.3)
            .onTapGesture(count: 1) { tap(piece) }
            // Drag & drop of a single card or a run's lead (R-TABLE-3.1).
            .gesture(dragGesture(piece, anchors: anchors))
            // Right-click "why can't I play this?" (R-TABLE-3.5).
            .contextMenu { whyNotMenu(piece) }
    }

    private func dragGesture(
        _ piece: ResolvedPiece, anchors: [(zone: ZoneID, frame: CGRect)]
    ) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { _ in
                if interaction.selection?.piece != piece.key
                    || interaction.selection?.isDragging != true
                {
                    interaction.beginDrag(piece.key, from: piece.zone)
                }
            }
            .onEnded { value in
                // The drag translation is measured from the piece's own center; add it to the piece's
                // resolved center to get the drop point in table coordinates, then hit-test zones.
                let dropPoint = CGPoint(
                    x: piece.frame.midX + value.translation.width,
                    y: piece.frame.midY + value.translation.height)
                if let dropZone = zoneUnder(point: dropPoint, anchors: anchors) {
                    _ = interaction.drop(on: dropZone, using: input)
                } else {
                    interaction.deselect()
                }
            }
    }

    // MARK: - Input path handlers

    /// Single click: select the piece if nothing is selected, or attempt to place the current selection on
    /// this piece's zone if it is a legal target; otherwise select this piece (R-TABLE-3.2).
    private func tap(_ piece: ResolvedPiece) {
        if let selection = interaction.selection, selection.piece != piece.key,
            input.isLegalTarget(piece.zone, for: selection.piece)
        {
            _ = interaction.place(on: piece.zone, using: input)
        } else {
            interaction.select(piece.key, from: piece.zone)
        }
    }

    private func smartMove(_ piece: ResolvedPiece) {
        _ = interaction.smartMove(piece.key, from: piece.zone, using: input)
    }

    // MARK: - Keyboard navigation (R-TABLE-3.4, R-A11Y-2)

    private func handleKey(_ press: KeyPress, topology: FocusTopology) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: moveFocus(.left, topology); return .handled
        case .rightArrow: moveFocus(.right, topology); return .handled
        case .upArrow: moveFocus(.up, topology); return .handled
        case .downArrow: moveFocus(.down, topology); return .handled
        case .space, .return: activateFocus(); return .handled
        case .escape: interaction.deselect(); return .handled
        default: return .ignored
        }
    }

    private func moveFocus(_ direction: FocusDirection, _ topology: FocusTopology) {
        let current = focus ?? TableFocusModel.initialFocus(topology)
        guard let current else { return }
        focus = TableFocusModel.next(from: current, direction: direction, in: topology)
    }

    /// Space/Return on a focused piece: select it, or — if something is already selected and the focused
    /// zone is a legal target — place there (R-TABLE-3.4).
    private func activateFocus() {
        guard let focus else { return }
        switch focus {
        case .piece(let key, let zone):
            if let selection = interaction.selection, selection.piece != key,
                input.isLegalTarget(zone, for: selection.piece)
            {
                _ = interaction.place(on: zone, using: input)
            } else {
                interaction.select(key, from: zone)
            }
        case .zone(let zone):
            if let selection = interaction.selection,
                input.isLegalTarget(zone, for: selection.piece)
            {
                _ = interaction.place(on: zone, using: input)
            }
        }
    }

    // MARK: - Why can't I play this? (R-TABLE-3.5)

    @ViewBuilder
    private func whyNotMenu(_ piece: ResolvedPiece) -> some View {
        if let violation = interaction.explanation(for: piece.key, from: piece.zone, using: input) {
            Section("Why can't I play this?") {
                Text(violation.reason)
            }
        } else {
            Text("This card can be played.")
        }
    }

    // MARK: - Visual affordances

    @ViewBuilder
    private func selectionOverlay(isSelected: Bool, size: CGSize) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
        }
    }

    @ViewBuilder
    private func focusRing(isFocused: Bool, size: CGSize) -> some View {
        if isFocused {
            // A visible focus indicator — a bright ring offset slightly outside the piece (R-A11Y-2).
            RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.14, style: .continuous)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .padding(-3)
        }
    }

    @ViewBuilder
    private func legalTargetHighlight(at frame: CGRect) -> some View {
        RoundedRectangle(cornerRadius: min(frame.width, frame.height) * 0.14, style: .continuous)
            .fill(Color.green.opacity(0.18))
            .overlay(
                RoundedRectangle(
                    cornerRadius: min(frame.width, frame.height) * 0.14, style: .continuous
                )
                .strokeBorder(Color.green.opacity(0.7), lineWidth: 2)
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func captionBar(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.black.opacity(0.72))
            )
            .accessibilityLabel(Text(text))
            .transition(.opacity)
    }

    // MARK: - Geometry helpers

    /// The keyboard zone order: the caller-supplied `zoneOrder` if given, else the zones present in a
    /// stable left→right, top→bottom order (from `zoneAnchors`) so nav works with zero config.
    private func orderedZones(_ anchors: [(zone: ZoneID, frame: CGRect)]) -> [ZoneID] {
        if !zoneOrder.isEmpty { return zoneOrder }
        return anchors.map(\.zone)
    }

    /// One anchor frame per zone present in `pieces`: the frame of the zone's bottom (index 0) piece, used
    /// to place legal-target highlights, to order zones, and to hit-test drops. Zones with pieces only.
    private func zoneAnchors(_ pieces: [ResolvedPiece]) -> [(zone: ZoneID, frame: CGRect)] {
        var byZone: [ZoneID: ResolvedPiece] = [:]
        for piece in pieces
        where byZone[piece.zone] == nil || piece.index < byZone[piece.zone]!.index {
            byZone[piece.zone] = piece
        }
        return
            byZone
            .map { (zone: $0.key, frame: $0.value.frame) }
            .sorted { lhs, rhs in
                if abs(lhs.frame.minX - rhs.frame.minX) > 0.5 {
                    return lhs.frame.minX < rhs.frame.minX
                }
                return lhs.frame.minY < rhs.frame.minY
            }
    }

    /// The zone whose anchor frame is nearest `point` (drop hit-testing) (R-TABLE-3.1).
    ///
    /// Prefers a frame that actually contains the drop point; if none does (a drop just past a pile's
    /// edge), falls back to the nearest anchor center within a tolerance so a slightly-off drop still
    /// lands sensibly. Returns `nil` only when there are no zones.
    private func zoneUnder(
        point: CGPoint, anchors: [(zone: ZoneID, frame: CGRect)]
    ) -> ZoneID? {
        if let hit = anchors.first(where: { $0.frame.contains(point) }) {
            return hit.zone
        }
        // Fall back to the nearest anchor center so a drop just past a pile still lands on it; the model
        // then validates the drop against the legal targets, so an over-generous snap is harmless.
        return anchors.min { lhs, rhs in
            distanceSquared(lhs.frame, point) < distanceSquared(rhs.frame, point)
        }?.zone
    }

    private func distanceSquared(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = frame.midX - point.x
        let dy = frame.midY - point.y
        return dx * dx + dy * dy
    }

    private func isFocusOn(_ focus: FocusTarget, _ piece: ResolvedPiece) -> Bool {
        switch focus {
        case .piece(let key, _): return key == piece.key
        case .zone: return false
        }
    }
}

// MARK: - Shake effect (R-TABLE-4.1)

/// A gentle horizontal shake for the spring-back on an illegal move (R-TABLE-4.1).
///
/// Animatable so it can be driven by a single `withAnimation`: when `shaking` toggles true the piece
/// oscillates a few times over a small amplitude and settles — the "gentle shake" the requirement calls
/// for, paired with the piece animating back to its origin frame (which happens automatically because the
/// render model never moved it on a rejected attempt).
public struct ShakeEffect: GeometryEffect {
    /// Whether the piece is currently shaking (0 → still, 1 → full shake cycle).
    public var shaking: Bool
    private var progress: CGFloat

    public init(shaking: Bool) {
        self.shaking = shaking
        self.progress = shaking ? 1 : 0
    }

    public var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        guard progress > 0 else { return ProjectionTransform(.identity) }
        let amplitude: CGFloat = 6
        let shakes: CGFloat = 3
        let dx = amplitude * sin(progress * .pi * 2 * shakes)
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}
