import Foundation
import Carbon.HIToolbox

public enum DebutKeyEvent: Equatable, Sendable {
    case cmdTabTap              // Quick Cmd+Tab press — switch to last window
    case cmdTabHold             // Cmd+Tab held — open overlay (window mode, select next)
    case cmdShiftTabHold        // Cmd+Shift+Tab — open overlay (window mode, select last)
    case cmdOptionTabHold       // Cmd+Option+Tab — open overlay (stage mode, select next)
    case cmdOptionShiftTabHold  // Cmd+Shift+Option+Tab — open overlay (stage mode, select previous)
    case cmdRelease             // Cmd key lifted while overlay open

    case nextWindow             // Tab
    case previousWindow         // Shift+Tab
    case nextStage              // Option+Tab
    case previousStage          // Shift+Option+Tab
    case jumpToStage(Int)       // 1-8 (selects stage within open overlay)
    case jumpToLastStage        // 9 (selects the final stage within open overlay)
    case switchToStage(Int)     // Ctrl+0-9 (global immediate switch; 0 is stage 10)

    case newStageBelow          // N
    case newStageAbove          // Shift+N
    case deleteStage            // Delete/Forward Delete
    case saveAsTemplate         // Space

    case moveWindowUp           // Up Arrow
    case moveWindowDown         // Down Arrow
    case swapStageUp            // Option+Up Arrow
    case swapStageDown          // Option+Down Arrow

    case cmdBacktick            // Cmd+` — next same-app window in stage
    case cmdShiftBacktick       // Cmd+Shift+` — previous same-app window in stage

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
