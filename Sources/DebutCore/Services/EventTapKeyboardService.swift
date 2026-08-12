import AppKit
import Carbon.HIToolbox

public final class EventTapKeyboardService: KeyboardService, @unchecked Sendable {
    private let lifecycleLock = NSLock()
    private var storedIsRunning: Bool = false
    private var storedEventTapRunsOnDedicatedThread: Bool = false
    public var isRunning: Bool {
        lifecycleLock.withLock { storedIsRunning }
    }
    public var eventTapRunsOnDedicatedThread: Bool {
        lifecycleLock.withLock { storedEventTapRunsOnDedicatedThread }
    }
    private weak var delegate: KeyboardEventDelegate?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    private var eventTapThread: Thread?
    private var stageManagerActive: Bool = false
    private var sessionPrimaryModifier: CGEventFlags?
    private var sessionTriggerKeyCode: Int64?
    private var quickSwitchKeysDown: Set<Int64> = []
    private let configurationLock = NSLock()
    private var cachedFrontmostAppBundleIdentifier: String?
    private var storedOverlayVisible: Bool = false
    private var storedKeyBindings: KeyBindings = KeyBindings()
    private var storedQuickSwitchExcludedBundleIDs: Set<String> = []

    public var overlayVisible: Bool {
        get { configurationLock.withLock { storedOverlayVisible } }
        set { configurationLock.withLock { storedOverlayVisible = newValue } }
    }
    public var keyBindings: KeyBindings {
        get { configurationLock.withLock { storedKeyBindings } }
        set { configurationLock.withLock { storedKeyBindings = newValue } }
    }
    public var quickSwitchExcludedBundleIDs: Set<String> {
        get { configurationLock.withLock { storedQuickSwitchExcludedBundleIDs } }
        set { configurationLock.withLock { storedQuickSwitchExcludedBundleIDs = newValue } }
    }

    public init() {}

    public func updateFrontmostApp(bundleIdentifier: String?) {
        configurationLock.withLock {
            cachedFrontmostAppBundleIdentifier = bundleIdentifier
        }
    }

    public func start(delegate: KeyboardEventDelegate) -> Bool {
        if isRunning { return true }
        self.delegate = delegate

        let startupSignal = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                startupSignal.signal()
                return
            }
            self.runEventTap(startupSignal: startupSignal)
        }
        thread.name = "com.thomplth.Debut.event-tap"
        lifecycleLock.withLock {
            eventTapThread = thread
        }
        thread.start()

        guard startupSignal.wait(timeout: .now() + 2) == .success else {
            return false
        }
        return isRunning
    }

    private func runEventTap(startupSignal: DispatchSemaphore) {
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
            startupSignal.signal()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        lifecycleLock.withLock {
            self.eventTap = tap
            self.runLoopSource = source
            self.eventTapRunLoop = runLoop
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lifecycleLock.withLock {
            storedEventTapRunsOnDedicatedThread = !Thread.isMainThread
            storedIsRunning = true
        }
        startupSignal.signal()

        CFRunLoopRun()

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        lifecycleLock.withLock {
            eventTap = nil
            runLoopSource = nil
            eventTapRunLoop = nil
            storedEventTapRunsOnDedicatedThread = false
            storedIsRunning = false
        }
    }

    public func stop() {
        let resources = lifecycleLock.withLock { (eventTap, eventTapRunLoop) }
        if let tap = resources.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = resources.1 {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        lifecycleLock.withLock {
            storedIsRunning = false
            eventTapThread = nil
        }
    }

    fileprivate func reenableEventTap() {
        let tap = lifecycleLock.withLock { eventTap }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func handleCGEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        handleCGEvent(type: type, event: event, deliverAsynchronously: false)
    }

    func handleCGEventFromTap(type: CGEventType, event: CGEvent) -> CGEvent? {
        handleCGEvent(type: type, event: event, deliverAsynchronously: true)
    }

    private func handleCGEvent(
        type: CGEventType,
        event: CGEvent,
        deliverAsynchronously: Bool
    ) -> CGEvent? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .keyUp, quickSwitchKeysDown.remove(keyCode) != nil {
            return nil
        }
        if type == .keyUp,
           stageManagerActive,
           sessionPrimaryModifier == nil,
           sessionTriggerKeyCode == keyCode {
            stageManagerActive = false
            sessionTriggerKeyCode = nil
            deliver(.cmdRelease, asynchronously: deliverAsynchronously)
            return nil
        }

        // A Stage Manager session commits when its activation modifier is released.
        if type == .flagsChanged {
            if stageManagerActive,
               let primaryModifier = sessionPrimaryModifier,
               !flags.contains(primaryModifier) {
                stageManagerActive = false
                sessionPrimaryModifier = nil
                sessionTriggerKeyCode = nil
                deliver(.cmdRelease, asynchronously: deliverAsynchronously)
                return nil
            }
            return event
        }

        if type == .keyDown,
           let globalAction = configuredAction(keyCode: keyCode, flags: flags, scope: .global) {
            if let stagePosition = globalAction.quickSwitchPosition {
                if quickSwitchKeysDown.contains(keyCode) {
                    return nil
                }
                let quickSwitchConfiguration = configurationLock.withLock {
                    (storedQuickSwitchExcludedBundleIDs, cachedFrontmostAppBundleIdentifier)
                }
                if !quickSwitchConfiguration.0.isEmpty,
                   let bundleID = quickSwitchConfiguration.1,
                   quickSwitchConfiguration.0.contains(bundleID) {
                    return event
                }
                if quickSwitchKeysDown.insert(keyCode).inserted {
                    deliver(.switchToStage(stagePosition), asynchronously: deliverAsynchronously)
                }
                return nil
            }

            if globalAction.isOverlayActivation {
                beginSession(using: globalAction)
                let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let keyEvent: DebutKeyEvent = if isAutoRepeat && globalAction == .activateNextWindow {
                    .nextWindowRepeat
                } else {
                    globalAction.toKeyEvent()
                }
                deliver(keyEvent, asynchronously: deliverAsynchronously)
                return nil
            }

            if globalAction.isSameAppCycle && !overlayVisible {
                beginSession(using: globalAction)
                let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let keyEvent: DebutKeyEvent = if isAutoRepeat && globalAction == .nextAppWindow {
                    .cmdBacktickRepeat
                } else {
                    globalAction.toKeyEvent()
                }
                deliver(keyEvent, asynchronously: deliverAsynchronously)
                return nil
            }
        }

        guard stageManagerActive else {
            return event
        }

        // Session active but overlay closed (after Esc): configured global activation
        // shortcuts above can reopen it; everything else passes through.
        guard overlayVisible else {
            return event
        }

        let sessionAction = configuredSessionAction(keyCode: keyCode, flags: flags)

        // Keep the standard app-quit shortcut available unless the user explicitly
        // assigns that physical key combination to a Stage Manager command.
        let shortcutFlags = flags.intersection([
            .maskCommand, .maskAlternate, .maskControl, .maskShift,
        ])
        if keyCode == Int64(kVK_ANSI_Q),
           shortcutFlags == .maskCommand,
           sessionAction == nil {
            return event
        }

        // Overlay visible — consume both key-down and key-up, dispatching configured
        // commands only for key-down.
        guard type == .keyDown else {
            return nil
        }

        if let sessionAction {
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let keyEvent: DebutKeyEvent = if isAutoRepeat && sessionAction == .nextWindow {
                .nextWindowRepeat
            } else {
                sessionAction.toKeyEvent()
            }
            deliver(keyEvent, asynchronously: deliverAsynchronously)
        }

        // Always consume — never let keyboard events leak to the active app
        return nil
    }

    private func beginSession(using action: KeyAction) {
        guard !stageManagerActive,
              let combo = keyBindings.combo(for: action)
        else { return }
        stageManagerActive = true
        sessionPrimaryModifier = Self.primaryModifier(for: combo)
        sessionTriggerKeyCode = sessionPrimaryModifier == nil ? Int64(combo.keyCode) : nil
    }

    private func configuredAction(
        keyCode: Int64,
        flags: CGEventFlags,
        scope: ShortcutScope
    ) -> KeyAction? {
        let combo = Self.keyCombo(keyCode: keyCode, flags: flags)
        return keyBindings.action(for: combo, scope: scope)
    }

    private func configuredSessionAction(
        keyCode: Int64,
        flags: CGEventFlags
    ) -> KeyAction? {
        var relativeFlags = flags
        if let primaryModifier = sessionPrimaryModifier {
            relativeFlags.remove(primaryModifier)
        }
        return configuredAction(keyCode: keyCode, flags: relativeFlags, scope: .session)
    }

    private static func keyCombo(keyCode: Int64, flags: CGEventFlags) -> KeyCombo {
        KeyCombo(
            keyCode: Int(keyCode),
            command: flags.contains(.maskCommand),
            control: flags.contains(.maskControl),
            shift: flags.contains(.maskShift),
            option: flags.contains(.maskAlternate)
        )
    }

    private static func primaryModifier(for combo: KeyCombo) -> CGEventFlags? {
        if combo.command { return .maskCommand }
        if combo.control { return .maskControl }
        if combo.option { return .maskAlternate }
        if combo.shift { return .maskShift }
        return nil
    }

    private func deliver(_ event: DebutKeyEvent, asynchronously: Bool) {
        if asynchronously {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.handleKeyEvent(event)
            }
        } else {
            delegate?.handleKeyEvent(event)
        }
    }

    /// Maps an exact Ctrl+number-row shortcut to its 1-based stage position.
    /// Ctrl+0 targets stage 10.
    static func quickSwitchStagePosition(keyCode: Int64, flags: CGEventFlags) -> Int? {
        guard flags.contains(.maskControl),
              !flags.contains(.maskCommand),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskShift)
        else { return nil }

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
        case kVK_ANSI_0: return 10
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
        service.reenableEventTap()
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<EventTapKeyboardService>.fromOpaque(userInfo).takeUnretainedValue()
    if let result = service.handleCGEventFromTap(type: type, event: event) {
        return Unmanaged.passUnretained(result)
    }
    return nil
}
