// CrazyEightsTableViewModel — app-side session wiring for the real Crazy Eights table.
//
// The model owns one autosaving session and one GamesUI controller. Human buttons and the generic TableKit
// gestures submit through the same controller; the AI receives only its redacted seat view and submits back
// through the same Codable session boundary.

import DesignSystem
import GamesUI
import Observation
import Persistence
import SwiftUI
import TableKit

@MainActor
@Observable
final class CrazyEightsTableViewModel {
    let gameID: String
    let gameTitle: String
    let layout: TableLayout
    let zoneOrder: [ZoneID]
    var settings: AppSettings
    let controller: CrazyEightsTableController

    private let session: AutosaveSession<CrazyEights>
    private let localSeat = SeatID.index(0)
    private let aiSeat = SeatID.index(1)
    private let onQuit: (() -> Void)?
    private var aiTask: Task<Void, Never>?

    var isAIThinking = false
    var isHandComplete = false

    /// The local action strip snapshot. Keeping this as observable App state avoids relying on nested
    /// controller observation when SwiftUI rebuilds the controls after a host transition.
    private(set) var displayedActions: [CrazyEightsAction]

    /// Bumps after every accepted human or AI action so the SwiftUI surface observes the controller's
    /// nested state transition and rebuilds its legal-action strip (R-QA-5.1).
    private(set) var uiRevision = 0

    var driver: AnimationDriver { controller.driver }
    var interactionInput: TableInteractionInput { controller.interactionInput }
    var latestState: CrazyEightsState { controller.latestState }
    var isSubmitting: Bool { controller.isSubmitting }

    init(
        session: AutosaveSession<CrazyEights>,
        initialState: CrazyEightsState,
        initialView: PlayerView,
        gameTitle: String,
        settings: AppSettings,
        onQuit: (() -> Void)? = nil
    ) {
        self.session = session
        self.gameID = CrazyEights.metadata.id
        self.gameTitle = gameTitle
        self.settings = settings
        self.onQuit = onQuit
        self.layout = .crazyEights()
        self.zoneOrder =
            [CrazyEightsZone.stockID, CrazyEightsZone.discardID]
            + (0..<initialState.seatCount).map(CrazyEightsZone.hand)

        let driver = AnimationDriver(
            model: TableRenderModel(playerView: initialView),
            settings: AnimationSettings(
                speed: settings.gameplay.animationSpeed.tableKitSpeed,
                reduceMotion: settings.accessibility.forceReduceMotion))
        self.controller = CrazyEightsTableController(
            seat: localSeat,
            initialState: initialState,
            initialView: initialView,
            driver: driver,
            submit: { action, seat in
                guard let any = try? AnyGameAction(action) else { return nil }
                return try? await session.submit(ActionEnvelope(seat: seat, action: any))
            },
            view: { await session.view(for: .seat(SeatID.index(0))) })
        self.displayedActions = []

        controller.onAccepted = { [weak self] state in
            self?.handleAccepted(state)
        }
        controller.onSettled = { [weak self] in
            self?.refreshActionStrip()
        }
        self.isHandComplete = CrazyEights().isTerminal(initialState)
        self.displayedActions = self.isHandComplete ? [] : controller.localLegalActions
    }

    var preferredTheme: TableTheme {
        TableTheme.theme(id: settings.appearance.themePackID) ?? .default
    }

    var preferredDeckStyle: DeckStyle {
        DeckStyle.style(id: settings.appearance.deckStyleID) ?? .default
    }

    var cardSizeScale: CardSizeScale { settings.appearance.cardSize.scale }

    var caption: String? { controller.caption }

    /// Only local-turn actions are rendered as enabled controls; AI turns expose the thinking status instead.
    var localActions: [CrazyEightsAction] {
        guard latestState.turn == localSeat, !isHandComplete, !isSubmitting else { return [] }
        return displayedActions
    }

    var statusText: String {
        if let caption { return caption }
        if isHandComplete { return "Hand complete" }
        if isAIThinking { return "Opponent thinking…" }
        return latestState.turn == localSeat ? "Your turn" : "Waiting for opponent"
    }

    func seatIndex(for seat: SeatID) -> Int? { latestState.seatIndex(of: seat) }

    func faceContent(_ key: RenderKey) -> PieceFaceContent { controller.faceContent(key) }

    func setTheme(_ id: String) {
        guard TableTheme.theme(id: id) != nil else { return }
        settings.appearance.themePackID = id
    }

    func setDeckStyle(_ id: String) {
        guard DeckStyle.style(id: id) != nil else { return }
        settings.appearance.deckStyleID = id
    }

    func actionLabel(_ action: CrazyEightsAction) -> String {
        switch action {
        case .play(let card): return "Play \(cardLabel(card))"
        case .playEight(let card, let suit):
            return "Play \(cardLabel(card)) as \(suit.rawValue.capitalized)"
        case .draw: return "Draw"
        case .pass: return "Pass"
        }
    }

    func actionIdentifier(_ action: CrazyEightsAction) -> String {
        switch action {
        case .play(let card): return "crazy.play.\(card.raw)"
        case .playEight(let card, let suit):
            return "crazy.play.\(card.raw).\(suit.rawValue)"
        case .draw: return "crazy.draw"
        case .pass: return "crazy.pass"
        }
    }

    func play(_ action: CrazyEightsAction) {
        let result = controller.submit(action)
        if case .success = result {
            // Disable the current action strip immediately while the serialized host submission is in
            // flight; the accepted callback will bump the revision again with the new legal actions.
            displayedActions = []
            uiRevision &+= 1
        }
    }

    func quitToLibrary() {
        aiTask?.cancel()
        aiTask = nil
        onQuit?()
    }

    func startAIIfNeeded() {
        guard aiTask == nil, !isHandComplete, latestState.turn == aiSeat else { return }
        isAIThinking = true
        aiTask = Task { [weak self] in
            await self?.runAIUntilLocalTurn()
            self?.aiTask = nil
            self?.isAIThinking = false
        }
    }

    private func handleAccepted(_ state: CrazyEightsState) {
        uiRevision &+= 1
        isHandComplete = CrazyEights().isTerminal(state)
        displayedActions =
            isHandComplete || state.turn != localSeat ? [] : controller.localLegalActions
        if !isHandComplete { startAIIfNeeded() }
    }

    private func refreshActionStrip() {
        displayedActions =
            isHandComplete || latestState.turn != localSeat ? [] : controller.localLegalActions
        uiRevision &+= 1
    }

    private func runAIUntilLocalTurn() async {
        let game = CrazyEights()
        while !Task.isCancelled, !game.isTerminal(controller.latestState),
            controller.latestState.turn == aiSeat
        {
            let view = await session.view(for: .seat(aiSeat))
            guard
                let any = await CrazyEightsAITier.choose(
                    for: .easy, options: controller.latestState.options, view: view, seat: aiSeat),
                let action = try? any.decode(as: CrazyEightsAction.self)
            else { return }
            _ = controller.submit(action, by: aiSeat)
            await controller.awaitQuiescence()
        }
    }

    private func cardLabel(_ id: PieceID) -> String {
        guard let face = latestState.face(of: id) else { return "card" }
        return PieceAccessibility.cardName(face)
    }
}
