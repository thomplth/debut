import Testing
import Foundation
@testable import DebutCore

final class TestKeyboardDelegate: KeyboardEventDelegate, @unchecked Sendable {
    var receivedEvents: [DebutKeyEvent] = []

    func handleKeyEvent(_ event: DebutKeyEvent) {
        receivedEvents.append(event)
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
