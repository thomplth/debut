import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

private final class MockProcessExitMonitor: ProcessExitMonitoring, @unchecked Sendable {
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

    @Test("Empty window snapshot does not erase state while apps are running")
    func emptySnapshotWithRunningApps() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "com.a", name: "A", pid: 10, isHidden: false),
        ]

        var stageManager = StageManager()
        stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Saved", ownerPID: 10),
            toStageID: stageManager.activeStageID
        )

        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        ).reconcileWindows(&stageManager)

        #expect(stageManager.activeStage.windows.map(\.windowID) == [101])
    }

    @Test("Startup reconciliation removes explicitly untrackable AX windows")
    func startupRemovesUntrackableWindows() {
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

        var stageManager = StageManager()
        let stageID = stageManager.activeStageID
        stageManager.addWindow(
            StageWindow(windowID: 1, ownerBundleID: "com.google.Chrome", ownerName: "Chrome", windowTitle: "Tab", ownerPID: 10),
            toStageID: stageID
        )
        stageManager.addWindow(
            StageWindow(windowID: 99, ownerBundleID: "com.google.Chrome", ownerName: "Chrome", windowTitle: "Recent Download History", ownerPID: 10),
            toStageID: stageID
        )

        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        ).reconcileWindows(&stageManager)

        #expect(stageManager.activeStage.windows.map(\.windowID) == [1])
    }

    @Test("Empty window snapshot makes stopped-app assignments dormant")
    func emptySnapshotMakesStoppedWindowsDormant() {
        let windowService = MockWindowService()
        var stageManager = StageManager()
        stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Saved", ownerPID: 10),
            toStageID: stageManager.activeStageID
        )

        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        ).reconcileWindows(&stageManager)

        #expect(stageManager.activeStage.windows.isEmpty)
        #expect(stageManager.dormantWindowAssignments.map(\.window.windowID) == [101])
    }

    @Test("Startup reconciliation restores a dormant window after relaunch")
    func startupRestoresDormantWindowAfterRelaunch() {
        let windowService = MockWindowService()
        var stageManager = StageManager()
        let originalStageID = stageManager.activeStageID
        stageManager.createStage(position: .below)
        stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Saved", ownerPID: 10),
            toStageID: originalStageID
        )
        _ = stageManager.makeWindowsDormant(forOwnerPID: 10)
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
        ).reconcileWindows(&stageManager)

        #expect(stageManager.dormantWindowAssignments.isEmpty)
        #expect(stageManager.stageContainingWindow(windowID: 201) == originalStageID)
    }

    @Test("Startup partial snapshot preserves omitted windows and their stages")
    func startupPartialSnapshotPreservesAssignments() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false),
        ]
        windowService.windowList = [liveWindow(1)]

        var stageManager = StageManager()
        let stage1 = stageManager.stages[0].id
        stageManager.createStage(position: .below)
        let stage2 = stageManager.stages[1].id
        stageManager.addWindow(
            StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Window 1", ownerPID: 10),
            toStageID: stage1
        )
        stageManager.addWindow(
            StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Window 2", ownerPID: 10),
            toStageID: stage2
        )

        let discovery = WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        )
        discovery.reconcileWindows(&stageManager)

        #expect(stageManager.stageContainingWindow(windowID: 1) == stage1)
        #expect(stageManager.stageContainingWindow(windowID: 2) == stage2)

        windowService.windowList = [liveWindow(1), liveWindow(2)]
        discovery.reconcileWindows(&stageManager)

        #expect(stageManager.stageContainingWindow(windowID: 1) == stage1)
        #expect(stageManager.stageContainingWindow(windowID: 2) == stage2)
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
        var stageManager = StageManager()
        let originalStageID = stageManager.activeStageID
        stageManager.addWindow(
            StageWindow(
                windowID: 101,
                ownerBundleID: "com.a",
                ownerName: "A",
                windowTitle: "Document",
                ownerPID: oldPID
            ),
            toStageID: originalStageID
        )
        service.onAppTerminated = { pid in
            _ = stageManager.makeWindowsDormant(forOwnerPID: pid)
        }
        service.onWindowsDiscovered = { windows in
            var reconciler = RuntimeWindowReconciler()
            _ = reconciler.reconcile(
                RuntimeWindowSnapshot(liveWindows: windows, allWindowIDs: nil),
                stageManager: &stageManager
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

        #expect(stageManager.dormantWindowAssignments.isEmpty)
        #expect(stageManager.stageContainingWindow(windowID: 201) == originalStageID)
        #expect(stageManager.stages.flatMap(\.windows).map(\.windowID) == [201])
        #expect(processExitMonitor.monitoredPIDs == [newPID])
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
}
