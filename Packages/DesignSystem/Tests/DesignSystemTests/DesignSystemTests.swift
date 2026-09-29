import Testing
@testable import DesignSystem

@Suite("DesignSystem scaffold")
struct DesignSystemScaffoldTests {
    @Test("module is wired")
    func moduleName() {
        #expect(DesignSystem.moduleName == "DesignSystem")
    }
}
