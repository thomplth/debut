import ApplicationServices
import Foundation

public final class NumberHotkeyMonitor: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keysDown: Set<Int64> = []
    private var requiredModifiers: LabModifiers = .control
    private var handler: (@Sendable (Int) -> Void)?

    public init() {}

    public var isRunning: Bool { eventTap != nil }

    @MainActor
    @discardableResult
    public func start(
        requiredModifiers: LabModifiers,
        handler: @escaping @Sendable (Int) -> Void
    ) -> Bool {
        stop()
        self.requiredModifiers = requiredModifiers
        self.handler = handler
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: numberHotkeyCallback,
            userInfo: pointer
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    @MainActor
    public func update(requiredModifiers: LabModifiers) {
        self.requiredModifiers = requiredModifiers
    }

    @MainActor
    public func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        keysDown.removeAll()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, keysDown.remove(keyCode) != nil { return nil }
        guard type == .keyDown else { return event }

        let index = HotkeyMapping.desktopIndex(
            keyCode: keyCode,
            modifiers: Self.modifiers(from: event.flags),
            requiredModifiers: requiredModifiers
        )
        guard let index else { return event }
        if keysDown.insert(keyCode).inserted { handler?(index) }
        return nil
    }

    fileprivate func reenable() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    private static func modifiers(from flags: CGEventFlags) -> LabModifiers {
        var result: LabModifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
}

private func numberHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<NumberHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard let output = monitor.handle(type: type, event: event) else { return nil }
    return Unmanaged.passUnretained(output)
}
