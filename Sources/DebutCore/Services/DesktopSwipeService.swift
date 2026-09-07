import CoreGraphics
import Foundation

/// Intercepts the horizontal DockSwipe family, not scroll-wheel or vertical gestures.
/// Field meanings are shared with DockSwipeEvent; see the references in SpaceService.
// Lifecycle and callbacks run on the main run loop. No work is dispatched off that loop.
final class DesktopSwipeService: @unchecked Sendable {
    static let syntheticMarker: Int64 = 0x4445425554535750
    private var dockTap: CFMachPort?
    private var envelopeTap: CFMachPort?
    private var envelopeEnabled = false
    private var sources: [CFRunLoopSource] = []
    var desktopNavigationAvailable = true
    private var enabled = false
    private var tracking = false
    private var committed = false
    private let switchDesktop: (Int) -> Void

    init(switchDesktop: @escaping (Int) -> Void) {
        self.switchDesktop = switchDesktop
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        self.enabled = enabled
        if !enabled {
            // Drain a claimed physical gesture before removing its taps.
            if !tracking { stop() }
            return true
        }
        guard dockTap == nil else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        func makeTap(_ type: Int64) -> CFMachPort? {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                              options: .defaultTap, eventsOfInterest: 1 << UInt64(type),
                              callback: type == kCGSEventGesture ? desktopEnvelopeCallback : desktopSwipeCallback, userInfo: context)
        }
        guard let dock = makeTap(kCGSEventDockControl) else { return false }
        dockTap = dock
        guard let envelope = makeTap(kCGSEventGesture) else { stop(); return false }
        envelopeTap = envelope
        for tap in [dock, envelope] {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
            sources.append(source)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        envelopeEnabled = true
        setEnvelopeEnabled(false)
        CGEvent.tapEnable(tap: dock, enable: true)
        DiagnosticReporter.shared.report("desktop_swipe_tap_started")
        return true
    }

    func stop() {
        for tap in [dockTap, envelopeTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        sources.removeAll()
        dockTap = nil
        envelopeTap = nil
        envelopeEnabled = false
        tracking = false
        committed = false
    }

    private func setEnvelopeEnabled(_ value: Bool) {
        guard value != envelopeEnabled else { return }
        envelopeEnabled = value
        if let envelopeTap { CGEvent.tapEnable(tap: envelopeTap, enable: value) }
    }

    fileprivate func receive(type: CGEventType, event: CGEvent, isEnvelope: Bool = false) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A deliberately disabled companion tap must not revive itself.
            if isEnvelope && !envelopeEnabled { return event }
            tracking = false
            committed = false
            if let dockTap { CGEvent.tapEnable(tap: dockTap, enable: enabled) }
            setEnvelopeEnabled(false)
            return event
        }
        let result = handle(event, enabled: enabled)
        setEnvelopeEnabled(tracking)
        if !enabled && !tracking { stop() }
        return result
    }

    func handle(_ event: CGEvent, enabled: Bool) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else { return event }
        let type = event.getIntegerValueField(kCGSEventTypeField)
        if type == kCGSEventGesture { return tracking ? nil : event }
        guard type == kCGSEventDockControl,
              event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe,
              event.getIntegerValueField(kCGEventGestureSwipeMotion) == kGestureMotionHorizontal
        else { return event }

        let phase = event.getIntegerValueField(kCGEventGesturePhase)
        if phase == kCGSGesturePhaseBegan {
            guard enabled && desktopNavigationAvailable else { return event }
            DiagnosticReporter.shared.report("desktop_swipe_claimed")
            tracking = true
            committed = false
            return nil
        }
        guard tracking else { return event }
        if phase == kCGSGesturePhaseChanged && enabled && !committed {
            let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
            if abs(progress) >= 0.05 {
                committed = true
                switchDesktop(progress > 0 ? 1 : -1)
            }
        }
        if phase == kCGSGesturePhaseEnded {
            let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
            if enabled && !committed && abs(velocity) >= 0.05 {
                switchDesktop(velocity > 0 ? 1 : -1)
            }
            tracking = false
            committed = false
        } else if phase == 8 { // Cancelled
            tracking = false
            committed = false
        }
        return nil
    }
}

private func desktopSwipeCallback(proxy: CGEventTapProxy, type: CGEventType,
                                  event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<DesktopSwipeService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.receive(type: type, event: event).map(Unmanaged.passUnretained)
}

private func desktopEnvelopeCallback(proxy: CGEventTapProxy, type: CGEventType,
                                     event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<DesktopSwipeService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.receive(type: type, event: event, isEnvelope: true).map(Unmanaged.passUnretained)
}
