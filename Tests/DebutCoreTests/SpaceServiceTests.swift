import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

@Suite("SpaceSwitchPlan")
struct SpaceSwitchPlanTests {

    @Test("A forward jump reports the distance and direction")
    func forward() {
        let plan = SpaceSwitchPlan(from: 0, to: 3, desktopCount: 4)
        #expect(plan?.direction == .right)
        #expect(plan?.steps == 3)
    }

    @Test("A backward jump reports the distance and direction")
    func backward() {
        let plan = SpaceSwitchPlan(from: 3, to: 1, desktopCount: 4)
        #expect(plan?.direction == .left)
        #expect(plan?.steps == 2)
    }

    // Switching to the desktop you are already on must post nothing at all.
    // A zero-step gesture still opens the Dock's gesture state, and the Dock
    // resolves an unmatched Began by rubber-banding, so "harmlessly do nothing"
    // is not what a zero-velocity swipe actually does.
    @Test("Switching to the current desktop plans nothing")
    func sameDesktop() {
        #expect(SpaceSwitchPlan(from: 2, to: 2, desktopCount: 4) == nil)
    }

    @Test("Out-of-range targets plan nothing")
    func outOfRange() {
        #expect(SpaceSwitchPlan(from: 0, to: 4, desktopCount: 4) == nil)
        #expect(SpaceSwitchPlan(from: 0, to: -1, desktopCount: 4) == nil)
        #expect(SpaceSwitchPlan(from: -1, to: 1, desktopCount: 4) == nil)
    }

    @Test("A single desktop plans nothing")
    func singleDesktop() {
        #expect(SpaceSwitchPlan(from: 0, to: 0, desktopCount: 1) == nil)
    }

    // A two-desktop jump at single-step velocity animates through the desktop in between,
    // which is the delay the whole gesture path exists to avoid.
    @Test("Velocity scales with the distance travelled")
    func velocityScalesWithDistance() {
        #expect(SpaceSwitchPlan(from: 0, to: 1, desktopCount: 4)?.velocity(base: 400) == 400)
        #expect(SpaceSwitchPlan(from: 0, to: 3, desktopCount: 4)?.velocity(base: 400) == 1200)
        #expect(SpaceSwitchPlan(from: 0, to: 1, desktopCount: 4)?.velocity(base: 150) == 150)
    }
}

@Suite("SpaceService switch speed")
struct SpaceServiceSpeedTests {

    @Test("Switch velocity defaults to the shipped setting")
    func defaultVelocity() {
        #expect(SpaceService().switchVelocity == AppSettings.defaultSpaceSwitchVelocity)
    }

    // A zero or negative velocity would post a gesture the Dock resolves by rubber-banding
    // back, so the setting's range is enforced by the service rather than only by the slider.
    @Test("Switch velocity is clamped to a range that actually moves the Dock")
    func velocityIsClamped() {
        let service = SpaceService()
        service.switchVelocity = 0
        #expect(service.switchVelocity == AppSettings.minimumSpaceSwitchVelocity)
        service.switchVelocity = 100_000
        #expect(service.switchVelocity == AppSettings.maximumSpaceSwitchVelocity)
    }
}

@Suite("DockSwipeEvent")
struct DockSwipeEventTests {

    // These assertions read the private fields back off a constructed event.
    // That needs no window server, so it is the one part of the gesture path
    // that a unit test can hold honest: a renamed or mistyped field ID shows up
    // here rather than as a space switch that silently does nothing.

    @Test("The Began phase carries the dock-control type and no velocity")
    func beganPhase() throws {
        let event = try #require(DockSwipeEvent.make(phase: .began, direction: .right))
        #expect(event.getIntegerValueField(kCGSEventTypeField) == kCGSEventDockControl)
        #expect(event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe)
        #expect(event.getIntegerValueField(kCGEventGesturePhase) == kCGSGesturePhaseBegan)
        #expect(event.getDoubleValueField(kCGEventGestureSwipeVelocityX) == 0)
    }

    @Test("The Ended phase carries signed velocity and progress")
    func endedPhase() throws {
        let right = try #require(DockSwipeEvent.make(phase: .ended, direction: .right, velocity: 400))
        #expect(right.getDoubleValueField(kCGEventGestureSwipeVelocityX) == 400)
        #expect(right.getDoubleValueField(kCGEventGestureSwipeProgress) > 0)

        let left = try #require(DockSwipeEvent.make(phase: .ended, direction: .left, velocity: 400))
        #expect(left.getDoubleValueField(kCGEventGestureSwipeVelocityX) == -400)
        #expect(left.getDoubleValueField(kCGEventGestureSwipeProgress) < 0)
    }

    // The Dock discards a dock-control event whose zoom delta is exactly zero,
    // so this epsilon is load-bearing rather than cosmetic.
    @Test("A non-zero zoom delta keeps the Dock from discarding the event")
    func zoomDeltaEpsilon() throws {
        let event = try #require(DockSwipeEvent.make(phase: .began, direction: .right))
        #expect(event.getDoubleValueField(kCGEventGestureZoomDeltaX) != 0)
    }

    @Test("The direction flag distinguishes left from right")
    func directionFlag() throws {
        let right = try #require(DockSwipeEvent.make(phase: .began, direction: .right))
        let left = try #require(DockSwipeEvent.make(phase: .began, direction: .left))
        #expect(right.getIntegerValueField(kCGEventScrollGestureFlagBits) == 1)
        #expect(left.getIntegerValueField(kCGEventScrollGestureFlagBits) == 0)
    }
}

@Suite("SpaceService desktop mapping")
struct SpaceServiceMappingTests {

    @Test("Desktop index maps to the ordered desktop list")
    func indexMapping() {
        let desktops: [CGSSpaceID] = [3, 4916, 4921]
        #expect(SpaceService.index(of: 4916, in: desktops) == 1)
        #expect(SpaceService.index(of: 3, in: desktops) == 0)
        #expect(SpaceService.index(of: 9999, in: desktops) == nil)
    }

    // A window assigned to every Space (Finder is, by default, on some systems)
    // resolves to no single desktop. Reporting "the first one" would silently
    // bind it to desktop 1 and then fight the user every time it is moved.
    @Test("A window on many desktops resolves to no index")
    func pinnedWindow() {
        let desktops: [CGSSpaceID] = [3, 4916, 4921]
        #expect(SpaceService.soleIndex(of: [3, 4916, 4921], in: desktops) == nil)
        #expect(SpaceService.soleIndex(of: [4916], in: desktops) == 1)
        #expect(SpaceService.soleIndex(of: [], in: desktops) == nil)
    }

    // The reconciler asks about every live window at once. A window with no single
    // desktop must be absent from the result rather than present with a wrong index,
    // because the reconciler reads absence as "leave this assignment alone".
    @Test("Batch lookup omits windows with no single desktop")
    func batchOmitsUnresolvedWindows() {
        let switcher = MockSpaceSwitcher(desktops: 3, current: 0)
        switcher.windowDesktops = [11: 0, 22: 2]

        let indexes = switcher.desktopIndexes(forWindows: [11, 22, 33])

        #expect(indexes == [11: 0, 22: 2])
    }
}
