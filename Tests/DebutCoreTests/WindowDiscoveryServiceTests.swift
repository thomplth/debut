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

    @Test("Activation samples focus before taking the reconciliation snapshot")
    func activationSamplesFocusFirst() {
        let windowService = MockWindowService()
        windowService.apps = [AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false)]
        windowService.windowList = [liveWindow(1), liveWindow(2), liveWindow(3), liveWindow(4)]
        windowService.allWindowIDList = [1, 2, 3, 4, 99]
        let service = WindowDiscoveryService(windowService: windowService) { _ in 4 }
        var callbackOrder: [String] = []
        var snapshotWindowIDs: Set<CGWindowID> = []
        var snapshotAllWindowIDs: Set<CGWindowID>?
        service.onWindowActivated = { _ in callbackOrder.append("focus") }
        service.onAppActivated = { snapshot in
            callbackOrder.append("snapshot")
            snapshotWindowIDs = Set(snapshot.liveWindows.map(\.windowID))
            snapshotAllWindowIDs = snapshot.allWindowIDs
        }

        service.handleAppActivation(AppInfo(bundleID: "notion.id", name: "Notion", pid: 10, isHidden: false))

        #expect(callbackOrder == ["focus", "snapshot"])
        #expect(snapshotWindowIDs == [1, 2, 3, 4])
        #expect(snapshotAllWindowIDs == [1, 2, 3, 4, 99])
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
