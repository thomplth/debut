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
        svc.simulateEvent(.nextApp)
        svc.simulateEvent(.cmdRelease)

        #expect(delegate.receivedEvents == [.cmdTabHold, .nextApp, .cmdRelease])
    }

    @Test("Stage navigation events")
    func stageNavigation() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.cmdTabHold)
        svc.simulateEvent(.nextStage)
        svc.simulateEvent(.previousStage)
        svc.simulateEvent(.jumpToStage(3))
        svc.simulateEvent(.cmdRelease)

        #expect(delegate.receivedEvents == [
            .cmdTabHold, .nextStage, .previousStage, .jumpToStage(3), .cmdRelease
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
        svc.simulateEvent(.renameStage)
        svc.simulateEvent(.saveAsTemplate)
        svc.simulateEvent(.cmdRelease)

        #expect(delegate.receivedEvents.count == 7)
        #expect(delegate.receivedEvents[1] == .newStageBelow)
        #expect(delegate.receivedEvents[2] == .newStageAbove)
        #expect(delegate.receivedEvents[3] == .deleteStage)
        #expect(delegate.receivedEvents[4] == .renameStage)
        #expect(delegate.receivedEvents[5] == .saveAsTemplate)
    }

    @Test("Reordering events")
    func reordering() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.moveAppUp)
        svc.simulateEvent(.moveAppDown)
        svc.simulateEvent(.swapStageUp)
        svc.simulateEvent(.swapStageDown)

        #expect(delegate.receivedEvents == [.moveAppUp, .moveAppDown, .swapStageUp, .swapStageDown])
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

    @Test("Events recorded in mock")
    func eventsRecorded() {
        let svc = MockKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = svc.start(delegate: delegate)

        svc.simulateEvent(.nextApp)
        svc.simulateEvent(.previousApp)

        #expect(svc.events == [.nextApp, .previousApp])
    }

    @Test("All DebutKeyEvent variants are equatable")
    func eventEquality() {
        #expect(DebutKeyEvent.cmdTabTap == .cmdTabTap)
        #expect(DebutKeyEvent.jumpToStage(5) == .jumpToStage(5))
        #expect(DebutKeyEvent.jumpToStage(5) != .jumpToStage(3))
        #expect(DebutKeyEvent.nextApp != .previousApp)
    }
}
