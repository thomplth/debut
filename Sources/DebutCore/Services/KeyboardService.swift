import Carbon.HIToolbox

public enum DebutKeyEvent: Equatable, Sendable {
    case cmdTabTap              // Quick Cmd+Tab press — switch to last window
    case cmdTabHold             // Cmd+Tab held — open overlay (window mode, select next)
    case cmdShiftTabHold        // Cmd+Shift+Tab — open overlay (window mode, select last)
    case cmdOptionTabHold       // Cmd+Option+Tab — open overlay (space mode, select next)
    case cmdOptionShiftTabHold  // Cmd+Shift+Option+Tab — open overlay (space mode, select previous)
    case cmdRelease             // Cmd key lifted while overlay open

    case nextWindow             // Tab
    case nextWindowRepeat       // Held Tab auto-repeat (stops at the last window)
    case previousWindow         // Shift+Tab
    case previousWindowRepeat   // Held Shift+Tab auto-repeat (stops at the first window)
    case nextSpace              // Option+Tab
    case previousSpace          // Shift+Option+Tab
    case nextDisplayStack       // Cmd+Return (Return relative to the held Cmd session)
    case jumpToSpace(Int)       // 1-8 (selects space within open overlay)
    case jumpToLastSpace        // 9 (selects the final space within open overlay)
    case switchToSpace(Int)     // Configured modifier + 1-9 (global immediate switch)
    case switchToSpaceKeepingCurrentApplication(Int)

    case moveWindowUp           // Up Arrow
    case moveWindowDown         // Down Arrow
    case moveWindowLeft         // Left Arrow — reorder within the space
    case moveWindowRight        // Right Arrow — reorder within the space
    case quitSelectedApp        // Cmd+Q — quit the app owning the selected window
    case closeSelectedWindow    // Cmd+W — close the selected window

    case cmdBacktick            // Cmd+` — next same-app window in space
    case cmdBacktickRepeat      // Held Cmd+` auto-repeat (stops at the last window)
    case cmdShiftBacktick       // Cmd+Shift+` — previous same-app window in space
    case cmdShiftBacktickRepeat // Held Cmd+Shift+` auto-repeat (stops at the first window)

    case escape

    public var commandHintAction: KeyAction? {
        switch self {
        case .cmdTabHold, .nextWindow:
            .nextWindow
        case .cmdShiftTabHold, .previousWindow:
            .previousWindow
        case .cmdOptionTabHold, .nextSpace:
            .nextSpace
        case .cmdOptionShiftTabHold, .previousSpace:
            .previousSpace
        case .nextDisplayStack:
            .nextDisplayStack
        case .jumpToSpace(let position):
            KeyAction.jumpAction(forSpaceIndex: position - 1)
        case .jumpToLastSpace:
            .jumpToSpace9
        case .moveWindowUp:
            .moveWindowUp
        case .moveWindowDown:
            .moveWindowDown
        case .moveWindowLeft:
            .moveWindowLeft
        case .moveWindowRight:
            .moveWindowRight
        case .quitSelectedApp:
            .quitSelectedApp
        case .closeSelectedWindow:
            .closeSelectedWindow
        case .escape:
            .dismissOverlay
        case .cmdTabTap, .cmdRelease, .nextWindowRepeat, .previousWindowRepeat,
             .switchToSpace, .switchToSpaceKeepingCurrentApplication,
             .cmdBacktick, .cmdBacktickRepeat, .cmdShiftBacktick,
             .cmdShiftBacktickRepeat:
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
