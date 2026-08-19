import Foundation
import Testing
@testable import DebutCore

private final class MockLaunchAtLoginManager: LaunchAtLoginManaging, @unchecked Sendable {
    var isRegistered = false
    var registerCalls = 0
    var unregisterCalls = 0
    var failure: Error?

    func register() throws {
        registerCalls += 1
        if let failure { throw failure }
        isRegistered = true
    }

    func unregister() throws {
        unregisterCalls += 1
        if let failure { throw failure }
        isRegistered = false
    }
}

private struct StubError: Error {}

@Suite("Launch at login")
struct LaunchAtLoginTests {
    @Test("Enabling registers the login item")
    func enableRegisters() {
        let manager = MockLaunchAtLoginManager()
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        #expect(coordinator.apply(enabled: true) == true)
        #expect(manager.registerCalls == 1)
        #expect(manager.isRegistered)
    }

    @Test("Applying the state the system already reports does nothing")
    func idempotent() {
        let manager = MockLaunchAtLoginManager()
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        coordinator.apply(enabled: true)
        coordinator.apply(enabled: true)

        #expect(manager.registerCalls == 1)
        #expect(manager.unregisterCalls == 0)
    }

    @Test("Disabling unregisters the login item")
    func disableUnregisters() {
        let manager = MockLaunchAtLoginManager()
        manager.isRegistered = true
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        #expect(coordinator.apply(enabled: false) == true)
        #expect(manager.unregisterCalls == 1)
        #expect(manager.isRegistered == false)
    }

    @Test("A registration the system refuses is reported instead of silently swallowed")
    func failureIsReported() {
        let manager = MockLaunchAtLoginManager()
        manager.failure = StubError()
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        #expect(coordinator.apply(enabled: true) == false)
        #expect(manager.registerCalls == 1)
        #expect(manager.isRegistered == false)
    }
}
