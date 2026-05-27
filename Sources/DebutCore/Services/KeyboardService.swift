import Foundation
import Carbon.HIToolbox

public enum DebutKeyEvent: Equatable, Sendable {
    case cmdTabTap
    case cmdTabHold
    case cmdRelease

    case nextApp
    case previousApp
    case nextStage
    case previousStage
    case jumpToStage(Int)

    case newStageBelow
    case newStageAbove
    case deleteStage
    case renameStage
    case saveAsTemplate

    case moveAppUp
    case moveAppDown
    case swapStageUp
    case swapStageDown

    case escape
}

public protocol KeyboardEventDelegate: AnyObject, Sendable {
    func handleKeyEvent(_ event: DebutKeyEvent)
}

public protocol KeyboardService: Sendable {
    func start(delegate: KeyboardEventDelegate) -> Bool
    func stop()
    var isRunning: Bool { get }
}
