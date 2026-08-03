import CoreGraphics
import Foundation

public struct RuntimeWindowSnapshot: Sendable {
    public let runningPIDs: Set<pid_t>
    public let hiddenPIDs: Set<pid_t>
    public let liveWindows: [WindowInfo]
    public let allWindowIDs: Set<CGWindowID>?
    public let untrackableWindowIDs: Set<CGWindowID>
    public let focusedWindowID: CGWindowID?

    public init(
        runningPIDs: Set<pid_t>,
        hiddenPIDs: Set<pid_t> = [],
        liveWindows: [WindowInfo],
        allWindowIDs: Set<CGWindowID>?,
        untrackableWindowIDs: Set<CGWindowID> = [],
        focusedWindowID: CGWindowID? = nil
    ) {
        self.runningPIDs = runningPIDs
        self.hiddenPIDs = hiddenPIDs
        self.liveWindows = liveWindows
        self.allWindowIDs = allWindowIDs
        self.untrackableWindowIDs = untrackableWindowIDs
        self.focusedWindowID = focusedWindowID
    }
}

public struct RuntimeWindowReconciliationResult: Equatable, Sendable {
    public let addedCount: Int
    public let removedCount: Int
    public let reassignedCount: Int

    public init(addedCount: Int = 0, removedCount: Int = 0, reassignedCount: Int = 0) {
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.reassignedCount = reassignedCount
    }

    public var didMutate: Bool { addedCount > 0 || removedCount > 0 || reassignedCount > 0 }
}

public struct RuntimeWindowReconciler: Sendable {
    private struct WindowAssignment: Sendable {
        let stageID: UUID
        let windowIndex: Int
        let window: StageWindow
    }

    private struct RecentWindowAssignment: Sendable {
        let assignment: WindowAssignment
        let removedAt: Date
    }

    private let requiredMissingSnapshots: Int
    private let assignmentRecoveryInterval: TimeInterval
    private var missingSnapshotCounts: [CGWindowID: Int] = [:]
    private var recentWindowAssignments: [RecentWindowAssignment] = []

    public init(requiredMissingSnapshots: Int = 2, assignmentRecoveryInterval: TimeInterval = 30) {
        self.requiredMissingSnapshots = max(1, requiredMissingSnapshots)
        self.assignmentRecoveryInterval = max(0, assignmentRecoveryInterval)
    }

    public mutating func reconcile(
        _ snapshot: RuntimeWindowSnapshot,
        stageManager: inout StageManager
    ) -> RuntimeWindowReconciliationResult {
        var addedCount = 0
        var reassignedCount = 0
        var removedCount = stageManager.removeWindowsOwnedByStoppedProcesses(
            runningPIDs: snapshot.runningPIDs
        )

        let now = Date()
        recentWindowAssignments.removeAll { recent in
            now.timeIntervalSince(recent.removedAt) > assignmentRecoveryInterval ||
                !stageManager.stages.contains(where: { $0.id == recent.assignment.stageID })
        }

        // Unlike an AX omission, these IDs were returned by AX and explicitly
        // classified as dialogs, floating windows, or other auxiliary UI.
        for stage in stageManager.stages {
            for windowID in stage.windowIDs where snapshot.untrackableWindowIDs.contains(windowID) {
                stageManager.removeWindow(windowID: windowID, fromStageID: stage.id)
                missingSnapshotCounts.removeValue(forKey: windowID)
                removedCount += 1
            }
        }

        let retainedWindowIDs = Set(stageManager.stages.flatMap(\.windows).map(\.windowID))
        missingSnapshotCounts = missingSnapshotCounts.filter { retainedWindowIDs.contains($0.key) }

        var missingAssignments: [WindowAssignment] = []

        // AX window enumeration can return a plausible-looking but partial list.
        // Only the independent, unfiltered CG ID snapshot may confirm absence.
        // Ordered-out windows disappear from that snapshot while their app is
        // hidden, so hidden processes suspend and reset absence tracking.
        if let allWindowIDs = snapshot.allWindowIDs {
            let persistedAssignments = assignments(in: stageManager)
            for assignment in persistedAssignments {
                let window = assignment.window
                if allWindowIDs.contains(window.windowID) {
                    missingSnapshotCounts.removeValue(forKey: window.windowID)
                    continue
                }

                if window.ownerPID.map(snapshot.hiddenPIDs.contains) == true {
                    missingSnapshotCounts.removeValue(forKey: window.windowID)
                    continue
                }

                let missingCount = missingSnapshotCounts[window.windowID, default: 0] + 1
                missingSnapshotCounts[window.windowID] = missingCount
                missingAssignments.append(assignment)
            }

            // Prefer stable identity before deleting anything. Reconciliation is
            // published before focus, so recreated windows are still unassigned.
            let directMatches = recoveryMatches(
                assignments: missingAssignments,
                liveWindows: snapshot.liveWindows,
                stageManager: stageManager
            )
            var recoveredOldWindowIDs = Set<CGWindowID>()
            var consumedLiveWindowIDs = Set<CGWindowID>()
            for (assignment, info) in directMatches {
                removeWindowFromAllStages(windowID: info.windowID, stageManager: &stageManager)
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
                missingSnapshotCounts.removeValue(forKey: assignment.window.windowID)
                recoveredOldWindowIDs.insert(assignment.window.windowID)
                consumedLiveWindowIDs.insert(info.windowID)
                reassignedCount += 1
            }

            for assignment in missingAssignments {
                let windowID = assignment.window.windowID
                guard !recoveredOldWindowIDs.contains(windowID),
                      missingSnapshotCounts[windowID, default: 0] >= requiredMissingSnapshots,
                      let currentLocation = location(of: windowID, in: stageManager)
                else { continue }

                let currentWindow = stageManager.stages[currentLocation.stageIndex].windows[currentLocation.windowIndex]
                recentWindowAssignments.removeAll { $0.assignment.window.id == currentWindow.id }
                recentWindowAssignments.append(RecentWindowAssignment(
                    assignment: WindowAssignment(
                        stageID: stageManager.stages[currentLocation.stageIndex].id,
                        windowIndex: currentLocation.windowIndex,
                        window: currentWindow
                    ),
                    removedAt: now
                ))
                stageManager.removeWindow(
                    windowID: windowID,
                    fromStageID: stageManager.stages[currentLocation.stageIndex].id
                )
                missingSnapshotCounts.removeValue(forKey: windowID)
                removedCount += 1
            }

            let recentMatches = recoveryMatches(
                assignments: recentWindowAssignments.map(\.assignment),
                liveWindows: snapshot.liveWindows.filter { !consumedLiveWindowIDs.contains($0.windowID) },
                stageManager: stageManager
            )
            let matchedAssignmentIDs = Set(recentMatches.map { $0.0.window.id })
            recentWindowAssignments.removeAll { matchedAssignmentIDs.contains($0.assignment.window.id) }

            let stageOrder = Dictionary(
                uniqueKeysWithValues: stageManager.stages.enumerated().map { ($0.element.id, $0.offset) }
            )
            for (assignment, info) in recentMatches.sorted(by: {
                let lhsStage = stageOrder[$0.0.stageID, default: .max]
                let rhsStage = stageOrder[$1.0.stageID, default: .max]
                return lhsStage == rhsStage
                    ? $0.0.windowIndex < $1.0.windowIndex
                    : lhsStage < rhsStage
            }) {
                removeWindowFromAllStages(windowID: info.windowID, stageManager: &stageManager)
                var restoredWindow = assignment.window
                restoredWindow.windowID = info.windowID
                restoredWindow.ownerPID = info.ownerPID
                restoredWindow.windowTitle = info.title
                stageManager.insertWindow(
                    restoredWindow,
                    at: assignment.windowIndex,
                    inStageID: assignment.stageID
                )
                consumedLiveWindowIDs.insert(info.windowID)
                reassignedCount += 1
            }
        }

        // AX metadata is still useful for additions, but never for destructive
        // absence checks. Existing assignments are left untouched.
        let targetStageID = stageManager.activeStageID
        var addedWindowIDs = Set<CGWindowID>()
        for info in snapshot.liveWindows where stageManager.stageContainingWindow(windowID: info.windowID) == nil {
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
            removedCount: removedCount,
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
        stageManager: StageManager
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
                    $0.window.windowID != info.windowID &&
                    $0.window.ownerBundleID == info.ownerBundleID &&
                    $0.window.windowTitle == info.title &&
                    stageManager.stageContainingWindow(windowID: info.windowID) == nil
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
                stageManager.stageContainingWindow(windowID: $0.windowID) == nil
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

    private func removeWindowFromAllStages(
        windowID: CGWindowID,
        stageManager: inout StageManager
    ) {
        let stageIDs = stageManager.stages
            .filter { $0.windowIDs.contains(windowID) }
            .map(\.id)
        for stageID in stageIDs {
            stageManager.removeWindow(windowID: windowID, fromStageID: stageID)
        }
    }
}
