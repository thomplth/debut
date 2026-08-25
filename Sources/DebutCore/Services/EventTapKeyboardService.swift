import Carbon.HIToolbox

public final class EventTapKeyboardService: KeyboardService, ShortcutRecordingService, @unchecked Sendable {
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
    private var storedExcludedBundleIDs: Set<String> = []
    private var storedQuickSwitchExcludedBundleIDs: Set<String> = []
    private var storedQuickSwitchModifiers: ShortcutModifiers = .control
    private var storedQuickSwitchSameApplicationModifiers = ShortcutModifiers(
        control: true,
        option: true
    )
    private var shortcutRecordingHandler: (@MainActor @Sendable (KeyCombo?) -> Void)?
    private var shortcutRecordingKeysDown: Set<Int64> = []
    private var storedHeldCycleMinimumInterval: TimeInterval =
        AppSettings.defaultHeldCycleMinimumInterval
    private var lastAcceptedCycleNanoseconds: UInt64?
    private let monotonicNanoseconds: @Sendable () -> UInt64
    private let overlayPresentationRecorder: OverlayPresentationRecorder
    private let performanceRecorder: PerformanceRecorder

    public var overlayVisible: Bool {
        get { configurationLock.withLock { storedOverlayVisible } }
        set { configurationLock.withLock { storedOverlayVisible = newValue } }
    }
    public var keyBindings: KeyBindings {
        get { configurationLock.withLock { storedKeyBindings } }
        set { configurationLock.withLock { storedKeyBindings = newValue } }
    }
    public var excludedBundleIDs: Set<String> {
        get { configurationLock.withLock { storedExcludedBundleIDs } }
        set { configurationLock.withLock { storedExcludedBundleIDs = newValue } }
    }
    public var quickSwitchExcludedBundleIDs: Set<String> {
        get { configurationLock.withLock { storedQuickSwitchExcludedBundleIDs } }
        set { configurationLock.withLock { storedQuickSwitchExcludedBundleIDs = newValue } }
    }
    public var quickSwitchModifiers: ShortcutModifiers {
        get { configurationLock.withLock { storedQuickSwitchModifiers } }
        set { configurationLock.withLock { storedQuickSwitchModifiers = newValue } }
    }
    public var quickSwitchSameApplicationModifiers: ShortcutModifiers {
        get { configurationLock.withLock { storedQuickSwitchSameApplicationModifiers } }
        set { configurationLock.withLock { storedQuickSwitchSameApplicationModifiers = newValue } }
    }

    public var heldCycleMinimumInterval: TimeInterval {
        get { configurationLock.withLock { storedHeldCycleMinimumInterval } }
        set { configurationLock.withLock { storedHeldCycleMinimumInterval = newValue } }
    }

    public init(
        overlayPresentationRecorder: OverlayPresentationRecorder = .shared,
        performanceRecorder: PerformanceRecorder = .shared,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.overlayPresentationRecorder = overlayPresentationRecorder
        self.performanceRecorder = performanceRecorder
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    /// A key-repeat rate set near zero would otherwise blur through every window on a single
    /// held Tab. Repeats arriving inside the pacing window are dropped rather than deferred, so
    /// the selection lands wherever the key was actually released.
    ///
    /// The clock is read outside the lock: it is a plain monotonic counter, and holding the
    /// configuration lock across it would put it on the event tap's critical path.
    private func shouldPaceHeldCycle(_ action: KeyAction, isAutoRepeat: Bool) -> Bool {
        guard action.isCycling else { return false }
        let now = monotonicNanoseconds()
        return configurationLock.withLock {
            let minimum = UInt64(max(0, storedHeldCycleMinimumInterval) * 1_000_000_000)
            if isAutoRepeat,
               minimum > 0,
               let last = lastAcceptedCycleNanoseconds,
               now >= last,
               now - last < minimum {
                return true
            }
            lastAcceptedCycleNanoseconds = now
            return false
        }
    }

    public func beginShortcutRecording(
        handler: @escaping @MainActor @Sendable (KeyCombo?) -> Void
    ) {
        configurationLock.withLock {
            shortcutRecordingHandler = handler
        }
    }

    public func endShortcutRecording() {
        configurationLock.withLock {
            shortcutRecordingHandler = nil
        }
    }

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
        let performanceID = performanceRecorder.begin(.eventTap, sampleResources: false)
        defer { performanceRecorder.end(performanceID) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .keyUp,
           configurationLock.withLock({ shortcutRecordingKeysDown.remove(keyCode) != nil }) {
            return nil
        }

        if type == .keyDown {
            var recordingHandler: (@MainActor @Sendable (KeyCombo?) -> Void)?
            let consumeForRecording = configurationLock.withLock {
                if shortcutRecordingKeysDown.contains(keyCode) {
                    return true
                }
                guard let handler = shortcutRecordingHandler else { return false }
                shortcutRecordingHandler = nil
                shortcutRecordingKeysDown.insert(keyCode)
                recordingHandler = handler
                return true
            }
            if consumeForRecording {
                if let recordingHandler {
                    let combo: KeyCombo? = keyCode == Int64(kVK_Escape)
                        ? nil
                        : Self.keyCombo(keyCode: keyCode, flags: flags)
                    DispatchQueue.main.async {
                        recordingHandler(combo)
                    }
                }
                return nil
            }
        }

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

        if type == .keyDown {
            let quickSwitchConfiguration = configurationLock.withLock {
                (
                    storedQuickSwitchModifiers,
                    storedQuickSwitchSameApplicationModifiers,
                    storedQuickSwitchExcludedBundleIDs,
                    cachedFrontmostAppBundleIdentifier
                )
            }
            let stagePosition = Self.quickSwitchStagePosition(
                keyCode: keyCode,
                flags: flags,
                modifiers: quickSwitchConfiguration.0
            )
            let sameApplicationStagePosition = Self.quickSwitchStagePosition(
                keyCode: keyCode,
                flags: flags,
                modifiers: quickSwitchConfiguration.1
            )
            if let stagePosition = stagePosition ?? sameApplicationStagePosition {
                if quickSwitchKeysDown.contains(keyCode) { return nil }
                if !quickSwitchConfiguration.2.isEmpty,
                   let bundleID = quickSwitchConfiguration.3,
                   quickSwitchConfiguration.2.contains(bundleID) {
                    return event
                }
                if quickSwitchKeysDown.insert(keyCode).inserted {
                    let keyEvent: DebutKeyEvent = sameApplicationStagePosition != nil
                        ? .switchToStageKeepingCurrentApplication(stagePosition)
                        : .switchToStage(stagePosition)
                    deliver(keyEvent, asynchronously: deliverAsynchronously)
                }
                return nil
            }
        }

        if type == .keyDown,
           let globalAction = configuredAction(keyCode: keyCode, flags: flags, scope: .global) {
            if globalAction.quickSwitchPosition != nil { return event }

            // Same-app cycling is Debut's replacement for macOS's Cmd-` handling. Excluded
            // apps have no tracked windows, so leave that shortcut untouched for macOS.
            if globalAction.isSameAppCycle && isFrontmostAppExcluded {
                return event
            }

            if globalAction.isOverlayActivation {
                beginSession(using: globalAction)
                let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if shouldPaceHeldCycle(globalAction, isAutoRepeat: isAutoRepeat) { return nil }
                let keyEvent = globalAction.toKeyEvent(autoRepeat: isAutoRepeat)
                let presentation = !isAutoRepeat && !overlayVisible
                    ? overlayPresentationRecorder.begin(
                        configuredDelayMilliseconds: 0,
                        eventTimestamp: event.timestamp
                    )
                    : nil
                if let presentation {
                    performanceRecorder.updateTraceID(
                        presentation.traceID,
                        for: performanceID
                    )
                }
                deliver(
                    keyEvent,
                    asynchronously: deliverAsynchronously,
                    overlayPresentation: presentation
                )
                return nil
            }

            if globalAction.isSameAppCycle && !overlayVisible {
                beginSession(using: globalAction)
                let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if shouldPaceHeldCycle(globalAction, isAutoRepeat: isAutoRepeat) { return nil }
                deliver(
                    globalAction.toKeyEvent(autoRepeat: isAutoRepeat),
                    asynchronously: deliverAsynchronously
                )
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

        // Keep the standard app quit/close shortcuts available unless the user explicitly
        // assigns that physical key combination to a Stage Manager command.
        let shortcutFlags = flags.intersection([
            .maskCommand, .maskAlternate, .maskControl, .maskShift,
        ])
        if (keyCode == Int64(kVK_ANSI_Q) || keyCode == Int64(kVK_ANSI_W)),
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
            if shouldPaceHeldCycle(sessionAction, isAutoRepeat: isAutoRepeat) { return nil }
            deliver(
                sessionAction.toKeyEvent(autoRepeat: isAutoRepeat),
                asynchronously: deliverAsynchronously
            )
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

    private var isFrontmostAppExcluded: Bool {
        configurationLock.withLock {
            guard let bundleID = cachedFrontmostAppBundleIdentifier else { return false }
            return storedExcludedBundleIDs.contains(bundleID)
        }
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

    private func deliver(
        _ event: DebutKeyEvent,
        asynchronously: Bool,
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        let deliveryID = performanceRecorder.begin(
            .mainQueueDelivery,
            traceID: overlayPresentation?.traceID,
            sampleResources: false
        )
        if asynchronously {
            DispatchQueue.main.async { [weak self] in
                _ = self?.performanceRecorder.end(deliveryID)
                if let overlayPresentation {
                    self?.overlayPresentationRecorder.mark(
                        .mainActorDequeued,
                        for: overlayPresentation
                    )
                }
                self?.delegate?.handleKeyEvent(
                    event,
                    overlayPresentation: overlayPresentation
                )
            }
        } else {
            _ = performanceRecorder.end(deliveryID)
            if let overlayPresentation {
                overlayPresentationRecorder.mark(.mainActorDequeued, for: overlayPresentation)
            }
            delegate?.handleKeyEvent(event, overlayPresentation: overlayPresentation)
        }
    }

    /// Maps an exact configured-modifier + number-row shortcut to stage positions 1-9.
    static func quickSwitchStagePosition(
        keyCode: Int64,
        flags: CGEventFlags,
        modifiers: ShortcutModifiers = .control
    ) -> Int? {
        let shortcutFlags = flags.intersection([
            .maskCommand, .maskControl, .maskAlternate, .maskShift,
        ])
        var expectedFlags: CGEventFlags = []
        if modifiers.command { expectedFlags.insert(.maskCommand) }
        if modifiers.control { expectedFlags.insert(.maskControl) }
        if modifiers.shift { expectedFlags.insert(.maskShift) }
        if modifiers.option { expectedFlags.insert(.maskAlternate) }
        guard shortcutFlags == expectedFlags else { return nil }

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
        service.reenableEventTap()
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<EventTapKeyboardService>.fromOpaque(userInfo).takeUnretainedValue()
    if let result = service.handleCGEventFromTap(type: type, event: event) {
        return Unmanaged.passUnretained(result)
    }
    return nil
}
