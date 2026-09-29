import Testing
@testable import TableKit

@Suite("TableKit scaffold")
struct TableKitScaffoldTests {
    @Test("module is wired to DesignSystem and EngineCore")
    func wiredDependencies() {
        #expect(TableKit.moduleName == "TableKit")
        #expect(TableKit.designModuleName == "DesignSystem")
        #expect(TableKit.engineModuleName == "EngineCore")
    }
}
