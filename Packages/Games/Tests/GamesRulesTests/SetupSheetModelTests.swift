// Tests for the setup-sheet model + builders (R-APP-2.1, R-APP-2.2).

import EngineCore
import Testing

@testable import GamesRules

@Suite("Setup sheet — presets, groups, opponents, remember")
struct SetupSheetModelTests {

    // MARK: - Presets first (R-APP-2.1)

    @Test("presets come from the game's options schema — R-APP-2.1")
    func presetsFromSchema() {
        let sheet = Klondike.setupSheet()
        let schemaNames = Klondike.optionsSchema.presets.map(\.name)
        #expect(sheet.presets.map(\.name) == schemaNames)
        #expect(!sheet.presets.isEmpty)
    }

    // MARK: - Options vs house rules grouped separately (R-APP-2.1)

    @Test("Klondike separates options from house rules, each control explained — R-APP-2.1")
    func klondikeGroups() {
        let sheet = Klondike.setupSheet()
        let options = sheet.optionsGroup
        let house = sheet.houseRulesGroup
        #expect(options != nil)
        #expect(house != nil)

        // Options carry the core variant choices; house rules carry the softer tweaks.
        let optionIDs = Set(options!.controls.map(\.id))
        #expect(optionIDs == ["draw-count", "scoring", "stock-passes", "timed"])
        let houseIDs = Set(house!.controls.map(\.id))
        #expect(houseIDs == ["auto-flip", "auto-move"])

        // Every control has a one-line explanation (R-APP-2.1).
        for group in sheet.groups {
            for control in group.controls {
                #expect(!control.explanation.isEmpty)
                #expect(!control.title.isEmpty)
            }
        }
    }

    @Test("Crazy Eights separates options from house rules — R-APP-2.1")
    func crazyEightsGroups() {
        let sheet = CrazyEights.setupSheet()
        let optionIDs = Set(sheet.optionsGroup!.controls.map(\.id))
        #expect(optionIDs == ["draw-mode", "stock-out", "match-target"])
        #expect(sheet.houseRulesGroup!.controls.map(\.id) == ["action-cards"])
    }

    @Test("controls reflect the supplied options' current values — R-APP-2.1")
    func controlsReflectValues() {
        let opts = KlondikeOptions(drawCount: .three, scoring: .vegas, autoFlip: false)
        let sheet = Klondike.setupSheet(options: opts)
        let draw = sheet.optionsGroup!.controls.first { $0.id == "draw-count" }!
        if case .choice(_, let selected) = draw.kind {
            #expect(selected == "three")
        } else {
            Issue.record("draw-count should be a choice control")
        }
        let autoFlip = sheet.houseRulesGroup!.controls.first { $0.id == "auto-flip" }!
        if case .toggle(let isOn) = autoFlip.kind {
            #expect(isOn == false)
        } else {
            Issue.record("auto-flip should be a toggle control")
        }
    }

    // MARK: - Opponent setup (R-APP-2.2)

    @Test("Klondike is solo — no opponent section — R-APP-2.2")
    func klondikeSolo() {
        let sheet = Klondike.setupSheet()
        #expect(sheet.opponents.supportsOpponents == false)
        #expect(sheet.opponents.opponentCount == 0)
        #expect(sheet.opponents.availablePersonas.isEmpty)
    }

    @Test("Crazy Eights offers opponent count, personas, and difficulty — R-APP-2.2")
    func crazyEightsOpponents() {
        let sheet = CrazyEights.setupSheet(
            options: CrazyEightsOptions(playerCount: 4), difficulty: .hard)
        let opp = sheet.opponents
        #expect(opp.supportsOpponents)
        // 2...5 seats → 1...4 opponents; a human + 3 opponents = 4 players.
        #expect(opp.opponentCountRange == 1...4)
        #expect(opp.opponentCount == 3)
        #expect(opp.selectedPersonaIDs.count == 3)
        #expect(opp.difficulty == .hard)
        #expect(!opp.availablePersonas.isEmpty)
        #expect(opp.availableDifficulties == DifficultyTier.allCases)
    }

    @Test("opponent count clamps into the valid range — R-APP-2.2")
    func opponentCountClamps() {
        // playerCount 2 → 1 opponent (minimum).
        let two = CrazyEights.setupSheet(options: CrazyEightsOptions(playerCount: 2))
        #expect(two.opponents.opponentCount == 1)
        // playerCount 5 → 4 opponents (maximum).
        let five = CrazyEights.setupSheet(options: CrazyEightsOptions(playerCount: 5))
        #expect(five.opponents.opponentCount == 4)
    }

    // MARK: - Remember choices (R-APP-2.2)

    @Test("remember-choices flag defaults off and is settable — R-APP-2.2")
    func rememberChoices() {
        #expect(Klondike.setupSheet().rememberChoices == false)
        #expect(Klondike.setupSheet(rememberChoices: true).rememberChoices == true)
        #expect(CrazyEights.setupSheet(rememberChoices: true).rememberChoices == true)
    }

    // MARK: - Identity

    @Test("sheet carries the game's id and name")
    func sheetIdentity() {
        #expect(Klondike.setupSheet().gameID == "klondike")
        #expect(Klondike.setupSheet().gameName == "Klondike")
        #expect(CrazyEights.setupSheet().gameID == "crazy-eights")
    }
}
