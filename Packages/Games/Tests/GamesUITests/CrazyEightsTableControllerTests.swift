import EngineCore
import GamesRules
import TableKit
import Testing

@testable import GamesUI

@MainActor
@Suite("Crazy Eights table controller")
struct CrazyEightsTableControllerTests {
    @Test("controller advances a complete hand through the host boundary")
    func advancesCompleteHand() async {
        let game = CrazyEights()
        let options = CrazyEightsOptions(
            playerCount: 2,
            drawMode: .drawOneThenPass,
            stockOut: .endHand,
            matchTarget: 50,
            actionCards: false)
        let seed: UInt64 = 0xCE18_2024
        let host = GameHost(
            game: game,
            options: options,
            seats: [SeatID.index(0), SeatID.index(1)],
            seed: seed)
        let initialState = game.initialState(options: options, seed: seed)
        let initialView = await host.view(for: .seat(SeatID.index(0)))
        let controller = CrazyEightsTableController(
            seat: SeatID.index(0),
            initialState: initialState,
            initialView: initialView,
            driver: AnimationDriver(
                model: TableRenderModel(playerView: initialView), settings: .minimal),
            submit: { action, seat in
                guard let erased = try? AnyGameAction(action) else { return nil }
                return await host.submit(ActionEnvelope(seat: seat, action: erased))
            },
            view: { await host.view(for: .seat(SeatID.index(0))) })

        for _ in 0..<120 where !game.isTerminal(controller.latestState) {
            let seat = controller.latestState.turn
            let view = await host.view(for: .seat(seat))
            guard
                let erased = await CrazyEightsAITier.choose(
                    for: .easy, options: options, view: view, seat: seat),
                let action = try? erased.decode(as: CrazyEightsAction.self)
            else {
                Issue.record("Easy AI returned no decodable action for \(seat).")
                return
            }

            let result = controller.submit(action, by: seat)
            guard case .success = result else {
                Issue.record("Controller rejected the host-legal action \(action).")
                return
            }
            await controller.awaitQuiescence()
            #expect(controller.caption == nil)
        }

        #expect(
            game.isTerminal(controller.latestState),
            "the deterministic full hand should terminate through the controller")
    }
}
