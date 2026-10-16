// KlondikeTableController — the per-window Klondike table controller (R-APP-6.2, R-TABLE-3, R-PERS-1.1).
//
// This is the piece that was previously stranded in `App/Sources/TableViewModel.swift` — a file the Xcode
// project compiles but SwiftPM does NOT (design.md §1), so it was never built, type-checked, or tested by
// `make build test`. The input→resolve→render→session logic lived there untested, and it was WRONG in two
// structural ways the user kept hitting:
//
//   1. The render model drifted from the game. It was seeded from the local seat's redacted view (hidden
//      cards keyed by `.hidden(token)`), then advanced by feeding it the RAW omniscient events from the
//      pure `game.apply` (real `PieceID`s). Nothing emitted `.pieceRevealed`, so a `pieceFlipped(realID)`
//      found no `.known` node and newly exposed tableau cards never turned face-up on screen; a draw's
//      `pieceMoved` created a NEW `.known` waste node while the old `.hidden(token)` stock node lingered
//      (a ghost card). Cards face-up in the real state could stay face-down and unselectable on screen.
//
//   2. Submissions were optimistic and raced. `resolve` returned `.success` immediately and spawned an
//      unawaited `Task { submit }`. Host rejections and thrown errors were dropped silently (the selection
//      cleared, nothing moved — "nothing happens"). Two quick moves could apply their local shadow
//      transitions out of order or skip one on failure, so the shadow state diverged from the host and
//      every subsequent move computed from it was rejected — silently.
//
// This controller fixes both by construction and lives in GamesUI so SwiftPM compiles and tests it on the
// SAME path the app uses (the headless invariant test in GamesUITests drives THIS type against a real
// `GameHost<Klondike>`). It is UI-layer but holds NO Persistence dependency (dependency direction is
// App → GamesUI/Persistence): the App injects `submit`/`view` closures that forward to its `AutosaveSession`.
//
// Single source of truth (R-TABLE-1.1; design.md §2.8/§6). After every ACCEPTED action the controller
// reconciles the `AnimationDriver`'s render model to the host's FRESH redacted view (carried in the
// `ResultEnvelope` or fetched via the `view` closure). Known pieces keep their `RenderKey` and slide via
// matched geometry; a hidden→known reveal crossfades. No ghost nodes, no stale face-down cards — the model
// always equals `TableRenderModel(playerView: host.view(for: localSeat))`.
//
// Serialized submission (R-SESS-1.1; R-TABLE-4.1). A chosen move is validated SYNCHRONOUSLY against the
// shadow state (the adapter derives legal actions), then submitted ONE AT A TIME: while a submission is in
// flight new input is ignored (no racing Tasks). The shadow `latestState` advances only in host-acceptance
// order. On ANY rejection or thrown error the controller surfaces the `RuleViolation` as the non-modal
// caption and RESYNCS its render model (and view) from the host, so it can never stay diverged.

import Foundation
import GamesRules
import TableKit
import os

/// The per-window Klondike table controller: owns the animation driver, the shadow authoritative snapshot,
/// and the serialized submission pipeline that keeps the on-screen model equal to the host's redacted view
/// (R-APP-6.2, R-TABLE-3, R-PERS-1.1).
///
/// `@MainActor @Observable` so a SwiftUI table binds to `driver.model` and `caption`. Construct it with the
/// initial state/view and two closures the owner supplies:
///   • `submit` — forward a Klondike action to the authoritative host (an `AutosaveSession` in the app, a
///     bare `GameHost` in tests) and return its `ResultEnvelope` (or `nil` if there is no host — the DEBUG
///     offline mode, which advances the shadow state directly).
///   • `view` — fetch the current redacted view for the local seat from the host, used to resync after a
///     rejection or when no envelope view is available.
@MainActor
@Observable
public final class KlondikeTableController {

    // MARK: Logging (R-NFR-QUAL.4) — the observability that was missing.

    /// The interaction log. `.notice` for every submitted/accepted/rejected game action (with the action
    /// and any violation code); `.debug` for tap/select/place/zone-action/drag-drop decisions. Interpolated
    /// values are marked `privacy: .public` because piece ids and zone names are not sensitive, so the full
    /// story shows up in Console/sysdiagnose when the user reports "clicking does nothing".
    private static let log = Logger(subsystem: "com.parlor.Parlor", category: "table")

    // MARK: Injected session seam (no Persistence dependency)

    /// Submit a Klondike action to the authoritative host; `nil` return means "no host" (DEBUG offline
    /// mode), in which case the shadow state is the sole authority.
    public typealias Submit = @MainActor (KlondikeAction) async -> ResultEnvelope?
    /// Fetch the current redacted view for the local seat from the host.
    public typealias ViewFetch = @MainActor () async -> PlayerView

    private let submitAction: Submit
    private let fetchView: ViewFetch

    /// Called exactly once after each ACCEPTED action (host-accepted or offline), on the main actor, with
    /// the new authoritative state. This is the NON-looping replacement for a self-re-arming observation:
    /// the owner (the view-model) uses it to check for a win and refresh derived flags once per real
    /// transition, instead of a `withObservationTracking` closure that re-registers itself by reading the
    /// same state it reacts to (an observation loop that re-fires on every accept). `nil` when the owner
    /// does not need acceptance callbacks.
    public var onAccepted: (@MainActor (KlondikeState) -> Void)?

    /// Regression-guard switch (internal, test-only): when true, reproduce the ORIGINAL broken behavior —
    /// enqueue the RAW omniscient events from `game.apply` into the driver and NEVER reconcile to the host
    /// view. The headless invariant test flips this on in one case to prove the render-model-equals-host
    /// invariant is non-vacuous: with the old path it DIVERGES (the test fails), with the real path it
    /// holds. Defaults to `false` and is never set by the app; it exists only so the bug can never silently
    /// come back without a test noticing.
    var legacyBrokenMode = false

    // MARK: State

    /// The game definition (pure), used to derive legal actions / smart destinations and, in the offline
    /// mode, to advance the shadow state.
    private let game = Klondike()

    /// The latest authoritative Klondike snapshot (the "shadow state"). Advanced only in host-acceptance
    /// order; resynced from the host after any rejection. Private — the table sees only the render model.
    public private(set) var latestState: KlondikeState

    /// The latest redacted view for the local seat. Kept so the HUD and face map read current faces.
    public private(set) var latestView: PlayerView

    /// The animation driver whose `model` the table draws. Reconciled to the host view after each accept.
    public let driver: AnimationDriver

    /// The current non-modal caption (an illegal-move reason), or `nil`. The table renders this; it is set
    /// on a rejection and cleared on the next accepted action (R-TABLE-4.1).
    public private(set) var caption: String?

    /// Whether a submission is currently in flight. While true, new input is ignored so submissions never
    /// race (one action at a time, applied in host-acceptance order).
    public private(set) var isSubmitting = false

    /// A handle to the in-flight submission `Task`, so callers (and the headless test) can await the host
    /// round-trip deterministically. `nil` when idle. Awaiting it is how a test drives the controller
    /// through the exact async path the app uses and then checks the invariant.
    private var inFlight: Task<Void, Never>?

    /// A local shadow history used only to reconcile the render snapshot after the host performs an
    /// unlimited-undo rewind. The host remains authoritative; these values never cross its boundary.
    private var stateHistory: [KlondikeState] = []
    private var redoStateHistory: [KlondikeState] = []

    /// The number of accepted actions this controller has started submitting (incremented once per
    /// `beginSubmission`, i.e. per action that passes synchronous validation and the in-flight gate). This
    /// is the regression guard for the auto-resubmit loop (the "cards move themselves" bug): a SINGLE user
    /// gesture must produce EXACTLY ONE submission. The headless test drives one move, awaits quiescence,
    /// and asserts this stays `1` — it was unbounded while a view re-evaluation (the right-click explainer
    /// probing `resolve`) re-drove submissions with no user input. Not reset by the app; tests read it.
    public private(set) var submissionCount = 0

    /// Await the current submission (if any) to completion — the deterministic quiescence point for tests
    /// and for callers that want to chain moves. After this returns, `isSubmitting` is `false` and the
    /// render model has been reconciled to the host's latest view.
    public func awaitQuiescence() async {
        // Submissions are serial (the `isSubmitting` gate rejects input while one is in flight), so there is
        // at most one task to await; awaiting it drains the current submission to its `defer` cleanup.
        if let task = inFlight { await task.value }
    }

    // MARK: Init

    /// Build a controller.
    ///
    /// - Parameters:
    ///   - initialState: the current authoritative Klondike state (from the freshly started/resumed host).
    ///   - initialView: the current redacted local-seat view.
    ///   - driver: the animation driver (its model should already be seeded from `initialView`).
    ///   - submit: forward an action to the host; `nil` return = offline mode (advance shadow directly).
    ///   - view: fetch the current local-seat redacted view from the host.
    public init(
        initialState: KlondikeState,
        initialView: PlayerView,
        driver: AnimationDriver,
        submit: @escaping Submit,
        view: @escaping ViewFetch
    ) {
        self.latestState = initialState
        self.latestView = initialView
        self.driver = driver
        self.submitAction = submit
        self.fetchView = view
    }

    // MARK: Interaction seam for the table (R-TABLE-3)

    /// The interaction seam the generic `TableInteractionView` reads for the current frame: Klondike's legal
    /// targets + smart-move closure + stock zone actions, plus the `resolve`/`performAction` closures that
    /// submit a chosen move/action through this controller.
    ///
    /// Rebuilt from the current shadow state each time the table refreshes, matching TableKit's per-frame
    /// model. `resolve`/`performAction` hop onto the main actor (the controller is `@MainActor`) and kick off
    /// a serialized submission; they report `.success` to TableKit for a move that PASSES synchronous
    /// validation (so the selection clears) and `.failure` for one that cannot possibly be legal, so the
    /// obviously-illegal case still springs back without troubling the host.
    public var interactionInput: TableInteractionInput {
        KlondikeTableAdapter.interactionInput(
            for: game, in: latestState,
            resolve: { [weak self] move in
                guard let self else {
                    return .failure(RuleViolation(code: "gone", reason: "No game."))
                }
                return MainActor.assumeIsolated { self.resolve(move) }
            },
            performAction: { [weak self] action in
                guard let self else {
                    return .failure(RuleViolation(code: "gone", reason: "No game."))
                }
                return MainActor.assumeIsolated { self.resolveAction(action) }
            })
    }

    /// How to draw a given render key (known face vs back) — from the current view's face map.
    public func faceContent(_ key: RenderKey) -> PieceFaceContent {
        latestView.faceContentMap()[key] ?? .back
    }

    // MARK: Resolve (synchronous validation + serialized submit)

    /// Resolve a chosen drag/place `TableMove`: map it to a Klondike action, validate it synchronously
    /// against the shadow state, and (if valid and nothing is in flight) submit it serially (R-TABLE-3,
    /// R-TABLE-4.1).
    ///
    /// Returns the `MoveResult` TableKit uses to clear the selection (success) or spring the piece back
    /// (failure). A move that maps to no legal action, or arrives while another submission is in flight,
    /// returns `.failure` so the piece springs back rather than appearing to vanish.
    @discardableResult
    public func resolve(_ move: TableMove) -> MoveResult {
        guard let action = KlondikeTableAdapter.action(for: move, in: latestState) else {
            Self.log.debug(
                "place rejected (no legal action): piece \(renderKeyLabel(move.piece), privacy: .public) → zone \(move.destination.name, privacy: .public)"
            )
            caption = "That move isn't available."
            return .failure(
                RuleViolation(code: "no-such-move", reason: "That move isn't available."))
        }
        return beginSubmission(of: action, springBack: move.piece)
    }

    /// Resolve a non-drag Klondike action (stock draw / recycle) from a tap or key on the stock zone
    /// (R-KLON-2.1, R-KLON-2.3; R-A11Y-2.1). Validated against the current legal actions, then submitted
    /// serially like `resolve`.
    @discardableResult
    public func resolveAction(_ action: KlondikeAction) -> MoveResult {
        return beginSubmission(of: action, springBack: nil)
    }

    /// Validate `action` synchronously against the shadow state's legal actions, then kick off a serialized
    /// submission. Pure synchronous verdict; the async host round-trip happens in a single owned `Task` that
    /// no other submission can interleave with (`isSubmitting` gate).
    private func beginSubmission(of action: KlondikeAction, springBack: RenderKey?) -> MoveResult {
        // Ignore input while a submission is in flight — this is what stops racing Tasks from applying
        // shadow transitions out of order or skipping one on failure (the silent-divergence bug).
        guard !isSubmitting else {
            Self.log.debug(
                "input ignored (submission in flight): action \(String(describing: action), privacy: .public)"
            )
            return .failure(RuleViolation(code: "busy", reason: "One move at a time."))
        }
        // Synchronous legality check against the shadow state — the adapter already derives legal actions.
        guard game.legalActions(for: klondikeSeat, in: latestState).contains(action) else {
            Self.log.notice(
                "rejected (not legal in shadow state): action \(String(describing: action), privacy: .public)"
            )
            caption = "That move isn't available."
            return .failure(RuleViolation(code: "illegal", reason: "That move isn't available."))
        }

        isSubmitting = true
        submissionCount += 1
        Self.log.notice(
            "submitted: action \(String(describing: action), privacy: .public)")
        inFlight = Task { [weak self] in
            await self?.performSubmission(of: action)
        }
        return .success(())
    }

    /// The owned, serialized submission: forward to the host, then on acceptance advance the shadow state
    /// and reconcile the render model to the host's fresh view; on rejection surface the caption and resync
    /// from the host. Exactly one of these runs at a time (guarded by `isSubmitting`).
    private func performSubmission(of action: KlondikeAction) async {
        var accepted = false
        defer {
            isSubmitting = false
            inFlight = nil
            // Notify the owner ONCE per accepted transition (win check / derived flags). This runs after
            // the shadow state and render model have been reconciled, and it is a plain callback — it does
            // NOT read observable state to re-arm itself, so it cannot form the observation loop the old
            // self-re-registering win-watch did.
            if accepted { onAccepted?(latestState) }
        }

        let envelope = await submitAction(action)

        switch envelope {
        case .some(.rejected(let violation)):
            // The host rejected: state is unchanged there. Surface the reason and RESYNC our render model
            // from the host so we can never stay diverged (R-TABLE-4.1, R-SESS-1.2).
            Self.log.notice(
                "rejected by host: action \(String(describing: action), privacy: .public) — \(violation.code, privacy: .public): \(violation.reason, privacy: .public)"
            )
            caption = violation.reason
            await resyncFromHost()

        case .some(.accepted(let events, let views)):
            // Accepted: advance the shadow state with the pure transition (the host vends no raw state), in
            // host-acceptance order, then reconcile the render model to the host's FRESH redacted view.
            Self.log.notice(
                "accepted: action \(String(describing: action), privacy: .public), \(events.count, privacy: .public) event(s)"
            )
            if legacyBrokenMode {
                // OLD BROKEN PATH (bug-demo only): feed the raw omniscient events to the driver and never
                // reconcile. This recreates the ghost/stale-face-down divergence the invariant must catch.
                if case .success(let (_, rawEvents)) = game.apply(
                    action, by: klondikeSeat, to: latestState)
                {
                    driver.enqueue(rawEvents)
                }
                applyToShadow(action)
                return
            }
            applyToShadow(action)
            // Prefer the local seat's view carried in the envelope; fall back to fetching it.
            if let view = Self.localSeatView(in: views) {
                latestView = view
            } else {
                latestView = await fetchView()
            }
            caption = nil
            driver.reconcile(to: latestView)
            accepted = true

        case .none:
            // Offline mode (no host): the shadow state is the sole authority. Advance it and reconcile to
            // the view we derive from it — same render path, no autosave layer (R-A11Y-5.1).
            Self.log.notice(
                "accepted (offline): action \(String(describing: action), privacy: .public)")
            applyToShadow(action)
            latestView = game.redactedView(of: latestState, for: .seat(klondikeSeat))
            caption = nil
            driver.reconcile(to: latestView)
            accepted = true
        }
    }

    /// Advance the shadow state by applying `action` through the pure game transition. The action was
    /// validated as legal before submission and accepted by the host, so a failure here would mean the
    /// shadow had already diverged — in that case we leave the state as-is and the next `resyncFromHost`
    /// (or the envelope view we reconcile to) corrects the display.
    private func applyToShadow(_ action: KlondikeAction) {
        if case .success(let (next, _)) = game.apply(action, by: klondikeSeat, to: latestState) {
            stateHistory.append(latestState)
            redoStateHistory.removeAll(keepingCapacity: false)
            latestState = next
        } else {
            Self.log.error(
                "shadow apply disagreed with host for action \(String(describing: action), privacy: .public) — will resync"
            )
        }
    }

    /// Resync the render model (and view) from the host after a rejection, so the on-screen board returns to
    /// exactly what the host says the local seat can see (R-SESS-1.2). The shadow STATE is left untouched by
    /// a rejection because the host did not mutate — but we refresh the view/render so a spring-back lands on
    /// the authoritative frame.
    private func resyncFromHost() async {
        latestView = await fetchView()
        driver.reconcile(to: latestView)
    }

    /// Public resync entry point: refresh the render model (and view) from the host, e.g. after a
    /// session-level undo/redo so the table lands on exactly the host's authoritative frame (R-SESS-1.2).
    public func resyncFromHostPublic() async {
        await resyncFromHost()
    }

    // MARK: Helpers

    /// Whether the local shadow has a previous accepted state to restore after a host undo.
    public var hasUndoState: Bool { !stateHistory.isEmpty }
    /// Whether the local shadow has a state to restore after a host redo.
    public var hasRedoState: Bool { !redoStateHistory.isEmpty }

    /// Adopt the state immediately before the most recent accepted action after the host has confirmed its
    /// undo. The caller then fetches the fresh redacted view and reconciles the renderer.
    @discardableResult
    public func adoptUndoState() -> Bool {
        guard let previous = stateHistory.popLast() else { return false }
        redoStateHistory.append(latestState)
        latestState = previous
        return true
    }

    /// Adopt the state most recently removed by an undo after the host has confirmed its redo.
    @discardableResult
    public func adoptRedoState() -> Bool {
        guard let next = redoStateHistory.popLast() else { return false }
        stateHistory.append(latestState)
        latestState = next
        return true
    }

    /// Fast-forward the current animation (Space/Return / click; R-TABLE-5.1).
    public func fastForwardOrConfirm() { driver.fastForward() }

    /// The redacted view for the local Klondike seat carried in an accepted envelope's `views`, or `nil`.
    ///
    /// The host addresses an accepted action to every seat plus the spectator (GameHost.viewsForAllViewers):
    /// `views == seats.map { seat view } + [spectator view]`. Klondike seats exactly one seat
    /// (`klondikeSeat`), so the local seat's view is the one whose `viewer == .seat(klondikeSeat)`. Match on
    /// the viewer rather than an index so this stays correct regardless of ordering.
    static func localSeatView(in views: [PlayerView]) -> PlayerView? {
        views.first { $0.viewer == .seat(klondikeSeat) }
    }
}

/// A short, non-sensitive label for a `RenderKey` for logging (piece id or token value).
private func renderKeyLabel(_ key: RenderKey) -> String {
    switch key {
    case .known(let id): return "card#\(id.raw)"
    case .hidden(let token): return "hidden#\(token.opaque)"
    }
}
