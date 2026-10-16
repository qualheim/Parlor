// CrazyEightsTableController — the UI-layer host bridge for a local Crazy Eights seat.
//
// The controller mirrors the Klondike controller's boundary: it owns only a redacted render snapshot and a
// shadow rules snapshot, serializes submissions, reconciles from the host's fresh local view, and never
// exposes or mutates the host's authoritative state. AI turns use the same submit seam from the app layer.

import Foundation
import GamesRules
import Observation
import TableKit

/// The per-table Crazy Eights controller. The App injects an autosaving session through `submit` and
/// `view`; GamesUI itself remains independent of Persistence.
@MainActor
@Observable
public final class CrazyEightsTableController {
    public typealias Submit = @MainActor (CrazyEightsAction, SeatID) async -> ResultEnvelope?
    public typealias ViewFetch = @MainActor () async -> PlayerView

    private let game = CrazyEights()
    private let seat: SeatID
    private let submitAction: Submit
    private let fetchView: ViewFetch

    public private(set) var latestState: CrazyEightsState
    public private(set) var latestView: PlayerView
    public let driver: AnimationDriver
    public private(set) var caption: String?
    public private(set) var isSubmitting = false
    public private(set) var submissionCount = 0
    private var inFlight: Task<Void, Never>?

    /// Called once after an accepted action, after the render model has reconciled to the host view.
    public var onAccepted: (@MainActor (CrazyEightsState) -> Void)?

    /// Called after every serialized submission finishes, whether the host accepted or rejected it. The App
    /// uses this to refresh its observable action strip after a rejection as well as an acceptance.
    public var onSettled: (@MainActor () -> Void)?

    public init(
        seat: SeatID,
        initialState: CrazyEightsState,
        initialView: PlayerView,
        driver: AnimationDriver,
        submit: @escaping Submit,
        view: @escaping ViewFetch
    ) {
        self.seat = seat
        self.latestState = initialState
        self.latestView = initialView
        self.driver = driver
        self.submitAction = submit
        self.fetchView = view
    }

    /// The generic TableKit interaction seam for the local human seat.
    public var interactionInput: TableInteractionInput {
        CrazyEightsTableAdapter.interactionInput(
            for: game,
            in: latestState,
            seat: seat,
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
                return MainActor.assumeIsolated { self.submit(action) }
            })
    }

    /// Draw the current local hand's visible faces from the redacted view.
    public func faceContent(_ key: RenderKey) -> PieceFaceContent {
        latestView.faceContentMap()[key] ?? .back
    }

    /// Submit a legal local or AI action through the same serialized host path.
    @discardableResult
    public func submit(_ action: CrazyEightsAction, by actingSeat: SeatID? = nil) -> MoveResult {
        let actor = actingSeat ?? seat
        guard !isSubmitting else {
            return .failure(RuleViolation(code: "busy", reason: "One move at a time."))
        }
        guard game.legalActions(for: actor, in: latestState).contains(action) else {
            caption = "That action isn't available."
            return .failure(
                RuleViolation(code: "illegal", reason: "That action isn't available."))
        }
        isSubmitting = true
        submissionCount += 1
        inFlight = Task { [weak self] in
            await self?.performSubmission(of: action, by: actor)
        }
        return .success(())
    }

    /// Resolve a generic card move into the first matching concrete Crazy Eights action.
    @discardableResult
    public func resolve(_ move: TableMove) -> MoveResult {
        guard
            let action = CrazyEightsTableAdapter.action(
                for: move, in: latestState, seat: seat)
        else {
            let violation = RuleViolation(
                code: "no-such-move",
                reason: "That card cannot be played on the current discard.")
            caption = violation.reason
            return .failure(violation)
        }
        return submit(action)
    }

    /// Await the current host round-trip. This is used by the AI loop and deterministic UI support so a
    /// following action never races a previous one.
    public func awaitQuiescence() async {
        if let inFlight { await inFlight.value }
    }

    /// Whether the local hand has ended.
    public var isTerminal: Bool { game.isTerminal(latestState) }

    /// The current legal actions for the local seat, used by the accessible action strip in the app shell.
    public var localLegalActions: [CrazyEightsAction] {
        game.legalActions(for: seat, in: latestState)
    }

    private func performSubmission(of action: CrazyEightsAction, by actingSeat: SeatID) async {
        var accepted = false
        defer {
            isSubmitting = false
            inFlight = nil
            if accepted { onAccepted?(latestState) }
            onSettled?()
        }

        let envelope = await submitAction(action, actingSeat)
        switch envelope {
        case .some(.rejected(let violation)):
            caption = violation.reason
            latestView = await fetchView()
            driver.reconcile(to: latestView)
        case .some(.accepted(_, let views)):
            applyToShadow(action, by: actingSeat)
            if let local = Self.localView(in: views, seat: seat) {
                latestView = local
            } else {
                latestView = await fetchView()
            }
            caption = nil
            driver.reconcile(to: latestView)
            accepted = true
        case .none:
            // Offline mode is useful for deterministic previews and follows the same local render path.
            applyToShadow(action, by: actingSeat)
            latestView = game.redactedView(of: latestState, for: .seat(seat))
            caption = nil
            driver.reconcile(to: latestView)
            accepted = true
        }
    }

    private func applyToShadow(_ action: CrazyEightsAction, by actingSeat: SeatID) {
        guard
            case .success(let (next, _)) = game.apply(
                action, by: actingSeat, to: latestState)
        else {
            caption = "The hand changed before that action was applied."
            return
        }
        latestState = next
    }

    private static func localView(in views: [PlayerView], seat: SeatID) -> PlayerView? {
        views.first { $0.viewer == .seat(seat) }
    }
}
