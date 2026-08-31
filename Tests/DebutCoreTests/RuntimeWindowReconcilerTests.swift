import CoreGraphics
import Foundation
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
        var manager = SpaceManager()
        let space1 = manager.spaces[0].id
        manager.createSpace(position: .below)
        let space2 = manager.spaces[1].id
        manager.activateSpace(id: space2)
        manager.addWindow(SpaceWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toSpaceID: space1)
        manager.addWindow(SpaceWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toSpaceID: space2)

        var reconciler = RuntimeWindowReconciler()
        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(1), liveWindow(2), liveWindow(3, title: "Missing")],
                allWindowIDs: [1, 2, 3]
            ),
            spaceManager: &manager
        )

        #expect(result.addedCount == 1)
        #expect(manager.spaceContainingWindow(windowID: 1) == space1)
        #expect(manager.spaceContainingWindow(windowID: 2) == space2)
        #expect(manager.spaceContainingWindow(windowID: 3) == space2)
    }

    @Test("Promotes only the focused newly discovered window to MRU")
    func focusedNewWindowBecomesMRU() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(windowID: 1, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Current", ownerPID: 10),
            toSpaceID: spaceID
        )
        manager.addWindow(
            SpaceWindow(windowID: 2, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Older", ownerPID: 20),
            toSpaceID: spaceID
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
            spaceManager: &manager
        )

        #expect(result.addedCount == 2)
        #expect(manager.activeSpace.windows.map(\.windowID) == [4, 1, 2, 3])
    }

    @Test("CG absence never removes a window without a lifecycle event")
    func preservesMissingWindowForRunningProcess() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(SpaceWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Live", ownerPID: 10), toSpaceID: spaceID)
        manager.addWindow(SpaceWindow(windowID: 99, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Transient", ownerPID: 10), toSpaceID: spaceID)
        let snapshot = RuntimeWindowSnapshot(
            liveWindows: [liveWindow(1, bundleID: "company.thebrowser.dia", ownerName: "Dia")],
            allWindowIDs: [1]
        )
        var reconciler = RuntimeWindowReconciler()

        for _ in 0..<10 {
            _ = reconciler.reconcile(snapshot, spaceManager: &manager)
        }
        #expect(manager.spaceContainingWindow(windowID: 99) == spaceID)
    }

    @Test("Failed and authoritative snapshots both preserve absent windows")
    func snapshotsPreserveAbsentWindows() {
        var manager = SpaceManager()
        manager.addWindow(SpaceWindow(windowID: 99, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Window", ownerPID: 10), toSpaceID: manager.activeSpaceID)
        let failedSnapshot = RuntimeWindowSnapshot(liveWindows: [], allWindowIDs: nil)
        let authoritativeMiss = RuntimeWindowSnapshot(liveWindows: [liveWindow(1)], allWindowIDs: [1])
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(failedSnapshot, spaceManager: &manager)
        _ = reconciler.reconcile(failedSnapshot, spaceManager: &manager)
        _ = reconciler.reconcile(authoritativeMiss, spaceManager: &manager)

        #expect(manager.spaceContainingWindow(windowID: 99) != nil)
    }

    @Test("A window snapshot never substitutes for a termination event")
    func snapshotDoesNotInferProcessTermination() {
        var manager = SpaceManager()
        manager.addWindow(SpaceWindow(windowID: 1, ownerBundleID: "com.live", ownerName: "Live", windowTitle: "Live", ownerPID: 10), toSpaceID: manager.activeSpaceID)
        manager.addWindow(SpaceWindow(windowID: 99, ownerBundleID: "com.dead", ownerName: "Dead", windowTitle: "Dead", ownerPID: 20), toSpaceID: manager.activeSpaceID)
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: [], allWindowIDs: nil),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 1) != nil)
        #expect(manager.spaceContainingWindow(windowID: 99) != nil)
    }

    @Test("Missing windows remain assigned without hidden-state information")
    func missingWindowsDoNotNeedHiddenState() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(
                windowID: 99,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toSpaceID: spaceID
        )
        var reconciler = RuntimeWindowReconciler()
        let visibleMiss = RuntimeWindowSnapshot(
            liveWindows: [],
            allWindowIDs: []
        )
        for _ in 0..<10 {
            _ = reconciler.reconcile(visibleMiss, spaceManager: &manager)
            #expect(manager.spaceContainingWindow(windowID: 99) == spaceID)
        }
    }

    @Test("A non-empty partial AX snapshot preserves omitted windows")
    func partialSnapshotPreservesOmittedWindows() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(SpaceWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toSpaceID: spaceID)
        manager.addWindow(SpaceWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toSpaceID: spaceID)
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(1)],
                allWindowIDs: [1, 2]
            ),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 2) == spaceID)
    }

    @Test("Repeated non-empty partial AX snapshots preserve omitted windows")
    func repeatedPartialSnapshotsPreserveOmittedWindows() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(SpaceWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toSpaceID: spaceID)
        manager.addWindow(SpaceWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toSpaceID: spaceID)
        let partialSnapshot = RuntimeWindowSnapshot(
            liveWindows: [liveWindow(1)],
            allWindowIDs: [1, 2]
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(partialSnapshot, spaceManager: &manager)
        _ = reconciler.reconcile(partialSnapshot, spaceManager: &manager)

        #expect(manager.spaceContainingWindow(windowID: 2) == spaceID)
    }

    @Test("Recovery from partial AX snapshots preserves original space ownership")
    func recoveryPreservesOriginalSpaceOwnership() {
        var manager = SpaceManager()
        let space1 = manager.spaces[0].id
        manager.createSpace(position: .below)
        let space2 = manager.spaces[1].id
        manager.activateSpace(id: space2)
        manager.addWindow(SpaceWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toSpaceID: space1)
        manager.addWindow(SpaceWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toSpaceID: space2)
        let partialSnapshot = RuntimeWindowSnapshot(
            liveWindows: [liveWindow(2)],
            allWindowIDs: [1, 2]
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(partialSnapshot, spaceManager: &manager)
        _ = reconciler.reconcile(partialSnapshot, spaceManager: &manager)
        let recovered = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(1), liveWindow(2)],
                allWindowIDs: [1, 2]
            ),
            spaceManager: &manager
        )

        #expect(recovered.addedCount == 0)
        #expect(manager.spaceContainingWindow(windowID: 1) == space1)
        #expect(manager.spaceContainingWindow(windowID: 2) == space2)
    }

    @Test("A failed CG snapshot preserves AX omissions")
    func failedCGSnapshotPreservesAXOmissions() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(SpaceWindow(windowID: 1, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "One", ownerPID: 10), toSpaceID: spaceID)
        manager.addWindow(SpaceWindow(windowID: 2, ownerBundleID: "notion.id", ownerName: "Notion", windowTitle: "Two", ownerPID: 10), toSpaceID: spaceID)
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(1)],
                allWindowIDs: nil
            ),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 2) == spaceID)
    }

    @Test("A recreated window keeps its space when its stable identity matches")
    func recreatedWindowKeepsSpaceByStableIdentity() {
        var manager = SpaceManager()
        let originalSpaceID = manager.activeSpaceID
        manager.createSpace(position: .below)
        let activeSpaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(
                windowID: 1,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toSpaceID: originalSpaceID
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
            spaceManager: &manager
        )

        #expect(result.reassignedCount == 1)
        #expect(manager.spaceContainingWindow(windowID: 101) == originalSpaceID)
        #expect(manager.spaces.first(where: { $0.id == activeSpaceID })?.windows.isEmpty == true)
    }

    @Test("Reconciliation does not reclaim an already assigned duplicate title")
    func assignedDuplicateTitleIsNotReclaimed() {
        var manager = SpaceManager()
        let originalSpaceID = manager.activeSpaceID
        manager.createSpace(position: .below)
        let activeSpaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(
                windowID: 1,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toSpaceID: originalSpaceID
        )
        manager.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toSpaceID: activeSpaceID
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
            spaceManager: &manager
        )

        #expect(result.reassignedCount == 0)
        #expect(manager.spaceContainingWindow(windowID: 101) == activeSpaceID)
        #expect(manager.spaces.first(where: { $0.id == originalSpaceID })?.windows.map(\.windowID) == [1])
    }

    @Test("A later replacement reclaims the retained assignment without a timeout")
    func laterReplacementReclaimsRetainedAssignment() {
        var manager = SpaceManager()
        let originalSpaceID = manager.activeSpaceID
        manager.createSpace(position: .below)
        let activeSpaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(
                windowID: 1,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toSpaceID: originalSpaceID
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [],
                allWindowIDs: []
            ),
            spaceManager: &manager
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
            spaceManager: &manager
        )

        #expect(result.reassignedCount == 1)
        #expect(manager.spaceContainingWindow(windowID: 101) == originalSpaceID)
        #expect(manager.spaces.first(where: { $0.id == activeSpaceID })?.windows.isEmpty == true)
    }

    @Test("A complete bundle recreation falls back one-to-one to the original spaces")
    func recreatedWindowsKeepSpacesByBundleFallback() {
        var manager = SpaceManager()
        let space1 = manager.activeSpaceID
        manager.createSpace(position: .below)
        let space2 = manager.activeSpaceID
        manager.createSpace(position: .below)
        let activeSpace = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old A", ownerPID: 10),
            toSpaceID: space1
        )
        manager.addWindow(
            SpaceWindow(windowID: 2, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old B", ownerPID: 10),
            toSpaceID: space2
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
            spaceManager: &manager
        )

        #expect(result.reassignedCount == 2)
        #expect(manager.spaceContainingWindow(windowID: 101) == space1)
        #expect(manager.spaceContainingWindow(windowID: 102) == space2)
        #expect(manager.spaces.first(where: { $0.id == activeSpace })?.windows.isEmpty == true)
    }

    @Test("A relaunched window reclaims its dormant assignment")
    func relaunchedWindowReclaimsDormantAssignment() {
        var manager = SpaceManager()
        let originalSpaceID = manager.activeSpaceID
        manager.createSpace(position: .below)
        let activeSpaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(
                windowID: 1,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Work",
                ownerPID: 10
            ),
            toSpaceID: originalSpaceID
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
            spaceManager: &manager
        )

        #expect(result.reassignedCount == 1)
        #expect(result.addedCount == 0)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(manager.spaceContainingWindow(windowID: 101) == originalSpaceID)
        #expect(manager.spaces.first(where: { $0.id == activeSpaceID })?.windows.isEmpty == true)
    }

    @Test("A complete relaunched bundle restores dormant windows one-to-one")
    func relaunchedBundleRestoresDormantWindows() {
        var manager = SpaceManager()
        let space1 = manager.activeSpaceID
        manager.createSpace(position: .below)
        let space2 = manager.activeSpaceID
        manager.createSpace(position: .below)
        let activeSpace = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old A", ownerPID: 10),
            toSpaceID: space1
        )
        manager.addWindow(
            SpaceWindow(windowID: 2, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old B", ownerPID: 10),
            toSpaceID: space2
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
            spaceManager: &manager
        )

        #expect(result.reassignedCount == 2)
        #expect(result.addedCount == 0)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(manager.spaceContainingWindow(windowID: 101) == space1)
        #expect(manager.spaceContainingWindow(windowID: 102) == space2)
        #expect(manager.spaces.first(where: { $0.id == activeSpace })?.windows.isEmpty == true)
    }

    @Test("A complete launch batch reclaims a window seen during partial activation")
    func completeLaunchBatchReclaimsPartiallyDiscoveredWindow() {
        var manager = SpaceManager()
        let space1 = manager.activeSpaceID
        manager.createSpace(position: .below)
        let space2 = manager.activeSpaceID
        manager.createSpace(position: .below)
        let activeSpace = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old A", ownerPID: 10),
            toSpaceID: space1
        )
        manager.addWindow(
            SpaceWindow(windowID: 2, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Old B", ownerPID: 10),
            toSpaceID: space2
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
            spaceManager: &manager
        )
        #expect(partial.addedCount == 1)
        #expect(manager.spaceContainingWindow(windowID: 101) == activeSpace)

        let complete = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(101, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "New A"),
                    liveWindow(102, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "New B"),
                ],
                allWindowIDs: [101, 102]
            ),
            spaceManager: &manager
        )

        #expect(complete.reassignedCount == 2)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(manager.spaceContainingWindow(windowID: 101) == space1)
        #expect(manager.spaceContainingWindow(windowID: 102) == space2)
        #expect(manager.spaces.first(where: { $0.id == activeSpace })?.windows.isEmpty == true)
    }

    @Test("Dormant recovery does not steal an established assigned window")
    func dormantRecoveryDoesNotStealEstablishedWindow() {
        var manager = SpaceManager()
        let originalSpace = manager.activeSpaceID
        manager.createSpace(position: .below)
        let activeSpace = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(windowID: 1, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Work", ownerPID: 10),
            toSpaceID: originalSpace
        )
        _ = manager.makeWindowsDormant(forOwnerPID: 10)
        manager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Work", ownerPID: 20),
            toSpaceID: activeSpace
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(101, bundleID: "company.thebrowser.dia", ownerName: "Dia", ownerPID: 20, title: "Work"),
                ],
                allWindowIDs: [101]
            ),
            spaceManager: &manager
        )

        #expect(result.reassignedCount == 0)
        #expect(manager.dormantWindowAssignments.count == 1)
        #expect(manager.spaceContainingWindow(windowID: 101) == activeSpace)
    }

    // MARK: - Assignment events

    @Test("Adding a new window reports which window landed in which space")
    func reportsAddedWindowEvent() {
        var manager = SpaceManager()
        manager.createSpace(position: .below)
        manager.activateSpace(id: manager.spaces[1].id)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7, bundleID: "company.thebrowser.dia", ownerName: "Dia", title: "Develop: repo")],
                allWindowIDs: [7]
            ),
            spaceManager: &manager
        )

        #expect(result.events.count == 1)
        let event = result.events[0]
        #expect(event.kind == .assigned)
        #expect(event.windowID == 7)
        #expect(event.bundleID == "company.thebrowser.dia")
        #expect(event.windowTitle == "Develop: repo")
        #expect(event.toSpace == 1)
        #expect(event.fromSpace == nil)
        #expect(event.reason == .new)
    }

    @Test("Recovering a replaced window reports the space it was restored into")
    func reportsRecoveredWindowEvent() {
        var manager = SpaceManager()
        manager.createSpace(position: .below)
        let secondSpace = manager.spaces[1].id
        manager.addWindow(
            SpaceWindow(windowID: 22359, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Develop: repo", ownerPID: 10),
            toSpaceID: secondSpace
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(61000, bundleID: "company.thebrowser.dia", ownerName: "Dia", title: "Develop: repo")],
                allWindowIDs: [61000]
            ),
            spaceManager: &manager
        )

        let recovered = result.events.filter { $0.reason == .recoveredExact }
        #expect(recovered.count == 1)
        #expect(recovered.first?.windowID == 61000)
        #expect(recovered.first?.toSpace == 1)
        #expect(result.events.contains { $0.reason == .new } == false)
    }

    @Test("Bundle-only recovery is reported with its own reason")
    func reportsBundleRecoveryReason() {
        var manager = SpaceManager()
        manager.addWindow(
            SpaceWindow(windowID: 22359, ownerBundleID: "company.thebrowser.dia", ownerName: "Dia", windowTitle: "Develop: old tab", ownerPID: 10),
            toSpaceID: manager.activeSpaceID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(61000, bundleID: "company.thebrowser.dia", ownerName: "Dia", title: "Develop: new tab")],
                allWindowIDs: [61000]
            ),
            spaceManager: &manager
        )

        #expect(result.events.map(\.reason) == [.recoveredBundle])
    }

    // MARK: - Dia regression
    //
    // Reproduces a real session. Debut held five Dia assignments while the
    // window server had four windows: 60760 had been closed without a destroy
    // notification, so its assignment could never be removed. Titles are the
    // observed ones, which drift on every tab switch and defeat exact matching.

    private enum Dia {
        static let bundleID = "company.thebrowser.dia"
        static let pid: pid_t = 33141
    }

    private func diaWindow(_ windowID: CGWindowID, _ title: String) -> WindowInfo {
        liveWindow(windowID, bundleID: Dia.bundleID, ownerName: "Dia", ownerPID: Dia.pid, title: title)
    }

    private func diaAssignment(_ windowID: CGWindowID, _ title: String) -> SpaceWindow {
        SpaceWindow(
            windowID: windowID,
            ownerBundleID: Dia.bundleID,
            ownerName: "Dia",
            windowTitle: title,
            ownerPID: Dia.pid
        )
    }

    /// Three spaces holding the incident's assignments, active space 0.
    private func makeDiaIncidentState() -> (SpaceManager, [UUID]) {
        var manager = SpaceManager()
        manager.createSpace(position: .below)
        manager.createSpace(position: .below)
        let ids = manager.spaces.map(\.id)

        manager.addWindow(diaAssignment(22358, "Goodnotes: Goodnotes"), toSpaceID: ids[1])
        manager.addWindow(diaAssignment(57414, "Develop: (1) thompson (@…"), toSpaceID: ids[1])
        manager.addWindow(diaAssignment(22357, "Leisure: 「劇場版 魔法少女…"), toSpaceID: ids[2])
        // Closed without a destroy notification; no live window will ever match.
        manager.addWindow(diaAssignment(60760, "Goodnotes: New Tab"), toSpaceID: ids[2])
        manager.addWindow(diaAssignment(22359, "Develop: nexu-io/open-de…"), toSpaceID: ids[2])

        manager.activateSpace(id: ids[0])
        return (manager, ids)
    }

    @Test("A replaced Dia window returns to its own space, not the active space")
    func replacedDiaWindowKeepsItsSpace() {
        var (manager, spaceIDs) = makeDiaIncidentState()
        var reconciler = RuntimeWindowReconciler()

        // 22359 is recreated as 61000 with a drifted title, as Dia does on
        // navigation. 60760 stays absent because it no longer exists.
        let live = [
            diaWindow(22358, "Goodnotes: Goodnotes"),
            diaWindow(57414, "Develop: Search results…"),
            diaWindow(22357, "Leisure: (1) XユーザーのＩｘｙ…"),
            diaWindow(61000, "Develop: nexu-io/open-decision"),
        ]

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: live, allWindowIDs: [22358, 57414, 22357, 61000]),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 61000) == spaceIDs[2])
        #expect(manager.spaceContainingWindow(windowID: 61000) != spaceIDs[0])
    }

    @Test("Repeated reconciles never drift a settled Dia window between spaces")
    func settledDiaWindowDoesNotFlap() {
        var (manager, spaceIDs) = makeDiaIncidentState()
        var reconciler = RuntimeWindowReconciler()

        let live = [
            diaWindow(22358, "Goodnotes: Goodnotes"),
            diaWindow(57414, "Develop: Search results…"),
            diaWindow(22357, "Leisure: (1) XユーザーのＩｘｙ…"),
            diaWindow(61000, "Develop: nexu-io/open-decision"),
        ]
        let snapshot = RuntimeWindowSnapshot(
            liveWindows: live,
            allWindowIDs: [22358, 57414, 22357, 61000]
        )

        _ = reconciler.reconcile(snapshot, spaceManager: &manager)
        let settled = manager.spaceContainingWindow(windowID: 61000)

        for _ in 0..<5 {
            _ = reconciler.reconcile(snapshot, spaceManager: &manager)
            #expect(manager.spaceContainingWindow(windowID: 61000) == settled)
        }
        #expect(settled == spaceIDs[2])
    }

    @Test("A stale assignment does not strand every other Dia window in the active space")
    func staleAssignmentDoesNotCollapseRemainingWindows() {
        var (manager, spaceIDs) = makeDiaIncidentState()
        var reconciler = RuntimeWindowReconciler()

        // Every window keeps its identity except the one that was already
        // closed. Nothing should move.
        let live = [
            diaWindow(22358, "Goodnotes: drifted"),
            diaWindow(57414, "Develop: drifted"),
            diaWindow(22357, "Leisure: drifted"),
            diaWindow(22359, "Develop: drifted"),
        ]

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: live, allWindowIDs: [22358, 57414, 22357, 22359]),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 22358) == spaceIDs[1])
        #expect(manager.spaceContainingWindow(windowID: 57414) == spaceIDs[1])
        #expect(manager.spaceContainingWindow(windowID: 22357) == spaceIDs[2])
        #expect(manager.spaceContainingWindow(windowID: 22359) == spaceIDs[2])
    }

    @Test("An ambiguously placed window is reclaimed once the stale assignment goes")
    func ambiguousPlacementIsReclaimedAfterStaleAssignmentRemoved() {
        var (manager, spaceIDs) = makeDiaIncidentState()
        var reconciler = RuntimeWindowReconciler()

        // Stranded assignments in two different spaces: 60760 in space 2 and
        // 57414 in space 1. Neither space can claim the replacement, so it
        // falls back to the active space.
        let live = [
            diaWindow(22358, "Goodnotes: drifted"),
            diaWindow(22357, "Leisure: drifted"),
            diaWindow(22359, "Develop: drifted"),
            diaWindow(61000, "Develop: replacement"),
        ]
        let ids: Set<CGWindowID> = [22358, 22357, 22359, 61000]

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: live, allWindowIDs: ids),
            spaceManager: &manager
        )
        #expect(manager.spaceContainingWindow(windowID: 61000) == spaceIDs[0])

        // The closed window finally emits its destroy notification, leaving a
        // single stranded assignment. 61000 must now be claimed by space 1.
        manager.removeWindow(windowID: 60760, fromSpaceID: spaceIDs[2])

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: live, allWindowIDs: ids),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 61000) == spaceIDs[1])
    }

    // MARK: - Window identity validation
    //
    // A CGWindowID only means anything within the boot that issued it, and macOS reissues
    // them continuously as windows close — not only across a reboot. A recycled ID is still
    // present in allWindowIDs, so the missing-assignment check never sees it; only comparing
    // the live window's bundleID against the assignment's catches it.

    @Test("A recycled window ID is parked then recovered onto its real window in one pass")
    func recycledIDIsParkedThenRecoveredInOnePass() {
        var manager = SpaceManager()
        let space1 = manager.spaces[0].id
        manager.createSpace(position: .below)
        manager.addWindow(
            SpaceWindow(windowID: 42, ownerBundleID: "com.old", ownerName: "Old", windowTitle: "Old Window", ownerPID: 10),
            toSpaceID: space1
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(42, bundleID: "com.new", ownerName: "New", ownerPID: 20, title: "New Window"),
                    liveWindow(99, bundleID: "com.old", ownerName: "Old", ownerPID: 10, title: "Old Window"),
                ],
                allWindowIDs: [42, 99]
            ),
            spaceManager: &manager
        )

        #expect(result.addedCount == 1)
        #expect(result.reassignedCount == 1)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(manager.spaceContainingWindow(windowID: 99) == space1)
        #expect(manager.spaces.first(where: { $0.id == space1 })?.windows.map(\.windowID) == [99])

        let dormancy = result.events.first { $0.kind == .madeDormant }
        #expect(dormancy?.windowID == 42)
        #expect(dormancy?.bundleID == "com.old")
        #expect(dormancy?.reason == .idRecycled)
        let recovery = result.events.first { $0.kind == .reassigned }
        #expect(recovery?.windowID == 99)
        #expect(recovery?.reason == .dormantRestored)
    }

    @Test("A window whose ID and bundle still agree is left untouched")
    func matchingIDAndBundleIsUntouched() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(windowID: 5, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Doc", ownerPID: 10),
            toSpaceID: spaceID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(5, bundleID: "com.a", ownerName: "A", ownerPID: 10, title: "Doc")],
                allWindowIDs: [5]
            ),
            spaceManager: &manager
        )

        #expect(result.events.isEmpty)
        #expect(manager.spaceContainingWindow(windowID: 5) == spaceID)
    }

    @Test("A recycled ID with no recovery candidate stays dormant rather than being deleted")
    func recycledIDWithNoCandidateStaysDormant() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.old", ownerName: "Old", windowTitle: "Doc", ownerPID: 10),
            toSpaceID: spaceID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7, bundleID: "com.new", ownerName: "New", ownerPID: 20, title: "Other")],
                allWindowIDs: [7]
            ),
            spaceManager: &manager
        )

        #expect(result.addedCount == 1)
        #expect(manager.dormantWindowAssignments.count == 1)
        #expect(manager.dormantWindowAssignments.first?.window.ownerBundleID == "com.old")
        #expect(manager.spaceContainingWindow(windowID: 7) == spaceID)
        #expect(manager.spaces.first(where: { $0.id == spaceID })?.windows.first?.ownerBundleID == "com.new")

        let dormancy = result.events.first { $0.kind == .madeDormant }
        #expect(dormancy?.reason == .idRecycled)
    }

    // Chrome's dismissed omnibox popup stays in CGWindowList for the life of the process, so
    // the missing-assignment check above can never reach it. AX declining to name it while its
    // own desktop showed is the only positive statement anything makes about it.
    @Test("A window AX contradicts is parked even though CG still lists it")
    func axContradictedWindowIsParked() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        for windowID in [CGWindowID(17774), CGWindowID(17776)] {
            manager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "com.google.Chrome",
                            ownerName: "Chrome", windowTitle: "", ownerPID: 89895),
                toSpaceID: spaceID
            )
        }
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(17774, bundleID: "com.google.Chrome",
                                         ownerName: "Chrome", ownerPID: 89895, title: "")],
                allWindowIDs: [17774, 17776],
                axContradictedWindowIDs: [17776]
            ),
            spaceManager: &manager
        )

        #expect(manager.activeSpace.windows.map(\.windowID) == [17774])
        #expect(manager.dormantWindowAssignments.map(\.window.windowID) == [17776])
        let dormancy = result.events.first { $0.kind == .madeDormant }
        #expect(dormancy?.windowID == 17776)
        #expect(dormancy?.reason == .axContradicted)
        #expect(dormancy?.fromSpace == 0)
        #expect(result.dormantCount == 1)
    }

    // A Dia assignment (18288, empty title) sat in space 4 across restarts while existing in no
    // source at all. Nothing could evict it: no AX element remained to fire a destroy
    // notification, its process was still alive, and CG absence alone may not evict.
    @Test("An assignment no window source can find is parked")
    func vanishedAssignmentIsParked() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        for windowID in [CGWindowID(17059), CGWindowID(18288)] {
            manager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "company.thebrowser.dia",
                            ownerName: "Dia", windowTitle: "", ownerPID: 40694),
                toSpaceID: spaceID
            )
        }
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(17059, bundleID: "company.thebrowser.dia",
                                         ownerName: "Dia", ownerPID: 40694, title: "")],
                allWindowIDs: [17059],
                skyLightWindowIDs: [17059]
            ),
            spaceManager: &manager
        )

        #expect(manager.activeSpace.windows.map(\.windowID) == [17059])
        #expect(manager.dormantWindowAssignments.map(\.window.windowID) == [18288])
        let dormancy = result.events.first { $0.kind == .madeDormant }
        #expect(dormancy?.windowID == 18288)
        #expect(dormancy?.reason == .vanished)
    }

    // Measured across 240 windows: 9 sat in SkyLight while absent from CG. Hiding an app was
    // measured too and removes its windows from neither. One source going quiet is still not
    // evidence, which is why both have to agree before anything is parked.
    @Test("A window CG lost but SkyLight still places stays assigned")
    func skyLightPresenceProtectsAgainstCGAbsence() {
        var manager = SpaceManager()
        manager.addWindow(
            SpaceWindow(windowID: 4795, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "Develop", ownerPID: 40694),
            toSpaceID: manager.activeSpaceID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [], allWindowIDs: [], skyLightWindowIDs: [4795]
            ),
            spaceManager: &manager
        )

        #expect(manager.activeSpace.windows.map(\.windowID) == [4795])
        #expect(result.events.isEmpty)
    }

    @Test("A SkyLight enumeration that did not answer parks nothing")
    func missingSkyLightAnswerParksNothing() {
        var manager = SpaceManager()
        manager.addWindow(
            SpaceWindow(windowID: 4795, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "Develop", ownerPID: 40694),
            toSpaceID: manager.activeSpaceID
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(liveWindows: [], allWindowIDs: [], skyLightWindowIDs: nil),
            spaceManager: &manager
        )

        #expect(manager.activeSpace.windows.map(\.windowID) == [4795])
        #expect(result.events.isEmpty)
    }

    // MARK: - Preview "Open" ghost regression (KHA-566)
    //
    // Reproduces a real session. Preview was quit while an image window and a generic
    // "Open" panel were both live, dormanting both. On relaunch the "Open" panel reclaimed
    // its own dormant slot by exact title and was later closed for real. A second, unrelated
    // "Open" panel then appeared through a routine activation reconcile — not a fresh launch
    // — and the bundle-only fallback paired it with the *other* remaining dormant slot (the
    // image window) purely because each was the last one left for the bundle. That silently
    // discarded the image's dormant assignment and left the panel's transient identity
    // masquerading as a live window long after the user dismissed it.

    @Test("An activation reconcile does not let a generic dialog steal an unrelated dormant slot")
    func activationReconcileDoesNotStealUnrelatedDormantSlot() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(
                windowID: 14262,
                ownerBundleID: "com.apple.Preview",
                ownerName: "Preview",
                windowTitle: "8B13A465-2069-4A75-AC10-9ECC85310F72.png",
                ownerPID: 24145
            ),
            toSpaceID: spaceID
        )
        #expect(manager.makeWindowsDormant(forOwnerPID: 24145) == 1)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(14266, bundleID: "com.apple.Preview", ownerName: "Preview", ownerPID: 24500, title: "Open"),
                ],
                allWindowIDs: [14266]
            ),
            spaceManager: &manager,
            allowDormantBundleFallback: false
        )

        #expect(result.reassignedCount == 0)
        #expect(result.addedCount == 1)
        #expect(manager.dormantWindowAssignments.count == 1)
        #expect(manager.dormantWindowAssignments.first?.window.windowTitle == "8B13A465-2069-4A75-AC10-9ECC85310F72.png")
        #expect(result.events.contains { $0.reason == WindowAssignmentEvent.Reason.dormantRestored } == false)
    }

    @Test("A launch reconcile still restores a dormant window by bundle fallback")
    func launchReconcileStillAllowsBundleFallback() {
        var manager = SpaceManager()
        let spaceID = manager.activeSpaceID
        manager.addWindow(
            SpaceWindow(
                windowID: 14262,
                ownerBundleID: "com.apple.Preview",
                ownerName: "Preview",
                windowTitle: "8B13A465-2069-4A75-AC10-9ECC85310F72.png",
                ownerPID: 24145
            ),
            toSpaceID: spaceID
        )
        #expect(manager.makeWindowsDormant(forOwnerPID: 24145) == 1)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [
                    liveWindow(14266, bundleID: "com.apple.Preview", ownerName: "Preview", ownerPID: 24500, title: "Open"),
                ],
                allWindowIDs: [14266]
            ),
            spaceManager: &manager
        )

        #expect(result.reassignedCount == 1)
        #expect(manager.dormantWindowAssignments.isEmpty)
        #expect(manager.spaceContainingWindow(windowID: 14266) == spaceID)
    }
}
