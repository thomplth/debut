import CoreGraphics
import Foundation

public struct RuntimeWindowSnapshot: Sendable {
    public let liveWindows: [WindowInfo]
    public let allWindowIDs: Set<CGWindowID>?
    public let focusedWindowID: CGWindowID?

    public init(
        liveWindows: [WindowInfo],
        allWindowIDs: Set<CGWindowID>?,
        focusedWindowID: CGWindowID? = nil
    ) {
        self.liveWindows = liveWindows
        self.allWindowIDs = allWindowIDs
        self.focusedWindowID = focusedWindowID
    }
}

public struct RuntimeWindowReconciliationResult: Equatable, Sendable {
    public let addedCount: Int
    public let reassignedCount: Int

    public init(addedCount: Int = 0, reassignedCount: Int = 0) {
        self.addedCount = addedCount
        self.reassignedCount = reassignedCount
    }

    public var didMutate: Bool { addedCount > 0 || reassignedCount > 0 }
}

public struct RuntimeWindowReconciler: Sendable {
    private struct WindowAssignment: Sendable {
        let stageID: UUID
        let windowIndex: Int
        let window: StageWindow
    }

    private var provisionalWindowIDs = Set<CGWindowID>()

    public init() {}

    public mutating func reconcile(
        _ snapshot: RuntimeWindowSnapshot,
        stageManager: inout StageManager,
        newWindowStageID: UUID? = nil
    ) -> RuntimeWindowReconciliationResult {
        var addedCount = 0
        var reassignedCount = 0
        var consumedLiveWindowIDs = Set<CGWindowID>()
        provisionalWindowIDs = provisionalWindowIDs.filter {
            stageManager.stageContainingWindow(windowID: $0) != nil
        }

        // CG absence is evidence that an ID may have been replaced, never evidence
        // that a window was destroyed. Only AX lifecycle events remove assignments.
        if let allWindowIDs = snapshot.allWindowIDs {
            let missingAssignments = assignments(in: stageManager).filter {
                !allWindowIDs.contains($0.window.windowID)
            }

            // Prefer stable identity before adding anything. Reconciliation is
            // published before focus, so recreated windows are still unassigned.
            let directMatches = recoveryMatches(
                assignments: missingAssignments,
                liveWindows: snapshot.liveWindows,
                stageManager: stageManager
            )
            for (assignment, info) in directMatches {
                guard let location = location(
                    of: assignment.window.windowID,
                    in: stageManager
                ) else { continue }

                stageManager.updateWindowIDs(
                    stageIndex: location.stageIndex,
                    windowIndex: location.windowIndex,
                    windowID: info.windowID,
                    ownerPID: info.ownerPID,
                    windowTitle: info.title
                )
                consumedLiveWindowIDs.insert(info.windowID)
                provisionalWindowIDs.remove(info.windowID)
                reassignedCount += 1
            }
        }

        let dormantAssignments = stageManager.dormantWindowAssignments.map {
            WindowAssignment(
                stageID: $0.stageID,
                windowIndex: $0.windowIndex,
                window: $0.window
            )
        }
        let dormantMatches = recoveryMatches(
            assignments: dormantAssignments,
            liveWindows: snapshot.liveWindows.filter { !consumedLiveWindowIDs.contains($0.windowID) },
            stageManager: stageManager,
            allowedAssignedWindowIDs: provisionalWindowIDs
        )
        for (assignment, info) in sortedByStagePosition(dormantMatches, stageManager: stageManager) {
            stageManager.removeLiveWindowFromAllStages(windowID: info.windowID)
            guard stageManager.restoreDormantWindow(
                assignmentID: assignment.window.id,
                windowID: info.windowID,
                ownerPID: info.ownerPID,
                windowTitle: info.title
            ) else { continue }
            consumedLiveWindowIDs.insert(info.windowID)
            provisionalWindowIDs.remove(info.windowID)
            reassignedCount += 1
        }

        // AX metadata is still useful for additions, but never for destructive
        // absence checks. Existing assignments are left untouched.
        let targetStageID = newWindowStageID.flatMap { requestedID in
            stageManager.stages.contains(where: { $0.id == requestedID }) ? requestedID : nil
        } ?? stageManager.activeStageID
        var addedWindowIDs = Set<CGWindowID>()
        for info in snapshot.liveWindows where
            !consumedLiveWindowIDs.contains(info.windowID) &&
            stageManager.stageContainingWindow(windowID: info.windowID) == nil {
            stageManager.addWindow(
                StageWindow(
                    windowID: info.windowID,
                    ownerBundleID: info.ownerBundleID,
                    ownerName: info.ownerName,
                    windowTitle: info.title,
                    ownerPID: info.ownerPID
                ),
                toStageID: targetStageID
            )
            if stageManager.dormantWindowAssignments.contains(where: {
                $0.window.ownerBundleID == info.ownerBundleID
            }) {
                provisionalWindowIDs.insert(info.windowID)
            }
            addedWindowIDs.insert(info.windowID)
            addedCount += 1
        }

        if let focusedWindowID = snapshot.focusedWindowID,
           addedWindowIDs.contains(focusedWindowID) {
            stageManager.bringWindowToFront(
                windowID: focusedWindowID,
                inStageID: targetStageID
            )
        }

        return RuntimeWindowReconciliationResult(
            addedCount: addedCount,
            reassignedCount: reassignedCount
        )
    }

    private func assignments(in stageManager: StageManager) -> [WindowAssignment] {
        stageManager.stages.flatMap { stage in
            stage.windows.enumerated().map { windowIndex, window in
                WindowAssignment(stageID: stage.id, windowIndex: windowIndex, window: window)
            }
        }
    }

    private func recoveryMatches(
        assignments: [WindowAssignment],
        liveWindows: [WindowInfo],
        stageManager: StageManager,
        allowedAssignedWindowIDs: Set<CGWindowID> = []
    ) -> [(WindowAssignment, WindowInfo)] {
        var matches: [(WindowAssignment, WindowInfo)] = []
        var usedAssignmentIDs = Set<UUID>()
        var usedLiveWindowIDs = Set<CGWindowID>()

        // Exact title matches reclaim only unassigned live windows. Activation
        // publishes reconciliation before focus, keeping replacements unassigned
        // here without risking an unrelated assigned window with a duplicate title.
        for info in liveWindows {
            guard let assignment = assignments.first(where: {
                !usedAssignmentIDs.contains($0.window.id) &&
                    $0.window.ownerBundleID == info.ownerBundleID &&
                    $0.window.windowTitle == info.title &&
                    (stageManager.stageContainingWindow(windowID: info.windowID) == nil ||
                        allowedAssignedWindowIDs.contains(info.windowID))
            }) else { continue }
            matches.append((assignment, info))
            usedAssignmentIDs.insert(assignment.window.id)
            usedLiveWindowIDs.insert(info.windowID)
        }

        // Dynamic titles require a bundle-only fallback. Use it only when all
        // remaining assignments and unassigned live windows for that bundle form
        // a complete one-to-one set, avoiding arbitrary partial reassignment.
        let remainingAssignments = assignments.filter { !usedAssignmentIDs.contains($0.window.id) }
        let remainingLiveWindows = liveWindows.filter {
            !usedLiveWindowIDs.contains($0.windowID) &&
                (stageManager.stageContainingWindow(windowID: $0.windowID) == nil ||
                    allowedAssignedWindowIDs.contains($0.windowID))
        }
        let bundleIDs = Set(remainingAssignments.map { $0.window.ownerBundleID })
        for bundleID in bundleIDs.sorted() {
            let bundleAssignments = remainingAssignments.filter { $0.window.ownerBundleID == bundleID }
            let bundleWindows = remainingLiveWindows.filter { $0.ownerBundleID == bundleID }
            guard !bundleAssignments.isEmpty,
                  bundleAssignments.count == bundleWindows.count
            else { continue }
            matches.append(contentsOf: zip(bundleAssignments, bundleWindows))
        }

        return matches
    }

    private func sortedByStagePosition(
        _ matches: [(WindowAssignment, WindowInfo)],
        stageManager: StageManager
    ) -> [(WindowAssignment, WindowInfo)] {
        let stageOrder = Dictionary(
            uniqueKeysWithValues: stageManager.stages.enumerated().map { ($0.element.id, $0.offset) }
        )
        return matches.sorted {
            let lhsStage = stageOrder[$0.0.stageID, default: .max]
            let rhsStage = stageOrder[$1.0.stageID, default: .max]
            return lhsStage == rhsStage
                ? $0.0.windowIndex < $1.0.windowIndex
                : lhsStage < rhsStage
        }
    }

    private func location(
        of windowID: CGWindowID,
        in stageManager: StageManager
    ) -> (stageIndex: Int, windowIndex: Int)? {
        for stageIndex in stageManager.stages.indices {
            if let windowIndex = stageManager.stages[stageIndex].windows.firstIndex(where: {
                $0.windowID == windowID
            }) {
                return (stageIndex, windowIndex)
            }
        }
        return nil
    }

}
