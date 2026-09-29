import Testing
@testable import GamesUI

@Suite("GamesUI scaffold")
struct GamesUIScaffoldTests {
    @Test("module is wired to GamesRules and TableKit")
    func wiredDependencies() {
        #expect(GamesUI.moduleName == "GamesUI")
        #expect(GamesUI.rulesModuleName == "GamesRules")
        #expect(GamesUI.tableModuleName == "TableKit")
    }
}
