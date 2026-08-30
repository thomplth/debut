import Testing
import Foundation
import AppKit
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

}

@Suite("Space switch coordinator")
struct SpaceSwitchCoordinatorTests {
    private let desktopIDs: [CGSSpaceID] = [10, 11, 12, 13]

    private func topology(current: Int, desktopIDs: [CGSSpaceID]? = nil) -> SpaceTopology {
        let ids = desktopIDs ?? self.desktopIDs
        return SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: SpaceTopology.sharedStackID,
                displayID: nil,
                displayName: "All Displays",
                frame: .zero,
                desktopIDs: ids,
                currentDesktopID: ids.indices.contains(current) ? ids[current] : nil
            ),
        ])
    }

    private func location(_ index: Int) -> DesktopLocation {
        DesktopLocation(
            stackID: SpaceTopology.sharedStackID,
            desktopID: desktopIDs[index],
            index: index
        )
    }

    @Test("A far target starts exactly one adjacent hop")
    func farTargetStartsOneHop() {
        var coordinator = SpaceSwitchCoordinator()

        let request = coordinator.request(to: location(3), in: topology(current: 0))

        #expect(request == .post(SpaceSwitchHop(
            stackID: SpaceTopology.sharedStackID,
            fromDesktopID: 10,
            toDesktopID: 11,
            direction: .right
        )))
        #expect(request.hop?.instantVelocity == 400)
        #expect(coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("Rapid targets coalesce without posting a second unconfirmed hop")
    func rapidTargetsCoalesce() {
        var coordinator = SpaceSwitchCoordinator()
        let first = coordinator.request(to: location(1), in: topology(current: 0))

        let second = coordinator.request(to: location(2), in: topology(current: 0))

        #expect(first != .coalesced)
        #expect(second == .coalesced)
        #expect(coordinator.desktopDidChange(to: topology(current: 1)) == [
            SpaceSwitchHop(
                stackID: SpaceTopology.sharedStackID,
                fromDesktopID: 11,
                toDesktopID: 12,
                direction: .right
            ),
        ])
        #expect(coordinator.desktopDidChange(to: topology(current: 2)).isEmpty)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("A request back to the showing desktop is retained while a hop is in flight")
    func reversesAfterConfirmingInFlightHop() {
        var coordinator = SpaceSwitchCoordinator()
        _ = coordinator.request(to: location(2), in: topology(current: 0))

        let reversal = coordinator.request(to: location(0), in: topology(current: 0))

        #expect(reversal == .coalesced)
        #expect(coordinator.desktopDidChange(to: topology(current: 1)) == [
            SpaceSwitchHop(
                stackID: SpaceTopology.sharedStackID,
                fromDesktopID: 11,
                toDesktopID: 10,
                direction: .left
            ),
        ])
        #expect(coordinator.desktopDidChange(to: topology(current: 0)).isEmpty)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("An unexpected landing stops instead of posting from an uncertain state")
    func unexpectedLandingStops() {
        var coordinator = SpaceSwitchCoordinator()
        _ = coordinator.request(to: location(3), in: topology(current: 0))

        let next = coordinator.desktopDidChange(to: topology(current: 2))

        #expect(next.isEmpty)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("Removing the desired desktop while switching stops safely")
    func topologyChangeStops() {
        var coordinator = SpaceSwitchCoordinator()
        _ = coordinator.request(to: location(3), in: topology(current: 0))

        let next = coordinator.desktopDidChange(
            to: topology(current: 1, desktopIDs: [10, 11, 12])
        )

        #expect(next.isEmpty)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("A posting failure clears the matching in-flight hop")
    func postingFailureClears() throws {
        var coordinator = SpaceSwitchCoordinator()
        let request = coordinator.request(to: location(2), in: topology(current: 0))
        let hop = try #require(request.hop)

        coordinator.postingFailed(hop)

        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
        #expect(coordinator.desktopDidChange(to: topology(current: 1)).isEmpty)
    }
}

@Suite("SpaceService switch speed")
struct SpaceServiceSpeedTests {

    @Test("Space service is safe to capture in its dispatch work")
    func serviceIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) {}
        requireSendable(SpaceService())
    }

    @Test("Switch duration defaults to the shipped setting")
    func defaultDuration() {
        #expect(SpaceService().switchDuration == AppSettings.defaultSpaceSwitchDuration)
    }

    // The slider is the only thing that should decide this, but a settings file can be edited
    // by hand and a negative duration would schedule samples into the past.
    @Test("Switch duration is clamped to the range the slider offers")
    func durationIsClamped() {
        let service = SpaceService()
        service.switchDuration = -1
        #expect(service.switchDuration == 0)
        service.switchDuration = 10
        #expect(service.switchDuration == AppSettings.maximumSpaceSwitchDuration)
    }
}

// The user-facing setting is a duration in milliseconds, and it is only honest because these
// samples are what the Dock is shown. A Began+Ended pair on its own hands the transition to
// the Dock, which picks "no transition at all" for any velocity much above 80 — which is the
// whole range the old speed slider offered, so every value on it looked identical.
@Suite("DockSwipeAnimation")
struct DockSwipeAnimationTests {

    @Test("An instant switch has no samples to send")
    func instantHasNoSamples() {
        #expect(DockSwipeAnimation.samples(duration: 0).isEmpty)
        #expect(DockSwipeAnimation.samples(duration: -1).isEmpty)
    }

    @Test("The last sample lands exactly on the requested duration")
    func lastSampleIsTheDuration() throws {
        let samples = DockSwipeAnimation.samples(duration: 0.12)
        let last = try #require(samples.last)
        #expect(abs(last.delay - 0.12) < 1e-9)
    }

    // Progress is what the Dock draws, and it saturates at one desktop per gesture — the
    // instant path asks for 2 and still lands exactly one hop. So the final sample has to
    // reach 1 exactly: short of it, the release settles back where the slide started.
    @Test("Progress rises from above zero to exactly one desktop")
    func progressSpansOneDesktop() throws {
        let samples = DockSwipeAnimation.samples(duration: 0.12)
        let first = try #require(samples.first)
        let last = try #require(samples.last)
        #expect(first.progress > 0)
        #expect(abs(last.progress - 1) < 1e-9)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.progress < $1.progress })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.delay < $1.delay })
    }

    @Test("Sample count follows the duration at the sample rate")
    func sampleCountFollowsDuration() {
        let short = DockSwipeAnimation.samples(duration: 0.1)
        let long = DockSwipeAnimation.samples(duration: 0.2)
        #expect(long.count == short.count * 2)
        #expect(short.count == Int((0.1 * DockSwipeAnimation.sampleRate).rounded()))
    }

    // A duration far below one frame still has to produce a usable gesture rather than a
    // single sample the Dock reads as a flick.
    @Test("A duration shorter than one sample still sends two samples")
    func veryShortDurationStillAnimates() {
        #expect(DockSwipeAnimation.samples(duration: 0.001).count == 2)
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

    // A conformer that has not implemented per-Space enumeration must not be forced to:
    // the default keeps callers working with an empty map rather than a compile error.
    @Test("A conformer without its own implementation reports no window locations")
    func defaultWindowLocationsIsEmpty() {
        let switcher = MockSpaceSwitcher(desktops: 3, current: 0)
        #expect(switcher.windowLocations().isEmpty)
    }
}

// kAXWindows only reports windows on the active Space, plus windows assigned to every Space.
// A window on a Space that is not showing is invisible to Accessibility, so discovering it at
// all requires asking the window server directly, one desktop at a time.
@Suite("SpaceService window enumeration")
struct SpaceServiceWindowEnumerationTests {

    // A freshly created test-process window does not reliably land on a listed user desktop —
    // measured landing on a Space absent from `userDesktops()` entirely — so this places the
    // window with the same bridged move the reassignment feature already relies on, rather
    // than trusting wherever AppKit happens to put a brand-new window.
    @Test("windowLocations finds a window placed on a known desktop")
    @MainActor func windowLocationsFindsPlacedWindow() throws {
        let service = SpaceService()
        let target = try #require(service.userDesktops().first)

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // Closing an NSWindow releases it by default, which over-releases the reference this
        // test still holds and segfaults the *next* test rather than this one.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let windowID = CGWindowID(window.windowNumber)
        #expect(BridgedWindowManagement.moveWindows([windowID], toSpace: target))
        #expect(service.waitForWindow(windowID, toReachSpace: target))

        let locations = service.windowLocations()

        #expect(locations[windowID]?.desktopID == target)
    }

    @Test("windowLocations finds a window on a desktop that is not showing",
          .enabled(if: BridgedWindowManagementTests.hasSecondDesktop, "needs at least two user desktops"))
    @MainActor func windowLocationsFindsOtherDesktopWindow() throws {
        let service = SpaceService()
        let desktops = service.userDesktops()

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let windowID = CGWindowID(window.windowNumber)
        let origin = try #require(service.spaces(forWindow: windowID).first)
        let target = try #require(desktops.first { $0 != origin })

        #expect(BridgedWindowManagement.moveWindows([windowID], toSpace: target))
        #expect(service.waitForWindow(windowID, toReachSpace: target))

        let locations = service.windowLocations()

        #expect(locations[windowID]?.desktopID == target)
    }

    // desktopLocation(forWindow:) already treats a window that belongs to more than one
    // Space as having no single answer — that is what stops an all-Spaces window like
    // Finder from being swept onto whichever desktop is queried first. windowLocations()
    // enumerates per desktop, so it must apply the same rule itself rather than letting the
    // last desktop queried silently win the dictionary write.
    @Test("windowLocations omits a window that belongs to every desktop",
          .enabled(if: BridgedWindowManagementTests.hasSecondDesktop, "needs at least two user desktops"))
    @MainActor func windowLocationsOmitsAllSpacesWindow() throws {
        let service = SpaceService()
        #expect(service.userDesktops().count >= 2)

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let windowID = CGWindowID(window.windowNumber)
        #expect(service.spaces(forWindow: windowID).count > 1)

        let locations = service.windowLocations()

        #expect(locations[windowID] == nil)
    }
}
