import Testing
import EngineCore
import AIKit
import GamesRules

@Suite("SimulationCLI scaffold")
struct SimulationCLIScaffoldTests {
    // The CLI target is an executable; its logic is exercised via the pure modules it wires.
    @Test("wired modules are reachable")
    func wiredModules() {
        #expect(EngineCore.moduleName == "EngineCore")
        #expect(AIKit.moduleName == "AIKit")
        #expect(GamesRules.moduleName == "GamesRules")
    }
}
