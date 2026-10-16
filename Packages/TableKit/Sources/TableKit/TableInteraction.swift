// TableInteraction — the game-agnostic INPUT SEAM for the generic table (R-TABLE-3, R-TABLE-4.1).
//
// TableKit renders and drives input for ANY game with no per-game input code (R-TABLE-1.2 spirit). But
// TableKit does not know game rules and MUST NOT import GamesRules or reach authoritative state
// (R-SESS-1.2): so which moves are legal, what a piece's "smart" auto-destination is, and whether a
// given attempt is accepted or rejected all arrive as DATA / CLOSURES supplied by the host. This file
// defines that seam:
//
//   • `TableMove`         — one generic move: a render key (the piece) leaving a source zone for a
//                           destination zone. TableKit expresses every input path as a `TableMove`.
//   • `MoveTarget`        — a legal destination for a given piece, as the host derived it from the
//                           viewer's `legalActions` (R-TABLE-3.6). A list of these is all TableKit needs
//                           to highlight legal targets and validate a place/drop.
//   • `TableInteractionInput` — the per-frame data the interaction model reads: the resolved pieces and
//                           the legal-move list, plus the closures the host provides to attempt a move
//                           (`resolve`), name a smart destination (`smartTarget`), and explain why a
//                           piece cannot move (`explain`).
//
// The host (a game's UI adapter, wired in a later task — Klondike in its own module) maps its concrete
// `AnyGameAction` legal actions into `[MoveTarget]`, provides `resolve` that submits the chosen move to
// the `GameHost` and returns `.success` or the `RuleViolation`, and — optionally — a `smartTarget` and
// an `explain` hook. TableKit stays generic.

import EngineCore
import Foundation

// MARK: - TableMove (R-TABLE-3.1, R-TABLE-3.2, R-TABLE-3.3)

/// One generic move the table is attempting: the piece (by its stable `RenderKey`) leaving `source` for
/// `destination` (R-TABLE-3.1/3.2/3.3).
///
/// Every input path — drag-drop, click-to-place, double-click smart-move, keyboard place — produces one
/// of these, so the host sees a single uniform shape regardless of how the player expressed the move. A
/// move over a *run* (a movable face-up sequence, R-KLON-1.3) is still one `TableMove` for the run's
/// LEADING piece; the host resolves the whole run from that lead when it applies the move (the run's
/// membership is a game-rules concern, not TableKit's).
public struct TableMove: Sendable, Hashable {
    /// The piece being moved (its stable render identity — the lead piece of a run).
    public let piece: RenderKey
    /// The zone the piece currently sits in.
    public let source: ZoneID
    /// The zone the player is trying to move it to.
    public let destination: ZoneID

    public init(piece: RenderKey, source: ZoneID, destination: ZoneID) {
        self.piece = piece
        self.source = source
        self.destination = destination
    }
}

// MARK: - MoveTarget (R-TABLE-3.6)

/// A legal destination for a given piece, as derived by the host from the viewer's `legalActions`
/// (R-TABLE-3.6).
///
/// TableKit does not compute legality; the host translates each of its game's legal actions that "moves
/// piece P to zone Z" into one of these. TableKit uses the set to (a) highlight legal target zones while
/// a piece is selected/dragged/focused (R-TABLE-3.6) and (b) validate a place/drop before asking the host
/// to apply it. `piece` is the lead piece's render key; `destination` is the zone it may legally enter.
public struct MoveTarget: Sendable, Hashable {
    /// The piece (lead render key) this legal target applies to.
    public let piece: RenderKey
    /// A zone the piece may legally move to.
    public let destination: ZoneID

    public init(piece: RenderKey, destination: ZoneID) {
        self.piece = piece
        self.destination = destination
    }
}

// MARK: - Move outcome

/// The result of asking the host to attempt a `TableMove`: either it was accepted, or it was rejected
/// with a typed `RuleViolation` whose `reason` drives the spring-back caption (R-TABLE-4.1, R-ENG-5.4).
public typealias MoveResult = Result<Void, RuleViolation>

// MARK: - Interaction input (the seam)

/// Everything the interaction model needs for one interaction pass: the current legal moves plus the host
/// closures for attempting, smart-targeting, and explaining a move (R-TABLE-3, R-TABLE-4.1).
///
/// This is the SEAM between generic TableKit and a specific game. The host builds one of these from the
/// current `PlayerView` each time the view refreshes:
///   • `legalTargets` — the flat list of (piece → destination) the host derived from `legalActions`;
///   • `resolve`      — submit a chosen `TableMove` to the host and report `.success`/`RuleViolation`;
///   • `smartTarget`  — the preferred auto-destination for a piece on double-click, or `nil` (R-TABLE-3.3);
///   • `explain`      — an optional dedicated "why can't I play this?" hook (R-TABLE-3.5); when absent,
///                      the model falls back to asking `resolve` for the piece's intended move and using
///                      the returned `RuleViolation.reason`.
///
/// All closures are `@Sendable` so the input can be held by a value-type model and used across actors.
public struct TableInteractionInput: Sendable {
    /// The legal (piece → destination) targets for the current view (R-TABLE-3.6).
    public let legalTargets: [MoveTarget]

    /// Attempt a move; returns `.success` or the rejecting `RuleViolation` (R-TABLE-4.1).
    ///
    /// IMPORTANT: `resolve` COMMITS — it submits the move to the authoritative host. It must be called ONLY
    /// from a discrete user gesture (drag-end, click-to-place, double-click smart move, keyboard place).
    /// Never call it from a view-evaluation side effect (e.g. building a context menu): doing so submits a
    /// move with no user input, which — for a piece whose smart destination oscillates between two legal
    /// piles — produces an infinite self-driving move loop. The read-only "would this move be rejected?"
    /// question has its own non-committing closure, `dryRunResolve`.
    public let resolve: @Sendable (TableMove) -> MoveResult

    /// A READ-ONLY validation of a move: returns the same verdict `resolve` would (`.success` if the move
    /// is legal, `.failure(RuleViolation)` if not) WITHOUT submitting anything to the host (R-TABLE-3.5).
    ///
    /// This is what the "why can't I play this?" explainer uses to discover a rejection reason without
    /// moving a card. The host validates against its current authoritative snapshot and returns a verdict;
    /// no state is mutated, nothing is submitted. When a host does not supply one, the default is a
    /// permissive `.success` (no reason to show) — crucially NOT a committing `resolve` call.
    public let dryRunResolve: @Sendable (TableMove) -> MoveResult

    /// The preferred smart destination for a piece on double-click, if the host defines one
    /// (R-TABLE-3.3). `nil` → double-click is a no-op for that piece.
    public let smartTarget: @Sendable (RenderKey) -> ZoneID?

    /// Optional dedicated explainer for the "why can't I play this?" menu (R-TABLE-3.5). When `nil`, the
    /// model derives the explanation from a rejected `resolve` attempt.
    public let explain: (@Sendable (RenderKey) -> RuleViolation?)?

    /// The host-supplied NON-DRAG actions attached to zones, reachable by focusing a zone and pressing
    /// space/return (R-A11Y-2.1). These cover actions dragging cannot express — Klondike stock draw /
    /// recycle, Crazy Eights draw-from-stock or pass. The host derives them from `legalActions`, exactly
    /// as it derives `legalTargets`; TableKit resolves which one the focused zone activates via
    /// `KeyboardActivation` and calls `performZoneAction` with the chosen action's opaque `id`.
    public let zoneActions: [ZoneAction]

    /// Invoke the non-drag zone action with the given opaque `id` (as carried by a `ZoneAction`)
    /// (R-A11Y-2.1). The host maps the id back to a concrete game action and submits it, returning
    /// `.success` or the rejecting `RuleViolation` (so an illegal activation gets the same gentle
    /// feedback as a rejected move, R-TABLE-4.1).
    public let performZoneAction: @Sendable (String) -> MoveResult

    /// Select the choice option with the given opaque `id` from a pending `ChoicePrompt` (e.g. naming a
    /// suit after playing an 8, R-CE-2.\*). The host maps the id back to a concrete action and submits it.
    /// Absent when the game never prompts for a choice.
    public let selectChoice: (@Sendable (String) -> MoveResult)?

    public init(
        legalTargets: [MoveTarget],
        resolve: @escaping @Sendable (TableMove) -> MoveResult,
        dryRunResolve: (@Sendable (TableMove) -> MoveResult)? = nil,
        smartTarget: @escaping @Sendable (RenderKey) -> ZoneID? = { _ in nil },
        explain: (@Sendable (RenderKey) -> RuleViolation?)? = nil,
        zoneActions: [ZoneAction] = [],
        performZoneAction: @escaping @Sendable (String) -> MoveResult = { _ in
            .failure(RuleViolation(code: "no-action", reason: "No action available."))
        },
        selectChoice: (@Sendable (String) -> MoveResult)? = nil
    ) {
        self.legalTargets = legalTargets
        self.resolve = resolve
        // Default to a permissive, NON-committing verdict when no dry-run is supplied. Never fall back to
        // `resolve` here — that is the committing path and must never run off a view evaluation.
        self.dryRunResolve = dryRunResolve ?? { _ in .success(()) }
        self.smartTarget = smartTarget
        self.explain = explain
        self.zoneActions = zoneActions
        self.performZoneAction = performZoneAction
        self.selectChoice = selectChoice
    }

    /// The primary non-drag action offered on `zone`, if any (R-A11Y-2.1). Pure query over `zoneActions`.
    public func zoneAction(for zone: ZoneID) -> ZoneAction? {
        KeyboardActivation.action(for: .zone(zone), in: zoneActions)
    }

    /// The set of zones the given piece may legally move to, per the current legal targets (R-TABLE-3.6).
    ///
    /// This is the pure highlight query: given a piece's render key, return exactly the destinations the
    /// host's legal moves allow — no more, no fewer. TableKit rings/glows precisely these zones while the
    /// piece is selected, dragged, or focused.
    public func legalTargets(for piece: RenderKey) -> [ZoneID] {
        legalTargets.filter { $0.piece == piece }.map(\.destination)
    }

    /// Whether `destination` is a legal target for `piece` under the current legal moves.
    public func isLegalTarget(_ destination: ZoneID, for piece: RenderKey) -> Bool {
        legalTargets.contains { $0.piece == piece && $0.destination == destination }
    }
}
