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

    private struct Move: Sendable {
        let windowID: CGWindowID
        let fromSpaceID: UUID
        let toSpaceID: UUID
        let windowIndex: Int
        /// Pointer drops name their gap by the windows around it, so a replay after an earlier
        /// edit still lands between the same neighbours. `nil` keeps the index semantics.
        let placement: PointerPlacement?
        let source: Source
        let activatedAt: Date?
    }

    private var moves: [Move] = []

    func preview(applyingTo spaceManager: SpaceManager) -> SpaceManager {
        var preview = spaceManager
        applyMoves(to: &preview)
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
        moves.append(Move(
            windowID: windowID,
            fromSpaceID: fromSpaceID,
            toSpaceID: toSpaceID,
            windowIndex: windowIndex,
            placement: nil,
            source: source,
            activatedAt: activatedAt
        ))
    }

    mutating func pointerMove(
        windowID: CGWindowID,
        fromSpaceID: UUID,
        toSpaceID: UUID,
        placement: PointerPlacement
    ) {
        moves.append(Move(
            windowID: windowID,
            fromSpaceID: fromSpaceID,
            toSpaceID: toSpaceID,
            windowIndex: 0,
            placement: placement,
            source: .pointer,
            activatedAt: nil
        ))
    }

    mutating func removeWindow(windowID: CGWindowID) {
        moves.removeAll { $0.windowID == windowID }
    }

    mutating func commit(to spaceManager: inout SpaceManager) -> Commit {
        let before = spaceManager
        let affectedWindowIDs = Set(moves.map(\.windowID))
        let keyboardWindowIDs = Set(moves.lazy.filter { $0.source == .keyboard }.map(\.windowID))
        let pointerWindowIDs = Set(moves.lazy.filter { $0.source == .pointer }.map(\.windowID))
        applyMoves(to: &spaceManager)

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
        moves.removeAll()
        return Commit(
            didMutate: didMutate,
            relocations: relocations,
            keyboardWindowIDs: keyboardWindowIDs,
            pointerWindowIDs: pointerWindowIDs
        )
    }

    mutating func discard() {
        moves.removeAll()
    }

    private func applyMoves(to spaceManager: inout SpaceManager) {
        for move in moves {
            var windowIndex = move.windowIndex
            if let placement = move.placement {
                // Neither neighbour survived: skip the move before removing its source rather
                // than appending it somewhere the user never pointed at.
                guard let remaining = spaceManager.windowIDs(inSpaceID: move.toSpaceID)?
                        .filter({ $0 != move.windowID }),
                      let resolved = placement.resolvedIndex(in: remaining)
                else { continue }
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
}
