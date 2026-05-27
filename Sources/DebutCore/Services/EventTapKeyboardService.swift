import AppKit
import Carbon.HIToolbox

public final class EventTapKeyboardService: KeyboardService, @unchecked Sendable {
    public private(set) var isRunning: Bool = false
    private weak var delegate: KeyboardEventDelegate?
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cmdHeld: Bool = false
    private var stageManagerActive: Bool = false
    private var tabPressedDuringHold: Bool = false

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

        if type == .keyDown && flags.contains(.maskCommand) {
            if keyCode == kVK_Tab {
                if !stageManagerActive {
                    cmdHeld = true
                    stageManagerActive = true
                    tabPressedDuringHold = false
                    delegate?.handleKeyEvent(.cmdTabHold)
                    return nil
                }
            }
        }

        guard stageManagerActive && type == .keyDown else {
            return event
        }

        let shift = flags.contains(.maskShift)
        let option = flags.contains(.maskAlternate)

        let debutEvent: DebutKeyEvent? = switch Int(keyCode) {
        case kVK_Tab where option && shift:
            .previousStage
        case kVK_Tab where option:
            .nextStage
        case kVK_Tab where shift:
            .previousApp
        case kVK_Tab:
            .nextApp
        case kVK_Escape:
            .escape
        case kVK_ANSI_N where shift:
            .newStageAbove
        case kVK_ANSI_N:
            .newStageBelow
        case kVK_Delete, kVK_ForwardDelete:
            .deleteStage
        case kVK_ANSI_R:
            .renameStage
        case kVK_Space:
            .saveAsTemplate
        case kVK_UpArrow where option:
            .swapStageUp
        case kVK_DownArrow where option:
            .swapStageDown
        case kVK_UpArrow:
            .moveAppUp
        case kVK_DownArrow:
            .moveAppDown
        case kVK_ANSI_1: .jumpToStage(1)
        case kVK_ANSI_2: .jumpToStage(2)
        case kVK_ANSI_3: .jumpToStage(3)
        case kVK_ANSI_4: .jumpToStage(4)
        case kVK_ANSI_5: .jumpToStage(5)
        case kVK_ANSI_6: .jumpToStage(6)
        case kVK_ANSI_7: .jumpToStage(7)
        case kVK_ANSI_8: .jumpToStage(8)
        case kVK_ANSI_9: .jumpToStage(9)
        default:
            nil
        }

        if let debutEvent {
            delegate?.handleKeyEvent(debutEvent)
            return nil
        }

        return event
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
