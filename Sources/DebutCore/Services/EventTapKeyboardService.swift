import AppKit
import Carbon.HIToolbox

public final class EventTapKeyboardService: KeyboardService, @unchecked Sendable {
    public private(set) var isRunning: Bool = false
    private weak var delegate: KeyboardEventDelegate?
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cmdHeld: Bool = false
    private var stageManagerActive: Bool = false

    public var overlayVisible: Bool = false
    public var keyBindings: KeyBindings = KeyBindings()

    public init() {}

    public func start(delegate: KeyboardEventDelegate) -> Bool {
        self.delegate = delegate

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            return false
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Ctrl+Option+<1-9> — global immediate switch to the stage at that position.
        // Works without a Cmd session or open overlay. Excludes Cmd so it never
        // collides with the in-overlay digit selection (which requires Cmd held).
        if type == .keyDown
            && flags.contains(.maskControl)
            && flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand),
           let stageNumber = stageNumber(forKeyCode: keyCode) {
            delegate?.handleKeyEvent(.switchToStage(stageNumber))
            return nil
        }

        // Track Cmd key state
        if type == .flagsChanged {
            let cmdDown = flags.contains(.maskCommand)
            if cmdHeld && !cmdDown {
                cmdHeld = false
                if stageManagerActive {
                    stageManagerActive = false
                    delegate?.handleKeyEvent(.cmdRelease)
                    return nil
                }
            }
            cmdHeld = cmdDown
            return event
        }

        let shift = flags.contains(.maskShift)

        // Cmd+Option+Tab — open/reopen overlay in stage mode, or cycle stages
        if type == .keyDown && flags.contains(.maskCommand) && flags.contains(.maskAlternate) && keyCode == Int64(kVK_Tab) {
            if !stageManagerActive {
                cmdHeld = true
            }
            stageManagerActive = true
            delegate?.handleKeyEvent(shift ? .cmdOptionShiftTabHold : .cmdOptionTabHold)
            return nil
        }

        // Cmd+Tab (without Option) — open/reopen overlay in window mode, or cycle windows
        if type == .keyDown && flags.contains(.maskCommand) && !flags.contains(.maskAlternate) && keyCode == Int64(kVK_Tab) {
            if !stageManagerActive {
                cmdHeld = true
            }
            stageManagerActive = true
            delegate?.handleKeyEvent(shift ? .cmdShiftTabHold : .cmdTabHold)
            return nil
        }

        guard stageManagerActive else {
            return event
        }

        // Session active but overlay closed (after Esc): only intercept Tab to reopen.
        // Pass everything else (including `) through to the system.
        if !overlayVisible {
            if type == .keyDown && keyCode == Int64(kVK_Tab) {
                // Tab/Shift+Tab/Option+Tab will reopen — already handled above
            }
            return event
        }

        // Overlay is visible — consume ALL keyboard events
        guard type == .keyDown else {
            return nil // Consume keyUp events too
        }

        // Escape is always hardcoded
        if Int(keyCode) == kVK_Escape {
            delegate?.handleKeyEvent(.escape)
            return nil
        }

        // Backtick always maps to previousWindow (Cmd+` equivalent)
        if Int(keyCode) == kVK_ANSI_Grave {
            delegate?.handleKeyEvent(.previousWindow)
            return nil
        }

        // Forward delete also maps to deleteStage (in addition to regular delete)
        if Int(keyCode) == kVK_ForwardDelete {
            delegate?.handleKeyEvent(.deleteStage)
            return nil
        }

        // Look up configurable bindings
        let combo = KeyCombo(
            keyCode: Int(keyCode),
            shift: shift,
            option: flags.contains(.maskAlternate)
        )
        if let action = keyBindings.action(for: combo) {
            delegate?.handleKeyEvent(action.toKeyEvent())
        }

        // Always consume — never let keyboard events leak to the active app
        return nil
    }

    /// Maps a number-row keycode (1-9) to its stage position. Returns nil otherwise.
    private func stageNumber(forKeyCode keyCode: Int64) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1: return 1
        case kVK_ANSI_2: return 2
        case kVK_ANSI_3: return 3
        case kVK_ANSI_4: return 4
        case kVK_ANSI_5: return 5
        case kVK_ANSI_6: return 6
        case kVK_ANSI_7: return 7
        case kVK_ANSI_8: return 8
        case kVK_ANSI_9: return 9
        default: return nil
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let service = Unmanaged<EventTapKeyboardService>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<EventTapKeyboardService>.fromOpaque(userInfo).takeUnretainedValue()
    if let result = service.handleCGEvent(type: type, event: event) {
        return Unmanaged.passUnretained(result)
    }
    return nil
}
