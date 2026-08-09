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
    private var cmdHeld: Bool = false
    private var stageManagerActive: Bool = false
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

        // Ctrl+<0-9> — immediate switch unless the frontmost app is excluded.
        // Once Debut captures a key-down, consume its repeats and key-up too so a
        // stage switch cannot leak the remainder of the key sequence to another app.
        if type == .keyDown,
           let stagePosition = Self.quickSwitchStagePosition(keyCode: keyCode, flags: flags) {
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
        if type == .keyUp, quickSwitchKeysDown.remove(keyCode) != nil {
            return nil
        }

        // Track Cmd key state
        if type == .flagsChanged {
            let cmdDown = flags.contains(.maskCommand)
            if cmdHeld && !cmdDown {
                cmdHeld = false
                if stageManagerActive {
                    stageManagerActive = false
                    deliver(.cmdRelease, asynchronously: deliverAsynchronously)
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
            deliver(
                shift ? .cmdOptionShiftTabHold : .cmdOptionTabHold,
                asynchronously: deliverAsynchronously
            )
            return nil
        }

        // Cmd+Tab (without Option) — open/reopen overlay in window mode, or cycle windows
        if type == .keyDown && flags.contains(.maskCommand) && !flags.contains(.maskAlternate) && keyCode == Int64(kVK_Tab) {
            if !stageManagerActive {
                cmdHeld = true
            }
            stageManagerActive = true
            deliver(
                shift ? .cmdShiftTabHold : .cmdTabHold,
                asynchronously: deliverAsynchronously
            )
            return nil
        }

        // Cmd+` (without Option, overlay closed) — stage-isolated same-app window cycling
        if type == .keyDown && flags.contains(.maskCommand) && !flags.contains(.maskAlternate) && keyCode == Int64(kVK_ANSI_Grave) && !overlayVisible {
            if !stageManagerActive {
                cmdHeld = true
            }
            stageManagerActive = true
            deliver(
                shift ? .cmdShiftBacktick : .cmdBacktick,
                asynchronously: deliverAsynchronously
            )
            return nil
        }

        guard stageManagerActive else {
            return event
        }

        // Keep the standard app-quit shortcut available during a stage-manager
        // session, including while the overlay is visible. Passing both keyDown
        // and keyUp avoids leaving a partial shortcut sequence in the target app.
        let shortcutFlags = flags.intersection([
            .maskCommand, .maskAlternate, .maskControl, .maskShift,
        ])
        if keyCode == Int64(kVK_ANSI_Q), shortcutFlags == .maskCommand {
            return event
        }

        // Session active but overlay closed (after Esc): only intercept Tab to reopen.
        // Cmd+` is already handled above; pass everything else through.
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
            deliver(.escape, asynchronously: deliverAsynchronously)
            return nil
        }

        // Backtick always maps to previousWindow (Cmd+` equivalent)
        if Int(keyCode) == kVK_ANSI_Grave {
            deliver(.previousWindow, asynchronously: deliverAsynchronously)
            return nil
        }

        // Forward delete also maps to deleteStage (in addition to regular delete)
        if Int(keyCode) == kVK_ForwardDelete {
            deliver(.deleteStage, asynchronously: deliverAsynchronously)
            return nil
        }

        // Look up configurable bindings
        let combo = KeyCombo(
            keyCode: Int(keyCode),
            shift: shift,
            option: flags.contains(.maskAlternate)
        )
        if let action = keyBindings.action(for: combo) {
            deliver(action.toKeyEvent(), asynchronously: deliverAsynchronously)
        }

        // Always consume — never let keyboard events leak to the active app
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
