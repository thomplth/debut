import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import SwiftUI

/// Mirrors physical key presses while the diagram is on screen. A listen-only tap
/// at the HID level sees Tab even when Debut's own shortcut tap claims it; without
/// Accessibility or Input Monitoring the diagram falls back to keys that reach this app.
@MainActor
@Observable
final class OnboardingKeyboardMonitor {
    private(set) var presses = OnboardingKeyPresses()
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    func start() {
        guard localMonitor == nil else { return }
        presses.apply(.reset)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            if let self, self.tap == nil { self.receive(type: event.cgEvent?.type, event: event.cgEvent) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap == nil else { return }
                self.presses.apply(.reset)
            }
        }
        // Debut's shortcut tap already runs on Accessibility alone. Both checks never
        // prompt, whereas creating the tap without either access would.
        guard AXIsProcessTrusted() || CGPreflightListenEventAccess() else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                if let info {
                    let monitor = Unmanaged<OnboardingKeyboardMonitor>.fromOpaque(info).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.receive(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        presses.apply(.reset)
    }

    private func receive(type: CGEventType?, event: CGEvent?) {
        guard let type, let event else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let input: OnboardingKeyInput
        switch type {
        case .keyDown: input = .keyDown(keyCode: keyCode)
        case .keyUp: input = .keyUp(keyCode: keyCode)
        case .flagsChanged:
            input = .flagsChanged(keyCode: keyCode, flags: event.flags, deviceFlags: event.flags.rawValue & 0xFFFF)
        default: return
        }
        var next = presses
        next.apply(input)
        if next != presses { presses = next }
    }
}

/// The left half of a Mac keyboard, cropped and faded, with the shortcut's keys
/// highlighted and live presses mirrored.
struct OnboardingKeyboardView: View {
    let highlighted: Set<CGKeyCode>
    /// Key pitch in points, fixed so the keyboard looks the same on every page.
    let unit: CGFloat
    /// Visible crop width; rows continue past it under the progressive blur.
    let width: CGFloat
    @State private var monitor = OnboardingKeyboardMonitor()
    @Environment(\.colorScheme) private var colorScheme

    static func height(unit: CGFloat) -> CGFloat {
        CGFloat(OnboardingKeyboard.leftHalf.count) * unit + gap(unit: unit)
    }

    private static func gap(unit: CGFloat) -> CGFloat { max(3, unit * 0.1) }

    var body: some View {
        let gap = Self.gap(unit: unit)
        let height = Self.height(unit: unit)
        let fadeStart = max(0, (width - OnboardingDemoLayout.fadeUnits * unit) / max(width, 1))
        let keys = VStack(alignment: .leading, spacing: gap) {
            ForEach(OnboardingKeyboard.leftHalf.indices, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(OnboardingKeyboard.leftHalf[row], id: \.keyCode) { key in
                        keyView(key, unit: unit, gap: gap)
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, gap)
        .frame(width: width, height: height, alignment: .topLeading)
        // Sharp keys fade out while a blurred copy takes over, so the crop dissolves
        // progressively instead of ending at a hard edge.
        ZStack {
            keys.mask(LinearGradient(stops: [.init(color: .black, location: fadeStart),
                                             .init(color: .clear, location: fadeStart + (1 - fadeStart) * 0.4)],
                                     startPoint: .leading, endPoint: .trailing))
            keys.blur(radius: unit * 0.12)
                .mask(LinearGradient(stops: [.init(color: .clear, location: fadeStart),
                                             .init(color: .black, location: fadeStart + (1 - fadeStart) * 0.3),
                                             .init(color: .clear, location: fadeStart + (1 - fadeStart) * 0.65)],
                                     startPoint: .leading, endPoint: .trailing))
            keys.blur(radius: unit * 0.3)
                .mask(LinearGradient(stops: [.init(color: .clear, location: fadeStart + (1 - fadeStart) * 0.3),
                                             .init(color: .black.opacity(0.8), location: fadeStart + (1 - fadeStart) * 0.6),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .frame(width: width, height: height)
        .clipped()
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let names = OnboardingKeyboard.leftHalf.flatMap(\.self).filter { highlighted.contains($0.keyCode) }.map(\.label)
        return "Keyboard showing \(names.joined(separator: " and ")) keys"
    }

    private func keyView(_ key: OnboardingKey, unit: CGFloat, gap: CGFloat) -> some View {
        let isHighlighted = highlighted.contains(key.keyCode)
        let isPressed = monitor.presses.pressed.contains(key.keyCode)
        let width = key.width * unit - gap
        let isWide = key.width > 1 || key.label.count > 2
        return ZStack(alignment: isWide ? .bottomLeading : .center) {
            RoundedRectangle(cornerRadius: unit * 0.16)
                .fill(fill(highlighted: isHighlighted, pressed: isPressed))
            RoundedRectangle(cornerRadius: unit * 0.16)
                .strokeBorder(isHighlighted ? Color.accentColor.opacity(isPressed ? 0 : 0.7) : Color.primary.opacity(0.1),
                              lineWidth: isHighlighted ? 1.5 : 1)
            legend(key, unit: unit, wide: isWide)
                .foregroundStyle(isPressed && isHighlighted ? Color.white
                    : isHighlighted ? Color.accentColor : Color.primary.opacity(isPressed ? 0.85 : 0.5))
                .padding(.horizontal, unit * 0.14).padding(.vertical, unit * 0.1)
        }
        .frame(width: width, height: unit - gap)
        .offset(y: isPressed ? 1 : 0)
        .shadow(color: .black.opacity(isPressed ? 0 : colorScheme == .dark ? 0.25 : 0.06), radius: 0, y: 1)
        .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    @ViewBuilder private func legend(_ key: OnboardingKey, unit: CGFloat, wide: Bool) -> some View {
        if wide {
            VStack(alignment: .leading, spacing: 0) {
                if let symbol = key.symbol {
                    Text(symbol).font(.system(size: unit * 0.26))
                }
                Spacer(minLength: 0)
                Text(key.label).font(.system(size: unit * 0.2, weight: .medium)).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text(key.label).font(.system(size: unit * 0.3, weight: .medium))
        }
    }

    private func fill(highlighted: Bool, pressed: Bool) -> Color {
        if pressed { return highlighted ? Color.accentColor : Color.primary.opacity(0.16) }
        if highlighted { return Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.12) }
        return colorScheme == .dark ? Color.white.opacity(0.07) : Color.white
    }
}
