import Testing
@testable import AIKit

@Suite("AIKit scaffold")
struct AIKitScaffoldTests {
    @Test("module is wired to EngineCore")
    func wiredToEngine() {
        #expect(AIKit.moduleName == "AIKit")
        #expect(AIKit.engineModuleName == "EngineCore")
    }
}
