import Testing
import Foundation
import Carbon.HIToolbox
import CoreGraphics
@testable import DebutCore

final class TestKeyboardDelegate: KeyboardEventDelegate, @unchecked Sendable {
    var receivedEvents: [DebutKeyEvent] = []
    var overlayContexts: [OverlayPresentationContext] = []

    func handleKeyEvent(_ event: DebutKeyEvent) {
        receivedEvents.append(event)
    }

    func handleKeyEvent(
        _ event: DebutKeyEvent,
        overlayPresentation: OverlayPresentationContext?
    ) {
        receivedEvents.append(event)
        if let overlayPresentation { overlayContexts.append(overlayPresentation) }
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

final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    func advance(milliseconds: Double) {
        lock.withLock { nanoseconds += UInt64(milliseconds * 1_000_000) }
    }

    func read() -> UInt64 {
        lock.withLock { nanoseconds }
    }
}

final class RecordedComboBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCombo: KeyCombo?

    var combo: KeyCombo? { lock.withLock { storedCombo } }

    func record(_ combo: KeyCombo?) {
        lock.withLock { storedCombo = combo }
    }
}

@Suite("KeyboardService")
struct KeyboardServiceTests {

    @Test("A fresh overlay activation carries one trace from event recognition to delivery")
    func overlayActivationCorrelation() {
        let performance = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader())
        let overlay = OverlayPresentationRecorder(performanceRecorder: performance)
        let service = EventTapKeyboardService(
            overlayPresentationRecorder: overlay,
            performanceRecorder: performance
        )
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        event.flags = .maskCommand
        #expect(service.handleCGEvent(type: .keyDown, event: event) == nil)

        #expect(delegate.receivedEvents == [.cmdTabHold])
        #expect(delegate.overlayContexts.count == 1)
        let trace = overlay.snapshot().active.first
        #expect(trace?.traceID == delegate.overlayContexts.first?.traceID)
        #expect(trace?.phases.map(\.phase) == [.activationRecognized, .mainActorDequeued])
        let correlatedOperations = performance.snapshot().recent.filter {
            $0.traceID == delegate.overlayContexts.first?.traceID
        }.map(\.operation)
        #expect(correlatedOperations.contains(.eventTap))
        #expect(correlatedOperations.contains(.mainQueueDelivery))
    }

    @Test("Shortcut recording captures Ctrl-Tab before normal dispatch")
    func recordingCapturesControlTab() async throws {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        let recorded = RecordedComboBox()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }
        service.beginShortcutRecording { recorded.record($0) }

        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        event.flags = .maskControl

        #expect(service.handleCGEvent(type: .keyDown, event: event) == nil)
        for _ in 0..<1_000 where recorded.combo == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorded.combo == KeyCombo(keyCode: kVK_Tab, control: true))
        #expect(delegate.receivedEvents.isEmpty)
    }

    @Test("Shortcut recording captures Cmd-Tab instead of opening Debut")
    func recordingCapturesCommandTab() async throws {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        let recorded = RecordedComboBox()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }
        service.beginShortcutRecording { recorded.record($0) }

        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        event.flags = .maskCommand

        #expect(service.handleCGEvent(type: .keyDown, event: event) == nil)
        for _ in 0..<1_000 where recorded.combo == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorded.combo == KeyCombo(keyCode: kVK_Tab, command: true))
        #expect(delegate.receivedEvents.isEmpty)
    }

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

    @Test("Overlay 9 targets the last stage and 0 has no default binding")
    func lastStageKeyMapping() {
        let bindings = KeyBindings()

        #expect(KeyAction.jumpToStage9.displayName == "Jump to last stage")
        #expect(KeyAction.jumpToStage9.toKeyEvent() == .jumpToLastStage)
        #expect(bindings.action(for: KeyCombo(keyCode: kVK_ANSI_9)) == .jumpToStage9)
        #expect(bindings.action(for: KeyCombo(keyCode: kVK_ANSI_0)) == nil)
    }

    @Test("Visible overlay dispatches Command-9 and ignores Command-0")
    func visibleOverlayDigitDispatch() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let stageModeEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        stageModeEvent.flags = [.maskCommand, .maskAlternate]
        #expect(service.handleCGEvent(type: .keyDown, event: stageModeEvent) == nil)
        service.overlayVisible = true

        let nineEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_9),
            keyDown: true
        )!
        nineEvent.flags = .maskCommand
        #expect(service.handleCGEvent(type: .keyDown, event: nineEvent) == nil)

        let zeroEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_0),
            keyDown: true
        )!
        zeroEvent.flags = .maskCommand
        #expect(service.handleCGEvent(type: .keyDown, event: zeroEvent) == nil)

        #expect(delegate.receivedEvents == [.cmdOptionTabHold, .jumpToLastStage])
    }

    @Test("Quick switch events")
    func quickSwitch() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.switchToStage(1))
        svc.simulateEvent(.switchToStageKeepingCurrentApplication(5))

        #expect(delegate.receivedEvents == [
            .switchToStage(1), .switchToStageKeepingCurrentApplication(5),
        ])
    }

    @Test("Quick switch digit shortcuts map only 1-9 to stages 1-9")
    func quickSwitchKeyMapping() {
        let mappings = [
            (kVK_ANSI_1, 1), (kVK_ANSI_2, 2), (kVK_ANSI_3, 3),
            (kVK_ANSI_4, 4), (kVK_ANSI_5, 5), (kVK_ANSI_6, 6),
            (kVK_ANSI_7, 7), (kVK_ANSI_8, 8), (kVK_ANSI_9, 9),
        ]

        for (keyCode, expectedPosition) in mappings {
            #expect(EventTapKeyboardService.quickSwitchStagePosition(
                keyCode: Int64(keyCode),
                flags: .maskControl
            ) == expectedPosition)
        }
        #expect(EventTapKeyboardService.quickSwitchStagePosition(
            keyCode: Int64(kVK_ANSI_0),
            flags: .maskControl
        ) == nil)
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

    @Test("Quick switch digit keys use the configured modifier chord")
    func quickSwitchUsesConfiguredModifiers() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = service.start(delegate: delegate)
        defer { service.stop() }
        service.quickSwitchModifiers = ShortcutModifiers(control: true, option: true)
        service.quickSwitchSameApplicationModifiers = ShortcutModifiers(command: true)

        let configured = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_4),
            keyDown: true
        )!
        configured.flags = [.maskControl, .maskAlternate]
        let oldDefault = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_4),
            keyDown: true
        )!
        oldDefault.flags = .maskControl

        #expect(service.handleCGEvent(type: .keyDown, event: configured) == nil)
        #expect(service.handleCGEvent(type: .keyDown, event: oldDefault) === oldDefault)
        #expect(delegate.receivedEvents == [.switchToStage(4)])
    }

    @Test("Same-app quick switch uses its own configured modifier chord")
    func sameAppQuickSwitchUsesConfiguredModifiers() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = service.start(delegate: delegate)
        defer { service.stop() }
        service.quickSwitchModifiers = .control
        service.quickSwitchSameApplicationModifiers = ShortcutModifiers(
            control: true,
            option: true
        )

        let sameApp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_4),
            keyDown: true
        )!
        sameApp.flags = [.maskControl, .maskAlternate]

        #expect(service.handleCGEvent(type: .keyDown, event: sameApp) == nil)
        #expect(delegate.receivedEvents == [.switchToStageKeepingCurrentApplication(4)])
    }

    @Test("Digit zero is not captured by either quick-switch shortcut")
    func quickSwitchIgnoresZero() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = service.start(delegate: delegate)
        defer { service.stop() }

        let direct = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_0),
            keyDown: true
        )!
        direct.flags = .maskControl
        let sameApp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_0),
            keyDown: true
        )!
        sameApp.flags = [.maskControl, .maskAlternate]

        #expect(service.handleCGEvent(type: .keyDown, event: direct) === direct)
        #expect(service.handleCGEvent(type: .keyDown, event: sameApp) === sameApp)
        #expect(delegate.receivedEvents.isEmpty)
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

        // The delegate finishes on its own thread, and parallel suites can delay
        // it far past its own sleep, so poll instead of waiting a fixed span.
        for _ in 0..<200 where delegate.receivedEvents.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
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

    @Test("Cmd+Tab auto-repeat is distinguished from a fresh press")
    func cmdTabAutoRepeat() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let repeatedTab = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        repeatedTab.flags = .maskCommand
        repeatedTab.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        #expect(service.handleCGEvent(type: .keyDown, event: repeatedTab) == nil)
        #expect(delegate.receivedEvents == [.nextWindowRepeat])
    }

    @Test("Cmd+backtick auto-repeat is distinguished from a fresh press")
    func cmdBacktickAutoRepeat() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let repeatedBacktick = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_Grave),
            keyDown: true
        )!
        repeatedBacktick.flags = .maskCommand
        repeatedBacktick.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        #expect(service.handleCGEvent(type: .keyDown, event: repeatedBacktick) == nil)
        #expect(delegate.receivedEvents == [.cmdBacktickRepeat])
    }

    @Test("Cmd+Shift+Tab auto-repeat is distinguished from a fresh press")
    func cmdShiftTabAutoRepeat() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let repeatedTab = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        repeatedTab.flags = [.maskCommand, .maskShift]
        repeatedTab.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        #expect(service.handleCGEvent(type: .keyDown, event: repeatedTab) == nil)
        #expect(delegate.receivedEvents == [.previousWindowRepeat])
    }

    @Test("Held backtick inside the overlay auto-repeats as a backward window step")
    func sessionBacktickAutoRepeat() {
        let service = EventTapKeyboardService()
        service.heldCycleMinimumInterval = 0 // pacing is covered separately
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let tabDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        tabDown.flags = .maskCommand
        #expect(service.handleCGEvent(type: .keyDown, event: tabDown) == nil)
        service.overlayVisible = true

        let repeatedBacktick = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_Grave),
            keyDown: true
        )!
        repeatedBacktick.flags = .maskCommand
        repeatedBacktick.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        #expect(service.handleCGEvent(type: .keyDown, event: repeatedBacktick) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold, .previousWindowRepeat])
    }

    @Test("Cmd+Shift+backtick auto-repeat is distinguished from a fresh press")
    func cmdShiftBacktickAutoRepeat() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let repeatedBacktick = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_Grave),
            keyDown: true
        )!
        repeatedBacktick.flags = [.maskCommand, .maskShift]
        repeatedBacktick.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        #expect(service.handleCGEvent(type: .keyDown, event: repeatedBacktick) == nil)
        #expect(delegate.receivedEvents == [.cmdShiftBacktickRepeat])
    }

    /// Builds a service whose held-cycle pacing is driven by `clock` rather than wall time.
    private func makeThrottledService(
        clock: TestMonotonicClock,
        interval: TimeInterval
    ) -> EventTapKeyboardService {
        let service = EventTapKeyboardService(monotonicNanoseconds: { clock.read() })
        service.heldCycleMinimumInterval = interval
        return service
    }

    private func tabEvent(autoRepeat: Bool, flags: CGEventFlags = .maskCommand) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autoRepeat ? 1 : 0)
        return event
    }

    @Test("Held cycling is paced to the configured minimum interval")
    func heldCycleRateLimit() {
        let clock = TestMonotonicClock()
        let service = makeThrottledService(clock: clock, interval: 0.1)
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: false)) == nil)
        clock.advance(milliseconds: 10)
        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: true)) == nil)
        clock.advance(milliseconds: 10)
        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: true)) == nil)
        clock.advance(milliseconds: 100)
        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: true)) == nil)

        // The two repeats inside the interval are swallowed, not merely delayed.
        #expect(delegate.receivedEvents == [.cmdTabHold, .nextWindowRepeat])
    }

    @Test("A fresh press is never paced, however fast it follows the last one")
    func freshPressBypassesRateLimit() {
        let clock = TestMonotonicClock()
        let service = makeThrottledService(clock: clock, interval: 0.1)
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: false)) == nil)
        clock.advance(milliseconds: 1)
        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: false)) == nil)

        #expect(delegate.receivedEvents == [.cmdTabHold, .cmdTabHold])
    }

    @Test("Held stage cycling is paced on the same budget as window cycling")
    func heldStageCycleRateLimit() {
        let clock = TestMonotonicClock()
        let service = makeThrottledService(clock: clock, interval: 0.1)
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let stageFlags: CGEventFlags = [.maskCommand, .maskAlternate]
        #expect(service.handleCGEvent(
            type: .keyDown,
            event: tabEvent(autoRepeat: false, flags: stageFlags)
        ) == nil)
        clock.advance(milliseconds: 5)
        #expect(service.handleCGEvent(
            type: .keyDown,
            event: tabEvent(autoRepeat: true, flags: stageFlags)
        ) == nil)

        #expect(delegate.receivedEvents == [.cmdOptionTabHold])
    }

    @Test("A zero interval turns the rate limit off")
    func zeroIntervalDisablesRateLimit() {
        let clock = TestMonotonicClock()
        let service = makeThrottledService(clock: clock, interval: 0)
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: false)) == nil)
        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: true)) == nil)
        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: true)) == nil)

        #expect(delegate.receivedEvents == [.cmdTabHold, .nextWindowRepeat, .nextWindowRepeat])
    }

    @Test("Non-cycling commands are exempt from held-cycle pacing")
    func nonCyclingCommandsAreNotPaced() {
        let clock = TestMonotonicClock()
        let service = makeThrottledService(clock: clock, interval: 0.1)
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        #expect(service.handleCGEvent(type: .keyDown, event: tabEvent(autoRepeat: false)) == nil)
        service.overlayVisible = true

        let downArrow = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_DownArrow),
            keyDown: true
        )!
        downArrow.flags = .maskCommand
        downArrow.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(service.handleCGEvent(type: .keyDown, event: downArrow) == nil)

        #expect(delegate.receivedEvents == [.cmdTabHold, .moveWindowDown])
    }

    @Test("Cmd+Option+Tab event")
    func cmdOptionTab() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.cmdOptionTabHold)

        #expect(delegate.receivedEvents == [.cmdOptionTabHold])
    }

    @Test("Cmd+Option+backtick opens the previous-stage direction")
    func cmdOptionBacktick() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_Grave),
            keyDown: true
        )!
        event.flags = [.maskCommand, .maskAlternate]

        #expect(service.handleCGEvent(type: .keyDown, event: event) == nil)
        #expect(delegate.receivedEvents == [.cmdOptionShiftTabHold])
    }

    @Test("Cmd+Q quits the overlay's selected app instead of the frontmost one")
    func commandQQuitsSelectedAppVisibleOverlay() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let tabDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        tabDown.flags = .maskCommand
        #expect(service.handleCGEvent(type: .keyDown, event: tabDown) == nil)
        service.overlayVisible = true

        let qDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_Q),
            keyDown: true
        )!
        qDown.flags = .maskCommand
        let qUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_Q),
            keyDown: false
        )!
        qUp.flags = .maskCommand

        #expect(service.handleCGEvent(type: .keyDown, event: qDown) == nil)
        #expect(service.handleCGEvent(type: .keyUp, event: qUp) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold, .quitSelectedApp])
    }

    @Test("Cmd+Q reaches the frontmost app when the quit command is unbound")
    func commandQPassesThroughWhenUnbound() {
        let service = EventTapKeyboardService()
        var bindings = KeyBindings()
        bindings.bindings.removeValue(forKey: .quitSelectedApp)
        service.keyBindings = bindings

        let tabDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        tabDown.flags = .maskCommand
        #expect(service.handleCGEvent(type: .keyDown, event: tabDown) == nil)
        service.overlayVisible = true

        let qDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_Q),
            keyDown: true
        )!
        qDown.flags = .maskCommand

        #expect(service.handleCGEvent(type: .keyDown, event: qDown) === qDown)
    }

    @Test("Plain Q remains consumed while the overlay is visible")
    func plainQRemainsConsumedVisibleOverlay() {
        let service = EventTapKeyboardService()
        let tabDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Tab),
            keyDown: true
        )!
        tabDown.flags = .maskCommand
        #expect(service.handleCGEvent(type: .keyDown, event: tabDown) == nil)
        service.overlayVisible = true

        let qDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_Q),
            keyDown: true
        )!
        qDown.flags = []

        #expect(service.handleCGEvent(type: .keyDown, event: qDown) == nil)
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
