import AppKit
import Foundation
import Testing
@testable import DebutCore

private final class MockActivationPolicyManager: ActivationPolicyManaging, @unchecked Sendable {
    var policy: NSApplication.ActivationPolicy = .accessory
    var setCalls: [NSApplication.ActivationPolicy] = []
    var refuses = false

    func setPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        setCalls.append(policy)
        guard !refuses else { return false }
        self.policy = policy
        return true
    }
}

@Suite("Activation policy")
struct ActivationPolicyTests {
    @Test("Debut shows a Dock icon by default")
    func defaultShowsDockIcon() {
        #expect(AppSettings().showsDockIcon == true)
    }

    @Test("Settings written before the Dock icon option still load, as a regular app")
    func legacySettingsDefaultToDockIcon() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["showsDockIcon"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.showsDockIcon == true)
    }

    @Test("Showing the Dock icon makes Debut a regular app")
    func dockIconAppliesRegularPolicy() {
        let manager = MockActivationPolicyManager()
        let coordinator = ActivationPolicyCoordinator(manager: manager)

        #expect(coordinator.apply(showsDockIcon: true) == true)
        #expect(manager.policy == .regular)
    }

    @Test("Hiding the Dock icon returns Debut to the menu bar")
    func noDockIconAppliesAccessoryPolicy() {
        let manager = MockActivationPolicyManager()
        manager.policy = .regular
        let coordinator = ActivationPolicyCoordinator(manager: manager)

        #expect(coordinator.apply(showsDockIcon: false) == true)
        #expect(manager.policy == .accessory)
    }

    @Test("Applying the policy the app already has does nothing")
    func idempotent() {
        let manager = MockActivationPolicyManager()
        manager.policy = .regular
        let coordinator = ActivationPolicyCoordinator(manager: manager)

        #expect(coordinator.apply(showsDockIcon: true) == true)
        #expect(manager.setCalls.isEmpty)
    }

    @Test("A refused policy change is reported as failure")
    func refusalIsReported() {
        let manager = MockActivationPolicyManager()
        manager.refuses = true
        let coordinator = ActivationPolicyCoordinator(manager: manager)

        #expect(coordinator.apply(showsDockIcon: true) == false)
        #expect(manager.policy == .accessory)
    }
}

@MainActor
@Suite("Main menu")
struct MainMenuTests {
    @Test("A regular Debut owns a menu bar with Settings and Quit")
    func mainMenuCarriesEssentialCommands() {
        let menu = AppDelegate.makeMainMenu(target: nil)

        let appMenu = try? #require(menu.items.first?.submenu)
        let titles = appMenu?.items.map(\.title) ?? []
        #expect(titles.contains("Settings..."))
        #expect(titles.contains("Quit Debut"))
        #expect(appMenu?.items.first { $0.title == "Settings..." }?.keyEquivalent == ",")
        #expect(appMenu?.items.first { $0.title == "Quit Debut" }?.keyEquivalent == "q")
    }

    @Test("The window menu closes and minimizes the frontmost window")
    func windowMenuCarriesWindowCommands() {
        let menu = AppDelegate.makeMainMenu(target: nil)

        let windowMenu = menu.items.first { $0.title == "Window" }?.submenu
        let actions = windowMenu?.items.map(\.action) ?? []
        #expect(actions.contains(#selector(NSWindow.performClose(_:))))
        #expect(actions.contains(#selector(NSWindow.performMiniaturize(_:))))
    }
}
