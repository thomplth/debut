import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import DebutCore

@Suite("SpaceSwitchPlan")
struct SpaceSwitchPlanTests {

    @Test("A forward jump reports the distance and direction")
    func forward() {
        let plan = SpaceSwitchPlan(from: 0, to: 3, spaceCount: 4)
        #expect(plan?.direction == .right)
        #expect(plan?.steps == 3)
    }

    @Test("A backward jump reports the distance and direction")
    func backward() {
        let plan = SpaceSwitchPlan(from: 3, to: 1, spaceCount: 4)
        #expect(plan?.direction == .left)
        #expect(plan?.steps == 2)
    }

    // Switching to the desktop you are already on must post nothing at all.
    // A zero-step gesture still opens the Dock's gesture state, and the Dock
    // resolves an unmatched Began by rubber-banding, so "harmlessly do nothing"
    // is not what a zero-velocity swipe actually does.
    @Test("Switching to the current desktop plans nothing")
    func sameDesktop() {
        #expect(SpaceSwitchPlan(from: 2, to: 2, spaceCount: 4) == nil)
    }

    @Test("Out-of-range targets plan nothing")
    func outOfRange() {
        #expect(SpaceSwitchPlan(from: 0, to: 4, spaceCount: 4) == nil)
        #expect(SpaceSwitchPlan(from: 0, to: -1, spaceCount: 4) == nil)
        #expect(SpaceSwitchPlan(from: -1, to: 1, spaceCount: 4) == nil)
    }

    @Test("A single desktop plans nothing")
    func singleDesktop() {
        #expect(SpaceSwitchPlan(from: 0, to: 0, spaceCount: 1) == nil)
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

    private func topology(
        currentSpaceID: CGSSpaceID,
        desktopIDs: [CGSSpaceID],
        orderedSpaceIDs: [CGSSpaceID]
    ) -> SpaceTopology {
        SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: SpaceTopology.sharedStackID,
                displayID: nil,
                displayName: "All Displays",
                frame: .zero,
                desktopIDs: desktopIDs,
                orderedSpaceIDs: orderedSpaceIDs,
                currentDesktopID: currentSpaceID
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

    private func hop(
        from: Int,
        to: Int,
        animation: SpaceSwitchAnimation = .configured
    ) -> SpaceSwitchHop {
        SpaceSwitchHop(
            stackID: SpaceTopology.sharedStackID,
            fromSpaceID: desktopIDs[from],
            toSpaceID: desktopIDs[to],
            direction: to > from ? .right : .left,
            animation: animation
        )
    }

    @Test("A far target posts every adjacent hop as one route")
    func farTargetPostsEveryHop() {
        var coordinator = SpaceSwitchCoordinator()

        let request = coordinator.request(to: location(3), in: topology(current: 0))

        #expect(request.hops.allSatisfy { $0.instantVelocity == 400 })
        #expect(request == .post([
            hop(from: 0, to: 1),
            hop(from: 1, to: 2),
            hop(from: 2, to: 3),
        ]))
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
                fromSpaceID: 11,
                toSpaceID: 12,
                direction: .right
            ),
        ])
        #expect(coordinator.desktopDidChange(to: topology(current: 2)).isEmpty)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("A route accepts intermediate confirmations and retargets from its endpoint")
    func batchedRouteRetargetsAfterEndpoint() {
        var coordinator = SpaceSwitchCoordinator()
        _ = coordinator.request(
            to: location(3),
            in: topology(current: 0)
        )

        let retarget = coordinator.request(
            to: location(1),
            in: topology(current: 0)
        )

        #expect(retarget == .coalesced)
        #expect(coordinator.desktopDidChange(to: topology(current: 1)).isEmpty)
        #expect(coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
        #expect(coordinator.desktopDidChange(to: topology(current: 2)).isEmpty)
        #expect(coordinator.desktopDidChange(to: topology(current: 3)) == [
            hop(from: 3, to: 2),
            hop(from: 2, to: 1),
        ])
        #expect(coordinator.desktopDidChange(to: topology(current: 2)).isEmpty)
        #expect(coordinator.desktopDidChange(to: topology(current: 1)).isEmpty)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("System animation is retained across every hop to a far desktop")
    func systemAnimationIsRetainedAcrossHops() throws {
        var coordinator = SpaceSwitchCoordinator()

        let hops = coordinator.request(
            to: location(3),
            in: topology(current: 0),
            animation: .system
        ).hops

        #expect(hops.count == 3)
        #expect(hops.allSatisfy { $0.animation == .system })
    }

    @Test("A request back to the showing desktop returns once the posted route lands")
    func reversesAfterConfirmingInFlightRoute() {
        var coordinator = SpaceSwitchCoordinator()
        _ = coordinator.request(to: location(2), in: topology(current: 0))

        let reversal = coordinator.request(to: location(0), in: topology(current: 0))

        #expect(reversal == .coalesced)
        #expect(coordinator.desktopDidChange(to: topology(current: 1)).isEmpty)
        #expect(coordinator.desktopDidChange(to: topology(current: 2)) == [
            hop(from: 2, to: 1),
            hop(from: 1, to: 0),
        ])
        #expect(coordinator.desktopDidChange(to: topology(current: 1)).isEmpty)
        #expect(coordinator.desktopDidChange(to: topology(current: 0)).isEmpty)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("An unexpected landing stops instead of posting from an uncertain state")
    func unexpectedLandingStops() {
        var coordinator = SpaceSwitchCoordinator()
        _ = coordinator.request(to: location(2), in: topology(current: 0))

        let next = coordinator.desktopDidChange(to: topology(current: 3))

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
        let request = coordinator.request(
            to: location(2),
            in: topology(current: 0)
        )
        let hops = try #require(request.hops.isEmpty ? nil : request.hops)

        coordinator.postingFailed(hops)

        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
        #expect(coordinator.desktopDidChange(to: topology(current: 1)).isEmpty)
    }

    @Test("Opening a Dock overview cancels an unconfirmed switch")
    func overviewCancelsPendingSwitch() {
        var coordinator = SpaceSwitchCoordinator()
        _ = coordinator.request(to: location(1), in: topology(current: 0))
        #expect(coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))

        coordinator.cancelPendingSwitches()

        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
        #expect(coordinator.request(to: location(1), in: topology(current: 0)) != .coalesced)
    }

    @Test("A missed desktop notification is recovered from the posted endpoint")
    func missedNotificationCompletesAtEndpoint() throws {
        var coordinator = SpaceSwitchCoordinator()
        let request = coordinator.request(to: location(1), in: topology(current: 0))
        let ticket = try #require(coordinator.recoveryTicket(matching: request.hops))

        #expect(coordinator.recover(ticket, in: topology(current: 1)) == .completed)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("A missed notification continues a coalesced target only from the proven endpoint")
    func missedNotificationContinuesRetargetedRoute() throws {
        var coordinator = SpaceSwitchCoordinator()
        let first = coordinator.request(to: location(1), in: topology(current: 0))
        let ticket = try #require(coordinator.recoveryTicket(matching: first.hops))
        #expect(coordinator.request(to: location(2), in: topology(current: 0)) == .coalesced)

        #expect(coordinator.recover(ticket, in: topology(current: 1)) == .post([
            hop(from: 1, to: 2),
        ]))
        #expect(coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("A stalled route is abandoned without reposting from an uncertain desktop")
    func stalledRouteIsAbandoned() throws {
        var coordinator = SpaceSwitchCoordinator()
        let request = coordinator.request(to: location(2), in: topology(current: 0))
        let ticket = try #require(coordinator.recoveryTicket(matching: request.hops))

        #expect(coordinator.recover(ticket, in: topology(current: 0)) == .abandoned)
        #expect(!coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
        #expect(coordinator.request(to: location(1), in: topology(current: 0)) != .coalesced)
    }

    @Test("A stale watchdog cannot clear a newer route")
    func staleRecoveryTicketIsIgnored() throws {
        var coordinator = SpaceSwitchCoordinator()
        let first = coordinator.request(to: location(1), in: topology(current: 0))
        let staleTicket = try #require(coordinator.recoveryTicket(matching: first.hops))
        _ = coordinator.desktopDidChange(to: topology(current: 1))

        let second = coordinator.request(to: location(0), in: topology(current: 1))
        let currentTicket = try #require(coordinator.recoveryTicket(matching: second.hops))

        #expect(staleTicket != currentTicket)
        #expect(coordinator.recover(staleTicket, in: topology(current: 1)) == .stale)
        #expect(coordinator.isInFlight(stackID: SpaceTopology.sharedStackID))
    }

    @Test("A desktop route includes fullscreen Spaces in native order")
    func desktopRouteIncludesFullscreenSpaces() {
        var coordinator = SpaceSwitchCoordinator()
        let initialTopology = topology(
            currentSpaceID: 10,
            desktopIDs: [10, 12],
            orderedSpaceIDs: [10, 11, 12]
        )

        let request = coordinator.request(
            to: DesktopLocation(
                stackID: SpaceTopology.sharedStackID,
                desktopID: 12,
                index: 1
            ),
            in: initialTopology
        )

        #expect(request == .post([
            SpaceSwitchHop(
                stackID: SpaceTopology.sharedStackID,
                fromSpaceID: 10,
                toSpaceID: 11,
                direction: .right
            ),
            SpaceSwitchHop(
                stackID: SpaceTopology.sharedStackID,
                fromSpaceID: 11,
                toSpaceID: 12,
                direction: .right
            ),
        ]))
    }

    @Test("Adjacent switching can leave a fullscreen Space in either direction")
    func adjacentSwitchLeavesFullscreenSpace() {
        let initialTopology = topology(
            currentSpaceID: 11,
            desktopIDs: [10, 12],
            orderedSpaceIDs: [10, 11, 12]
        )

        var leftCoordinator = SpaceSwitchCoordinator()
        let leftOffset: Int = -1
        let left: SpaceSwitchRequestResult = leftCoordinator.requestAdjacent(
            offset: leftOffset,
            stackID: SpaceTopology.sharedStackID,
            in: initialTopology,
            animation: .configured
        )
        #expect(left == .post([
            SpaceSwitchHop(
                stackID: SpaceTopology.sharedStackID,
                fromSpaceID: 11,
                toSpaceID: 10,
                direction: .left
            ),
        ]))

        var rightCoordinator = SpaceSwitchCoordinator()
        let rightOffset: Int = 1
        let right: SpaceSwitchRequestResult = rightCoordinator.requestAdjacent(
            offset: rightOffset,
            stackID: SpaceTopology.sharedStackID,
            in: initialTopology,
            animation: .configured
        )
        #expect(right == .post([
            SpaceSwitchHop(
                stackID: SpaceTopology.sharedStackID,
                fromSpaceID: 11,
                toSpaceID: 12,
                direction: .right
            ),
        ]))
    }

    @Test("Adjacent switching reaches fullscreen Spaces at both native edges")
    func adjacentSwitchReachesFullscreenEdgeSpaces() {
        let orderedSpaceIDs: [CGSSpaceID] = [9, 10, 12, 13]

        var firstCoordinator = SpaceSwitchCoordinator()
        let first = firstCoordinator.requestAdjacent(
            offset: -1,
            stackID: SpaceTopology.sharedStackID,
            in: topology(
                currentSpaceID: 10,
                desktopIDs: [10, 12],
                orderedSpaceIDs: orderedSpaceIDs
            ),
            animation: .configured
        )
        #expect(first == .post([
            SpaceSwitchHop(
                stackID: SpaceTopology.sharedStackID,
                fromSpaceID: 10,
                toSpaceID: 9,
                direction: .left
            ),
        ]))

        var lastCoordinator = SpaceSwitchCoordinator()
        let last = lastCoordinator.requestAdjacent(
            offset: 1,
            stackID: SpaceTopology.sharedStackID,
            in: topology(
                currentSpaceID: 12,
                desktopIDs: [10, 12],
                orderedSpaceIDs: orderedSpaceIDs
            ),
            animation: .configured
        )
        #expect(last == .post([
            SpaceSwitchHop(
                stackID: SpaceTopology.sharedStackID,
                fromSpaceID: 12,
                toSpaceID: 13,
                direction: .right
            ),
        ]))
    }

    @Test("Repeated adjacent requests advance from the pending fullscreen target")
    func repeatedAdjacentRequestsAdvanceAcrossFullscreen() {
        var coordinator = SpaceSwitchCoordinator()
        let initialTopology = topology(
            currentSpaceID: 10,
            desktopIDs: [10, 12],
            orderedSpaceIDs: [10, 11, 12]
        )

        #expect(coordinator.requestAdjacent(
            offset: 1,
            stackID: SpaceTopology.sharedStackID,
            in: initialTopology,
            animation: .configured
        ).hops.map(\.toSpaceID) == [11])
        #expect(coordinator.requestAdjacent(
            offset: 1,
            stackID: SpaceTopology.sharedStackID,
            in: initialTopology,
            animation: .configured
        ) == .coalesced)
        #expect(coordinator.desktopDidChange(to: topology(
            currentSpaceID: 11,
            desktopIDs: [10, 12],
            orderedSpaceIDs: [10, 11, 12]
        )).map(\.toSpaceID) == [12])
    }
}

@Suite("Managed Space parsing")
struct ManagedSpaceParsingTests {
    @Test("Desktop identity stays type-zero while navigation keeps fullscreen order")
    func fullscreenSpacesRemainNavigable() {
        let identities = SpaceService.spaceIdentities(in: [
            "Spaces": [
                ["type": 4, "id64": NSNumber(value: 9), "uuid": "FULLSCREEN-FIRST"],
                ["type": 0, "id64": NSNumber(value: 10), "uuid": "DESKTOP-A"],
                ["type": 4, "id64": NSNumber(value: 11), "uuid": "FULLSCREEN-MIDDLE"],
                ["type": 0, "id64": NSNumber(value: 12), "uuid": "DESKTOP-B"],
                ["type": 4, "id64": NSNumber(value: 13), "uuid": "FULLSCREEN-LAST"],
            ],
        ])

        #expect(identities.desktopIDs == [10, 12])
        #expect(identities.desktopUUIDs == ["DESKTOP-A", "DESKTOP-B"])
        #expect(identities.orderedSpaceIDs == [9, 10, 11, 12, 13])
    }
}

@Suite("SpaceService switch speed")
struct SpaceServiceSpeedTests {

    @Test("System animation ignores the configured faster-switch duration")
    func systemAnimationIgnoresConfiguredDuration() {
        #expect(SpaceSwitchAnimation.configured.duration(configuredDuration: 0.07) == 0.07)
        #expect(
            SpaceSwitchAnimation.system.duration(configuredDuration: 0)
                == SpaceSwitchAnimation.systemDuration
        )
        #expect(
            SpaceSwitchAnimation.system.duration(configuredDuration: 0.13)
                == SpaceSwitchAnimation.systemDuration
        )
    }

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

    @Test("Progress rises from above zero to the whole distance")
    func progressSpansTheDistance() throws {
        let samples = DockSwipeAnimation.samples(duration: 0.12, distance: 3)
        let first = try #require(samples.first)
        let last = try #require(samples.last)
        #expect(first.progress > 0)
        #expect(abs(last.progress - 3) < 1e-9)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.delay < $1.delay })
    }

    @Test("Progress advances by the same amount every frame")
    func progressHasConstantSpeed() {
        let samples = DockSwipeAnimation.samples(duration: 0.2, distance: 2)
        let steps = zip([DockSwipeSample(delay: 0, progress: 0)] + samples, samples)
            .map { $1.progress - $0.progress }
        #expect(steps.allSatisfy { abs($0 - steps[0]) < 1e-9 })
    }

    @Test("A far route takes the same time as an adjacent one")
    func farRouteKeepsTheDuration() {
        let near = DockSwipeAnimation.samples(duration: 0.15, distance: 1)
        let far = DockSwipeAnimation.samples(duration: 0.15, distance: 4)
        #expect(near.map(\.delay) == far.map(\.delay))
    }

    @Test("Sample count follows the duration at the display's refresh rate")
    func sampleCountFollowsDuration() {
        #expect(DockSwipeAnimation.samples(duration: 0.1, sampleRate: 120).count == 12)
        #expect(DockSwipeAnimation.samples(duration: 0.1, sampleRate: 60).count == 6)
        #expect(DockSwipeAnimation.samples(duration: 0.2, sampleRate: 120).count == 24)
    }

    @Test("An unknown display samples at the fallback rate")
    func unknownDisplayUsesFallbackRate() {
        #expect(DockSwipeAnimation.sampleRate(of: nil) == DockSwipeAnimation.fallbackSampleRate)
    }

    // A duration far below one frame still has to produce a usable gesture rather than a
    // single sample the Dock reads as a flick.
    @Test("A duration shorter than one sample still sends two samples")
    func veryShortDurationStillAnimates() {
        #expect(DockSwipeAnimation.samples(duration: 0.001).count == 2)
    }

    @Test("One desktop of progress stops just short of the Dock's strip-relative desktop")
    func progressPerDesktopFollowsSpaceCount() {
        #expect(abs(DockSwipeAnimation.progressPerDesktop(spaceCount: 2) - 1.98) < 1e-9)
        #expect(abs(DockSwipeAnimation.progressPerDesktop(spaceCount: 3) - 1.485) < 1e-9)
        #expect(abs(DockSwipeAnimation.progressPerDesktop(spaceCount: 5) - 1.2375) < 1e-9)
    }
}

@Suite("DockSwipeRoute")
struct DockSwipeRouteTests {
    private func sample(_ progress: Double) -> DockSwipeSample {
        DockSwipeSample(delay: progress, progress: progress)
    }

    @Test("An adjacent route begins once, drags, and ends on the boundary")
    func adjacentRouteIsOneGesture() {
        let frames = DockSwipeRoute.strokes(for: [sample(0.5), sample(1)])
        #expect(frames == [
            [DockSwipeStroke(phase: .began, progress: 0),
             DockSwipeStroke(phase: .changed, progress: 0.5)],
            [DockSwipeStroke(phase: .changed, progress: 1),
             DockSwipeStroke(phase: .ended, progress: 1)],
        ])
    }

    @Test("Crossing a desktop boundary ends one gesture and begins the next in the same frame")
    func boundaryHandsOverWithinOneFrame() {
        let frames = DockSwipeRoute.strokes(for: [sample(0.75), sample(1.5), sample(2)])
        #expect(frames == [
            [DockSwipeStroke(phase: .began, progress: 0),
             DockSwipeStroke(phase: .changed, progress: 0.75)],
            [DockSwipeStroke(phase: .changed, progress: 1),
             DockSwipeStroke(phase: .ended, progress: 1),
             DockSwipeStroke(phase: .began, progress: 0),
             DockSwipeStroke(phase: .changed, progress: 0.5)],
            [DockSwipeStroke(phase: .changed, progress: 1),
             DockSwipeStroke(phase: .ended, progress: 1)],
        ])
    }

    @Test("A frame that lands exactly on a boundary opens the next gesture on the following frame")
    func exactBoundaryDefersTheNextGesture() {
        let frames = DockSwipeRoute.strokes(for: [sample(1), sample(2)])
        #expect(frames == [
            [DockSwipeStroke(phase: .began, progress: 0),
             DockSwipeStroke(phase: .changed, progress: 1),
             DockSwipeStroke(phase: .ended, progress: 1)],
            [DockSwipeStroke(phase: .began, progress: 0),
             DockSwipeStroke(phase: .changed, progress: 1),
             DockSwipeStroke(phase: .ended, progress: 1)],
        ])
    }

    @Test("Every gesture a route opens is ended")
    func everyGestureEnds() {
        let samples = DockSwipeAnimation.samples(duration: 0.3, distance: 3)
        let phases = DockSwipeRoute.strokes(for: samples).flatMap { $0.map(\.phase) }
        #expect(phases.filter { $0 == .began }.count == 3)
        #expect(phases.filter { $0 == .ended }.count == 3)
        #expect(phases.last == .ended)
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

    @Test("macOS 27 uses an augmented gesture while older and future releases stay gated")
    func postingModeByOperatingSystem() {
        #expect(DockSwipeCompatibility.mode(
            operatingSystemMajor: 26,
            build: "25G76",
            naturalScrolling: true
        ) == .legacy)
        #expect(DockSwipeCompatibility.mode(
            operatingSystemMajor: 27,
            build: "26A428",
            naturalScrolling: true
        ) == .augmented(invertSigns: true))
        #expect(DockSwipeCompatibility.mode(
            operatingSystemMajor: 28,
            build: "27A1",
            naturalScrolling: true
        ) == nil)
    }

    @Test("macOS 27 release signs follow Natural scrolling without misclassifying release builds as beta seeds")
    func augmentedSignCompatibility() {
        #expect(DockSwipeCompatibility.mode(
            operatingSystemMajor: 27,
            build: "26A428",
            naturalScrolling: false
        ) == .augmented(invertSigns: false))
        #expect(DockSwipeCompatibility.mode(
            operatingSystemMajor: 27,
            build: "26A5388g",
            naturalScrolling: false
        ) == .augmented(invertSigns: true))
        #expect(DockSwipeCompatibility.mode(
            operatingSystemMajor: 27,
            build: "26A5416b",
            naturalScrolling: false
        ) == .augmented(invertSigns: false))
    }

    @Test("macOS 27 posts the required Changed phase while legacy releases keep their pair")
    func instantPostingPhases() {
        #expect(DockSwipeEvent.instantPhases(for: .legacy) == [.began, .ended])
        #expect(DockSwipeEvent.instantPhases(
            for: .augmented(invertSigns: true)
        ) == [.began, .changed, .ended])
    }

    @Test("macOS 27 events mirror fields into a packed IOHID payload")
    func augmentedPayload() throws {
        let event = try #require(DockSwipeEvent.makeForPosting(
            phase: .ended,
            direction: .right,
            velocity: 9_999,
            progress: 1,
            mode: .augmented(invertSigns: true)
        ))

        #expect(event.getIntegerValueField(kCGEventGesturePhase) == kCGSGesturePhaseEnded)
        #expect(event.getIntegerValueField(kCGEventGesturePhase2) == kCGSGesturePhaseEnded)
        #expect(event.getDoubleValueField(kCGEventGestureFlavor) == 3)
        #expect(abs(event.getDoubleValueField(kCGEventGesturePositionX) - 0.1) < 0.000_001)
        #expect(event.getDoubleValueField(kCGEventGestureSwipeProgress) == -1)
        #expect(event.getDoubleValueField(kCGEventGestureSwipeVelocityX) == -9_999)

        let serialized = try #require(event.data as Data?)
        let payload = try #require(Self.binaryField(4_205, in: serialized))
        #expect(payload.count == 96)
        #expect(Self.littleEndianUInt32(payload, at: 24) == 2)
        #expect(Self.littleEndianUInt32(payload, at: 28) == 40)
        #expect(Self.littleEndianUInt32(payload, at: 32) == 23)
        #expect(Self.littleEndianInt32(payload, at: 64) == -65_536)
        #expect(Self.littleEndianUInt32(payload, at: 68) == 28)
        #expect(Self.littleEndianUInt32(payload, at: 72) == 9)
        #expect(Self.littleEndianInt32(payload, at: 84) == -655_294_464)
    }

    @Test("macOS 27 Began preserves a non-zero signed 16.16 progress epsilon")
    func augmentedBeganEpsilon() throws {
        let event = try #require(DockSwipeEvent.makeForPosting(
            phase: .began,
            direction: .left,
            velocity: 0,
            progress: 1,
            mode: .augmented(invertSigns: true)
        ))

        #expect(event.getDoubleValueField(kCGEventGestureSwipeProgress) == 1.0 / 65_536.0)
        let serialized = try #require(event.data as Data?)
        let payload = try #require(Self.binaryField(4_205, in: serialized))
        #expect(payload.count == 68)
        #expect(Self.littleEndianUInt32(payload, at: 24) == 1)
        #expect(Self.littleEndianInt32(payload, at: 64) == 1)
    }

    private static func binaryField(_ field: UInt16, in bytes: Data) -> Data? {
        guard bytes.count >= 4 else { return nil }
        var offset = 4
        while offset + 4 <= bytes.count {
            let elementSize = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            let tagAndField = (UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3])
            let tag = tagAndField >> 14
            let currentField = tagAndField & 0x3FFF
            let valueSize: Int
            switch (tag, elementSize) {
            case (0, 1): valueSize = 8
            case (0, let size) where size > 1: valueSize = Int(size)
            case (1, 1), (3, 1): valueSize = 4
            case (3, 2): valueSize = 8
            default: return nil
            }
            let end = offset + 4 + valueSize
            guard end <= bytes.count else { return nil }
            if currentField == field { return bytes.subdata(in: (offset + 4)..<end) }
            offset = end
        }
        return nil
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(0) { result, byte in
            result | (UInt32(byte.element) << UInt32(byte.offset * 8))
        }
    }

    private static func littleEndianInt32(_ data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: littleEndianUInt32(data, at: offset))
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

        let window = OffDesktopWindow()
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

        let window = OffDesktopWindow()
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

        let window = OffDesktopWindow()
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

    // Dropping the all-desktops window from windowLocations() is right for placement and wrong
    // for presence: absence from the placement set is what tells the reconciler SkyLight has a
    // window on no desktop at all, and a window on every desktop is the opposite of that.
    @Test("placedWindowIDs keeps the window windowLocations omits",
          .enabled(if: BridgedWindowManagementTests.hasSecondDesktop, "needs at least two user desktops"))
    @MainActor func placedWindowIDsIncludesAllSpacesWindow() throws {
        let service = SpaceService()
        #expect(service.userDesktops().count >= 2)

        let window = OffDesktopWindow()
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let windowID = CGWindowID(window.windowNumber)
        #expect(service.spaces(forWindow: windowID).count > 1)

        #expect(service.windowLocations()[windowID] == nil)
        #expect(service.placedWindowIDs().contains(windowID))
    }

    @Test("Repeated window-server verdict queries retain no window-server memory")
    @MainActor func verdictQueriesRetainNoWindowServerMemory() {
        let service = SpaceService()
        let windows = (0..<128).map { _ in
            let window = OffDesktopWindow()
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            return window
        }
        defer { windows.forEach { $0.close() } }
        let candidates = windows.map { CGWindowID($0.windowNumber) }

        _ = service.windowServerVerdicts(among: candidates)
        let bytesBefore = mallocBytesInUse()
        let queries = 200
        for _ in 0..<queries {
            _ = service.windowServerVerdicts(among: candidates)
        }
        let bytesAfter = mallocBytesInUse()

        #expect(bytesAfter - bytesBefore < queries * 1_024,
                "malloc bytes in use went from \(bytesBefore) to \(bytesAfter) over \(queries) queries")
    }
}

private func mallocBytesInUse() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return statistics.size_in_use
}
