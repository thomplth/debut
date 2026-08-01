import CoreGraphics
import Testing
@testable import DebutCore

@Suite("RuntimeWindowReconciler")
struct RuntimeWindowReconcilerTests {
    private func liveWindow(
        _ windowID: CGWindowID,
        bundleID: String = "notion.id",
        ownerName: String = "Notion",
        ownerPID: pid_t = 10,
        title: String = "Window"
    ) -> WindowInfo {
        WindowInfo(
            windowID: windowID,
            ownerBundleID: bundleID,
            ownerName: ownerName,
            ownerPID: ownerPID,
            title: title,
            bounds: .zero,
            isOnScreen: true
        )
    }

    @Test("Adds missing live windows without moving existing assignments")
    func addsMissingLiveWindows() {
        var manager = StageManager()
        let stage1 = manager.stages[0].id
        manager.createStage(position: .below)
        let stage2 = manager.stages[1].id
        manager.activateStage(id: stage2)
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toStageID: stage1)
        manager.addWindow(StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toStageID: stage2)

        var reconciler = RuntimeWindowReconciler()
        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                runningPIDs: [10],
                liveWindows: [liveWindow(1), liveWindow(2), liveWindow(3, title: "Missing")],
                allWindowIDs: [1, 2, 3]
            ),
            stageManager: &manager
        )

        #expect(result.addedCount == 1)
        #expect(manager.stageContainingWindow(windowID: 1) == stage1)
        #expect(manager.stageContainingWindow(windowID: 2) == stage2)
        #expect(manager.stageContainingWindow(windowID: 3) == stage2)
    }

    @Test("Promotes only the focused newly discovered window to MRU")
    func focusedNewWindowBecomesMRU() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(
            StageWindow(windowID: 1, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Current", ownerPID: 10),
            toStageID: stageID
        )
        manager.addWindow(
            StageWindow(windowID: 2, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Older", ownerPID: 20),
            toStageID: stageID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                runningPIDs: [10, 20, 30],
                liveWindows: [
                    liveWindow(1, bundleID: "com.a", ownerName: "A", ownerPID: 10),
                    liveWindow(2, bundleID: "com.b", ownerName: "B", ownerPID: 20),
                    liveWindow(3, bundleID: "com.c", ownerName: "C", ownerPID: 30),
                    liveWindow(4, bundleID: "com.c", ownerName: "C", ownerPID: 30),
                ],
                allWindowIDs: [1, 2, 3, 4],
                focusedWindowID: 4
            ),
            stageManager: &manager
        )

        #expect(result.addedCount == 2)
        #expect(manager.activeStage.windows.map(\.windowID) == [4, 1, 2, 3])
    }

    @Test("Removes a closed window from a running app after two misses")
    func removesClosedWindowAfterTwoMisses() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Live", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 99, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Transient", ownerPID: 10), toStageID: stageID)
        let snapshot = RuntimeWindowSnapshot(
            runningPIDs: [10],
            liveWindows: [liveWindow(1, bundleID: "company.thebrowser.dia", ownerName: "Dia")],
            allWindowIDs: [1]
        )
        var reconciler = RuntimeWindowReconciler(requiredMissingSnapshots: 2)

        let first = reconciler.reconcile(snapshot, stageManager: &manager)
        #expect(first.removedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 99) != nil)

        let second = reconciler.reconcile(snapshot, stageManager: &manager)
        #expect(second.removedCount == 1)
        #expect(manager.stageContainingWindow(windowID: 99) == nil)
    }

    @Test("Explicitly untrackable AX windows are removed immediately")
    func removesUntrackableWindowsImmediately() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "com.google.Chrome", ownerName: "Chrome", windowTitle: "Tab", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 99, ownerBundleID: "com.google.Chrome", ownerName: "Chrome", windowTitle: "Recent Download History", ownerPID: 10), toStageID: stageID)
        var reconciler = RuntimeWindowReconciler(requiredMissingSnapshots: 2)

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                runningPIDs: [10],
                liveWindows: [liveWindow(1, bundleID: "com.google.Chrome", ownerName: "Chrome")],
                allWindowIDs: [1, 99],
                untrackableWindowIDs: [99]
            ),
            stageManager: &manager
        )

        #expect(result.removedCount == 1)
        #expect(manager.stageContainingWindow(windowID: 1) == stageID)
        #expect(manager.stageContainingWindow(windowID: 99) == nil)
    }

    @Test("Failed empty snapshots preserve windows and do not count as misses")
    func failedSnapshotsDoNotCountAsMisses() {
        var manager = StageManager()
        manager.addWindow(StageWindow(windowID: 99, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Window", ownerPID: 10), toStageID: manager.activeStageID)
        let failedSnapshot = RuntimeWindowSnapshot(runningPIDs: [10], liveWindows: [], allWindowIDs: nil)
        let authoritativeMiss = RuntimeWindowSnapshot(runningPIDs: [10], liveWindows: [liveWindow(1)], allWindowIDs: [1])
        var reconciler = RuntimeWindowReconciler(requiredMissingSnapshots: 2)

        _ = reconciler.reconcile(failedSnapshot, stageManager: &manager)
        _ = reconciler.reconcile(failedSnapshot, stageManager: &manager)
        let firstRealMiss = reconciler.reconcile(authoritativeMiss, stageManager: &manager)

        #expect(firstRealMiss.removedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 99) != nil)
    }

    @Test("Dead PID cleanup remains immediate when the window snapshot failed")
    func deadPIDCleanupIsImmediate() {
        var manager = StageManager()
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "com.live", ownerName: "Live", windowTitle: "Live", ownerPID: 10), toStageID: manager.activeStageID)
        manager.addWindow(StageWindow(windowID: 99, ownerBundleID: "com.dead", ownerName: "Dead", windowTitle: "Dead", ownerPID: 20), toStageID: manager.activeStageID)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(runningPIDs: [10], liveWindows: [], allWindowIDs: nil),
            stageManager: &manager
        )

        #expect(result.removedCount == 1)
        #expect(manager.stageContainingWindow(windowID: 1) != nil)
        #expect(manager.stageContainingWindow(windowID: 99) == nil)
    }

    @Test("A reappearing window resets its consecutive miss count")
    func reappearingWindowResetsMissCount() {
        var manager = StageManager()
        manager.addWindow(StageWindow(windowID: 99, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Window", ownerPID: 10), toStageID: manager.activeStageID)
        var reconciler = RuntimeWindowReconciler(requiredMissingSnapshots: 2)
        let missing = RuntimeWindowSnapshot(runningPIDs: [10], liveWindows: [liveWindow(1)], allWindowIDs: [1])
        let present = RuntimeWindowSnapshot(runningPIDs: [10], liveWindows: [liveWindow(99)], allWindowIDs: [99])

        _ = reconciler.reconcile(missing, stageManager: &manager)
        _ = reconciler.reconcile(present, stageManager: &manager)
        let nextMiss = reconciler.reconcile(missing, stageManager: &manager)

        #expect(nextMiss.removedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 99) != nil)
    }

    @Test("A non-empty partial AX snapshot preserves omitted windows")
    func partialSnapshotPreservesOmittedWindows() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toStageID: stageID)
        var reconciler = RuntimeWindowReconciler(requiredMissingSnapshots: 1)

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                runningPIDs: [10],
                liveWindows: [liveWindow(1)],
                allWindowIDs: [1, 2]
            ),
            stageManager: &manager
        )

        #expect(result.removedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 2) == stageID)
    }

    @Test("Repeated non-empty partial AX snapshots preserve omitted windows")
    func repeatedPartialSnapshotsPreserveOmittedWindows() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toStageID: stageID)
        let partialSnapshot = RuntimeWindowSnapshot(
            runningPIDs: [10],
            liveWindows: [liveWindow(1)],
            allWindowIDs: [1, 2]
        )
        var reconciler = RuntimeWindowReconciler(requiredMissingSnapshots: 2)

        _ = reconciler.reconcile(partialSnapshot, stageManager: &manager)
        let second = reconciler.reconcile(partialSnapshot, stageManager: &manager)

        #expect(second.removedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 2) == stageID)
    }

    @Test("Recovery from partial AX snapshots preserves original stage ownership")
    func recoveryPreservesOriginalStageOwnership() {
        var manager = StageManager()
        let stage1 = manager.stages[0].id
        manager.createStage(position: .below)
        let stage2 = manager.stages[1].id
        manager.activateStage(id: stage2)
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toStageID: stage1)
        manager.addWindow(StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toStageID: stage2)
        let partialSnapshot = RuntimeWindowSnapshot(
            runningPIDs: [10],
            liveWindows: [liveWindow(2)],
            allWindowIDs: [1, 2]
        )
        var reconciler = RuntimeWindowReconciler(requiredMissingSnapshots: 2)

        _ = reconciler.reconcile(partialSnapshot, stageManager: &manager)
        _ = reconciler.reconcile(partialSnapshot, stageManager: &manager)
        let recovered = reconciler.reconcile(
            RuntimeWindowSnapshot(
                runningPIDs: [10],
                liveWindows: [liveWindow(1), liveWindow(2)],
                allWindowIDs: [1, 2]
            ),
            stageManager: &manager
        )

        #expect(recovered.addedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 1) == stage1)
        #expect(manager.stageContainingWindow(windowID: 2) == stage2)
    }

    @Test("A failed CG snapshot does not count AX omissions as misses")
    func failedCGSnapshotDoesNotCountAXOmissions() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toStageID: stageID)
        var reconciler = RuntimeWindowReconciler(requiredMissingSnapshots: 1)

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                runningPIDs: [10],
                liveWindows: [liveWindow(1)],
                allWindowIDs: nil
            ),
            stageManager: &manager
        )

        #expect(result.removedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 2) == stageID)
    }
}
