import CoreGraphics
import Foundation

/// Stages plate-stack edits without touching the persisted model or the window server.
///
/// Every move shown by the overlay passes through this transaction. The controller is the
/// only owner of the commit boundary, so an input handler cannot accidentally turn a preview
/// gesture into an immediate assignment change.
struct PlateStackTransaction: Sendable {
    enum Source: Sendable, Equatable {
        case keyboard
        case pointer
    }

    struct Relocation: Sendable, Equatable {
        let windowID: CGWindowID
        let fromStageIndex: Int
        let toStageIndex: Int
    }

    struct Commit: Sendable {
        let didMutate: Bool
        let relocations: [Relocation]
        let keyboardWindowIDs: Set<CGWindowID>
        let pointerWindowIDs: Set<CGWindowID>
    }

    private struct Move: Sendable {
        let windowID: CGWindowID
        let fromStageID: UUID
        let toStageID: UUID
        let windowIndex: Int
        let source: Source
    }

    private var moves: [Move] = []

    func preview(applyingTo stageManager: StageManager) -> StageManager {
        var preview = stageManager
        applyMoves(to: &preview)
        return preview
    }

    mutating func stageMove(
        windowID: CGWindowID,
        fromStageID: UUID,
        toStageID: UUID,
        windowIndex: Int,
        source: Source
    ) {
        moves.append(Move(
            windowID: windowID,
            fromStageID: fromStageID,
            toStageID: toStageID,
            windowIndex: windowIndex,
            source: source
        ))
    }

    mutating func removeWindow(windowID: CGWindowID) {
        moves.removeAll { $0.windowID == windowID }
    }

    mutating func commit(to stageManager: inout StageManager) -> Commit {
        let before = stageManager
        let affectedWindowIDs = Set(moves.map(\.windowID))
        let keyboardWindowIDs = Set(moves.lazy.filter { $0.source == .keyboard }.map(\.windowID))
        let pointerWindowIDs = Set(moves.lazy.filter { $0.source == .pointer }.map(\.windowID))
        applyMoves(to: &stageManager)

        let relocations = affectedWindowIDs.compactMap { windowID -> Relocation? in
            guard let fromStageID = before.stageContainingWindow(windowID: windowID),
                  let toStageID = stageManager.stageContainingWindow(windowID: windowID),
                  fromStageID != toStageID,
                  let fromStageIndex = before.stages.firstIndex(where: { $0.id == fromStageID }),
                  let toStageIndex = stageManager.stages.firstIndex(where: { $0.id == toStageID })
            else { return nil }
            return Relocation(
                windowID: windowID,
                fromStageIndex: fromStageIndex,
                toStageIndex: toStageIndex
            )
        }
        .sorted { $0.windowID < $1.windowID }

        let didMutate = before.stages.count != stageManager.stages.count
            || zip(before.stages, stageManager.stages).contains { beforeStage, afterStage in
                beforeStage.id != afterStage.id || beforeStage.windows != afterStage.windows
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

    private func applyMoves(to stageManager: inout StageManager) {
        for move in moves {
            stageManager.moveWindow(
                windowID: move.windowID,
                fromStageID: move.fromStageID,
                toStageID: move.toStageID,
                at: move.windowIndex
            )
        }
    }
}
