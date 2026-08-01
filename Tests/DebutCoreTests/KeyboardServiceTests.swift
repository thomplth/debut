import Testing
import Foundation
import Carbon.HIToolbox
import CoreGraphics
@testable import DebutCore

final class TestKeyboardDelegate: KeyboardEventDelegate, @unchecked Sendable {
    var receivedEvents: [DebutKeyEvent] = []

    func handleKeyEvent(_ event: DebutKeyEvent) {
        receivedEvents.append(event)
    }
}

final class SlowKeyboardDelegate: KeyboardEventDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReceivedEvents: [DebutKeyEvent] = []
    var receivedEvents: [DebutKeyEvent] {
        lock.withLock { storedReceivedEvents }
    }

    func handleKeyEvent(_ event: DebutKeyEvent) {
        Thread.sleep(forTimeInterval: 0.25)
        lock.withLock {
            storedReceivedEvents.append(event)
        }
    }
}

@Suite("KeyboardService")
struct KeyboardServiceTests {

    @Test("Mock service starts and stops")
    func startStop() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(svc.start(delegate: delegate))
        #expect(svc.isRunning)
        svc.stop()
        #expect(!svc.isRunning)
    }

    @Test("Events are forwarded to delegate")
    func eventForwarding() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.cmdTabHold)
        svc.simulateEvent(.nextWindow)
        svc.simulateEvent(.cmdRelease)

        #expect(delegate.receivedEvents == [.cmdTabHold, .nextWindow, .cmdRelease])
    }

    @Test("Stage navigation events")
    func stageNavigation() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.cmdOptionTabHold)
        svc.simulateEvent(.nextStage)
        svc.simulateEvent(.previousStage)
        svc.simulateEvent(.jumpToStage(3))
        svc.simulateEvent(.cmdRelease)

        #expect(delegate.receivedEvents == [
            .cmdOptionTabHold, .nextStage, .previousStage, .jumpToStage(3), .cmdRelease
        ])
    }

    @Test("Stage management events")
    func stageManagement() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.cmdTabHold)
        svc.simulateEvent(.newStageBelow)
        svc.simulateEvent(.newStageAbove)
        svc.simulateEvent(.deleteStage)
        svc.simulateEvent(.saveAsTemplate)
        svc.simulateEvent(.cmdRelease)

        #expect(delegate.receivedEvents.count == 6)
        #expect(delegate.receivedEvents[1] == .newStageBelow)
        #expect(delegate.receivedEvents[2] == .newStageAbove)
        #expect(delegate.receivedEvents[3] == .deleteStage)
        #expect(delegate.receivedEvents[4] == .saveAsTemplate)
    }

    @Test("Quick switch events")
    func quickSwitch() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.switchToStage(1))
        svc.simulateEvent(.switchToStage(5))

        #expect(delegate.receivedEvents == [.switchToStage(1), .switchToStage(5)])
    }

    @Test("Ctrl digit shortcuts map 1-9 to stages 1-9 and 0 to stage 10")
    func quickSwitchKeyMapping() {
        let mappings = [
            (kVK_ANSI_1, 1), (kVK_ANSI_2, 2), (kVK_ANSI_3, 3),
            (kVK_ANSI_4, 4), (kVK_ANSI_5, 5), (kVK_ANSI_6, 6),
            (kVK_ANSI_7, 7), (kVK_ANSI_8, 8), (kVK_ANSI_9, 9),
            (kVK_ANSI_0, 10),
        ]

        for (keyCode, expectedPosition) in mappings {
            #expect(EventTapKeyboardService.quickSwitchStagePosition(
                keyCode: Int64(keyCode),
                flags: .maskControl
            ) == expectedPosition)
        }
    }

    @Test("Quick switch requires Ctrl without Command, Option, or Shift")
    func quickSwitchKeyModifiers() {
        #expect(EventTapKeyboardService.quickSwitchStagePosition(
            keyCode: Int64(kVK_ANSI_1),
            flags: []
        ) == nil)
        #expect(EventTapKeyboardService.quickSwitchStagePosition(
            keyCode: Int64(kVK_ANSI_1),
            flags: [.maskControl, .maskAlternate]
        ) == nil)
        #expect(EventTapKeyboardService.quickSwitchStagePosition(
            keyCode: Int64(kVK_ANSI_1),
            flags: [.maskControl, .maskShift]
        ) == nil)
        #expect(EventTapKeyboardService.quickSwitchStagePosition(
            keyCode: Int64(kVK_ANSI_1),
            flags: [.maskControl, .maskCommand]
        ) == nil)
    }

    @Test("Quick switch consumes key-up even when Ctrl was released first")
    func quickSwitchConsumesKeyUpAfterControlRelease() {
        let service = EventTapKeyboardService()
        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_1),
            keyDown: true
        )!
        keyDown.flags = .maskControl
        let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_1),
            keyDown: false
        )!
        keyUp.flags = []

        #expect(service.handleCGEvent(type: .keyDown, event: keyDown) == nil)
        #expect(service.handleCGEvent(type: .keyUp, event: keyUp) == nil)
    }

    @Test("Unconfigured app Ctrl digit shortcuts do not take priority over quick switch")
    func unconfiguredAppShortcutDoesNotTakePriority() {
        let service = EventTapKeyboardService()
        service.updateFrontmostApp(bundleIdentifier: "com.example.Unconfigured")
        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_1),
            keyDown: true
        )!
        keyDown.flags = .maskControl
        let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_1),
            keyDown: false
        )!
        keyUp.flags = []

        #expect(service.handleCGEvent(type: .keyDown, event: keyDown) == nil)
        #expect(service.handleCGEvent(type: .keyUp, event: keyUp) == nil)
    }

    @Test("A Debut-captured quick switch remains captured during key repeat")
    func capturedQuickSwitchRepeatStaysCaptured() {
        let service = EventTapKeyboardService()
        let initialKeyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_1),
            keyDown: true
        )!
        initialKeyDown.flags = .maskControl
        let repeatedKeyDown = initialKeyDown.copy()!

        #expect(service.handleCGEvent(type: .keyDown, event: initialKeyDown) == nil)
        #expect(service.handleCGEvent(type: .keyDown, event: repeatedKeyDown) == nil)
    }

    @Test("Event-tap callback returns before delegate work completes")
    func eventTapDoesNotBlockOnDelegate() async throws {
        let service = EventTapKeyboardService()
        let delegate = SlowKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        #expect(service.eventTapRunsOnDedicatedThread)
        defer { service.stop() }

        let tabDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        tabDown.flags = .maskCommand

        let start = Date()
        let result = service.handleCGEventFromTap(type: .keyDown, event: tabDown)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result == nil)
        #expect(elapsed < 0.1)

        try await Task.sleep(for: .milliseconds(400))
        #expect(delegate.receivedEvents == [.cmdTabHold])
    }

    @Test("Configured frontmost apps keep Ctrl digit shortcuts")
    func configuredAppKeepsShortcut() {
        let bundleID = "com.example.Reserved"
        let service = EventTapKeyboardService()
        service.updateFrontmostApp(bundleIdentifier: bundleID)
        service.quickSwitchExcludedBundleIDs = [bundleID]
        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_1),
            keyDown: true
        )!
        keyDown.flags = .maskControl
        let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_1),
            keyDown: false
        )!

        #expect(service.handleCGEvent(type: .keyDown, event: keyDown) != nil)
        #expect(service.handleCGEvent(type: .keyUp, event: keyUp) != nil)
    }

    @Test("Reordering events")
    func reordering() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.moveWindowUp)
        svc.simulateEvent(.moveWindowDown)
        svc.simulateEvent(.swapStageUp)
        svc.simulateEvent(.swapStageDown)

        #expect(delegate.receivedEvents == [.moveWindowUp, .moveWindowDown, .swapStageUp, .swapStageDown])
    }

    @Test("Escape event")
    func escapeEvent() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.cmdTabHold)
        svc.simulateEvent(.escape)

        #expect(delegate.receivedEvents == [.cmdTabHold, .escape])
    }

    @Test("Cmd+Tab tap event")
    func cmdTabTap() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.cmdTabTap)

        #expect(delegate.receivedEvents == [.cmdTabTap])
    }

    @Test("Cmd+Option+Tab event")
    func cmdOptionTab() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.cmdOptionTabHold)

        #expect(delegate.receivedEvents == [.cmdOptionTabHold])
    }

    @Test("Events recorded in mock")
    func eventsRecorded() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.nextWindow)
        svc.simulateEvent(.previousWindow)

        #expect(svc.events == [.nextWindow, .previousWindow])
    }

    @Test("All DebutKeyEvent variants are equatable")
    func eventEquality() {
        #expect(DebutKeyEvent.cmdTabTap == .cmdTabTap)
        #expect(DebutKeyEvent.cmdOptionTabHold == .cmdOptionTabHold)
        #expect(DebutKeyEvent.jumpToStage(5) == .jumpToStage(5))
        #expect(DebutKeyEvent.jumpToStage(5) != .jumpToStage(3))
        #expect(DebutKeyEvent.nextWindow != .previousWindow)
    }
}
