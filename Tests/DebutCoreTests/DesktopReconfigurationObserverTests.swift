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

        #expect(!DockOverviewDetector.isActive(
            in: ordinary, operatingSystemMajor: 26, displayBounds: []
        ))
        #expect(DockOverviewDetector.isActive(
            in: missionControl, operatingSystemMajor: 26, displayBounds: []
        ))
    }

    @Test("macOS 27 WindowManager overlays identify every overview without matching thumbnails")
    func detectsWindowManagerOverviewWindows() {
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let ordinary: [[String: Any]] = [
            ["kCGWindowLayer": 19, "kCGWindowOwnerName": "WindowManager",
             "kCGWindowBounds": CGRect(x: 20, y: 20, width: 700, height: 500).dictionaryRepresentation],
            ["kCGWindowLayer": 18, "kCGWindowOwnerName": "Dock",
             "kCGWindowBounds": display.dictionaryRepresentation],
        ]
        let missionControl = ordinary + [[
            "kCGWindowLayer": 19, "kCGWindowOwnerName": "WindowManager",
            "kCGWindowBounds": display.dictionaryRepresentation,
        ]]
        let showDesktop = ordinary + [[
            "kCGWindowLayer": 18, "kCGWindowOwnerName": "WindowManager",
            "kCGWindowBounds": display.dictionaryRepresentation,
        ]]

        #expect(!DockOverviewDetector.isActive(
            in: ordinary, operatingSystemMajor: 27, displayBounds: [display]
        ))
        #expect(DockOverviewDetector.isActive(
            in: missionControl, operatingSystemMajor: 27, displayBounds: [display]
        ))
        #expect(DockOverviewDetector.isActive(
            in: showDesktop, operatingSystemMajor: 27, displayBounds: [display]
        ))
    }

    @Test("Overview recovery yields once after the Dock overlay disappears")
    func overviewEligibilityRecovers() {
        let state = NavigationEligibilityState()
        let eligibility = DesktopNavigationEligibility(
            canSwitchSpaces: { state.canSwitch },
            requiresOverviewRecovery: true
        )
        eligibility.update(
            stackID: "display",
            topology: state.topology,
            overviewActive: false
        )
        #expect(eligibility.overviewWillOpen(confirmed: true))

        state.overviewActive = true
        state.hasCurrentDesktop = false
        #expect(!eligibility.isAvailable())
        #expect(eligibility.blockReason() == .dockOverviewActive)

        state.overviewActive = false
        state.hasCurrentDesktop = true
        eligibility.update(
            stackID: "display",
            topology: state.topology,
            overviewActive: false
        )
        #expect(eligibility.blockReason() == .dockOverviewRecovery)
        #expect(eligibility.isAvailable())

        state.canSwitch = false
        #expect(!eligibility.isAvailable())
        #expect(eligibility.blockReason() == .syntheticSwitchUnsupported)
    }

    @Test("macOS 27 does not sacrifice the first post-overview navigation input")
    func modernOverviewEligibilityResumesImmediately() {
        let state = NavigationEligibilityState()
        let eligibility = DesktopNavigationEligibility(
            canSwitchSpaces: { state.canSwitch },
            requiresOverviewRecovery: false
        )
        eligibility.update(
            stackID: "display",
            topology: state.topology,
            overviewActive: false
        )
        #expect(eligibility.overviewWillOpen(confirmed: true))
        eligibility.update(
            stackID: "display",
            topology: state.topology,
            overviewActive: false
        )

        #expect(eligibility.blockReason() == nil)
    }

    @Test("An unconfirmed reconfiguration signal cannot poison the next navigation input")
    func unconfirmedOverviewSignalIsIgnored() {
        let state = NavigationEligibilityState()
        let eligibility = DesktopNavigationEligibility(
            canSwitchSpaces: { state.canSwitch },
            requiresOverviewRecovery: true
        )
        eligibility.update(
            stackID: "display",
            topology: state.topology,
            overviewActive: false
        )

        #expect(!eligibility.overviewWillOpen(confirmed: false))
        #expect(eligibility.blockReason() == nil)
    }

    /// Runs scheduled checks by hand, so the tests control time instead of sleeping.
    final class ManualScheduler {
        var pending: [(delay: TimeInterval, work: () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            pending.append((delay, work))
        }
        /// Returns how many checks ran.
        @discardableResult
        func drain(limit: Int = 1_000) -> Int {
            var ran = 0
            while !pending.isEmpty, ran < limit {
                pending.removeFirst().work()
                ran += 1
            }
            return ran
        }
    }

    @Test("An overview whose marker appears after SkyLight's signal is still confirmed")
    func lateOverviewMarkerIsConfirmed() {
        // Tart, macOS 26: 1327 arrived before Dock's layer-18 marker, the signal was discarded,
        // and Debut claimed the next swipe and Control-arrow inside Mission Control.
        let scheduler = ManualScheduler()
        var probes = 0
        var confirmations = 0
        let confirmer = OverviewSignalConfirmer(
            isActive: { probes += 1; return probes >= 4 },
            schedule: scheduler.schedule
        )

        confirmer.signalReceived { confirmations += 1 }
        #expect(confirmations == 0)
        scheduler.drain()
        #expect(confirmations == 1)
        #expect(scheduler.pending.isEmpty)
    }

    @Test("A signal from an ordinary desktop transition expires after a bounded wait")
    func unconfirmedOverviewSignalExpires() {
        let scheduler = ManualScheduler()
        var probes = 0
        var confirmations = 0
        let confirmer = OverviewSignalConfirmer(
            isActive: { probes += 1; return false },
            schedule: scheduler.schedule
        )

        confirmer.signalReceived { confirmations += 1 }
        scheduler.drain()
        #expect(confirmations == 0)
        #expect(probes <= Int(
            OverviewSignalConfirmer.maximumWait / OverviewSignalConfirmer.checkInterval
        ) + 1)
        #expect(scheduler.pending.isEmpty)
    }

    @Test("An already visible marker confirms without scheduling a recheck")
    func visibleOverviewMarkerConfirmsImmediately() {
        let scheduler = ManualScheduler()
        var confirmations = 0
        let confirmer = OverviewSignalConfirmer(isActive: { true }, schedule: scheduler.schedule)

        confirmer.signalReceived { confirmations += 1 }
        #expect(confirmations == 1)
        #expect(scheduler.pending.isEmpty)
    }

    @Test("A completed desktop change stops rechecking its transition's signal")
    func desktopChangeCancelsOverviewConfirmation() {
        let scheduler = ManualScheduler()
        var markerVisible = false
        var confirmations = 0
        let confirmer = OverviewSignalConfirmer(
            isActive: { markerVisible },
            schedule: scheduler.schedule
        )

        confirmer.signalReceived { confirmations += 1 }
        confirmer.cancel()
        markerVisible = true
        scheduler.drain()
        #expect(confirmations == 0)
    }

    @Test("A newer signal replaces the rechecks of an older one")
    func newerOverviewSignalSupersedesOlder() {
        let scheduler = ManualScheduler()
        var markerVisible = false
        var confirmations = 0
        let confirmer = OverviewSignalConfirmer(
            isActive: { markerVisible },
            schedule: scheduler.schedule
        )

        confirmer.signalReceived { confirmations += 1 }
        confirmer.signalReceived { confirmations += 1 }
        markerVisible = true
        scheduler.drain()
        #expect(confirmations == 1)
    }

    @Test("Only macOS 26 needs the Dock post-overview recovery input")
    func overviewRecoveryPolicyMatchesOperatingSystem() {
        #expect(DesktopNavigationEligibility.requiresOverviewRecovery(
            operatingSystemMajor: 26
        ))
        #expect(!DesktopNavigationEligibility.requiresOverviewRecovery(
            operatingSystemMajor: 27
        ))
    }

    @Test("Every gesture stays native while cached Mission Control state is active")
    func overviewNeverTransfersTrackpadOwnership() {
        let state = NavigationEligibilityState()
        let eligibility = DesktopNavigationEligibility(canSwitchSpaces: { state.canSwitch })
        eligibility.update(
            stackID: "display",
            topology: state.topology,
            overviewActive: false
        )
        #expect(eligibility.overviewWillOpen(confirmed: true))

        #expect(eligibility.blockReason() == .dockOverviewActive)
        #expect(eligibility.blockReason() == .dockOverviewActive)
        #expect(eligibility.blockReason() == .dockOverviewActive)

        eligibility.update(
            stackID: "display",
            topology: state.topology,
            overviewActive: false,
            consumeOverviewRecovery: true
        )
        #expect(eligibility.isAvailable())
    }

    @Test("Unknown cached overview state fails native without querying live state")
    func unknownOverviewStateYieldsInput() {
        let eligibility = DesktopNavigationEligibility(canSwitchSpaces: { true })

        #expect(eligibility.blockReason() == .dockOverviewStateUnknown)
    }

    @Test("A fullscreen current Space remains eligible for accelerated navigation")
    func fullscreenCurrentSpaceIsEligible() {
        let eligibility = DesktopNavigationEligibility(canSwitchSpaces: { true })
        eligibility.update(
            stackID: "display",
            topology: SpaceTopology(separateSpaces: true, stacks: [
                SpaceStackDescriptor(
                    id: "display",
                    displayID: 1,
                    displayName: "Display",
                    frame: .zero,
                    desktopIDs: [10, 12],
                    orderedSpaceIDs: [10, 11, 12],
                    currentDesktopID: 11
                ),
            ]),
            overviewActive: false
        )

        #expect(eligibility.isAvailable())
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
