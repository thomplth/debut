import Carbon.HIToolbox

public enum DebutKeyEvent: Equatable, Sendable {
    case cmdTabTap              // Quick Cmd+Tab press — switch to last window
    case cmdTabHold             // Cmd+Tab held — open overlay (window mode, select next)
    case cmdShiftTabHold        // Cmd+Shift+Tab — open overlay (window mode, select last)
    case cmdOptionTabHold       // Cmd+Option+Tab — open overlay (stage mode, select next)
    case cmdOptionShiftTabHold  // Cmd+Shift+Option+Tab — open overlay (stage mode, select previous)
    case cmdRelease             // Cmd key lifted while overlay open

    case nextWindow             // Tab
    case nextWindowRepeat       // Held Tab auto-repeat (stops at the last window)
    case previousWindow         // Shift+Tab
    case previousWindowRepeat   // Held Shift+Tab auto-repeat (stops at the first window)
    case nextStage              // Option+Tab
    case previousStage          // Shift+Option+Tab
    case jumpToStage(Int)       // 1-8 (selects stage within open overlay)
    case jumpToLastStage        // 9 (selects the final stage within open overlay)
    case switchToStage(Int)     // Configured modifier + 1-9 (global immediate switch)
    case switchToStageKeepingCurrentApplication(Int)

    case newStageBelow          // N
    case newStageAbove          // Shift+N
    case deleteStage            // Delete/Forward Delete
    case moveWindowUp           // Up Arrow
    case moveWindowDown         // Down Arrow
    case swapStageUp            // Option+Up Arrow
    case swapStageDown          // Option+Down Arrow

    case cmdBacktick            // Cmd+` — next same-app window in stage
    case cmdBacktickRepeat      // Held Cmd+` auto-repeat (stops at the last window)
    case cmdShiftBacktick       // Cmd+Shift+` — previous same-app window in stage
    case cmdShiftBacktickRepeat // Held Cmd+Shift+` auto-repeat (stops at the first window)

    case escape

    public var commandHintAction: KeyAction? {
        switch self {
        case .cmdTabHold, .nextWindow:
            .nextWindow
        case .cmdShiftTabHold, .previousWindow:
            .previousWindow
        case .cmdOptionTabHold, .nextStage:
            .nextStage
        case .cmdOptionShiftTabHold, .previousStage:
            .previousStage
        case .jumpToStage(let position):
            KeyAction.jumpAction(forStageIndex: position - 1)
        case .jumpToLastStage:
            .jumpToStage9
        case .newStageBelow:
            .newStageBelow
        case .newStageAbove:
            .newStageAbove
        case .deleteStage:
            .deleteStage
        case .moveWindowUp:
            .moveWindowUp
        case .moveWindowDown:
            .moveWindowDown
        case .swapStageUp:
            .swapStageUp
        case .swapStageDown:
            .swapStageDown
        case .cmdTabTap, .cmdRelease, .nextWindowRepeat, .previousWindowRepeat,
             .switchToStage, .switchToStageKeepingCurrentApplication,
             .cmdBacktick, .cmdBacktickRepeat, .cmdShiftBacktick,
             .cmdShiftBacktickRepeat, .escape:
            nil
        }
    }
}

public protocol KeyboardEventDelegate: AnyObject, Sendable {
    func handleKeyEvent(_ event: DebutKeyEvent)
    func handleKeyEvent(
        _ event: DebutKeyEvent,
        overlayPresentation: OverlayPresentationContext?
    )
}

public extension KeyboardEventDelegate {
    func handleKeyEvent(
        _ event: DebutKeyEvent,
        overlayPresentation: OverlayPresentationContext?
    ) {
        handleKeyEvent(event)
    }
}

public protocol KeyboardService: Sendable {
    func start(delegate: KeyboardEventDelegate) -> Bool
    func stop()
    var isRunning: Bool { get }
}

public protocol ShortcutRecordingService: AnyObject, Sendable {
    func beginShortcutRecording(
        handler: @escaping @MainActor @Sendable (KeyCombo?) -> Void
    )
    func endShortcutRecording()
}
