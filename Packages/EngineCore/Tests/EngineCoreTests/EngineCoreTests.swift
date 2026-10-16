import Testing
@testable import EngineCore

@Suite("EngineCore scaffold")
struct EngineCoreScaffoldTests {
    @Test("module is wired")
    func moduleName() {
        #expect(EngineCore.moduleName == "EngineCore")
    }
}
