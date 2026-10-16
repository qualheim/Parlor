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
import os

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
    private let handZones: Set<ZoneID>
    /// The animation settings (speed + reduce-motion) used only to settle a RELEASED drag's live offset
    /// back to zero over the SAME spring the controller's reconcile animates the move with (R-TABLE-5.1).
    /// Defaults to the resting Normal settings; the host passes the driver's current settings so the drop
    /// settle honors the chosen speed and Reduce Motion.
    private let animationSettings: AnimationSettings

    @State private var interaction = TableInteractionModel()
    @FocusState private var keyboardFocused: Bool
    @State private var focus: FocusTarget?
    /// The last single-tap (key, time) used to detect a double-click WITHOUT the built-in count:2 gesture,
    /// which forces every single click to wait a full double-click interval before it selects. By acting on
    /// the first click immediately (select/place) and treating a second click on the same piece within the
    /// window as a smart move, a single click selects with no delay (R-TABLE-3.2/3.3).
    @State private var lastTap: (key: RenderKey, at: Date)?

    /// The in-flight DRAG that follows the cursor live (fix for the "card doesn't track the pointer" lag):
    /// the lead piece being dragged, the zone it came from, its index within that zone, and the running
    /// translation from the gesture. While a drag is active, the lead piece — and any piece stacked ABOVE
    /// it in the same source zone (the visual "run" the player grabbed) — is offset by `translation` so it
    /// moves 1:1 with the pointer. This is DIRECT MANIPULATION: the offset is applied WITHOUT
    /// `withAnimation`, so there is zero animation lag between the cursor and the card. On drop it is
    /// cleared inside the move spring so the card slides smoothly from the drop point to its final slot
    /// (the controller's reconcile animates the `.position` change over the same spring) rather than
    /// snapping back to the origin and then forward. `nil` when nothing is being dragged (R-TABLE-3.1).
    @State private var liveDrag: LiveDrag?

    /// The live, cursor-following drag state (see `liveDrag`). A plain value so it stays testable headless.
    struct LiveDrag: Equatable {
        /// The lead piece being dragged (its stable render key).
        var key: RenderKey
        /// The zone the lead piece came from — only pieces in THIS zone follow the cursor.
        var zone: ZoneID
        /// The lead piece's index within its zone — only pieces at this index OR ABOVE follow (the run).
        var index: Int
        /// The running gesture translation applied as a live `.offset`.
        var translation: CGSize
        /// Set true on release: the finger/mouse is up and the offset is now holding the card at the drop
        /// point, waiting for the model to reconcile. The HELD offset is cleared the moment the render
        /// model next changes (the reconcile), inside the move spring, so the card slides from the drop
        /// point straight to its final slot with no snap back to the origin.
        var released: Bool = false
    }

    /// Interaction log: `.debug` for every tap/select/place/zone-action/drag-drop DECISION (piece key,
    /// zone, outcome), so a user report of "clicking does nothing" leaves a trail in Console. Values are
    /// `privacy: .public` — piece ids and zone names are not sensitive. The game-action notices (submitted/
    /// accepted/rejected) are logged one layer up by the controller, under the same subsystem/category.
    private static let log = Logger(subsystem: "com.parlor.Parlor", category: "table")
    @Namespace private var namespace
    @Namespace private var rotorNamespace

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
    ///   - handZones: the zones that form the LOCAL player's hand, grouped into the "Hand" VoiceOver rotor
    ///     (R-A11Y-1.2). Everything else becomes the "Piles" rotor. Defaults to empty (no hand rotor).
    ///   - animationSettings: the current speed + reduce-motion, used only to settle a released drag's
    ///     live offset over the same spring the controller's reconcile uses. Defaults to Normal.
    ///   - faceContent: how to draw a given render key (known face vs back).
    public init(
        model: TableRenderModel,
        layout: TableLayout,
        input: TableInteractionInput,
        zoneOrder: [ZoneID] = [],
        resolver: LayoutResolver = LayoutResolver(),
        seatCount: Int = 1,
        seatIndexForOwner: @escaping (SeatID) -> Int? = { _ in nil },
        handZones: Set<ZoneID> = [],
        animationSettings: AnimationSettings = .minimal,
        faceContent: @escaping (RenderKey) -> PieceFaceContent
    ) {
        self.model = model
        self.layout = layout
        self.input = input
        self.zoneOrder = zoneOrder
        self.resolver = resolver
        self.seatCount = seatCount
        self.seatIndexForOwner = seatIndexForOwner
        self.handZones = handZones
        self.animationSettings = animationSettings
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
            let rotorModel = rotorModel(pieces: pieces, highlighted: highlighted)

            ZStack(alignment: .topLeading) {
                // A visible focus ring on a focused ZONE — including an EMPTY pile, which has no piece to
                // ring — so every focusable target shows the indicator (R-A11Y-2.1, R-KLON-1.4).
                if case .zone(let focusedZone) = focus,
                    let frame = zoneFrame(focusedZone, anchors: anchors, tableSize: tableSize)
                {
                    zoneFocusRing(at: frame)
                }

                // Invisible tappable slots for zones that have NO top piece to click but still need a mouse
                // target: an empty stock (tap to recycle — R-KLON-2.3), and an empty legal-target pile the
                // current selection may move onto (e.g. a King onto an empty tableau — R-KLON-1.4). Zones
                // that DO have a top piece are handled by that piece's own tap, so they are excluded here.
                ForEach(
                    emptyTapZones(
                        anchors: anchors, highlighted: highlighted, tableSize: tableSize),
                    id: \.zone
                ) { slot in
                    zoneTapSlot(slot.zone, at: slot.frame, cardSize: cardSize)
                }

                // The pieces themselves, each interactive.
                ForEach(pieces, id: \.key) { piece in
                    pieceView(piece, cardSize: cardSize, highlighted: highlighted, anchors: anchors)
                }

                // Legal-target highlights drawn ON TOP of each target pile's TOP card / empty slot, so the
                // "where can this go" outline is always visible rather than hidden beneath the cards
                // (R-TABLE-3.6). Anchored to the top piece's frame (the card you'd drop onto), not the
                // index-0 bottom card, and non-hit-testing so it never swallows a click/drop.
                ForEach(
                    legalTargetHighlights(
                        pieces: pieces, highlighted: highlighted, anchors: anchors,
                        tableSize: tableSize),
                    id: \.zone
                ) { target in
                    legalTargetHighlight(at: target.frame)
                }

                // The transient illegal-move caption (non-blocking, no modal — R-TABLE-4.1).
                if let feedback = interaction.feedback {
                    captionBar(feedback.caption)
                        .position(
                            x: tableSize.width / 2, y: tableSize.height - cardSize.height * 0.4)
                }
            }
            .frame(width: tableSize.width, height: tableSize.height)
            .accessibilityRotors(rotorModel, in: rotorNamespace)
            .contentShape(Rectangle())
            .onTapGesture {
                // A tap on empty felt deselects (R-TABLE-3.2).
                interaction.deselect()
            }
            // When the render model reconciles after an accepted/rejected drop, clear a RELEASED live drag
            // inside the move spring so the held card slides from the drop point to its final slot in one
            // motion (see `settleLiveDrag(after:)`). Keyed on the model value — reconcile replaces it.
            .onChange(of: model) {
                clearReleasedLiveDragOnReconcile()
            }
            .overlay(alignment: .topLeading) {
                keyboardFocusProxy(topology)
            }
        }
    }

    private func keyboardFocusProxy(_ topology: FocusTopology) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable(interactions: .activate)
            .focused($keyboardFocused)
            .focusEffectDisabled()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Table keyboard focus")
            .accessibilityIdentifier("table.keyboard.focus")
            .contentShape(Rectangle())
            .onKeyPress { press in handleKey(press, topology: topology) }
            .onAppear {
                if focus == nil { focus = TableFocusModel.initialFocus(topology) }
                keyboardFocused = true
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

        let isLegalTarget = highlighted.contains(piece.zone)
        // The live cursor-follow offset for this piece (zero unless it is the dragged lead or part of the
        // grabbed run), and whether it is currently following — used for the lift scale and raised z.
        let dragFollowOffset = liveFollowOffset(for: piece)
        let isDragFollowing = isFollowingDrag(piece)

        PieceView(
            content: content, size: cardSize,
            accessibility: accessibilityDescription(
                for: piece, content: content, isSelected: isSelected,
                isLegalTarget: isLegalTarget)
        )
        .accessibilityIdentifier(Self.pieceAccessibilityIdentifier(piece.key))
        .accessibilityRotorEntry(id: piece.key, in: rotorNamespace)
        .overlay(selectionOverlay(isSelected: isSelected, size: cardSize))
        .overlay(focusRing(isFocused: isFocused, size: cardSize))
        .modifier(ShakeEffect(shaking: springing))
        // CRITICAL: the input gestures and hit shape are attached to the CARD-SIZED view, BEFORE
        // `.position(...)`. `.position` returns a view that expands to fill ALL available space; attaching
        // gestures after it would give every piece a full-table hit region, so the top-most z-index piece
        // would swallow every click and no tap would map to the card under the cursor (the mouse-dead-table
        // bug). Constraining the hit shape to the card rect here — and only then positioning — makes each
        // piece hit-test to its own bounds, so a click on a card reaches THAT card (R-TABLE-3.1/3.2/3.3).
        .contentShape(Rectangle())
        // Right-click "why can't I play this?" (R-TABLE-3.5). On the sized view so it targets the card.
        .contextMenu { whyNotMenu(piece) }
        // Drag & drop of a single card or a run's lead (R-TABLE-3.1). A `.highPriorityGesture` so the drag
        // is recognized before the felt's tap, and `minimumDistance` keeps a plain click a tap, not a drag.
        .highPriorityGesture(dragGesture(piece, anchors: anchors))
        // A SINGLE `onTapGesture(count: 1)` so the first click acts IMMEDIATELY (no double-click delay —
        // the previous `count: 2` alongside this one made every single click wait a full interval, so users
        // clicked again and tripped an unexpected smart move). A double click is detected manually in
        // `handleTap` from the timestamp of the previous click on the same piece (R-TABLE-3.2/3.3).
        .onTapGesture(count: 1) { handleTap(piece) }
        // A slight "lift off the table" on the piece being dragged: a small scale + raised z so the held
        // card (and its run) reads as picked up. Cheap (a transform, no shadow redraw) and only on the
        // dragged pieces, so a resting table is untouched (R-TABLE-1.3 lift cue).
        .scaleEffect(isDragFollowing ? 1.04 : 1.0)
        .matchedGeometryEffect(id: piece.key, in: namespace)
        .position(x: piece.frame.midX, y: piece.frame.midY)
        // The LIVE drag offset: the dragged lead piece and any piece stacked above it in the same source
        // zone follow the cursor 1:1. Applied AFTER `.position` so it shifts the positioned card directly,
        // and NEVER wrapped in `withAnimation` — direct manipulation must be immediate, with no spring lag
        // between the pointer and the card (fixes the "card doesn't track the cursor / feels sluggish" bug,
        // R-TABLE-3.1). Zero for every piece not part of the current drag, so resting cards stay put.
        .offset(dragFollowOffset)
        .zIndex(Double(piece.index) + (isSelected || springing || isDragFollowing ? 1000 : 0))
    }

    /// The live cursor-follow offset for `piece`: the current drag translation when `piece` is the dragged
    /// lead OR is stacked above it in the same source zone (the run that moves together), else `.zero`.
    /// Pure over `liveDrag`; the heavy lifting is in the testable static `followOffset`.
    private func liveFollowOffset(for piece: ResolvedPiece) -> CGSize {
        Self.followOffset(for: piece.key, zone: piece.zone, index: piece.index, drag: liveDrag)
    }

    /// Whether `piece` is currently following the cursor (the dragged lead or a piece in its run).
    private func isFollowingDrag(_ piece: ResolvedPiece) -> Bool {
        liveFollowOffset(for: piece) != .zero
            || (liveDrag.map { $0.key == piece.key } ?? false)
    }

    /// Pure, testable rule for the live-follow offset: a piece follows the cursor iff a drag is active and
    /// the piece is in the SAME zone as the dragged lead AND at the lead's index or above (so the lead and
    /// the cards stacked on top of it — the grabbed run — move together, while cards below it stay put).
    /// Game-agnostic: TableKit does not know run membership, but "the cards stacked on the one you grabbed
    /// move with it" is the correct visual for both a single card and a tableau run.
    ///
    /// `nonisolated` because it is pure value logic over its arguments with no access to actor-isolated
    /// view state, so it is callable from any context (including the headless, non-MainActor tests).
    nonisolated static func followOffset(
        for key: RenderKey, zone: ZoneID, index: Int, drag: LiveDrag?
    ) -> CGSize {
        guard let drag else { return .zero }
        if key == drag.key { return drag.translation }
        if zone == drag.zone && index >= drag.index { return drag.translation }
        return .zero
    }

    private func dragGesture(
        _ piece: ResolvedPiece, anchors: [(zone: ZoneID, frame: CGRect)]
    ) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if interaction.selection?.piece != piece.key
                    || interaction.selection?.isDragging != true
                {
                    interaction.beginDrag(piece.key, from: piece.zone)
                }
                // Track the translation live so the card follows the cursor 1:1. NOT wrapped in
                // `withAnimation` — direct manipulation must be immediate, with no spring lag between
                // the pointer and the card (R-TABLE-3.1).
                liveDrag = LiveDrag(
                    key: piece.key, zone: piece.zone, index: piece.index,
                    translation: value.translation)
            }
            .onEnded { value in
                // The drag translation is measured from the piece's own center; add it to the piece's
                // resolved center to get the drop point in table coordinates, then hit-test zones.
                let dropPoint = CGPoint(
                    x: piece.frame.midX + value.translation.width,
                    y: piece.frame.midY + value.translation.height)
                let outcome: PlacementOutcome
                if let dropZone = zoneUnder(point: dropPoint, anchors: anchors) {
                    Self.log.debug(
                        "drag-drop: \(renderKeyLabel(piece.key), privacy: .public) → zone \(dropZone.name, privacy: .public)"
                    )
                    outcome = interaction.drop(on: dropZone, using: input)
                } else {
                    Self.log.debug(
                        "drag-drop: \(renderKeyLabel(piece.key), privacy: .public) released off-table → deselect"
                    )
                    interaction.deselect()
                    outcome = .noAttempt
                }
                settleLiveDrag(after: outcome)
            }
    }

    /// Clear the live cursor-follow offset at drop time, choosing WHERE the card settles from based on the
    /// drop outcome so there is never a visible jump:
    ///   • `.accepted` or `.rejected` → the host WILL reconcile the render model (to the new board, or back
    ///     to the authoritative board on a rejection). We must NOT zero the offset now — the model has not
    ///     reconciled yet (the host round-trip is async), so zeroing it would snap the card to its ORIGIN
    ///     for a frame before the reconcile slides it forward. Instead mark the drag RELEASED and leave the
    ///     card pinned at the drop point; `.onChange(of: model)` clears it inside the move spring the
    ///     instant the model changes, so the card's `.position` (origin→destination) and this offset
    ///     (translation→0) animate together into one smooth slide to the final slot.
    ///   • `.noAttempt` → nothing was submitted (a drop on a non-target zone, or an off-table release), so
    ///     NO reconcile is coming. Settle the offset to zero right here over the move spring, which slides
    ///     the card smoothly back to its origin.
    private func settleLiveDrag(after outcome: PlacementOutcome) {
        switch outcome {
        case .accepted, .rejected:
            if liveDrag != nil { liveDrag?.released = true }
        case .noAttempt:
            withAnimation(moveSpringAnimation) { liveDrag = nil }
        }
    }

    /// Clear a RELEASED live drag once the render model has reconciled (the move landed on the host). Runs
    /// from `.onChange(of: model)` inside the move spring so the offset→0 animation composes with the
    /// reconcile's position animation into a single slide from the drop point to the final slot. A no-op
    /// while a drag is still active (not released) or when there is nothing to clear.
    private func clearReleasedLiveDragOnReconcile() {
        guard let drag = liveDrag, drag.released else { return }
        withAnimation(moveSpringAnimation) { liveDrag = nil }
    }

    /// The spring used to settle a released drag's live offset back to zero — matched to the current
    /// animation speed/reduce-motion so the drop settles over the SAME spring the controller's reconcile
    /// animates the `.position` change with. Keeps the two in lockstep so the card slides from the drop
    /// point to its final slot (R-TABLE-5.1/5.3).
    private var moveSpringAnimation: Animation {
        animationSettings.timing().token.swiftUIAnimation
    }

    // MARK: - Input path handlers

    /// The double-click window: a second click on the same piece within this interval is a smart move; a
    /// slower second click is just another single tap. Short enough that the first click still feels
    /// immediate (it acts right away) yet long enough to catch an intentional double click.
    private static let doubleClickInterval: TimeInterval = 0.35

    /// Route a single tap: the FIRST click acts immediately via `tap(_:)` (select/place/zone-action); a
    /// second click on the SAME piece within `doubleClickInterval` is promoted to a smart move
    /// (R-TABLE-3.2/3.3). Because the first click already acted, selection is instant with no delay.
    private func handleTap(_ piece: ResolvedPiece) {
        let now = Date()
        if let last = lastTap, last.key == piece.key,
            now.timeIntervalSince(last.at) <= Self.doubleClickInterval
        {
            // Second quick click on the same piece → smart move. Clear the tap record so a third click
            // starts fresh rather than chaining.
            lastTap = nil
            smartMove(piece)
            return
        }
        lastTap = (key: piece.key, at: now)
        tap(piece)
    }

    /// Single click: select the piece if nothing is selected, or attempt to place the current selection on
    /// this piece's zone if it is a legal target; otherwise select this piece (R-TABLE-3.2).
    private func tap(_ piece: ResolvedPiece) {
        // If the current selection can legally land on this piece's zone, placing wins (finishing a move).
        if let selection = interaction.selection, selection.piece != piece.key,
            input.isLegalTarget(piece.zone, for: selection.piece)
        {
            Self.log.debug(
                "tap: place \(renderKeyLabel(selection.piece), privacy: .public) → zone \(piece.zone.name, privacy: .public)"
            )
            _ = interaction.place(on: piece.zone, using: input)
            return
        }
        // A tap on a zone that carries a NON-DRAG action (the stock's draw/recycle) invokes that action —
        // the mouse path for actions dragging cannot express (R-KLON-2.1, R-KLON-2.3; R-A11Y-2.1). CRITICAL:
        // this must fire whether or not a selection lingers, as long as that selection can't legally land
        // here. Previously it only fired when NOTHING was selected, so a stale selection turned a click on
        // the stock into "select the stock card" forever — the stock looked dead. Clear any such stale
        // selection first, then perform the action, so clicking the stock always draws/recycles.
        if let action = input.zoneAction(for: piece.zone) {
            if interaction.selection != nil { interaction.deselect() }
            Self.log.debug(
                "tap: zone-action \(action.id, privacy: .public) on zone \(piece.zone.name, privacy: .public)"
            )
            _ = interaction.performZoneAction(action.id, using: input)
            return
        }
        Self.log.debug(
            "tap: select \(renderKeyLabel(piece.key), privacy: .public) in zone \(piece.zone.name, privacy: .public)"
        )
        interaction.select(piece.key, from: piece.zone)
    }

    /// Whether no piece is currently selected (a plain resting table).
    private var nothingSelected: Bool { interaction.selection == nil }

    /// A tap on an empty zone slot: place the current selection there if it is a legal target, else invoke
    /// the zone's non-drag action if it has one (empty-stock recycle) (R-KLON-1.4, R-KLON-2.3; R-A11Y-2.1).
    private func tapZone(_ zone: ZoneID) {
        if let selection = interaction.selection,
            input.isLegalTarget(zone, for: selection.piece)
        {
            tapZoneLog(zone, "place \(renderKeyLabel(selection.piece))")
            _ = interaction.place(on: zone, using: input)
            return
        }
        if let action = input.zoneAction(for: zone) {
            tapZoneLog(zone, "zone-action \(action.id)")
            _ = interaction.performZoneAction(action.id, using: input)
        }
    }

    /// The empty zones (no top piece) that still need a mouse tap target this frame (R-KLON-1.4,
    /// R-KLON-2.3): every zone carrying a non-drag action, plus every highlighted legal-target zone,
    /// minus the zones that already have a piece anchor (those are tapped via the piece). Each is resolved
    /// to its single card-slot frame so the slot sits exactly where the pile's bottom card would.
    private func emptyTapZones(
        anchors: [(zone: ZoneID, frame: CGRect)], highlighted: Set<ZoneID>, tableSize: CGSize
    ) -> [(zone: ZoneID, frame: CGRect)] {
        let withPiece = Set(anchors.map(\.zone))
        var wanted: [ZoneID] = input.zoneActions.map(\.zone)
        wanted.append(contentsOf: highlighted)
        var seen: Set<ZoneID> = []
        var result: [(zone: ZoneID, frame: CGRect)] = []
        for zone in wanted where !withPiece.contains(zone) && seen.insert(zone).inserted {
            if let frame = zoneFrame(zone, anchors: anchors, tableSize: tableSize) {
                result.append((zone: zone, frame: frame))
            }
        }
        return result
    }

    /// An invisible, card-sized tap target placed over an empty zone's card slot (R-KLON-1.4, R-KLON-2.3).
    /// It draws nothing (so the felt/placeholder shows through) but is hit-testable, so a click on an empty
    /// stock or an empty legal-target pile reaches `tapZone`. Sits under the pieces in the ZStack; since the
    /// zone is empty there is no piece over it, so the slot receives the click.
    @ViewBuilder
    private func zoneTapSlot(_ zone: ZoneID, at frame: CGRect, cardSize: CGSize) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: cardSize.width, height: cardSize.height)
            .position(x: frame.midX, y: frame.midY)
            .onTapGesture { tapZone(zone) }
    }

    private func smartMove(_ piece: ResolvedPiece) {
        Self.log.debug(
            "smart-move: \(renderKeyLabel(piece.key), privacy: .public) from zone \(piece.zone.name, privacy: .public)"
        )
        _ = interaction.smartMove(piece.key, from: piece.zone, using: input)
    }

    private func tapZoneLog(_ zone: ZoneID, _ outcome: String) {
        Self.log.debug(
            "tap-zone: \(zone.name, privacy: .public) → \(outcome, privacy: .public)")
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
    /// zone is a legal target — place there (R-TABLE-3.4). On a focused ZONE with a non-drag primary
    /// action (draw / recycle / pass), invoke that action first (R-A11Y-2.1).
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
            // If something is selected and this zone is a legal drop, placing wins (finishing a move the
            // player started). Otherwise, if the zone carries a non-drag action (stock draw/recycle,
            // pass), invoke it — this is the keyboard path for actions dragging cannot express.
            if let selection = interaction.selection,
                input.isLegalTarget(zone, for: selection.piece)
            {
                _ = interaction.place(on: zone, using: input)
            } else if let action = KeyboardActivation.action(for: focus, in: input.zoneActions) {
                _ = interaction.performZoneAction(action.id, using: input)
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
    private func zoneFocusRing(at frame: CGRect) -> some View {
        // Same bright ring as a focused piece, drawn on the zone's card slot so an empty pile still shows
        // a visible focus indicator (R-A11Y-2.1).
        RoundedRectangle(cornerRadius: min(frame.width, frame.height) * 0.14, style: .continuous)
            .strokeBorder(Color.yellow, lineWidth: 3)
            .frame(width: frame.width + 6, height: frame.height + 6)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
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

    /// The frames to draw a legal-target highlight on this frame: one per highlighted zone, at that zone's
    /// TOP piece frame (the card you would drop onto), or the empty-slot frame for an empty target pile
    /// (e.g. a King onto an empty tableau — R-KLON-1.4). Drawn on top of the pieces and non-hit-testing so
    /// the "where can this go" feedback is always visible (R-TABLE-3.6).
    private func legalTargetHighlights(
        pieces: [ResolvedPiece], highlighted: Set<ZoneID>,
        anchors: [(zone: ZoneID, frame: CGRect)], tableSize: CGSize
    ) -> [(zone: ZoneID, frame: CGRect)] {
        // The TOP (highest index) piece per zone — the card a drop would land on.
        var topByZone: [ZoneID: ResolvedPiece] = [:]
        for piece in pieces
        where topByZone[piece.zone] == nil || piece.index > topByZone[piece.zone]!.index {
            topByZone[piece.zone] = piece
        }
        var result: [(zone: ZoneID, frame: CGRect)] = []
        for zone in highlighted {
            if let top = topByZone[zone] {
                result.append((zone: zone, frame: top.frame))
            } else if let frame = zoneFrame(zone, anchors: anchors, tableSize: tableSize) {
                // An empty highlighted pile: ring its card slot so the destination still shows.
                result.append((zone: zone, frame: frame))
            }
        }
        return result
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

    /// The frame to ring for a focused zone: its bottom-piece anchor if the zone holds pieces, else the
    /// resolver's empty-zone anchor so an empty pile still rings (R-A11Y-2.1). `nil` if neither resolves.
    private func zoneFrame(
        _ zone: ZoneID, anchors: [(zone: ZoneID, frame: CGRect)], tableSize: CGSize
    ) -> CGRect? {
        if let hit = anchors.first(where: { $0.zone == zone }) {
            return hit.frame
        }
        let ownerSeat = zone.owner.flatMap(seatIndexForOwner)
        return resolver.zoneAnchorFrame(
            layout: layout, zone: zone, tableSize: tableSize,
            ownerSeatIndex: ownerSeat, seatCount: seatCount)
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

    // MARK: - Accessibility: labels + rotors (R-A11Y-1)

    /// Derive the VoiceOver description for a resolved piece from its content and current interaction
    /// state (R-A11Y-1.1). Face-down pieces never leak identity; the local hand carries a position; a
    /// selected piece says "selected"; a piece over a highlighted legal target reads "playable".
    private func accessibilityDescription(
        for piece: ResolvedPiece,
        content: PieceFaceContent,
        isSelected: Bool,
        isLegalTarget: Bool
    ) -> AccessibilityDescription {
        let context = PieceAccessibilityContext(
            isPlayable: isLegalTarget ? true : nil,
            isSelected: isSelected)
        return PieceAccessibility.description(for: content, context: context)
    }

    /// Build the custom rotor model for the current pieces, reusing the same per-piece description so a
    /// rotor entry reads exactly like the element it focuses (R-A11Y-1.2).
    private func rotorModel(pieces: [ResolvedPiece], highlighted: Set<ZoneID>) -> TableRotorModel {
        TableRotorModel.derive(
            pieces: pieces,
            handZones: handZones,
            describe: { piece in
                let content: PieceFaceContent =
                    piece.faceUp ? faceContent(piece.key) : .back
                let isSelected = interaction.selection?.piece == piece.key
                let isLegalTarget = highlighted.contains(piece.zone)
                return accessibilityDescription(
                    for: piece, content: content, isSelected: isSelected,
                    isLegalTarget: isLegalTarget
                ).combinedLabel
            })
    }
}

// MARK: - Rotor application helper (R-A11Y-1.2)

extension View {
    /// Apply every rotor in a `TableRotorModel` as a SwiftUI `.accessibilityRotor`, tying each entry to a
    /// piece view tagged with `.accessibilityRotorEntry(id:in:)` in the same namespace (R-A11Y-1.2). This
    /// gives VoiceOver users a "Hand" and "Piles" rotor to spin directly to those elements.
    @ViewBuilder
    fileprivate func accessibilityRotors(
        _ model: TableRotorModel, in namespace: Namespace.ID
    ) -> some View {
        // Fold each rotor onto the view. `reduce` keeps the number of rotors data-driven while producing a
        // single erased view; SwiftUI merges the rotors it discovers.
        model.rotors.reduce(AnyView(self)) { view, rotor in
            AnyView(
                view.accessibilityRotor(rotor.name) {
                    ForEach(rotor.entries) { entry in
                        AccessibilityRotorEntry(Text(entry.label), id: entry.key, in: namespace)
                    }
                }
            )
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

private extension TableInteractionView {
    static func pieceAccessibilityIdentifier(_ key: RenderKey) -> String {
        switch key {
        case .known(let id): return "table.piece.\(id.raw)"
        case .hidden(let token): return "table.hidden.\(token.opaque)"
        }
    }
}

// MARK: - Logging helpers

/// A short, non-sensitive label for a `RenderKey` for interaction logging (a piece id or a hidden token).
private func renderKeyLabel(_ key: RenderKey) -> String {
    switch key {
    case .known(let id): return "card#\(id.raw)"
    case .hidden(let token): return "hidden#\(token.opaque)"
    }
}
