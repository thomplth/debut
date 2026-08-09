import CoreGraphics
import Foundation

public struct RuntimeWindowSnapshot: Sendable {
    public let liveWindows: [WindowInfo]
    public let allWindowIDs: Set<CGWindowID>?
    public let focusedWindowID: CGWindowID?
    /// Windows currently assigned without an armed destroy notification, so
    /// nothing can ever prove they closed.
    public let unarmedWindowIDs: Set<CGWindowID>

    public init(
        liveWindows: [WindowInfo],
        allWindowIDs: Set<CGWindowID>?,
        focusedWindowID: CGWindowID? = nil,
        unarmedWindowIDs: Set<CGWindowID> = []
    ) {
        self.liveWindows = liveWindows
        self.allWindowIDs = allWindowIDs
        self.focusedWindowID = focusedWindowID
        self.unarmedWindowIDs = unarmedWindowIDs
    }
}

/// A single assignment change, carrying enough identity to diagnose a
/// misplacement after the fact. Aggregate counts cannot show which window moved.
public struct WindowAssignmentEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case assigned
        case reassigned
    }

    public enum Reason: String, Sendable {
        case new
        case recoveredExact = "recovered_exact"
        case recoveredBundle = "recovered_bundle"
        case dormantRestored = "dormant_restored"
        case strandedStageRecovered = "stranded_stage_recovered"
    }

    public let kind: Kind
    public let windowID: CGWindowID
    public let bundleID: String
    public let windowTitle: String
    public let fromStage: Int?
    public let toStage: Int?
    public let reason: Reason

    public var diagnosticDetails: [String: String] {
        var details: [String: String] = [
            "windowID": "\(windowID)",
            "bundleID": bundleID,
            "windowTitle": windowTitle,
            "reason": reason.rawValue,
        ]
        if let fromStage { details["fromStage"] = "\(fromStage)" }
        if let toStage { details["toStage"] = "\(toStage)" }
        return details
    }
}

public struct RuntimeWindowReconciliationResult: Equatable, Sendable {
    public let addedCount: Int
    public let reassignedCount: Int
    public let events: [WindowAssignmentEvent]

    public init(
        addedCount: Int = 0,
        reassignedCount: Int = 0,
        events: [WindowAssignmentEvent] = []
    ) {
        self.addedCount = addedCount
        self.reassignedCount = reassignedCount
        self.events = events
    }

    public var didMutate: Bool { addedCount > 0 || reassignedCount > 0 }
}

public struct RuntimeWindowReconciler: Sendable {
    private struct WindowAssignment: Sendable {
        let stageID: UUID
        let windowIndex: Int
        let window: StageWindow
    }

    private struct RecoveryMatch: Sendable {
        let assignment: WindowAssignment
        let info: WindowInfo
        let reason: WindowAssignmentEvent.Reason
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
        var events: [WindowAssignmentEvent] = []
        var consumedLiveWindowIDs = Set<CGWindowID>()
        provisionalWindowIDs = provisionalWindowIDs.filter {
            stageManager.stageContainingWindow(windowID: $0) != nil
        }

        // Stages still holding an assignment whose window vanished and could not
        // be recovered, keyed by bundle. A replacement belongs with them rather
        // than wherever the user happens to be standing.
        var strandedStageIDs: [String: Set<UUID>] = [:]

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
                stageManager: stageManager,
                allowedAssignedWindowIDs: provisionalWindowIDs
            )
            let matchedAssignmentIDs = Set(directMatches.map(\.assignment.window.id))
            for assignment in missingAssignments
            where !matchedAssignmentIDs.contains(assignment.window.id) {
                strandedStageIDs[assignment.window.ownerBundleID, default: []]
                    .insert(assignment.stageID)
            }
            for match in directMatches {
                // A provisional window already occupies a guessed slot. Drop it
                // before rebinding, or it ends up assigned to two stages.
                if provisionalWindowIDs.contains(match.info.windowID) {
                    stageManager.removeLiveWindowFromAllStages(windowID: match.info.windowID)
                }
                guard let location = location(
                    of: match.assignment.window.windowID,
                    in: stageManager
                ) else { continue }

                stageManager.updateWindowIDs(
                    stageIndex: location.stageIndex,
                    windowIndex: location.windowIndex,
                    windowID: match.info.windowID,
                    ownerPID: match.info.ownerPID,
                    windowTitle: match.info.title
                )
                consumedLiveWindowIDs.insert(match.info.windowID)
                provisionalWindowIDs.remove(match.info.windowID)
                reassignedCount += 1
                events.append(WindowAssignmentEvent(
                    kind: .reassigned,
                    windowID: match.info.windowID,
                    bundleID: match.info.ownerBundleID,
                    windowTitle: match.info.title,
                    fromStage: location.stageIndex,
                    toStage: location.stageIndex,
                    reason: match.reason
                ))
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
        for match in sortedByStagePosition(dormantMatches, stageManager: stageManager) {
            let previousStage = stageManager.stageContainingWindow(windowID: match.info.windowID)
                .flatMap { id in stageManager.stages.firstIndex(where: { $0.id == id }) }
            stageManager.removeLiveWindowFromAllStages(windowID: match.info.windowID)
            guard stageManager.restoreDormantWindow(
                assignmentID: match.assignment.window.id,
                windowID: match.info.windowID,
                ownerPID: match.info.ownerPID,
                windowTitle: match.info.title
            ) else { continue }
            consumedLiveWindowIDs.insert(match.info.windowID)
            provisionalWindowIDs.remove(match.info.windowID)
            reassignedCount += 1
            events.append(WindowAssignmentEvent(
                kind: .reassigned,
                windowID: match.info.windowID,
                bundleID: match.info.ownerBundleID,
                windowTitle: match.info.title,
                fromStage: previousStage,
                toStage: stageManager.stages.firstIndex(where: { $0.id == match.assignment.stageID }),
                reason: .dormantRestored
            ))
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
            let strandedStageID = unambiguousStrandedStageID(
                forBundleID: info.ownerBundleID,
                strandedStageIDs: strandedStageIDs,
                stageManager: stageManager
            )
            stageManager.addWindow(
                StageWindow(
                    windowID: info.windowID,
                    ownerBundleID: info.ownerBundleID,
                    ownerName: info.ownerName,
                    windowTitle: info.title,
                    ownerPID: info.ownerPID
                ),
                toStageID: strandedStageID ?? targetStageID
            )
            // Placement was a guess while the bundle has unresolved assignments,
            // so leave it reclaimable once the counts settle.
            if strandedStageIDs[info.ownerBundleID] != nil ||
                stageManager.dormantWindowAssignments.contains(where: {
                    $0.window.ownerBundleID == info.ownerBundleID
                }) {
                provisionalWindowIDs.insert(info.windowID)
            }
            addedWindowIDs.insert(info.windowID)
            addedCount += 1
            events.append(WindowAssignmentEvent(
                kind: .assigned,
                windowID: info.windowID,
                bundleID: info.ownerBundleID,
                windowTitle: info.title,
                fromStage: nil,
                toStage: stageManager.stages.firstIndex(where: { $0.id == (strandedStageID ?? targetStageID) }),
                reason: strandedStageID == nil ? .new : .strandedStageRecovered
            ))
        }

        if let focusedWindowID = snapshot.focusedWindowID,
           addedWindowIDs.contains(focusedWindowID),
           let focusedStageID = stageManager.stageContainingWindow(windowID: focusedWindowID) {
            stageManager.bringWindowToFront(
                windowID: focusedWindowID,
                inStageID: focusedStageID
            )
        }

        return RuntimeWindowReconciliationResult(
            addedCount: addedCount,
            reassignedCount: reassignedCount,
            events: events
        )
    }

    /// The stage a replacement window should join. Only answerable when every
    /// stranded assignment for the bundle sits in one stage; spread across
    /// several, choosing one would be the same guess `zip` already makes.
    private func unambiguousStrandedStageID(
        forBundleID bundleID: String,
        strandedStageIDs: [String: Set<UUID>],
        stageManager: StageManager
    ) -> UUID? {
        guard let stageIDs = strandedStageIDs[bundleID],
              stageIDs.count == 1,
              let stageID = stageIDs.first,
              stageManager.stages.contains(where: { $0.id == stageID })
        else { return nil }
        return stageID
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
    ) -> [RecoveryMatch] {
        var matches: [RecoveryMatch] = []
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
            matches.append(RecoveryMatch(assignment: assignment, info: info, reason: .recoveredExact))
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
            matches.append(contentsOf: zip(bundleAssignments, bundleWindows).map {
                RecoveryMatch(assignment: $0.0, info: $0.1, reason: .recoveredBundle)
            })
        }

        return matches
    }

    private func sortedByStagePosition(
        _ matches: [RecoveryMatch],
        stageManager: StageManager
    ) -> [RecoveryMatch] {
        let stageOrder = Dictionary(
            uniqueKeysWithValues: stageManager.stages.enumerated().map { ($0.element.id, $0.offset) }
        )
        return matches.sorted {
            let lhsStage = stageOrder[$0.assignment.stageID, default: .max]
            let rhsStage = stageOrder[$1.assignment.stageID, default: .max]
            return lhsStage == rhsStage
                ? $0.assignment.windowIndex < $1.assignment.windowIndex
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
