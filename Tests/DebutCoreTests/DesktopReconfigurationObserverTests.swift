import Foundation
import Testing
@testable import DebutCore

@Suite("Desktop reconfiguration observer")
struct DesktopReconfigurationObserverTests {
    @Test("The subscribed events are the measured Mission Control reconfiguration pair")
    func subscribesToMissionControlLifecycle() {
        // Measured on macOS 26.5.2 against a live Mission Control drag: 1327 arrived before
        // the reordered desktop list became readable and 1328 arrived 0.1s after it. The
        // constants are the whole contract with the window server, so they are pinned here
        // rather than left to drift silently into a no-op subscription.
        #expect(DesktopReconfigurationObserver.subscribedEvents == [1327, 1328])
        #expect(DesktopReconfigurationEvent.allCases == [.overviewWillOpen, .desktopListDidSettle])
        #expect(!DesktopReconfigurationEvent.overviewWillOpen.desktopListIsSettled)
        #expect(DesktopReconfigurationEvent.desktopListDidSettle.desktopListIsSettled)
    }

    @Test("A Dock layer-18 window identifies an overview without Screen Recording")
    func detectsDockOverviewWindow() {
        let ordinary: [[String: Any]] = [
            ["kCGWindowLayer": 0, "kCGWindowOwnerName": "Finder"],
            ["kCGWindowLayer": 18, "kCGWindowOwnerName": "Other"],
        ]
        let missionControl = ordinary + [
            ["kCGWindowLayer": 18, "kCGWindowOwnerName": "Dock"],
        ]

        #expect(!DockOverviewDetector.isActive(in: ordinary))
        #expect(DockOverviewDetector.isActive(in: missionControl))
    }

    @Test("Overview recovery yields once after the Dock overlay disappears")
    func overviewEligibilityRecovers() {
        let state = NavigationEligibilityState()
        let eligibility = DesktopNavigationEligibility(
            canSwitchSpaces: { state.canSwitch },
            overviewActive: { state.overviewActive },
            topology: { state.topology }
        )
        eligibility.updateStackID("display")
        eligibility.overviewWillOpen()

        state.overviewActive = true
        state.hasCurrentDesktop = false
        #expect(!eligibility.isAvailable())
        #expect(eligibility.blockReason() == .dockOverviewActive)

        state.overviewActive = false
        state.hasCurrentDesktop = true
        #expect(eligibility.blockReason() == .dockOverviewRecovery)
        #expect(eligibility.isAvailable())

        state.canSwitch = false
        #expect(!eligibility.isAvailable())
        #expect(eligibility.blockReason() == .syntheticSwitchUnsupported)
    }

    @Test("Subscribing reports the events it actually registered")
    func startReportsRegisteredEvents() {
        // The private symbol exists on every macOS this ships to, so an empty result would
        // mean the subscription silently stopped covering reorders.
        #expect(DesktopReconfigurationObserver.start() == [1327, 1328])
    }

    @Test("The layout notification reaches an observer on the main queue")
    func notificationReachesObservers() async {
        await confirmation("observer runs") { observed in
            await withCheckedContinuation { continuation in
                var token: (any NSObjectProtocol)?
                token = NotificationCenter.default.addObserver(
                    forName: .debutDesktopLayoutMayHaveChanged,
                    object: nil,
                    queue: .main
                ) { _ in
                    observed()
                    if let token { NotificationCenter.default.removeObserver(token) }
                    continuation.resume()
                }
                DispatchQueue.global().async {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .debutDesktopLayoutMayHaveChanged,
                            object: nil
                        )
                    }
                }
            }
        }
    }
}

private final class NavigationEligibilityState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCanSwitch = true
    private var storedOverviewActive = false
    private var storedHasCurrentDesktop = true

    var canSwitch: Bool {
        get { lock.withLock { storedCanSwitch } }
        set { lock.withLock { storedCanSwitch = newValue } }
    }

    var overviewActive: Bool {
        get { lock.withLock { storedOverviewActive } }
        set { lock.withLock { storedOverviewActive = newValue } }
    }

    var hasCurrentDesktop: Bool {
        get { lock.withLock { storedHasCurrentDesktop } }
        set { lock.withLock { storedHasCurrentDesktop = newValue } }
    }

    var topology: SpaceTopology {
        let current: CGSSpaceID? = hasCurrentDesktop ? 1 : nil
        return SpaceTopology(separateSpaces: true, stacks: [
            SpaceStackDescriptor(
                id: "display",
                displayID: 1,
                displayName: "Display",
                frame: .zero,
                desktopIDs: [1, 2],
                currentDesktopID: current
            ),
        ])
    }
}
