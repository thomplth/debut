import Testing
@testable import DebutCore

@Suite("DebutCore basics")
struct DebutCoreTests {
    @Test("Version is set")
    func versionExists() {
        #expect(!DebutCore.version.isEmpty)
    }
}
