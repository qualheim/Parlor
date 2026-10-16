import EngineCore
import GamesRules
import Testing

@testable import Persistence

@Suite("Klondike autosave resume")
struct KlondikeAutosaveTests {
    @Test("a stock draw resumes from the autosaved action log")
    func stockDrawResumes() async throws {
        let game = Klondike()
        let seat = klondikeSeat
        let options = KlondikeOptions()
        let store = InMemorySaveStore()
        let session = try await AutosaveSession<Klondike>.start(
            game: game,
            options: options,
            seats: [SavedSeat(id: seat, profile: .defaultLocalHuman())],
            match: Match(dealer: seat, target: .openEnded),
            seed: 2024,
            store: store,
            saveID: .game(Klondike.metadata.id))

        let result = try await session.submit(
            ActionEnvelope(
                seat: seat,
                action: try AnyGameAction(KlondikeAction.drawFromStock)))
        guard result.isAccepted else {
            Issue.record("the stock draw was rejected")
            return
        }

        let savedData = try #require(try store.read(.game(Klondike.metadata.id)))
        let saved = try SaveCodec().decode(
            SaveDocument<KlondikeOptions>.self, from: savedData)
        let savedAction = try #require(
            try saved.actionLog.first?.action.decode(as: KlondikeAction.self))
        #expect(savedAction == .drawFromStock)
        let replayStart = game.initialState(
            options: saved.options, seed: try #require(saved.match.handSeeds.last))
        guard
            case .success(let (replayedState, _)) = game.apply(
                .drawFromStock, by: seat, to: replayStart)
        else {
            Issue.record("the draw could not be replayed from the saved seed")
            return
        }
        let replayHash = try StateHash.canonical(replayedState)
        let savedHash = try #require(saved.actionLog.first?.resultingStateHash)
        let liveHash = try #require(await session.host.lastStateHash)
        #expect(saved.match.handSeeds.last == 2024)
        #expect(saved.options == options)
        #expect(liveHash == savedHash, "the live host hash must be the saved hash")
        #expect(replayHash == savedHash, "the saved draw hash must match a deterministic replay")

        let resumed = await AutosaveSession<Klondike>.resume(
            game: game, store: store, saveID: .game(Klondike.metadata.id))
        guard case .success(let restored) = resumed else {
            Issue.record("resume failed: \(String(describing: resumed))")
            return
        }

        #expect(await restored.host.logCount == 1)
        let view = await restored.view(for: .seat(seat))
        #expect(view.zones.contains { $0.id == KlondikeZone.wasteID && !$0.pieces.isEmpty })
    }
}
