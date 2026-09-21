import Testing
import Foundation
import Carbon.HIToolbox
@testable import DebutCore

@Suite("Launch feature controls")
struct LaunchFeatureTests {
    @Test("Existing preferences without feature choices gain the current defaults")
    func migration() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "features")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.features.windowPreviews)
        #expect(restored.features.workspaceIsolation)
        #expect(restored.features.fasterDesktopSwitching)
        #expect(restored.features.numberShortcuts)
        #expect(restored.features.controlArrows)
        #expect(restored.features.trackpadSwipes)
    }

    @Test("Existing feature preferences enable faster desktop switching")
    func fasterDesktopSwitchingMigration() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var features = try #require(json["features"] as? [String: Any])
        features.removeValue(forKey: "fasterDesktopSwitching")
        json["features"] = features

        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        #expect(restored.features.fasterDesktopSwitching)
    }

    @Test("Disabling faster desktop switching preserves every desktop override")
    func disablingFasterDesktopSwitchingPreservesOverrides() {
        var features = FeatureSettings()
        features.numberShortcuts = false
        features.controlArrows = true
        features.trackpadSwipes = false

        features.setFasterDesktopSwitching(false)

        #expect(!features.fasterDesktopSwitching)
        #expect(!features.numberShortcuts)
        #expect(features.controlArrows)
        #expect(!features.trackpadSwipes)
        #expect(!features.effectiveNumberShortcuts)
        #expect(!features.effectiveControlArrows)
        #expect(!features.effectiveTrackpadSwipes)

        features.setFasterDesktopSwitching(true)
        #expect(!features.numberShortcuts)
        #expect(features.controlArrows)
        #expect(!features.trackpadSwipes)
        #expect(!features.effectiveNumberShortcuts)
        #expect(features.effectiveControlArrows)
        #expect(!features.effectiveTrackpadSwipes)
    }

    @Test("Choices survive settings round trip independently")
    func persistence() throws {
        var settings = AppSettings()
        settings.features.windowPreviews = false
        settings.features.workspaceIsolation = false
        settings.features.numberShortcuts = false
        settings.features.controlArrows = true
        settings.features.trackpadSwipes = false
        settings.features.setFasterDesktopSwitching(false)
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(restored == settings)
        #expect(!restored.features.numberShortcuts)
        #expect(restored.features.controlArrows)
        #expect(!restored.features.trackpadSwipes)
    }

    @Test("Disabled shortcuts pass through; Control arrows consume their matching key up")
    func keyboardChoices() throws {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = service.start(delegate: delegate) // Direct dispatch below does not require a live event tap.
        defer { service.stop() }
        var features = FeatureSettings()
        features.workspaceIsolation = false
        features.numberShortcuts = false
        features.controlArrows = true
        service.features = features
        func event(_ code: Int, _ down: Bool, _ flags: CGEventFlags) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            event.flags = flags
            return event
        }
        #expect(service.handleCGEvent(type: .keyDown, event: event(kVK_Tab, true, .maskCommand)) != nil)
        #expect(service.handleCGEvent(type: .keyDown, event: event(kVK_ANSI_1, true, .maskControl)) != nil)
        #expect(service.handleCGEvent(type: .keyDown, event: event(kVK_RightArrow, true, [.maskControl, .maskShift])) != nil)
        #expect(service.handleCGEvent(type: .keyDown, event: event(kVK_RightArrow, true, .maskControl)) == nil)
        service.features.controlArrows = false
        #expect(service.handleCGEvent(type: .keyDown, event: event(kVK_RightArrow, true, .maskControl)) == nil)
        #expect(service.handleCGEvent(type: .keyUp, event: event(kVK_RightArrow, false, [])) == nil)
        #expect(delegate.receivedEvents == [.switchAdjacentSpace(1)])
        service.features.controlArrows = true
        service.desktopNavigationAvailable = false
        #expect(service.handleCGEvent(type: .keyDown, event: event(kVK_RightArrow, true, .maskControl)) != nil)
    }

    @Test("The faster-desktop master gates preserved keyboard overrides", arguments: [true, false])
    func fasterDesktopMasterGatesKeyboardOverrides(masterEnabled: Bool) {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = service.start(delegate: delegate)
        defer { service.stop() }

        var features = FeatureSettings()
        features.numberShortcuts = true
        features.controlArrows = true
        features.setFasterDesktopSwitching(masterEnabled)
        service.features = features

        func event(_ code: Int, down: Bool, _ flags: CGEventFlags) -> CGEvent {
            let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(code),
                keyDown: down
            )!
            event.flags = flags
            return event
        }

        let numberResult = service.handleCGEvent(
            type: .keyDown,
            event: event(kVK_ANSI_2, down: true, .maskControl)
        )
        let arrowResult = service.handleCGEvent(
            type: .keyDown,
            event: event(kVK_RightArrow, down: true, .maskControl)
        )
        let numberUpResult = service.handleCGEvent(
            type: .keyUp,
            event: event(kVK_ANSI_2, down: false, [])
        )
        let arrowUpResult = service.handleCGEvent(
            type: .keyUp,
            event: event(kVK_RightArrow, down: false, [])
        )

        if masterEnabled {
            #expect(numberResult == nil)
            #expect(arrowResult == nil)
            #expect(numberUpResult == nil)
            #expect(arrowUpResult == nil)
            #expect(delegate.receivedEvents == [.switchToSpace(2), .switchAdjacentSpace(1)])
        } else {
            #expect(numberResult != nil)
            #expect(arrowResult != nil)
            #expect(numberUpResult != nil)
            #expect(arrowUpResult != nil)
            #expect(delegate.receivedEvents.isEmpty)
        }
    }

    @Test("Control-arrow remains native throughout an overview and resumes on the next press")
    func controlArrowOverviewPassthrough() {
        let overview = OverviewState()
        let service = EventTapKeyboardService(desktopNavigationBlocked: { overview.active })
        let delegate = TestKeyboardDelegate()
        _ = service.start(delegate: delegate)
        defer { service.stop() }
        service.features.controlArrows = true
        overview.active = true

        func event(_ down: Bool) -> CGEvent {
            let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_RightArrow),
                keyDown: down
            )!
            event.flags = down ? .maskControl : []
            return event
        }

        #expect(service.handleCGEvent(type: .keyDown, event: event(true)) != nil)
        #expect(service.handleCGEvent(type: .keyUp, event: event(false)) != nil)
        #expect(delegate.receivedEvents.isEmpty)

        overview.active = false
        #expect(service.handleCGEvent(type: .keyDown, event: event(true)) == nil)
        #expect(service.handleCGEvent(type: .keyUp, event: event(false)) == nil)
        #expect(delegate.receivedEvents == [.switchAdjacentSpace(1)])
    }
}

private final class OverviewState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedActive = false

    var active: Bool {
        get { lock.withLock { storedActive } }
        set { lock.withLock { storedActive = newValue } }
    }
}
