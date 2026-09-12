import Testing
import CoreGraphics
import Foundation
@testable import DebutCore

@MainActor
@Suite("Desktop swipe interception")
struct DesktopSwipeTests {
    func event(_ phase: Int64, _ progress: Double = 0, horizontal: Bool = true) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
        event.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(kCGEventGestureSwipeMotion, value: horizontal ? 1 : 2)
        event.setIntegerValueField(kCGEventGesturePhase, value: phase)
        event.setDoubleValueField(kCGEventGestureSwipeProgress, value: progress)
        return event
    }

    @Test("Only horizontal desktop swipes are claimed and one gesture makes one hop")
    func claimsOnlyDesktopSwipe() {
        var moves: [Int] = []
        let service = DesktopSwipeService { moves.append($0) }
        #expect(service.handle(event(1), enabled: false) != nil)
        #expect(service.handle(event(1, horizontal: false), enabled: true) != nil)
        #expect(service.handle(event(1), enabled: true) == nil)
        #expect(service.handle(event(2, 0.01), enabled: true) == nil)
        #expect(moves.isEmpty)
        #expect(service.handle(event(2, -0.12), enabled: true) == nil)
        #expect(service.handle(event(2, -0.7), enabled: true) == nil)
        #expect(service.handle(event(4, -0.7), enabled: true) == nil)
        #expect(moves == [-1])
    }

    @Test("Own synthetic events pass through and disabling drains the physical gesture")
    func syntheticAndDisable() {
        var moves: [Int] = []
        let service = DesktopSwipeService { moves.append($0) }
        let synthetic = DockSwipeEvent.make(phase: .began, direction: .right)!
        #expect(service.handle(synthetic, enabled: true) != nil)
        #expect(service.handle(event(1), enabled: true) == nil)
        #expect(service.handle(event(2, 0.3), enabled: false) == nil)
        #expect(service.handle(event(4), enabled: false) == nil)
        #expect(moves.isEmpty)
        #expect(service.handle(event(1), enabled: false) != nil)
    }

    @Test("Cancelled gestures never switch; a flick can commit from terminal velocity")
    func cancellationAndFlick() {
        var moves: [Int] = []
        let service = DesktopSwipeService { moves.append($0) }
        _ = service.handle(event(1), enabled: true)
        _ = service.handle(event(8), enabled: true)
        #expect(moves.isEmpty)
        _ = service.handle(event(1), enabled: true)
        let ended = event(4)
        ended.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0.3)
        _ = service.handle(ended, enabled: true)
        #expect(moves == [1])
        service.desktopNavigationAvailable = false
        #expect(service.handle(event(1), enabled: true) != nil)
    }

    @Test("An overview receives the complete native gesture and interception resumes afterwards")
    func overviewPassthroughDoesNotLeaveTrackingState() {
        var moves: [Int] = []
        let overview = SwipeOverviewState(active: true)
        let service = DesktopSwipeService(
            desktopNavigationBlocked: { overview.active },
            switchDesktop: { moves.append($0) }
        )

        #expect(service.handle(event(1), enabled: true) != nil)
        #expect(service.handle(event(2, 0.4), enabled: true) != nil)
        #expect(service.handle(event(4, 0.4), enabled: true) != nil)
        #expect(moves.isEmpty)

        overview.active = false
        #expect(service.handle(event(1), enabled: true) == nil)
        #expect(service.handle(event(2, 0.4), enabled: true) == nil)
        #expect(service.handle(event(4, 0.4), enabled: true) == nil)
        #expect(moves == [1])
    }

    @Test("An overview arriving during a claimed gesture drains it without switching")
    func overviewDrainsClaimedGesture() {
        var moves: [Int] = []
        let service = DesktopSwipeService { moves.append($0) }

        #expect(service.handle(event(1), enabled: true) == nil)
        service.cancelActiveGesture()
        #expect(service.handle(event(2, 0.4), enabled: true) == nil)
        #expect(service.handle(event(4, 0.4), enabled: true) == nil)
        #expect(moves.isEmpty)

        #expect(service.handle(event(1), enabled: true) == nil)
        #expect(service.handle(event(2, -0.4), enabled: true) == nil)
        #expect(service.handle(event(4, -0.4), enabled: true) == nil)
        #expect(moves == [-1])
    }
}

private final class SwipeOverviewState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedActive: Bool

    init(active: Bool) {
        storedActive = active
    }

    var active: Bool {
        get { lock.withLock { storedActive } }
        set { lock.withLock { storedActive = newValue } }
    }
}
