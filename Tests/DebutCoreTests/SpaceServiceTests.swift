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
