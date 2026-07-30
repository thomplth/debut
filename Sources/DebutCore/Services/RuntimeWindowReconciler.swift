import CoreGraphics
import Foundation

public struct RuntimeWindowSnapshot: Sendable {
    public let runningPIDs: Set<pid_t>
    public let liveWindows: [WindowInfo]
    public let allWindowIDs: Set<CGWindowID>?

    public init(runningPIDs: Set<pid_t>, liveWindows: [WindowInfo], allWindowIDs: Set<CGWindowID>?) {
        self.runningPIDs = runningPIDs
        self.liveWindows = liveWindows
        self.allWindowIDs = allWindowIDs
    }
}

public struct RuntimeWindowReconciliationResult: Equatable, Sendable {
    public let addedCount: Int
    public let removedCount: Int

    public init(addedCount: Int = 0, removedCount: Int = 0) {
        self.addedCount = addedCount
        self.removedCount = removedCount
    }

    public var didMutate: Bool { addedCount > 0 || removedCount > 0 }
}

public struct RuntimeWindowReconciler: Sendable {
    private let requiredMissingSnapshots: Int
    private var missingSnapshotCounts: [CGWindowID: Int] = [:]

    public init(requiredMissingSnapshots: Int = 2) {
        self.requiredMissingSnapshots = max(1, requiredMissingSnapshots)
    }

    public mutating func reconcile(
        _ snapshot: RuntimeWindowSnapshot,
        stageManager: inout StageManager
    ) -> RuntimeWindowReconciliationResult {
        var addedCount = 0
        var removedCount = stageManager.removeWindowsOwnedByStoppedProcesses(
            runningPIDs: snapshot.runningPIDs
        )

        let retainedWindowIDs = Set(stageManager.stages.flatMap(\.windows).map(\.windowID))
        missingSnapshotCounts = missingSnapshotCounts.filter { retainedWindowIDs.contains($0.key) }

        // AX window enumeration can return a plausible-looking but partial list.
        // Only the independent, unfiltered CG ID snapshot may confirm absence.
        if let allWindowIDs = snapshot.allWindowIDs {
            let persistedWindows = stageManager.stages.flatMap(\.windows)
            for window in persistedWindows {
                if allWindowIDs.contains(window.windowID) {
                    missingSnapshotCounts.removeValue(forKey: window.windowID)
                    continue
                }

                let missingCount = missingSnapshotCounts[window.windowID, default: 0] + 1
                missingSnapshotCounts[window.windowID] = missingCount
                guard missingCount >= requiredMissingSnapshots else { continue }

                for stage in stageManager.stages where stage.windowIDs.contains(window.windowID) {
                    stageManager.removeWindow(windowID: window.windowID, fromStageID: stage.id)
                    removedCount += 1
                }
                missingSnapshotCounts.removeValue(forKey: window.windowID)
            }
        }

        // AX metadata is still useful for additions, but never for destructive
        // absence checks. Existing assignments are left untouched.
        let targetStageID = stageManager.activeStageID
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
            addedCount += 1
        }

        return RuntimeWindowReconciliationResult(
            addedCount: addedCount,
            removedCount: removedCount
        )
    }
}
