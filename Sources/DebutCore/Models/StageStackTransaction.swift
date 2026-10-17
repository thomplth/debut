import CoreGraphics
import Foundation

/// Spaces stage-stack edits without touching the persisted model or the window server.
///
/// Every move shown by the overlay passes through this transaction. The controller is the
/// only owner of the commit boundary, so an input handler cannot accidentally turn a preview
/// gesture into an immediate assignment change.
struct StageStackTransaction: Sendable {
    enum Source: Sendable, Equatable {
        case keyboard
        case pointer
    }

    struct Relocation: Sendable, Equatable {
        let windowID: CGWindowID
        let fromSpaceIndex: Int
        let toSpaceIndex: Int
    }

    struct Commit: Sendable {
        let didMutate: Bool
        let relocations: [Relocation]
        let keyboardWindowIDs: Set<CGWindowID>
        let pointerWindowIDs: Set<CGWindowID>
    }

    /// A desktop the session has added. It exists only in the preview until the commit creates
    /// it and `resolveDesktop` swaps in the space macOS actually gave it.
    struct StagedDesktop: Sendable, Equatable {
        let spaceID: UUID
        let stackID: String
        /// The space it goes straight after, or nil for the top of the stack. Named by identity
        /// so later edits cannot shift it; a predecessor taken out again hands over its own.
        var predecessorID: UUID?
    }

    /// A desktop the session has removed. Its windows join `destinationID` in the preview at
    /// once, and on commit they move there before the desktop is destroyed.
    struct StagedRemoval: Sendable, Equatable {
        let spaceID: UUID
        var destinationID: UUID
        /// Where in the destination its windows go, when a held plate was dropped into a gap.
        /// Nil files them by activation, as macOS does.
        var placement: PointerPlacement? = nil
    }

    /// A desktop the session has moved. Named by identity, like an added desktop's place.
    struct StagedReorder: Sendable, Equatable {
        var spaceID: UUID
        let stackID: String
        var predecessorID: UUID?
    }

    /// The edits that change macOS's desktop list ahead of window moves, in staging order.
    enum DesktopEdit: Sendable, Equatable {
        case add(StagedDesktop)
        case reorder(StagedReorder)
    }

    private struct Move: Sendable {
        let windowID: CGWindowID
        var fromSpaceID: UUID
        var toSpaceID: UUID
        let windowIndex: Int
        /// Pointer drops name their gap by the windows around it, so a replay after an earlier
        /// edit still lands between the same neighbours. `nil` keeps the index semantics.
        let placement: PointerPlacement?
        let source: Source
        let activatedAt: Date?
    }

    /// Replayed in the order they were made: a window moved after its desktop was removed
    /// starts from wherever the removal put it.
    private enum Operation: Sendable {
        case move(Move)
        case add(StagedDesktop)
        case remove(StagedRemoval)
        case reorder(StagedReorder)
    }

    private var operations: [Operation] = []

    private var moves: [Move] {
        operations.compactMap { if case let .move(move) = $0 { move } else { nil } }
    }

    /// Desktops still waiting to be created, in the order they were added.
    var stagedDesktops: [StagedDesktop] {
        operations.compactMap { if case let .add(desktop) = $0 { desktop } else { nil } }
    }

    var stagedRemovals: [StagedRemoval] {
        operations.compactMap { if case let .remove(removal) = $0 { removal } else { nil } }
    }

    var stagedReorders: [StagedReorder] {
        operations.compactMap { if case let .reorder(reorder) = $0 { reorder } else { nil } }
    }

    var changesDesktops: Bool {
        !stagedDesktops.isEmpty || !stagedRemovals.isEmpty || !stagedReorders.isEmpty
    }

    /// The first add or reorder still to be carried out on commit.
    var nextDesktopEdit: DesktopEdit? {
        for operation in operations {
            switch operation {
            case let .add(desktop): return .add(desktop)
            case let .reorder(reorder): return .reorder(reorder)
            case .move, .remove: continue
            }
        }
        return nil
    }

    func preview(applyingTo spaceManager: SpaceManager) -> SpaceManager {
        var preview = spaceManager
        apply(to: &preview, isPreview: true)
        return preview
    }

    mutating func spaceMove(
        windowID: CGWindowID,
        fromSpaceID: UUID,
        toSpaceID: UUID,
        windowIndex: Int,
        source: Source,
        activatedAt: Date? = nil
    ) {
        operations.append(.move(Move(
            windowID: windowID,
            fromSpaceID: fromSpaceID,
            toSpaceID: toSpaceID,
            windowIndex: windowIndex,
            placement: nil,
            source: source,
            activatedAt: activatedAt
        )))
    }

    mutating func pointerMove(
        windowID: CGWindowID,
        fromSpaceID: UUID,
        toSpaceID: UUID,
        placement: PointerPlacement
    ) {
        operations.append(.move(Move(
            windowID: windowID,
            fromSpaceID: fromSpaceID,
            toSpaceID: toSpaceID,
            windowIndex: 0,
            placement: placement,
            source: .pointer,
            activatedAt: nil
        )))
    }

    mutating func removeWindow(windowID: CGWindowID) {
        operations.removeAll {
            if case let .move(move) = $0 { move.windowID == windowID } else { false }
        }
    }

    mutating func addDesktop(spaceID: UUID, onStack stackID: String, after predecessorID: UUID?) {
        guard !stagedDesktops.contains(where: { $0.spaceID == spaceID }) else { return }
        operations.append(.add(StagedDesktop(
            spaceID: spaceID, stackID: stackID, predecessorID: predecessorID
        )))
    }

    /// Removing a desktop this session added takes it back out instead: it was never created,
    /// so every edit aimed at it goes too, and windows moved onto it return to where they were.
    mutating func removeDesktop(spaceID: UUID, into destinationID: UUID,
                                placement: PointerPlacement? = nil) {
        guard spaceID != destinationID else { return }
        if stagedDesktops.contains(where: { $0.spaceID == spaceID }) {
            unstageDesktop(spaceID: spaceID, retargetingTo: destinationID)
            return
        }
        guard !stagedRemovals.contains(where: { $0.spaceID == spaceID }) else { return }
        retargetRemovals(from: spaceID, to: destinationID)
        operations.append(.remove(StagedRemoval(
            spaceID: spaceID, destinationID: destinationID, placement: placement
        )))
    }

    mutating func reorderDesktop(spaceID: UUID, onStack stackID: String, after predecessorID: UUID?) {
        guard spaceID != predecessorID else { return }
        operations.append(.reorder(StagedReorder(
            spaceID: spaceID, stackID: stackID, predecessorID: predecessorID
        )))
    }

    /// A reorder carried out on commit, or one whose desktop macOS refused to move.
    mutating func finishReorder(_ reorder: StagedReorder) {
        guard let index = operations.firstIndex(where: {
            if case let .reorder(staged) = $0 { staged == reorder } else { false }
        }) else { return }
        operations.remove(at: index)
    }

    /// Swaps a created desktop's real space in for the id it was staged under, or drops it when
    /// macOS refused to create it.
    mutating func resolveDesktop(_ stagedID: UUID, as spaceID: UUID?) {
        guard let spaceID else {
            unstageDesktop(spaceID: stagedID, retargetingTo: nil)
            return
        }
        operations = operations.compactMap { operation in
            switch operation {
            case var .add(desktop):
                guard desktop.spaceID != stagedID else { return nil }
                if desktop.predecessorID == stagedID { desktop.predecessorID = spaceID }
                return .add(desktop)
            case var .move(move):
                if move.fromSpaceID == stagedID { move.fromSpaceID = spaceID }
                if move.toSpaceID == stagedID { move.toSpaceID = spaceID }
                return .move(move)
            case var .remove(removal):
                if removal.destinationID == stagedID { removal.destinationID = spaceID }
                return .remove(removal)
            case var .reorder(reorder):
                if reorder.spaceID == stagedID { reorder.spaceID = spaceID }
                if reorder.predecessorID == stagedID { reorder.predecessorID = spaceID }
                return .reorder(reorder)
            }
        }
    }

    private mutating func unstageDesktop(spaceID: UUID, retargetingTo destinationID: UUID?) {
        let predecessorID = stagedDesktops.first { $0.spaceID == spaceID }?.predecessorID
        operations = operations.map { operation in
            switch operation {
            case var .add(desktop) where desktop.predecessorID == spaceID:
                desktop.predecessorID = predecessorID
                return .add(desktop)
            case var .reorder(reorder) where reorder.predecessorID == spaceID:
                reorder.predecessorID = predecessorID
                return .reorder(reorder)
            default:
                return operation
            }
        }
        operations.removeAll { operation in
            switch operation {
            case let .add(desktop): desktop.spaceID == spaceID
            case let .move(move): move.fromSpaceID == spaceID || move.toSpaceID == spaceID
            case let .reorder(reorder): reorder.spaceID == spaceID
            case .remove: false
            }
        }
        if let destinationID {
            retargetRemovals(from: spaceID, to: destinationID)
        } else {
            operations.removeAll {
                if case let .remove(removal) = $0 { removal.destinationID == spaceID } else { false }
            }
        }
    }

    /// A desktop that was another removal's destination is going too, so what was headed for it
    /// follows it to its own destination.
    private mutating func retargetRemovals(from spaceID: UUID, to destinationID: UUID) {
        operations = operations.map { operation in
            guard case var .remove(removal) = operation, removal.destinationID == spaceID
            else { return operation }
            removal.destinationID = destinationID
            return .remove(removal)
        }
    }

    mutating func commit(to spaceManager: inout SpaceManager) -> Commit {
        let before = spaceManager
        // A removed desktop's windows move without a staged move of their own.
        let removedSpaceIDs = Set(stagedRemovals.map(\.spaceID))
        let affectedWindowIDs = Set(moves.map(\.windowID)).union(
            before.allSpaces.filter { removedSpaceIDs.contains($0.id) }
                .flatMap(\.windows).map(\.windowID)
        )
        let keyboardWindowIDs = Set(moves.lazy.filter { $0.source == .keyboard }.map(\.windowID))
        let pointerWindowIDs = Set(moves.lazy.filter { $0.source == .pointer }.map(\.windowID))
        apply(to: &spaceManager, isPreview: false)

        let relocations = affectedWindowIDs.compactMap { windowID -> Relocation? in
            guard let fromSpaceID = before.spaceContainingWindow(windowID: windowID),
                  let toSpaceID = spaceManager.spaceContainingWindow(windowID: windowID),
                  fromSpaceID != toSpaceID,
                  let fromSpaceIndex = before.spaces.firstIndex(where: { $0.id == fromSpaceID }),
                  let toSpaceIndex = spaceManager.spaces.firstIndex(where: { $0.id == toSpaceID })
            else { return nil }
            return Relocation(
                windowID: windowID,
                fromSpaceIndex: fromSpaceIndex,
                toSpaceIndex: toSpaceIndex
            )
        }
        .sorted { $0.windowID < $1.windowID }

        let didMutate = before.spaces.count != spaceManager.spaces.count
            || zip(before.spaces, spaceManager.spaces).contains { beforeSpace, afterSpace in
                beforeSpace.id != afterSpace.id || beforeSpace.windows != afterSpace.windows
            }
        operations.removeAll()
        return Commit(
            didMutate: didMutate,
            relocations: relocations,
            keyboardWindowIDs: keyboardWindowIDs,
            pointerWindowIDs: pointerWindowIDs
        )
    }

    mutating func discard() {
        operations.removeAll()
    }

    /// The committed model never gains or loses a space here; that is reconciliation's job once
    /// macOS has the desktop. A commit only merges a removed desktop's windows into their
    /// destination, ahead of the desktop being destroyed.
    private func apply(to spaceManager: inout SpaceManager, isPreview: Bool) {
        for operation in operations {
            switch operation {
            case let .move(move):
                apply(move, to: &spaceManager)
            case let .add(desktop):
                if isPreview {
                    spaceManager.insertStagedSpace(
                        id: desktop.spaceID, after: desktop.predecessorID, toStackID: desktop.stackID
                    )
                }
            case let .reorder(reorder):
                if isPreview {
                    spaceManager.moveStagedSpace(id: reorder.spaceID, after: reorder.predecessorID)
                }
            case let .remove(removal):
                if let placement = removal.placement {
                    spaceManager.mergeSpace(id: removal.spaceID, intoSpaceID: removal.destinationID,
                                            at: placement)
                } else {
                    spaceManager.mergeSpace(id: removal.spaceID, intoSpaceID: removal.destinationID)
                }
                if isPreview {
                    spaceManager.dropStagedSpace(id: removal.spaceID, showing: removal.destinationID)
                }
            }
        }
    }

    private func apply(_ move: Move, to spaceManager: inout SpaceManager) {
        var windowIndex = move.windowIndex
        if let placement = move.placement {
            // Neither neighbour survived: skip the move before removing its source rather
            // than appending it somewhere the user never pointed at.
            guard let remaining = spaceManager.windowIDs(inSpaceID: move.toSpaceID)?
                    .filter({ $0 != move.windowID }),
                  let resolved = placement.resolvedIndex(in: remaining)
            else { return }
            windowIndex = resolved
        }
        spaceManager.moveWindow(
            windowID: move.windowID,
            fromSpaceID: move.fromSpaceID,
            toSpaceID: move.toSpaceID,
            at: windowIndex
        )
        if let activatedAt = move.activatedAt {
            spaceManager.bringWindowToFront(
                windowID: move.windowID,
                inSpaceID: move.toSpaceID,
                activatedAt: activatedAt
            )
        }
    }
}
