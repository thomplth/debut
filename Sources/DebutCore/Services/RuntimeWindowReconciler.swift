import CoreGraphics
import Foundation

public struct RuntimeWindowSnapshot: Sendable {
    public let liveWindows: [WindowInfo]
    public let allWindowIDs: Set<CGWindowID>?
    public let focusedWindowID: CGWindowID?
    /// Windows currently assigned without an armed destroy notification, so
    /// nothing can ever prove they closed.
    public let unarmedWindowIDs: Set<CGWindowID>
    /// The desktop macOS reports for each window. Absent means macOS gave no single
    /// answer — an all-Spaces or fullscreen window — which must not be read as desktop 0.
    public let desktopIndexes: [CGWindowID: Int]
    /// Display-qualified desktop locations. New snapshots use this so desktop 1 on two
    /// displays cannot collapse into the same space.
    public let desktopLocations: [CGWindowID: DesktopLocation]

    public init(
        liveWindows: [WindowInfo],
        allWindowIDs: Set<CGWindowID>?,
        focusedWindowID: CGWindowID? = nil,
        unarmedWindowIDs: Set<CGWindowID> = [],
        desktopIndexes: [CGWindowID: Int] = [:],
        desktopLocations: [CGWindowID: DesktopLocation] = [:]
    ) {
        self.liveWindows = liveWindows
        self.allWindowIDs = allWindowIDs
        self.focusedWindowID = focusedWindowID
        self.unarmedWindowIDs = unarmedWindowIDs
        self.desktopIndexes = desktopIndexes
        self.desktopLocations = desktopLocations
    }
}

/// A single assignment change, carrying enough identity to diagnose a
/// misplacement after the fact. Aggregate counts cannot show which window moved.
public struct WindowAssignmentEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case assigned
        case reassigned
        case madeDormant = "made_dormant"
    }

    public enum Reason: String, Sendable {
        case new
        case recoveredExact = "recovered_exact"
        case recoveredBundle = "recovered_bundle"
        case dormantRestored = "dormant_restored"
        case strandedSpaceRecovered = "stranded_space_recovered"
        case desktopChanged = "desktop_changed"
        /// A CGWindowID macOS reissued to a window with a different owner. Caught by the
        /// identity pass, which parks the stale assignment rather than leaving it live under
        /// somebody else's window.
        case idRecycled = "id_recycled"
    }

    public let kind: Kind
    public let windowID: CGWindowID
    public let bundleID: String
    public let windowTitle: String
    public let fromSpace: Int?
    public let toSpace: Int?
    public let reason: Reason

    public var diagnosticDetails: [String: String] {
        var details: [String: String] = [
            "windowID": "\(windowID)",
            "bundleID": bundleID,
            "windowTitle": windowTitle,
            "reason": reason.rawValue,
        ]
        if let fromSpace { details["fromSpace"] = "\(fromSpace)" }
        if let toSpace { details["toSpace"] = "\(toSpace)" }
        return details
    }
}

public struct RuntimeWindowReconciliationResult: Equatable, Sendable {
    public let addedCount: Int
    public let reassignedCount: Int
    public let dormantCount: Int
    public let events: [WindowAssignmentEvent]

    public init(
        addedCount: Int = 0,
        reassignedCount: Int = 0,
        dormantCount: Int = 0,
        events: [WindowAssignmentEvent] = []
    ) {
        self.addedCount = addedCount
        self.reassignedCount = reassignedCount
        self.dormantCount = dormantCount
        self.events = events
    }

    public var didMutate: Bool { addedCount > 0 || reassignedCount > 0 || dormantCount > 0 }
}

public struct RuntimeWindowReconciler: Sendable {
    private struct WindowAssignment: Sendable {
        let spaceID: UUID
        let windowIndex: Int
        let window: SpaceWindow
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
        spaceManager: inout SpaceManager,
        newWindowSpaceID: UUID? = nil
    ) -> RuntimeWindowReconciliationResult {
        var addedCount = 0
        var reassignedCount = 0
        var dormantCount = 0
        var events: [WindowAssignmentEvent] = []
        var consumedLiveWindowIDs = Set<CGWindowID>()
        let preferredSpaceIDs: [CGWindowID: UUID] = Dictionary(
            uniqueKeysWithValues: snapshot.liveWindows.compactMap { info in
                guard let spaceID = desktopSpaceID(
                    for: info.windowID,
                    snapshot: snapshot,
                    spaceManager: spaceManager
                ) else { return nil }
                return (info.windowID, spaceID)
            }
        )
        provisionalWindowIDs = provisionalWindowIDs.filter {
            spaceManager.spaceContainingWindow(windowID: $0) != nil
        }

        // A CGWindowID only means anything within the boot that issued it, and macOS
        // reissues them continuously as windows close — not only across a reboot. A recycled
        // ID is still present in allWindowIDs, so the missing-assignment check below would
        // never catch it; only comparing the live window's bundleID against the assignment's
        // does. Parking here, before that check runs, lets the same pass recover the
        // assignment onto its real window by (bundleID, title) below.
        let liveWindowsByID = Dictionary(
            snapshot.liveWindows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for assignment in assignments(in: spaceManager) {
            guard let info = liveWindowsByID[assignment.window.windowID],
                  info.ownerBundleID != assignment.window.ownerBundleID
            else { continue }
            let fromSpace = spaceManager.spaceIndex(id: assignment.spaceID)
            guard spaceManager.makeWindowDormant(windowID: assignment.window.windowID) != nil
            else { continue }
            dormantCount += 1
            events.append(WindowAssignmentEvent(
                kind: .madeDormant,
                windowID: assignment.window.windowID,
                bundleID: assignment.window.ownerBundleID,
                windowTitle: assignment.window.windowTitle,
                fromSpace: fromSpace,
                toSpace: nil,
                reason: .idRecycled
            ))
        }

        // Spaces still holding an assignment whose window vanished and could not
        // be recovered, keyed by bundle. A replacement belongs with them rather
        // than wherever the user happens to be standing.
        var strandedSpaceIDs: [String: Set<UUID>] = [:]

        // CG absence is evidence that an ID may have been replaced, never evidence
        // that a window was destroyed. Only AX lifecycle events remove assignments.
        if let allWindowIDs = snapshot.allWindowIDs {
            let missingAssignments = assignments(in: spaceManager).filter {
                !allWindowIDs.contains($0.window.windowID)
            }

            // Prefer stable identity before adding anything. Reconciliation is
            // published before focus, so recreated windows are still unassigned.
            let directMatches = recoveryMatches(
                assignments: missingAssignments,
                liveWindows: snapshot.liveWindows,
                spaceManager: spaceManager,
                allowedAssignedWindowIDs: provisionalWindowIDs,
                preferredSpaceIDs: preferredSpaceIDs
            )
            let matchedAssignmentIDs = Set(directMatches.map(\.assignment.window.id))
            for assignment in missingAssignments
            where !matchedAssignmentIDs.contains(assignment.window.id) {
                strandedSpaceIDs[assignment.window.ownerBundleID, default: []]
                    .insert(assignment.spaceID)
            }
            for match in directMatches {
                // A provisional window already occupies a guessed slot. Drop it
                // before rebinding, or it ends up assigned to two spaces.
                if provisionalWindowIDs.contains(match.info.windowID) {
                    spaceManager.removeLiveWindowFromAllSpaces(windowID: match.info.windowID)
                }
                guard let location = location(
                    of: match.assignment.window.windowID,
                    in: spaceManager
                ) else { continue }

                spaceManager.updateWindowIDs(
                    spaceID: location.spaceID,
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
                    fromSpace: location.spaceIndex,
                    toSpace: location.spaceIndex,
                    reason: match.reason
                ))
            }
        }

        let dormantAssignments = spaceManager.dormantWindowAssignments.map {
            WindowAssignment(
                spaceID: $0.spaceID,
                windowIndex: $0.windowIndex,
                window: $0.window
            )
        }
        let dormantMatches = recoveryMatches(
            assignments: dormantAssignments,
            liveWindows: snapshot.liveWindows.filter { !consumedLiveWindowIDs.contains($0.windowID) },
            spaceManager: spaceManager,
            allowedAssignedWindowIDs: provisionalWindowIDs,
            preferredSpaceIDs: preferredSpaceIDs
        )
        for match in sortedBySpacePosition(dormantMatches, spaceManager: spaceManager) {
            let previousSpace = spaceManager.spaceContainingWindow(windowID: match.info.windowID)
                .flatMap(spaceManager.spaceIndex(id:))
            spaceManager.removeLiveWindowFromAllSpaces(windowID: match.info.windowID)
            guard spaceManager.restoreDormantWindow(
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
                fromSpace: previousSpace,
                toSpace: spaceManager.spaceIndex(id: match.assignment.spaceID),
                reason: .dormantRestored
            ))
        }

        // Spaces are desktops, so macOS owns the membership question. An assignment that
        // disagrees is stale — the user dragged the window in Mission Control — and the
        // desktop wins. Unlike CG absence this is a positive statement about where the
        // window is, so acting on it cannot erase anything.
        for info in snapshot.liveWindows {
            guard let currentSpaceID = spaceManager.spaceContainingWindow(windowID: info.windowID),
                  let desktopSpaceID = desktopSpaceID(
                      for: info.windowID,
                      snapshot: snapshot,
                      spaceManager: spaceManager
                  ),
                  desktopSpaceID != currentSpaceID,
                  let window = spaceManager.allSpaces
                      .first(where: { $0.id == currentSpaceID })?
                      .windows.first(where: { $0.windowID == info.windowID })
            else { continue }

            let fromSpace = spaceManager.spaceIndex(id: currentSpaceID)
            spaceManager.removeLiveWindowFromAllSpaces(windowID: info.windowID)
            spaceManager.addWindow(window, toSpaceID: desktopSpaceID)
            provisionalWindowIDs.remove(info.windowID)
            consumedLiveWindowIDs.insert(info.windowID)
            reassignedCount += 1
            events.append(WindowAssignmentEvent(
                kind: .reassigned,
                windowID: info.windowID,
                bundleID: info.ownerBundleID,
                windowTitle: info.title,
                fromSpace: fromSpace,
                toSpace: spaceManager.spaceIndex(id: desktopSpaceID),
                reason: .desktopChanged
            ))
        }

        // AX metadata is still useful for additions, but never for destructive
        // absence checks. Existing assignments are left untouched.
        let targetSpaceID = newWindowSpaceID.flatMap { requestedID in
            spaceManager.allSpaces.contains(where: { $0.id == requestedID }) ? requestedID : nil
        } ?? spaceManager.activeSpaceID
        var addedWindowIDs = Set<CGWindowID>()
        for info in snapshot.liveWindows where
            !consumedLiveWindowIDs.contains(info.windowID) &&
            spaceManager.spaceContainingWindow(windowID: info.windowID) == nil {
            let desktopSpaceID = desktopSpaceID(
                for: info.windowID,
                snapshot: snapshot,
                spaceManager: spaceManager
            )
            let strandedSpaceID = unambiguousStrandedSpaceID(
                forBundleID: info.ownerBundleID,
                strandedSpaceIDs: strandedSpaceIDs,
                spaceManager: spaceManager
            )
            let placementSpaceID = desktopSpaceID ?? strandedSpaceID ?? targetSpaceID
            spaceManager.addWindow(
                SpaceWindow(
                    windowID: info.windowID,
                    ownerBundleID: info.ownerBundleID,
                    ownerName: info.ownerName,
                    windowTitle: info.title,
                    ownerPID: info.ownerPID
                ),
                toSpaceID: placementSpaceID
            )
            // Placement was a guess while the bundle has unresolved assignments,
            // so leave it reclaimable once the counts settle. A desktop answer is not
            // a guess, and letting a later bundle-only match reclaim it would drag the
            // window off the desktop it is demonstrably on.
            if desktopSpaceID == nil,
               strandedSpaceIDs[info.ownerBundleID] != nil ||
                spaceManager.dormantWindowAssignments.contains(where: {
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
                fromSpace: nil,
                toSpace: spaceManager.spaceIndex(id: placementSpaceID),
                reason: desktopSpaceID == nil && strandedSpaceID != nil
                    ? .strandedSpaceRecovered
                    : .new
            ))
        }

        if let focusedWindowID = snapshot.focusedWindowID,
           addedWindowIDs.contains(focusedWindowID),
           let focusedSpaceID = spaceManager.spaceContainingWindow(windowID: focusedWindowID) {
            spaceManager.bringWindowToFront(
                windowID: focusedWindowID,
                inSpaceID: focusedSpaceID
            )
        }

        return RuntimeWindowReconciliationResult(
            addedCount: addedCount,
            reassignedCount: reassignedCount,
            dormantCount: dormantCount,
            events: events
        )
    }

    /// The space matching the desktop macOS reports for a window. Nil when macOS gave no
    /// single desktop, or when the space list has not yet grown to include it.
    private func desktopSpaceID(
        for windowID: CGWindowID,
        snapshot: RuntimeWindowSnapshot,
        spaceManager: SpaceManager
    ) -> UUID? {
        if let location = snapshot.desktopLocations[windowID] {
            return spaceManager.spaceID(stackID: location.stackID, at: location.index)
        }
        guard let index = snapshot.desktopIndexes[windowID] else { return nil }
        return spaceManager.space(atIndex: index)?.id
    }

    /// The space a replacement window should join. Only answerable when every
    /// stranded assignment for the bundle sits in one space; spread across
    /// several, choosing one would be the same guess `zip` already makes.
    private func unambiguousStrandedSpaceID(
        forBundleID bundleID: String,
        strandedSpaceIDs: [String: Set<UUID>],
        spaceManager: SpaceManager
    ) -> UUID? {
        guard let spaceIDs = strandedSpaceIDs[bundleID],
              spaceIDs.count == 1,
              let spaceID = spaceIDs.first,
              spaceManager.allSpaces.contains(where: { $0.id == spaceID })
        else { return nil }
        return spaceID
    }

    private func assignments(in spaceManager: SpaceManager) -> [WindowAssignment] {
        spaceManager.allSpaces.flatMap { space in
            space.windows.enumerated().map { windowIndex, window in
                WindowAssignment(spaceID: space.id, windowIndex: windowIndex, window: window)
            }
        }
    }

    private func recoveryMatches(
        assignments: [WindowAssignment],
        liveWindows: [WindowInfo],
        spaceManager: SpaceManager,
        allowedAssignedWindowIDs: Set<CGWindowID> = [],
        preferredSpaceIDs: [CGWindowID: UUID] = [:]
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
                    (spaceManager.spaceContainingWindow(windowID: info.windowID) == nil ||
                        allowedAssignedWindowIDs.contains(info.windowID))
            }) else { continue }
            matches.append(RecoveryMatch(assignment: assignment, info: info, reason: .recoveredExact))
            usedAssignmentIDs.insert(assignment.window.id)
            usedLiveWindowIDs.insert(info.windowID)
        }

        // A desktop answer is stronger than a dynamic title. During relaunch, CGWindowList
        // often reveals one desktop at a time, so requiring every window in a bundle to be
        // present would leave the replacement as a new assignment and strand its old one.
        // Match one-to-one within a desktop when that desktop has an unambiguous set.
        let remainingAssignmentsAfterExact = assignments.filter {
            !usedAssignmentIDs.contains($0.window.id)
        }
        let remainingLiveWindowsAfterExact = liveWindows.filter {
            !usedLiveWindowIDs.contains($0.windowID) &&
                (spaceManager.spaceContainingWindow(windowID: $0.windowID) == nil ||
                    allowedAssignedWindowIDs.contains($0.windowID))
        }
        let spaceIDs = Set(remainingAssignmentsAfterExact.map(\.spaceID))
        for spaceID in spaceIDs {
            let spaceAssignments = remainingAssignmentsAfterExact.filter { $0.spaceID == spaceID }
            let spaceWindows = remainingLiveWindowsAfterExact.filter {
                preferredSpaceIDs[$0.windowID] == spaceID
            }
            let bundleIDs = Set(spaceAssignments.map { $0.window.ownerBundleID })
            for bundleID in bundleIDs.sorted() {
                let bundleAssignments = spaceAssignments.filter {
                    $0.window.ownerBundleID == bundleID && !usedAssignmentIDs.contains($0.window.id)
                }
                let bundleWindows = spaceWindows.filter {
                    $0.ownerBundleID == bundleID && !usedLiveWindowIDs.contains($0.windowID)
                }
                guard !bundleAssignments.isEmpty,
                      bundleAssignments.count == bundleWindows.count
                else { continue }
                for (assignment, info) in zip(bundleAssignments, bundleWindows) {
                    matches.append(RecoveryMatch(
                        assignment: assignment,
                        info: info,
                        reason: .recoveredBundle
                    ))
                    usedAssignmentIDs.insert(assignment.window.id)
                    usedLiveWindowIDs.insert(info.windowID)
                }
            }
        }

        // Dynamic titles without a desktop answer require a bundle-only fallback. Use it only
        // when all remaining assignments and unassigned live windows for that bundle form a
        // complete one-to-one set, avoiding arbitrary partial reassignment.
        let remainingAssignments = assignments.filter { !usedAssignmentIDs.contains($0.window.id) }
        let remainingLiveWindows = liveWindows.filter {
            !usedLiveWindowIDs.contains($0.windowID) &&
                (spaceManager.spaceContainingWindow(windowID: $0.windowID) == nil ||
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

    private func sortedBySpacePosition(
        _ matches: [RecoveryMatch],
        spaceManager: SpaceManager
    ) -> [RecoveryMatch] {
        let spaceOrder = Dictionary(
            uniqueKeysWithValues: spaceManager.allSpaces.enumerated().map { ($0.element.id, $0.offset) }
        )
        return matches.sorted {
            let lhsSpace = spaceOrder[$0.assignment.spaceID, default: .max]
            let rhsSpace = spaceOrder[$1.assignment.spaceID, default: .max]
            return lhsSpace == rhsSpace
                ? $0.assignment.windowIndex < $1.assignment.windowIndex
                : lhsSpace < rhsSpace
        }
    }

    private func location(
        of windowID: CGWindowID,
        in spaceManager: SpaceManager
    ) -> (spaceID: UUID, spaceIndex: Int, windowIndex: Int)? {
        for space in spaceManager.allSpaces {
            if let windowIndex = space.windows.firstIndex(where: {
                $0.windowID == windowID
            }) {
                return (space.id, spaceManager.spaceIndex(id: space.id) ?? 0, windowIndex)
            }
        }
        return nil
    }

}
