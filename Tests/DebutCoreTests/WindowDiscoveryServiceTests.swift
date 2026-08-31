import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

final class MockProcessExitMonitor: ProcessExitMonitoring, @unchecked Sendable {
    private(set) var monitoredPIDs: Set<pid_t> = []
    private(set) var cancelledPIDs: [pid_t] = []
    private var handlers: [pid_t: @Sendable (pid_t) -> Void] = [:]

    func startMonitoring(pid: pid_t, onExit: @escaping @Sendable (pid_t) -> Void) {
        guard handlers[pid] == nil else { return }
        monitoredPIDs.insert(pid)
        handlers[pid] = onExit
    }

    func stopMonitoring(pid: pid_t) {
        monitoredPIDs.remove(pid)
        handlers.removeValue(forKey: pid)
        cancelledPIDs.append(pid)
    }

    func stopMonitoringAll() {
        for pid in monitoredPIDs {
            stopMonitoring(pid: pid)
        }
    }

    func emitExit(pid: pid_t) {
        handlers[pid]?(pid)
    }
}

@Suite("WindowDiscoveryService")
struct WindowDiscoveryServiceTests {
    private func liveWindow(_ windowID: CGWindowID, ownerPID: pid_t = 10) -> WindowInfo {
        WindowInfo(
            windowID: windowID,
            ownerBundleID: "notion.id",
            ownerName: "Notion",
            ownerPID: ownerPID,
            title: "Window \(windowID)",
            bounds: .zero,
            isOnScreen: true
        )
    }

    @Test("Activation reconciles the early focus sample before publishing focus")
    func activationReconcilesBeforePublishingFocus() {
        let windowService = MockWindowService()
        windowService.apps = [AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false)]
        windowService.windowList = [liveWindow(1), liveWindow(2), liveWindow(3), liveWindow(4)]
        windowService.allWindowIDList = [1, 2, 3, 4, 99]
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in 4 },
            processExitMonitor: MockProcessExitMonitor()
        )
        var callbackOrder: [String] = []
        var snapshotWindowIDs: Set<CGWindowID> = []
        var snapshotAllWindowIDs: Set<CGWindowID>?
        var snapshotFocusedWindowID: CGWindowID?
        service.onFrontmostAppChanged = { bundleID in
            callbackOrder.append("app:\(bundleID ?? "nil")")
        }
        service.onWindowActivated = { _ in callbackOrder.append("focus") }
        service.onAppActivated = { snapshot in
            callbackOrder.append("snapshot")
            snapshotWindowIDs = Set(snapshot.liveWindows.map(\.windowID))
            snapshotAllWindowIDs = snapshot.allWindowIDs
            snapshotFocusedWindowID = snapshot.focusedWindowID
        }

        service.handleAppActivation(AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false))

        #expect(callbackOrder == ["app:notion.id", "snapshot", "focus"])
        #expect(snapshotWindowIDs == [1, 2, 3, 4])
        #expect(snapshotAllWindowIDs == [1, 2, 3, 4, 99])
        #expect(snapshotFocusedWindowID == 4)
    }

    // The reconciler decides space membership from the snapshot alone, so a snapshot that
    // omits desktops silently reverts it to guessing from the active space.
    @Test("Activation snapshots carry the desktop macOS reports for each window")
    func activationSnapshotCarriesDesktops() {
        let windowService = MockWindowService()
        windowService.apps = [AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false)]
        windowService.windowList = [liveWindow(1), liveWindow(2)]
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        spaces.windowDesktops = [1: 0, 2: 2]
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in 1 },
            processExitMonitor: MockProcessExitMonitor()
        )
        service.spaceSwitcher = spaces
        var desktopIndexes: [CGWindowID: Int] = [:]
        service.onAppActivated = { desktopIndexes = $0.desktopIndexes }

        service.handleAppActivation(AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false))

        #expect(desktopIndexes == [1: 0, 2: 2])
    }

    // Dragging a window to another desktop activates no app, so the activation snapshot never
    // fires and the assignment stayed stale until the user clicked the window — the move was
    // invisible in Debut until then. A desktop change has to take its own snapshot.
    @Test("A desktop refresh snapshots where every window now is")
    func desktopRefreshSnapshotsDesktops() {
        let windowService = MockWindowService()
        windowService.apps = [AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false)]
        windowService.windowList = [liveWindow(1), liveWindow(2)]
        windowService.allWindowIDList = [1, 2]
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        spaces.windowDesktops = [1: 0, 2: 2]
        let service = WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        )
        service.spaceSwitcher = spaces
        var snapshot: RuntimeWindowSnapshot?
        service.onDesktopsChanged = { snapshot = $0 }

        service.refreshDesktopAssignments()

        #expect(snapshot?.desktopIndexes == [1: 0, 2: 2])
        #expect(snapshot?.liveWindows.map(\.windowID) == [1, 2])
        // Nothing was activated, so naming a focused window would reorder a space on a
        // refresh that is only meant to answer "where is everything now".
        #expect(snapshot?.focusedWindowID == nil)
    }

    @Test("Startup reconcile places each window on the desktop it is actually on")
    func startupReconcilePlacesByDesktop() {
        let windowService = MockWindowService()
        windowService.apps = [AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false)]
        windowService.windowList = [liveWindow(1), liveWindow(2)]
        windowService.allWindowIDList = [1, 2]
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        spaces.windowDesktops = [1: 2, 2: 1]
        let service = WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        )
        service.spaceSwitcher = spaces
        var manager = SpaceManager()
        SpaceController.reconcileSpaces(&manager, desktopCount: 3)

        service.reconcileWindows(&manager)

        #expect(manager.spaceContainingWindow(windowID: 1) == manager.spaces[2].id)
        #expect(manager.spaceContainingWindow(windowID: 2) == manager.spaces[1].id)
    }

    // The first-run path bypasses the reconciler entirely, so it needs the desktop rule
    // spelled out separately or a fresh install collapses every desktop onto space 1.
    @Test("First-run population places windows by desktop rather than all on space 1")
    func defaultSpacePopulationPlacesByDesktop() {
        let windowService = MockWindowService()
        windowService.apps = [AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false)]
        windowService.windowList = [liveWindow(1), liveWindow(2)]
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.windowDesktops = [1: 1, 2: 0]
        let service = WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        )
        service.spaceSwitcher = spaces
        var manager = SpaceManager()
        SpaceController.reconcileSpaces(&manager, desktopCount: 2)

        service.populateDefaultSpace(&manager)

        #expect(manager.spaceContainingWindow(windowID: 1) == manager.spaces[1].id)
        #expect(manager.spaceContainingWindow(windowID: 2) == manager.spaces[0].id)
    }

    @Test("Launch publishes its complete window batch before focused-window activation")
    func knownLaunchedWindowStillActivates() {
        let windowService = MockWindowService()
        windowService.windowList = [liveWindow(3, ownerPID: 30)]
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in 3 },
            frontmostPIDProvider: { 30 },
            launchDiscoveryDelay: 0,
            processExitMonitor: MockProcessExitMonitor()
        )
        service.registerTracking(windowID: 3, pid: 30)

        var availableWindowIDs: [CGWindowID] = []
        var activatedWindowIDs: [CGWindowID] = []
        var callbackOrder: [String] = []
        service.onWindowsDiscovered = {
            callbackOrder.append("windows")
            availableWindowIDs = $0.map(\.windowID)
        }
        service.onWindowActivated = {
            callbackOrder.append("focus")
            activatedWindowIDs.append($0)
        }

        service.handleAppLaunch(
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 30, isHidden: false)
        )

        #expect(availableWindowIDs == [3])
        #expect(activatedWindowIDs == [3])
        #expect(callbackOrder == ["windows", "focus"])
    }

    @Test("Activation falls back to the activated app's frontmost enumerated window")
    func activationFallsBackToEnumeratedWindow() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 30, isHidden: false),
        ]
        windowService.windowList = [
            liveWindow(3, ownerPID: 30),
            liveWindow(4, ownerPID: 30),
        ]
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in nil },
            processExitMonitor: MockProcessExitMonitor()
        )
        var activatedWindowIDs: [CGWindowID] = []
        var snapshotFocusedWindowID: CGWindowID?
        service.onWindowActivated = { activatedWindowIDs.append($0) }
        service.onAppActivated = { snapshotFocusedWindowID = $0.focusedWindowID }

        service.handleAppActivation(
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 30, isHidden: false)
        )

        #expect(activatedWindowIDs == [3])
        #expect(snapshotFocusedWindowID == 3)
    }

    @Test("Activation replaces a stale focused window with the frontmost live window")
    func activationReplacesStaleFocusedWindow() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 30, isHidden: false),
        ]
        windowService.windowList = [
            liveWindow(3, ownerPID: 30),
            liveWindow(4, ownerPID: 30),
        ]
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in 99 },
            processExitMonitor: MockProcessExitMonitor()
        )
        var activatedWindowIDs: [CGWindowID] = []
        var snapshotFocusedWindowID: CGWindowID?
        service.onWindowActivated = { activatedWindowIDs.append($0) }
        service.onAppActivated = { snapshotFocusedWindowID = $0.focusedWindowID }

        service.handleAppActivation(
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 30, isHidden: false)
        )

        #expect(activatedWindowIDs == [3])
        #expect(snapshotFocusedWindowID == 3)
    }

    @Test("Empty window snapshot does not erase state while apps are running")
    func emptySnapshotWithRunningApps() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "com.a", name: "A", pid: 10, isHidden: false),
        ]

        var spaceManager = SpaceManager()
        spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Saved", ownerPID: 10),
            toSpaceID: spaceManager.activeSpaceID
        )

        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        ).reconcileWindows(&spaceManager)

        #expect(spaceManager.activeSpace.windows.map(\.windowID) == [101])
    }

    @Test("Startup reconciliation makes explicitly untrackable AX windows dormant")
    func startupMakesUntrackableWindowsDormant() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "com.google.Chrome", name: "Chrome", pid: 10, isHidden: false),
        ]
        windowService.windowList = [WindowInfo(
            windowID: 1,
            ownerBundleID: "com.google.Chrome",
            ownerName: "Chrome",
            ownerPID: 10,
            title: "Tab",
            bounds: .zero,
            isOnScreen: true
        )]
        windowService.untrackableWindowIDList = [99]

        var spaceManager = SpaceManager()
        let spaceID = spaceManager.activeSpaceID
        spaceManager.addWindow(
            SpaceWindow(windowID: 1, ownerBundleID: "com.google.Chrome", ownerName: "Chrome", windowTitle: "Tab", ownerPID: 10),
            toSpaceID: spaceID
        )
        spaceManager.addWindow(
            SpaceWindow(windowID: 99, ownerBundleID: "com.google.Chrome", ownerName: "Chrome", windowTitle: "Recent Download History", ownerPID: 10),
            toSpaceID: spaceID
        )

        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        ).reconcileWindows(&spaceManager)

        #expect(spaceManager.activeSpace.windows.map(\.windowID) == [1])
        // A misreported classification must stay recoverable. Deleting the
        // assignment discards the only record of where the window belonged.
        #expect(spaceManager.dormantWindowAssignments.map(\.window.windowID) == [99])
        #expect(spaceManager.dormantWindowAssignments.first?.spaceID == spaceID)
    }

    @Test("A window misreported as untrackable returns to its own space, not the active one")
    func untrackableWindowReturnsToItsOriginalSpace() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "company.thebrowser.dia", name: "Dia", pid: 10, isHidden: false),
        ]
        windowService.untrackableWindowIDList = [22357]

        var spaceManager = SpaceManager()
        spaceManager.createSpace(position: .below)
        spaceManager.createSpace(position: .below)
        let originalSpaceID = spaceManager.spaces[2].id
        spaceManager.addWindow(
            SpaceWindow(windowID: 22357, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Leisure", ownerPID: 10),
            toSpaceID: originalSpaceID
        )

        let service = WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        )
        service.reconcileWindows(&spaceManager)
        #expect(spaceManager.dormantWindowAssignments.count == 1)

        // The classification recovers, and the browser has retitled the window
        // in the meantime — the case that defeats exact-title matching.
        windowService.untrackableWindowIDList = []
        windowService.windowList = [WindowInfo(
            windowID: 22357,
            ownerBundleID: "company.thebrowser.dia",
            ownerName: "Dia",
            ownerPID: 10,
            title: "Develop: something else",
            bounds: .zero,
            isOnScreen: true
        )]
        service.reconcileWindows(&spaceManager)

        #expect(spaceManager.dormantWindowAssignments.isEmpty)
        #expect(spaceManager.spaces[0].windows.isEmpty)
        #expect(spaceManager.spaces[2].windows.map(\.windowID) == [22357])
    }

    @Test("Untrackable dormancy is reported with the placement it set aside")
    func untrackableDormancyIsReported() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutDiscoveryDiag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "company.thebrowser.dia", name: "Dia", pid: 10, isHidden: false),
        ]
        windowService.untrackableWindowIDList = [22357]

        var spaceManager = SpaceManager()
        spaceManager.createSpace(position: .below)
        spaceManager.addWindow(
            SpaceWindow(windowID: 22357, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Leisure", ownerPID: 10),
            toSpaceID: spaceManager.spaces[1].id
        )

        let reporter = DiagnosticReporter(directory: directory)
        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor(),
            diagnosticReporter: reporter
        ).reconcileWindows(&spaceManager)
        reporter.flush()

        let lines = try String(contentsOf: directory.appendingPathComponent("diagnostic.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
        let dormancy = try #require(lines.first { $0["event"] == "window_made_dormant" })
        #expect(dormancy["reason"] == "untrackable")
        #expect(dormancy["windowID"] == "22357")
        #expect(dormancy["bundleID"] == "company.thebrowser.dia")
        #expect(dormancy["windowTitle"] == "Leisure")
        #expect(dormancy["fromSpace"] == "1")

        let summary = try #require(lines.first { $0["event"] == "windows_reconciled" })
        #expect(summary["untrackable"] == "1")
    }

    @Test("Empty window snapshot makes stopped-app assignments dormant")
    func emptySnapshotMakesStoppedWindowsDormant() {
        let windowService = MockWindowService()
        var spaceManager = SpaceManager()
        spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Saved", ownerPID: 10),
            toSpaceID: spaceManager.activeSpaceID
        )

        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        ).reconcileWindows(&spaceManager)

        #expect(spaceManager.activeSpace.windows.isEmpty)
        #expect(spaceManager.dormantWindowAssignments.map(\.window.windowID) == [101])
    }

    @Test("Startup reconciliation restores a dormant window after relaunch")
    func startupRestoresDormantWindowAfterRelaunch() {
        let windowService = MockWindowService()
        var spaceManager = SpaceManager()
        let originalSpaceID = spaceManager.activeSpaceID
        spaceManager.createSpace(position: .below)
        spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Saved", ownerPID: 10),
            toSpaceID: originalSpaceID
        )
        _ = spaceManager.makeWindowsDormant(forOwnerPID: 10)
        windowService.apps = [AppInfo(bundleID: "com.a", name: "A", pid: 20, isHidden: false)]
        windowService.windowList = [WindowInfo(
            windowID: 201,
            ownerBundleID: "com.a",
            ownerName: "A",
            ownerPID: 20,
            title: "Saved",
            bounds: .zero,
            isOnScreen: true
        )]
        windowService.allWindowIDList = [201]

        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        ).reconcileWindows(&spaceManager)

        #expect(spaceManager.dormantWindowAssignments.isEmpty)
        #expect(spaceManager.spaceContainingWindow(windowID: 201) == originalSpaceID)
    }

    @Test("Startup partial snapshot preserves omitted windows and their spaces")
    func startupPartialSnapshotPreservesAssignments() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false),
        ]
        windowService.windowList = [liveWindow(1)]

        var spaceManager = SpaceManager()
        let space1 = spaceManager.spaces[0].id
        spaceManager.createSpace(position: .below)
        let space2 = spaceManager.spaces[1].id
        spaceManager.addWindow(
            SpaceWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Window 1", ownerPID: 10),
            toSpaceID: space1
        )
        spaceManager.addWindow(
            SpaceWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Window 2", ownerPID: 10),
            toSpaceID: space2
        )

        let discovery = WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        )
        discovery.reconcileWindows(&spaceManager)

        #expect(spaceManager.spaceContainingWindow(windowID: 1) == space1)
        #expect(spaceManager.spaceContainingWindow(windowID: 2) == space2)

        windowService.windowList = [liveWindow(1), liveWindow(2)]
        discovery.reconcileWindows(&spaceManager)

        #expect(spaceManager.spaceContainingWindow(windowID: 1) == space1)
        #expect(spaceManager.spaceContainingWindow(windowID: 2) == space2)
    }

    @Test("Tracking a window also monitors its process even when AX registration fails")
    func trackingStartsProcessExitMonitoring() {
        let processExitMonitor = MockProcessExitMonitor()
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: processExitMonitor
        )

        service.registerTracking(windowID: 101, pid: 10)

        #expect(processExitMonitor.monitoredPIDs == [10])
    }

    @Test("Direct and workspace exit signals share idempotent cleanup")
    func duplicateProcessExitSignalsAreIdempotent() {
        let processExitMonitor = MockProcessExitMonitor()
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: processExitMonitor
        )
        var terminatedPIDs: [pid_t] = []
        service.onAppTerminated = { terminatedPIDs.append($0) }
        service.registerTracking(windowID: 101, pid: 10)

        processExitMonitor.emitExit(pid: 10)
        service.handleProcessExit(pid: 10)

        #expect(terminatedPIDs == [10])
        #expect(!processExitMonitor.monitoredPIDs.contains(10))
    }

    @Test("Observer pruning does not discard process exit monitoring")
    func observerPruningKeepsProcessExitMonitoring() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "com.b", name: "B", pid: 20, isHidden: false),
        ]
        let processExitMonitor = MockProcessExitMonitor()
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in nil },
            processExitMonitor: processExitMonitor
        )
        service.registerTracking(windowID: 101, pid: 10)

        service.handleAppActivation(
            AppInfo(bundleID: "com.b", name: "B", pid: 20, isHidden: false)
        )

        #expect(processExitMonitor.monitoredPIDs.contains(10))
    }

    @Test("A hidden tracked app remains live until its process exits")
    func hiddenAppDoesNotTriggerTermination() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "com.a", name: "A", pid: 10, isHidden: true),
        ]
        let processExitMonitor = MockProcessExitMonitor()
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in nil },
            processExitMonitor: processExitMonitor
        )
        var terminatedPIDs: [pid_t] = []
        service.onAppTerminated = { terminatedPIDs.append($0) }
        service.registerTracking(windowID: 101, pid: 10)

        service.handleAppActivation(
            AppInfo(bundleID: "com.a", name: "A", pid: 10, isHidden: true)
        )

        #expect(terminatedPIDs.isEmpty)
        #expect(processExitMonitor.monitoredPIDs.contains(10))
    }

    @Test("Rapid same-bundle relaunch makes the old window dormant and restores the new one")
    func rapidSameBundleRelaunchRestoresDormantAssignment() {
        let oldPID: pid_t = 10
        let newPID: pid_t = 20
        let windowService = MockWindowService()
        let processExitMonitor = MockProcessExitMonitor()
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in nil },
            frontmostPIDProvider: { nil },
            launchDiscoveryDelay: 0,
            processExitMonitor: processExitMonitor
        )
        var spaceManager = SpaceManager()
        let originalSpaceID = spaceManager.activeSpaceID
        spaceManager.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "com.a",
                ownerName: "A",
                windowTitle: "Document",
                ownerPID: oldPID
            ),
            toSpaceID: originalSpaceID
        )
        service.onAppTerminated = { pid in
            _ = spaceManager.makeWindowsDormant(forOwnerPID: pid)
        }
        service.onWindowsDiscovered = { windows in
            var reconciler = RuntimeWindowReconciler()
            _ = reconciler.reconcile(
                RuntimeWindowSnapshot(liveWindows: windows, allWindowIDs: nil),
                spaceManager: &spaceManager
            )
        }
        service.registerTracking(windowID: 101, pid: oldPID)

        processExitMonitor.emitExit(pid: oldPID)
        windowService.windowList = [WindowInfo(
            windowID: 201,
            ownerBundleID: "com.a",
            ownerName: "A",
            ownerPID: newPID,
            title: "Document",
            bounds: .zero,
            isOnScreen: true
        )]
        service.handleAppLaunch(
            AppInfo(bundleID: "com.a", name: "A", pid: newPID, isHidden: false)
        )

        #expect(spaceManager.dormantWindowAssignments.isEmpty)
        #expect(spaceManager.spaceContainingWindow(windowID: 201) == originalSpaceID)
        #expect(spaceManager.spaces.flatMap(\.windows).map(\.windowID) == [201])
        #expect(processExitMonitor.monitoredPIDs == [newPID])
    }

    @Test("A window ID reused by a different process is re-armed rather than skipped as already tracked")
    func reusedWindowIDForNewProcessIsRearmed() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        var attempts: [(CGWindowID, pid_t)] = []
        service.armingOverride = { windowID, pid in
            attempts.append((windowID, pid))
            return .armed
        }

        service.registerTracking(windowID: 101, pid: 10)
        // The old process's exit was never signaled, so bookkeeping still points at pid 10
        // when a new process reuses windowID 101.
        service.registerTracking(windowID: 101, pid: 20)

        #expect(attempts.map(\.1) == [10, 20])
        #expect(service.diagnosticTrackingSnapshot.windowOwners.first { $0.windowID == 101 }?.ownerPID == 20)
    }

    @Test("Launch discovery re-tracks a window ID that was already known under a different process")
    func launchDiscoveryRetracksReusedWindowIDForNewProcess() {
        let windowService = MockWindowService()
        let processExitMonitor = MockProcessExitMonitor()
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in nil },
            frontmostPIDProvider: { nil },
            launchDiscoveryDelay: 0,
            processExitMonitor: processExitMonitor
        )
        var attempts: [(CGWindowID, pid_t)] = []
        service.armingOverride = { windowID, pid in
            attempts.append((windowID, pid))
            return .armed
        }
        service.registerTracking(windowID: 101, pid: 10)

        // Old process's exit signal never arrives (missed/delayed), so armedWindowIDs and
        // windowOwnerPIDs still point at the old PID when the new process reuses windowID 101.
        windowService.windowList = [WindowInfo(
            windowID: 101,
            ownerBundleID: "com.a",
            ownerName: "A",
            ownerPID: 20,
            title: "Document",
            bounds: .zero,
            isOnScreen: true
        )]
        service.handleAppLaunch(AppInfo(bundleID: "com.a", name: "A", pid: 20, isHidden: false))

        #expect(attempts.map(\.1) == [10, 20])
        #expect(processExitMonitor.monitoredPIDs.contains(20))
    }

    // MARK: - Lifecycle notification arming

    @Test("A window whose notifications were rejected is not treated as tracked")
    func rejectedArmingLeavesWindowUnarmed() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        service.armingOverride = { _, _ in .notificationRejected(-25204) }

        service.registerTracking(windowID: 1, pid: 10)

        #expect(service.unarmedWindowIDs == [1])
        #expect(service.armedWindowIDs.isEmpty)
    }

    @Test("Arming is retried after a rejection instead of being blocked forever")
    func armingIsRetriedAfterRejection() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        var attempts = 0
        service.armingOverride = { _, _ in
            attempts += 1
            return attempts == 1 ? .notificationRejected(-25204) : .armed
        }

        service.registerTracking(windowID: 1, pid: 10)
        service.registerTracking(windowID: 1, pid: 10)

        #expect(attempts == 2)
        #expect(service.armedWindowIDs == [1])
        #expect(service.unarmedWindowIDs.isEmpty)
    }

    @Test("A recycled AX element renews an inherited notification registration")
    func recycledElementRenewsInheritedNotificationRegistration() {
        var addResults: [AXError] = [.notificationAlreadyRegistered, .success]
        var addCount = 0
        var removeCount = 0

        let result = WindowDiscoveryService.renewNotificationRegistration(
            add: {
                addCount += 1
                return addResults.removeFirst()
            },
            remove: {
                removeCount += 1
                return .success
            }
        )

        #expect(result == .success)
        #expect(addCount == 2)
        #expect(removeCount == 1)
    }

    @Test("An armed window is not re-armed on every activation")
    func armedWindowIsNotRearmed() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        var attempts = 0
        service.armingOverride = { _, _ in
            attempts += 1
            return .armed
        }

        service.registerTracking(windowID: 1, pid: 10)
        service.registerTracking(windowID: 1, pid: 10)
        service.registerTracking(windowID: 1, pid: 10)

        #expect(attempts == 1)
    }

    @Test("Reset clears tracking caches and allows live windows to be armed again")
    func resetWindowTracking() {
        let processExitMonitor = MockProcessExitMonitor()
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: processExitMonitor
        )
        var attempts = 0
        service.armingOverride = { _, _ in
            attempts += 1
            return .armed
        }
        service.registerTracking(windowID: 1, pid: 10)

        service.resetWindowTracking()

        #expect(service.diagnosticTrackingSnapshot.knownWindowIDs.isEmpty)
        #expect(service.diagnosticTrackingSnapshot.armedWindowIDs.isEmpty)
        #expect(service.diagnosticTrackingSnapshot.windowOwners.isEmpty)
        #expect(processExitMonitor.monitoredPIDs.isEmpty)

        service.registerTracking(windowID: 1, pid: 10)
        #expect(attempts == 2)
        #expect(service.armedWindowIDs == [1])
    }

    @Test("An unresolvable window element is recorded as unarmed, not silently dropped")
    func unresolvableElementIsRecordedUnarmed() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        service.armingOverride = { _, _ in .elementUnavailable }

        service.registerTracking(windowID: 7, pid: 10)

        #expect(service.unarmedWindowIDs == [7])
    }

    @Test("A window whose AX element is never found is reported untrackable after repeated failures")
    func persistentElementLookupFailureReportsUntrackable() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        service.armingOverride = { _, _ in .elementUnavailable }
        var untrackableWindowIDs: [CGWindowID] = []
        service.onWindowUntrackable = { untrackableWindowIDs.append($0) }

        service.registerTracking(windowID: 7, pid: 10)
        service.registerTracking(windowID: 7, pid: 10)
        #expect(untrackableWindowIDs.isEmpty)

        service.registerTracking(windowID: 7, pid: 10)

        #expect(untrackableWindowIDs == [7])
        #expect(service.unarmedWindowIDs.isEmpty)
        #expect(service.persistentlyUnarmableWindowIDs == [7])
    }

    @Test("Arming successfully resets the element-lookup failure count")
    func successfulArmResetsElementUnavailableCount() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        var attempts = 0
        service.armingOverride = { _, _ in
            attempts += 1
            return attempts <= 2 ? .elementUnavailable : .armed
        }
        var untrackableWindowIDs: [CGWindowID] = []
        service.onWindowUntrackable = { untrackableWindowIDs.append($0) }

        service.registerTracking(windowID: 7, pid: 10)
        service.registerTracking(windowID: 7, pid: 10)
        service.registerTracking(windowID: 7, pid: 10)

        #expect(service.armedWindowIDs == [7])
        #expect(untrackableWindowIDs.isEmpty)
    }

    @Test("A window flagged untrackable stops being re-discovered as live")
    func persistentlyUnarmableWindowStopsRetryingAfterThreshold() {
        let windowService = MockWindowService()
        windowService.windowList = [liveWindow(7)]
        windowService.apps = [AppInfo(bundleID: "com.a", name: "A", pid: 10, isHidden: false)]
        let service = WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        )
        var attempts = 0
        service.armingOverride = { _, _ in
            attempts += 1
            return .elementUnavailable
        }
        var untrackableWindowIDs: [CGWindowID] = []
        service.onWindowUntrackable = { untrackableWindowIDs.append($0) }

        var spaceManager = SpaceManager()
        service.reconcileWindows(&spaceManager)
        service.reconcileWindows(&spaceManager)
        service.reconcileWindows(&spaceManager)
        service.reconcileWindows(&spaceManager)

        #expect(attempts == 3)
        #expect(untrackableWindowIDs == [7])
        #expect(service.persistentlyUnarmableWindowIDs == [7])
    }

    @Test("Process exit clears both armed and unarmed records for that app")
    func processExitClearsArmingRecords() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        service.armingOverride = { windowID, _ in windowID == 1 ? .armed : .elementUnavailable }
        service.registerTracking(windowID: 1, pid: 10)
        service.registerTracking(windowID: 2, pid: 10)
        service.registerTracking(windowID: 3, pid: 20)

        service.handleProcessExit(pid: 10)

        #expect(service.armedWindowIDs == [])
        #expect(service.unarmedWindowIDs == [3])
    }

    @Test("Unarmed windows reach the reconciler through the activation snapshot")
    func unarmedWindowsSurfaceInSnapshot() {
        let windowService = MockWindowService()
        windowService.apps = [AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false)]
        windowService.windowList = [liveWindow(1), liveWindow(2)]
        windowService.allWindowIDList = [1, 2]
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in 1 },
            processExitMonitor: MockProcessExitMonitor()
        )
        service.armingOverride = { windowID, _ in windowID == 2 ? .elementUnavailable : .armed }
        var snapshotUnarmed: Set<CGWindowID> = []
        service.onAppActivated = { snapshotUnarmed = $0.unarmedWindowIDs }

        service.handleAppActivation(AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false))

        #expect(snapshotUnarmed == [2])
    }

    @Test("A tracked window exposes its AX element so raising need not rescan every app")
    func trackedWindowExposesElement() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        let element = AXUIElementCreateSystemWide()
        service.windowElementOverride = { _, _ in element }
        service.armingOverride = { _, _ in .armed }

        service.registerTracking(windowID: 101, pid: 10)

        #expect(service.trackedWindowElement(windowID: 101) != nil)
        #expect(service.trackedWindowElement(windowID: 999) == nil)
    }

    @Test("A window that fails to arm exposes no element")
    func unarmedWindowExposesNoElement() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        let element = AXUIElementCreateSystemWide()
        service.windowElementOverride = { _, _ in element }
        service.armingOverride = { _, _ in .elementUnavailable }

        service.registerTracking(windowID: 101, pid: 10)

        #expect(service.trackedWindowElement(windowID: 101) == nil)
    }

    @Test("A destroyed window stops exposing its AX element")
    func destroyedWindowDropsElement() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        let element = AXUIElementCreateSystemWide()
        service.windowElementOverride = { _, _ in element }
        service.armingOverride = { _, _ in .armed }
        service.registerTracking(windowID: 101, pid: 10)

        service.handleWindowDestroyed(element: element)

        #expect(service.trackedWindowElement(windowID: 101) == nil)
    }

    @Test("Resetting window tracking clears exposed AX elements")
    func resetClearsExposedElements() {
        let service = WindowDiscoveryService(
            windowService: MockWindowService(),
            processExitMonitor: MockProcessExitMonitor()
        )
        let element = AXUIElementCreateSystemWide()
        service.windowElementOverride = { _, _ in element }
        service.armingOverride = { _, _ in .armed }
        service.registerTracking(windowID: 101, pid: 10)

        service.resetWindowTracking()

        #expect(service.trackedWindowElement(windowID: 101) == nil)
    }
}
