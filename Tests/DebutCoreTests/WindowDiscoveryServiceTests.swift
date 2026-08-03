import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

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
        let service = WindowDiscoveryService(windowService: windowService) { _ in 4 }
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

    @Test("Activation snapshots identify other hidden applications")
    func activationSnapshotIncludesHiddenPIDs() {
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false),
            AppInfo(bundleID: "company.thebrowser.dia", name: "Dia", pid: 20, isHidden: true),
        ]
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in nil }
        )
        var hiddenPIDs: Set<pid_t> = []
        service.onAppActivated = { hiddenPIDs = $0.hiddenPIDs }

        service.handleAppActivation(
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false)
        )

        #expect(hiddenPIDs == [20])
    }

    @Test("Delayed launch activates a focused window already known from reconciliation")
    func knownLaunchedWindowStillActivates() async throws {
        let windowService = MockWindowService()
        windowService.windowList = [liveWindow(3, ownerPID: 30)]
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusedWindowProvider: { _ in 3 },
            frontmostPIDProvider: { 30 },
            launchDiscoveryDelay: 0
        )
        service.registerTracking(windowID: 3, pid: 30)

        var discoveredWindowIDs: [CGWindowID] = []
        var activatedWindowIDs: [CGWindowID] = []
        service.onWindowDiscovered = { discoveredWindowIDs.append($0.windowID) }
        service.onWindowActivated = { activatedWindowIDs.append($0) }

        service.handleAppLaunch(
            AppInfo(bundleID: "notion.id", name: "Notion", pid: 30, isHidden: false)
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(discoveredWindowIDs.isEmpty)
        #expect(activatedWindowIDs == [3])
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
            focusedWindowProvider: { _ in nil }
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

        WindowDiscoveryService(windowService: windowService).reconcileWindows(&stageManager)

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

        WindowDiscoveryService(windowService: windowService).reconcileWindows(&stageManager)

        #expect(stageManager.activeStage.windows.map(\.windowID) == [1])
    }

    @Test("Empty window snapshot clears stale state when no apps are running")
    func emptySnapshotWithoutRunningApps() {
        let windowService = MockWindowService()
        var stageManager = StageManager()
        stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Saved", ownerPID: 10),
            toStageID: stageManager.activeStageID
        )

        WindowDiscoveryService(windowService: windowService).reconcileWindows(&stageManager)

        #expect(stageManager.activeStage.windows.isEmpty)
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

        let discovery = WindowDiscoveryService(windowService: windowService)
        discovery.reconcileWindows(&stageManager)

        #expect(stageManager.stageContainingWindow(windowID: 1) == stage1)
        #expect(stageManager.stageContainingWindow(windowID: 2) == stage2)

        windowService.windowList = [liveWindow(1), liveWindow(2)]
        discovery.reconcileWindows(&stageManager)

        #expect(stageManager.stageContainingWindow(windowID: 1) == stage1)
        #expect(stageManager.stageContainingWindow(windowID: 2) == stage2)
    }
}
