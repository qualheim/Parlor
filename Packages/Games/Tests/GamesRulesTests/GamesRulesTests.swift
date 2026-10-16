import Testing
@testable import GamesRules

@Suite("GamesRules scaffold")
struct GamesRulesScaffoldTests {
    @Test("module is wired to AIKit and EngineCore")
    func wiredDependencies() {
        #expect(GamesRules.moduleName == "GamesRules")
        #expect(GamesRules.aiModuleName == "AIKit")
        #expect(GamesRules.engineModuleName == "EngineCore")
    }
}
