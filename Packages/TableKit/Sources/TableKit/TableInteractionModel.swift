// TableInteractionModel — the pure, testable core of table input (R-TABLE-3, R-TABLE-4.1).
//
// This is the game-agnostic INTERACTION LOGIC that backs all three input paths (drag-drop, click-to-
// place, double-click smart-move) plus keyboard place/cancel, legal-target highlighting, the "why can't
// I play this?" explainer, and the gentle illegal-move feedback. It is a plain value type with NO SwiftUI
// dependency: the interaction-layer view (`TableInteractionView`) is a thin shell that forwards gestures
// into these methods and renders the resulting state. Keeping the logic here — pure and deterministic —
// is what makes selection, highlighting, and illegal feedback exhaustively unit-testable without a
// running UI (design.md §6; the same "pure core, thin view" split as `TableRenderModel`).
//
// The model never decides legality itself: which targets are legal, and whether an attempted move is
// accepted, come from the host through `TableInteractionInput` (see `TableInteraction.swift`). The model
// only orchestrates the interaction state machine around that seam.

import EngineCore
import Foundation

// MARK: - Selection

/// The currently selected/dragged piece and the zone it came from (R-TABLE-3.1, R-TABLE-3.2).
///
/// A single value serves both click-to-select and drag: `isDragging` distinguishes a piece being held
/// mid-drag (highlight targets, follow the cursor) from a piece clicked to select (highlight targets,
/// await a second click). Selecting is idempotent per piece; selecting a different piece replaces it.
public struct TableSelection: Sendable, Hashable {
    /// The selected/dragged piece (its stable render key — the lead piece of a run).
    public let piece: RenderKey
    /// The zone the piece currently sits in (its move source).
    public let source: ZoneID
    /// Whether the piece is being actively dragged (vs. click-selected and resting).
    public var isDragging: Bool

    public init(piece: RenderKey, source: ZoneID, isDragging: Bool = false) {
        self.piece = piece
        self.source = source
        self.isDragging = isDragging
    }
}

// MARK: - Illegal-move feedback (R-TABLE-4.1)

/// Transient feedback for a rejected move: the piece to spring back and the caption to show — NEVER a
/// modal dialog (R-TABLE-4.1).
///
/// When the host rejects an attempt with a `RuleViolation`, the model records one of these. The view
/// reads `springBack` to animate the offending piece back to its origin with a gentle shake, and
/// `caption` (the violation's human-readable `reason`) to show a brief, non-blocking caption. Both clear
/// on the next successful interaction or when explicitly dismissed. A minimal caption bar lives in the
/// interaction view; the full caption/HUD polish is task 5.6.
public struct IllegalMoveFeedback: Sendable, Hashable {
    /// The piece that must spring back to its origin (the attempted move's lead piece).
    public let springBack: RenderKey
    /// The short caption built from `RuleViolation.reason` (R-TABLE-4.1).
    public let caption: String
    /// The stable violation code, for tests and styling (never surfaced as a dialog).
    public let code: String

    public init(springBack: RenderKey, caption: String, code: String) {
        self.springBack = springBack
        self.caption = caption
        self.code = code
    }
}

// MARK: - Placement outcome

/// The result of a place/drop/smart-move attempt, so the view knows what animation to run.
public enum PlacementOutcome: Sendable, Hashable {
    /// The move was accepted; selection cleared, no caption (R-TABLE-4.1: success is silent).
    case accepted(TableMove)
    /// The move was rejected; spring-back + caption were set from the `RuleViolation` (R-TABLE-4.1).
    case rejected(IllegalMoveFeedback)
    /// Nothing was attempted (e.g. the destination was not a legal/known target, or no piece selected).
    case noAttempt
}

// MARK: - Interaction model

/// The pure state machine for table input (R-TABLE-3, R-TABLE-4.1). Holds the current selection and the
/// latest illegal-move feedback; every input path is a method that reads the host seam and returns a
/// `PlacementOutcome`.
///
/// Deliberately value-typed and UI-free: tests drive `select`/`place`/`drop`/`smartMove`/`deselect`
/// directly and assert the resulting selection, produced `TableMove`, and feedback — no SwiftUI needed.
/// The interaction view owns one of these and mutates it in response to gestures.
public struct TableInteractionModel: Sendable, Hashable {
    /// The current selection/drag, or `nil` when nothing is selected.
    public private(set) var selection: TableSelection?

    /// The latest illegal-move feedback, or `nil` when there is none pending (R-TABLE-4.1).
    public private(set) var feedback: IllegalMoveFeedback?

    public init(selection: TableSelection? = nil, feedback: IllegalMoveFeedback? = nil) {
        self.selection = selection
        self.feedback = feedback
    }

    // MARK: Selection (R-TABLE-3.2)

    /// Select a piece resting in `source` (click-to-select), clearing any prior feedback (R-TABLE-3.2).
    ///
    /// Selecting begins a click-to-place interaction: the view then highlights the piece's legal targets
    /// (via `input.legalTargets(for:)`) and awaits a second click on one of them. Re-selecting the same
    /// piece is a no-op beyond clearing feedback; selecting a different piece replaces the selection.
    public mutating func select(_ piece: RenderKey, from source: ZoneID) {
        selection = TableSelection(piece: piece, source: source, isDragging: false)
        feedback = nil
    }

    /// Begin dragging a piece from `source` (R-TABLE-3.1). Same state as `select` but flagged dragging so
    /// the view can follow the cursor and highlight legal drop targets (R-TABLE-3.6).
    public mutating func beginDrag(_ piece: RenderKey, from source: ZoneID) {
        selection = TableSelection(piece: piece, source: source, isDragging: true)
        feedback = nil
    }

    /// Clear the current selection and any pending feedback (e.g. a click on empty felt, or Escape).
    public mutating func deselect() {
        selection = nil
        feedback = nil
    }

    /// Dismiss just the illegal-move caption/spring-back, keeping any selection (the caption auto-hides).
    public mutating func clearFeedback() {
        feedback = nil
    }

    // MARK: Legal-target highlighting (R-TABLE-3.6)

    /// The zones to highlight for the current selection/drag, per the host's legal targets (R-TABLE-3.6).
    ///
    /// Empty when nothing is selected. This is the exact set the view rings/glows while a piece is held or
    /// selected — it comes straight from the seam, so TableKit never guesses legality.
    public func highlightedTargets(_ input: TableInteractionInput) -> [ZoneID] {
        guard let selection else { return [] }
        return input.legalTargets(for: selection.piece)
    }

    // MARK: Place / drop (R-TABLE-3.1, R-TABLE-3.2, R-TABLE-4.1)

    /// Attempt to place the currently selected piece onto `destination` (the second click of click-to-
    /// place, R-TABLE-3.2), or complete a drag by dropping there (R-TABLE-3.1).
    ///
    /// Behaviour:
    ///   • no selection → `.noAttempt`;
    ///   • `destination` is not a legal target for the piece → NO host call; `.noAttempt` (the view simply
    ///     keeps the selection — a click on a non-target zone does not error);
    ///   • `destination` is legal → ask the host to `resolve` the move. On `.success`, selection clears
    ///     and no caption is shown (success is silent, R-TABLE-4.1). On failure, set spring-back + caption
    ///     from the `RuleViolation` and keep the selection so the player can retry (R-TABLE-4.1).
    ///
    /// A destination the seam vetoes at apply-time (legal-looking but rejected by authoritative rules)
    /// still lands in the `.rejected` path, so the gentle feedback covers both "not a target" hardening
    /// and true rule rejections.
    public mutating func place(
        on destination: ZoneID, using input: TableInteractionInput
    ) -> PlacementOutcome {
        guard let selection else { return .noAttempt }
        guard input.isLegalTarget(destination, for: selection.piece) else {
            // Not a legal target: keep the selection, do not bother the host, do not caption.
            return .noAttempt
        }
        let move = TableMove(
            piece: selection.piece, source: selection.source, destination: destination)
        return attempt(move, using: input)
    }

    /// Drop the dragged piece on `destination` (R-TABLE-3.1). Alias of `place(on:using:)` — a drop is the
    /// same attempt as the second click of click-to-place, so both paths share one code path and one set
    /// of tests.
    public mutating func drop(
        on destination: ZoneID, using input: TableInteractionInput
    ) -> PlacementOutcome {
        place(on: destination, using: input)
    }

    // MARK: Smart move (R-TABLE-3.3)

    /// Double-click "smart move": attempt the host's preferred destination for `piece`, if any
    /// (R-TABLE-3.3).
    ///
    /// The host supplies the smart destination through the seam (`input.smartTarget`) — TableKit does not
    /// know it is, say, a foundation. If the host gives a destination, the model attempts that move (and
    /// applies the same success/spring-back handling as a normal place). If the host returns `nil`, the
    /// double-click is a no-op (`.noAttempt`) and selection is left as-is.
    public mutating func smartMove(
        _ piece: RenderKey, from source: ZoneID, using input: TableInteractionInput
    ) -> PlacementOutcome {
        guard let destination = input.smartTarget(piece) else { return .noAttempt }
        let move = TableMove(piece: piece, source: source, destination: destination)
        return attempt(move, using: input)
    }

    // MARK: Why can't I play this? (R-TABLE-3.5)

    /// Build the "why can't I play this?" explanation for `piece` in `source` (R-TABLE-3.5).
    ///
    /// Prefers the host's dedicated `explain` hook when provided; otherwise falls back to asking the seam
    /// to `resolve` the piece's intended (smart) move and surfacing the returned `RuleViolation.reason`.
    /// The view knows the piece's current zone, so it passes `source` explicitly. Returns `nil` when the
    /// piece actually *can* be played (no violation to explain) or when there is no intended move to
    /// evaluate. This is a pure QUERY — it does not mutate selection or feedback, and the fallback
    /// `resolve` is consulted only for its rejection reason, never to commit a move on success.
    public func explanation(
        for piece: RenderKey, from source: ZoneID, using input: TableInteractionInput
    ) -> RuleViolation? {
        if let explain = input.explain {
            return explain(piece)
        }
        // Fallback: probe the intended (smart) move; a rejection carries the reason to show.
        guard let destination = input.smartTarget(piece) else { return nil }
        let move = TableMove(piece: piece, source: source, destination: destination)
        if case .failure(let violation) = input.resolve(move) {
            return violation
        }
        return nil
    }

    // MARK: - Internals

    /// Ask the host to apply `move`; update selection/feedback and return the outcome (R-TABLE-4.1).
    private mutating func attempt(
        _ move: TableMove, using input: TableInteractionInput
    ) -> PlacementOutcome {
        switch input.resolve(move) {
        case .success:
            // Success is silent: clear selection and any prior caption (R-TABLE-4.1).
            selection = nil
            feedback = nil
            return .accepted(move)
        case .failure(let violation):
            // Gentle feedback: spring the piece back and caption the reason — no modal (R-TABLE-4.1).
            let fb = IllegalMoveFeedback(
                springBack: move.piece, caption: violation.reason, code: violation.code)
            feedback = fb
            return .rejected(fb)
        }
    }
}
