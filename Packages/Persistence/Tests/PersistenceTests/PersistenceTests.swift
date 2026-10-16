import Testing
@testable import Persistence

@Suite("Persistence scaffold")
struct PersistenceScaffoldTests {
    @Test("module is wired to EngineCore")
    func wiredToEngine() {
        #expect(Persistence.moduleName == "Persistence")
        #expect(Persistence.engineModuleName == "EngineCore")
    }
}
