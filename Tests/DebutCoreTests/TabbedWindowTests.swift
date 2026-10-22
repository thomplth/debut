import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Native window tabs")
struct TabbedWindowTests {
    private let finder = AppInfo(bundleID: "com.apple.finder", name: "Finder", pid: 850, isHidden: false)
    private let backgroundTab: CGWindowID = 268
    private let selectedTab: CGWindowID = 629

    private final class Published: @unchecked Sendable {
        var snapshots: [(snapshot: RuntimeWindowSnapshot, event: WindowServerWindowEvent)] = []
    }

    private struct Harness {
        let service: WindowDiscoveryService
        let windowService: MockWindowService
        let events: MockWindowServerEvents
        let published: Published
    }

    private func makeHarness(reads: DeferredDiscoveryRead? = nil) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTabbedWindowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windowService = MockWindowService()
        windowService.apps = [finder]
        windowService.windowList = [tab(selectedTab)]
        let events = MockWindowServerEvents()
        let service = WindowDiscoveryService(
            windowService: windowService,
            discoveryReadScheduler: reads.map { reads in { reads.schedule($0) } },
            frontmostPIDProvider: { nil },
            processExitMonitor: MockProcessExitMonitor(),
            windowServerEvents: events,
            diagnosticReporter: DiagnosticReporter(directory: directory)
        )
        service.armingOverride = { _, _ in .armed }
        service.windowElementOverride = { _, _ in nil }
        let published = Published()
        service.onWindowOrderChanged = { snapshot, event in
            published.snapshots.append((snapshot, event))
        }
        service.startWindowServerFocus()
        service.registerTracking(windowID: backgroundTab, pid: finder.pid)
        service.registerTracking(windowID: selectedTab, pid: finder.pid)
        return Harness(service: service, windowService: windowService, events: events, published: published)
    }

    private func tab(_ windowID: CGWindowID) -> WindowInfo {
        WindowInfo(
            windowID: windowID,
            ownerBundleID: finder.bundleID,
            ownerName: finder.name,
            ownerPID: finder.pid,
            title: "Downloads",
            bounds: CGRect(x: 29, y: 290, width: 920, height: 464),
            isOnScreen: windowID == selectedTab
        )
    }

    private func orderOutBehindNewTab(_ harness: Harness) {
        harness.windowService.orderedOutWindowIDList = [backgroundTab]
        harness.events.send(.windowOrderedOut, backgroundTab, at: 200)
    }

    @Test("A tab ordered out behind its group's selected tab is published for parking")
    func orderedOutTabIsPublishedForParking() throws {
        let harness = try makeHarness()

        orderOutBehindNewTab(harness)

        let published = try #require(harness.published.snapshots.first)
        #expect(harness.published.snapshots.count == 1)
        #expect(published.event == .windowOrderedOut)
        #expect(published.snapshot.orderedOutWindowIDs == [backgroundTab])
        #expect(published.snapshot.liveWindows.isEmpty)
    }

    @Test("An order-out the window server does not call a ghost publishes nothing")
    func orderOutWithoutGhostVerdictPublishesNothing() throws {
        let harness = try makeHarness()

        harness.events.send(.windowOrderedOut, backgroundTab, at: 200)

        #expect(harness.published.snapshots.isEmpty)
    }

    @Test("A parked tab is published live again when the user selects it")
    func parkedTabIsPublishedWhenOrderedIn() throws {
        let harness = try makeHarness()
        orderOutBehindNewTab(harness)

        harness.windowService.orderedOutWindowIDList = []
        harness.windowService.windowList = [tab(backgroundTab), tab(selectedTab)]
        harness.events.send(.windowOrderedIn, backgroundTab, at: 201)

        let published = try #require(harness.published.snapshots.last)
        #expect(harness.published.snapshots.count == 2)
        #expect(published.event == .windowOrderedIn)
        #expect(published.snapshot.liveWindows.map(\.windowID) == [backgroundTab])
        #expect(published.snapshot.orderedOutWindowIDs.isEmpty)
    }

    @Test("An order-in of a window that was never parked asks no app for its windows")
    func orderInOfUnparkedWindowAsksNoApp() throws {
        let harness = try makeHarness()

        harness.events.send(.windowOrderedIn, selectedTab, at: 200)

        #expect(harness.windowService.scopedListRequests.isEmpty)
        #expect(harness.published.snapshots.isEmpty)
    }

    @Test("A tab ordered back in before its order-out read lands is not parked")
    func orderInBeforeTheReadLandsKeepsTheTab() throws {
        let reads = DeferredDiscoveryRead()
        let harness = try makeHarness(reads: reads)

        orderOutBehindNewTab(harness)
        harness.events.send(.windowOrderedIn, backgroundTab, at: 200.05)
        reads.runAll()

        #expect(harness.published.snapshots.isEmpty)
    }

    @Test("Order-outs arriving while a read is out are judged by a later read")
    func orderOutDuringAReadIsJudgedByTheNextRead() throws {
        let reads = DeferredDiscoveryRead()
        let harness = try makeHarness(reads: reads)

        harness.events.send(.windowOrderedOut, selectedTab, at: 200)
        orderOutBehindNewTab(harness)
        reads.runAll()

        #expect(harness.published.snapshots.flatMap(\.snapshot.orderedOutWindowIDs) == [backgroundTab])
    }

    @Test("The reconciler parks a background tab and restores it to its own slot when it returns")
    func reconcilerParksAndRestoresTheTab() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        for windowID in [selectedTab, backgroundTab] {
            manager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: finder.bundleID,
                            ownerName: finder.name, windowTitle: "Downloads", ownerPID: finder.pid),
                toSpaceID: spaceID
            )
        }
        let slotBefore = manager.activeSpace.windows.map(\.windowID)
        var reconciler = RuntimeWindowReconciler()

        let parking = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: [], allWindowIDs: nil, orderedOutWindowIDs: [backgroundTab]),
            spaceManager: &manager
        )

        #expect(manager.activeSpace.windows.map(\.windowID) == [selectedTab])
        #expect(parking.events.map(\.reason) == [.orderedOut])
        #expect(parking.dormantCount == 1)

        let restoring = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: [tab(backgroundTab)], allWindowIDs: nil),
            spaceManager: &manager,
            allowDormantBundleFallback: false
        )

        #expect(manager.activeSpace.windows.map(\.windowID) == slotBefore)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(restoring.events.map(\.reason) == [.dormantRestored])
    }
}
