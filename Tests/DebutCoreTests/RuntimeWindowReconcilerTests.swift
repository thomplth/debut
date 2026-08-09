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

    @Test("CG absence never removes a window without a lifecycle event")
    func preservesMissingWindowForRunningProcess() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Live", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 99, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Transient", ownerPID: 10), toStageID: stageID)
        let snapshot = RuntimeWindowSnapshot(
            liveWindows: [liveWindow(1, bundleID: "company.thebrowser.dia", ownerName: "Dia")],
            allWindowIDs: [1]
        )
        var reconciler = RuntimeWindowReconciler()

        for _ in 0..<10 {
            _ = reconciler.reconcile(snapshot, stageManager: &manager)
        }
        #expect(manager.stageContainingWindow(windowID: 99) == stageID)
    }

    @Test("Failed and authoritative snapshots both preserve absent windows")
    func snapshotsPreserveAbsentWindows() {
        var manager = StageManager()
        manager.addWindow(StageWindow(windowID: 99, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Window", ownerPID: 10), toStageID: manager.activeStageID)
        let failedSnapshot = RuntimeWindowSnapshot(liveWindows: [], allWindowIDs: nil)
        let authoritativeMiss = RuntimeWindowSnapshot(liveWindows: [liveWindow(1)], allWindowIDs: [1])
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(failedSnapshot, stageManager: &manager)
        _ = reconciler.reconcile(failedSnapshot, stageManager: &manager)
        _ = reconciler.reconcile(authoritativeMiss, stageManager: &manager)

        #expect(manager.stageContainingWindow(windowID: 99) != nil)
    }

    @Test("A window snapshot never substitutes for a termination event")
    func snapshotDoesNotInferProcessTermination() {
        var manager = StageManager()
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "com.live", ownerName: "Live", windowTitle: "Live", ownerPID: 10), toStageID: manager.activeStageID)
        manager.addWindow(StageWindow(windowID: 99, ownerBundleID: "com.dead", ownerName: "Dead", windowTitle: "Dead", ownerPID: 20), toStageID: manager.activeStageID)
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: [], allWindowIDs: nil),
            stageManager: &manager
        )

        #expect(manager.stageContainingWindow(windowID: 1) != nil)
        #expect(manager.stageContainingWindow(windowID: 99) != nil)
    }

    @Test("Missing windows remain assigned without hidden-state information")
    func missingWindowsDoNotNeedHiddenState() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(
            StageWindow(
                windowID: 99,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toStageID: stageID
        )
        var reconciler = RuntimeWindowReconciler()
        let visibleMiss = RuntimeWindowSnapshot(
            liveWindows: [],
            allWindowIDs: []
        )
        for _ in 0..<10 {
            _ = reconciler.reconcile(visibleMiss, stageManager: &manager)
            #expect(manager.stageContainingWindow(windowID: 99) == stageID)
        }
    }

    @Test("A non-empty partial AX snapshot preserves omitted windows")
    func partialSnapshotPreservesOmittedWindows() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toStageID: stageID)
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(1)],
                allWindowIDs: [1, 2]
            ),
            stageManager: &manager
        )

        #expect(manager.stageContainingWindow(windowID: 2) == stageID)
    }

    @Test("Repeated non-empty partial AX snapshots preserve omitted windows")
    func repeatedPartialSnapshotsPreserveOmittedWindows() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toStageID: stageID)
        let partialSnapshot = RuntimeWindowSnapshot(
            liveWindows: [liveWindow(1)],
            allWindowIDs: [1, 2]
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(partialSnapshot, stageManager: &manager)
        _ = reconciler.reconcile(partialSnapshot, stageManager: &manager)

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
            liveWindows: [liveWindow(2)],
            allWindowIDs: [1, 2]
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(partialSnapshot, stageManager: &manager)
        _ = reconciler.reconcile(partialSnapshot, stageManager: &manager)
        let recovered = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(1), liveWindow(2)],
                allWindowIDs: [1, 2]
            ),
            stageManager: &manager
        )

        #expect(recovered.addedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 1) == stage1)
        #expect(manager.stageContainingWindow(windowID: 2) == stage2)
    }

    @Test("A failed CG snapshot preserves AX omissions")
    func failedCGSnapshotPreservesAXOmissions() {
        var manager = StageManager()
        let stageID = manager.activeStageID
        manager.addWindow(StageWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toStageID: stageID)
        manager.addWindow(StageWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toStageID: stageID)
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(1)],
                allWindowIDs: nil
            ),
            stageManager: &manager
        )

        #expect(manager.stageContainingWindow(windowID: 2) == stageID)
    }

    @Test("A recreated window keeps its stage when its stable identity matches")
    func recreatedWindowKeepsStageByStableIdentity() {
        var manager = StageManager()
        let originalStageID = manager.activeStageID
        manager.createStage(position: .below)
        let activeStageID = manager.activeStageID
        manager.addWindow(
            StageWindow(
                windowID: 1,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toStageID: originalStageID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(
                        101,
                        bundleID: "company.thebrowser.dia",
                        ownerName: "Dia",
                        ownerPID: 10,
                        title: "Work"
                    ),
                ],
                allWindowIDs: [101]
            ),
            stageManager: &manager
        )

        #expect(result.reassignedCount == 1)
        #expect(manager.stageContainingWindow(windowID: 101) == originalStageID)
        #expect(manager.stages.first(where: { $0.id == activeStageID })?.windows.isEmpty == true)
    }

    @Test("Reconciliation does not reclaim an already assigned duplicate title")
    func assignedDuplicateTitleIsNotReclaimed() {
        var manager = StageManager()
        let originalStageID = manager.activeStageID
        manager.createStage(position: .below)
        let activeStageID = manager.activeStageID
        manager.addWindow(
            StageWindow(
                windowID: 1,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toStageID: originalStageID
        )
        manager.addWindow(
            StageWindow(
                windowID: 101,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toStageID: activeStageID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(
                        101,
                        bundleID: "company.thebrowser.dia",
                        ownerName: "Dia",
                        ownerPID: 10,
                        title: "Work"
                    ),
                ],
                allWindowIDs: [101],
                focusedWindowID: 101
            ),
            stageManager: &manager
        )

        #expect(result.reassignedCount == 0)
        #expect(manager.stageContainingWindow(windowID: 101) == activeStageID)
        #expect(manager.stages.first(where: { $0.id == originalStageID })?.windows.map(\.windowID) == [1])
    }

    @Test("A later replacement reclaims the retained assignment without a timeout")
    func laterReplacementReclaimsRetainedAssignment() {
        var manager = StageManager()
        let originalStageID = manager.activeStageID
        manager.createStage(position: .below)
        let activeStageID = manager.activeStageID
        manager.addWindow(
            StageWindow(
                windowID: 1,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toStageID: originalStageID
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [],
                allWindowIDs: []
            ),
            stageManager: &manager
        )
        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(
                        101,
                        bundleID: "company.thebrowser.dia",
                        ownerName: "Dia",
                        ownerPID: 10,
                        title: "Work"
                    ),
                ],
                allWindowIDs: [101]
            ),
            stageManager: &manager
        )

        #expect(result.reassignedCount == 1)
        #expect(manager.stageContainingWindow(windowID: 101) == originalStageID)
        #expect(manager.stages.first(where: { $0.id == activeStageID })?.windows.isEmpty == true)
    }

    @Test("A complete bundle recreation falls back one-to-one to the original stages")
    func recreatedWindowsKeepStagesByBundleFallback() {
        var manager = StageManager()
        let stage1 = manager.activeStageID
        manager.createStage(position: .below)
        let stage2 = manager.activeStageID
        manager.createStage(position: .below)
        let activeStage = manager.activeStageID
        manager.addWindow(
            StageWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old A", ownerPID: 10),
            toStageID: stage1
        )
        manager.addWindow(
            StageWindow(windowID: 2, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old B", ownerPID: 10),
            toStageID: stage2
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(101, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 10, title: "New A"),
                    liveWindow(102, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 10, title: "New B"),
                ],
                allWindowIDs: [101, 102]
            ),
            stageManager: &manager
        )

        #expect(result.reassignedCount == 2)
        #expect(manager.stageContainingWindow(windowID: 101) == stage1)
        #expect(manager.stageContainingWindow(windowID: 102) == stage2)
        #expect(manager.stages.first(where: { $0.id == activeStage })?.windows.isEmpty == true)
    }

    @Test("A relaunched window reclaims its dormant assignment")
    func relaunchedWindowReclaimsDormantAssignment() {
        var manager = StageManager()
        let originalStageID = manager.activeStageID
        manager.createStage(position: .below)
        let activeStageID = manager.activeStageID
        manager.addWindow(
            StageWindow(
                windowID: 1,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toStageID: originalStageID
        )
        #expect(manager.makeWindowsDormant(forOwnerPID: 10) == 1)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(
                        101,
                        bundleID: "company.thebrowser.dia",
                        ownerName: "Dia",
                        ownerPID: 20,
                        title: "Work"
                    ),
                ],
                allWindowIDs: [101]
            ),
            stageManager: &manager
        )

        #expect(result.reassignedCount == 1)
        #expect(result.addedCount == 0)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(manager.stageContainingWindow(windowID: 101) == originalStageID)
        #expect(manager.stages.first(where: { $0.id == activeStageID })?.windows.isEmpty == true)
    }

    @Test("A complete relaunched bundle restores dormant windows one-to-one")
    func relaunchedBundleRestoresDormantWindows() {
        var manager = StageManager()
        let stage1 = manager.activeStageID
        manager.createStage(position: .below)
        let stage2 = manager.activeStageID
        manager.createStage(position: .below)
        let activeStage = manager.activeStageID
        manager.addWindow(
            StageWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old A", ownerPID: 10),
            toStageID: stage1
        )
        manager.addWindow(
            StageWindow(windowID: 2, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old B", ownerPID: 10),
            toStageID: stage2
        )
        #expect(manager.makeWindowsDormant(forOwnerPID: 10) == 2)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(101, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "New A"),
                    liveWindow(102, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "New B"),
                ],
                allWindowIDs: [101, 102]
            ),
            stageManager: &manager
        )

        #expect(result.reassignedCount == 2)
        #expect(result.addedCount == 0)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(manager.stageContainingWindow(windowID: 101) == stage1)
        #expect(manager.stageContainingWindow(windowID: 102) == stage2)
        #expect(manager.stages.first(where: { $0.id == activeStage })?.windows.isEmpty == true)
    }

    @Test("A complete launch batch reclaims a window seen during partial activation")
    func completeLaunchBatchReclaimsPartiallyDiscoveredWindow() {
        var manager = StageManager()
        let stage1 = manager.activeStageID
        manager.createStage(position: .below)
        let stage2 = manager.activeStageID
        manager.createStage(position: .below)
        let activeStage = manager.activeStageID
        manager.addWindow(
            StageWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old A", ownerPID: 10),
            toStageID: stage1
        )
        manager.addWindow(
            StageWindow(windowID: 2, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old B", ownerPID: 10),
            toStageID: stage2
        )
        _ = manager.makeWindowsDormant(forOwnerPID: 10)
        var reconciler = RuntimeWindowReconciler()

        let partial = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(101, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "New A"),
                ],
                allWindowIDs: [101]
            ),
            stageManager: &manager
        )
        #expect(partial.addedCount == 1)
        #expect(manager.stageContainingWindow(windowID: 101) == activeStage)

        let complete = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(101, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "New A"),
                    liveWindow(102, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "New B"),
                ],
                allWindowIDs: [101, 102]
            ),
            stageManager: &manager
        )

        #expect(complete.reassignedCount == 2)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(manager.stageContainingWindow(windowID: 101) == stage1)
        #expect(manager.stageContainingWindow(windowID: 102) == stage2)
        #expect(manager.stages.first(where: { $0.id == activeStage })?.windows.isEmpty == true)
    }

    @Test("Dormant recovery does not steal an established assigned window")
    func dormantRecoveryDoesNotStealEstablishedWindow() {
        var manager = StageManager()
        let originalStage = manager.activeStageID
        manager.createStage(position: .below)
        let activeStage = manager.activeStageID
        manager.addWindow(
            StageWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Work", ownerPID: 10),
            toStageID: originalStage
        )
        _ = manager.makeWindowsDormant(forOwnerPID: 10)
        manager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Work", ownerPID: 20),
            toStageID: activeStage
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(101, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "Work"),
                ],
                allWindowIDs: [101]
            ),
            stageManager: &manager
        )

        #expect(result.reassignedCount == 0)
        #expect(manager.dormantWindowAssignments.count == 1)
        #expect(manager.stageContainingWindow(windowID: 101) == activeStage)
    }

    // MARK: - Assignment events

    @Test("Adding a new window reports which window landed in which stage")
    func reportsAddedWindowEvent() {
        var manager = StageManager()
        manager.createStage(position: .below)
        manager.activateStage(id: manager.stages[1].id)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7, bundleID: "company.thebrowser.dia", ownerName: "Dia", title: "Develop: repo")],
                allWindowIDs: [7]
            ),
            stageManager: &manager
        )

        #expect(result.events.count == 1)
        let event = result.events[0]
        #expect(event.kind == .assigned)
        #expect(event.windowID == 7)
        #expect(event.bundleID == "company.thebrowser.dia")
        #expect(event.windowTitle == "Develop: repo")
        #expect(event.toStage == 1)
        #expect(event.fromStage == nil)
        #expect(event.reason == .new)
    }

    @Test("Recovering a replaced window reports the stage it was restored into")
    func reportsRecoveredWindowEvent() {
        var manager = StageManager()
        manager.createStage(position: .below)
        let secondStage = manager.stages[1].id
        manager.addWindow(
            StageWindow(windowID: 22359, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Develop: repo", ownerPID: 10),
            toStageID: secondStage
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(61000, bundleID: "company.thebrowser.dia", ownerName: "Dia", title: "Develop: repo")],
                allWindowIDs: [61000]
            ),
            stageManager: &manager
        )

        let recovered = result.events.filter { $0.reason == .recoveredExact }
        #expect(recovered.count == 1)
        #expect(recovered.first?.windowID == 61000)
        #expect(recovered.first?.toStage == 1)
        #expect(result.events.contains { $0.reason == .new } == false)
    }

    @Test("Bundle-only recovery is reported with its own reason")
    func reportsBundleRecoveryReason() {
        var manager = StageManager()
        manager.addWindow(
            StageWindow(windowID: 22359, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Develop: old tab", ownerPID: 10),
            toStageID: manager.activeStageID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(61000, bundleID: "company.thebrowser.dia", ownerName: "Dia", title: "Develop: new tab")],
                allWindowIDs: [61000]
            ),
            stageManager: &manager
        )

        #expect(result.events.map(\.reason) == [.recoveredBundle])
    }
}
