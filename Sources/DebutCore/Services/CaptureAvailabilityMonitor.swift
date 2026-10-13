import AppKit
import Foundation

/// Whether a window capture can show anything worth having (KHA-1082).
///
/// Captures used to run only when the overlay opened, which cannot happen on the lock screen.
/// Background capture is driven by window events instead, and apps keep retitling and resizing
/// windows while the screen is locked, the displays sleep, or another user's session is in
/// front. A capture then costs the same ~80 CPU-ms in the privacy machinery and returns nothing
/// the user can see, so background capture stops until all three have cleared.
final class CaptureAvailabilityMonitor: @unchecked Sendable {
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private enum Reason: Hashable {
        case locked
        case displaysAsleep
        case sessionInactive
    }

    private let lock = NSLock()
    private var reasons: Set<Reason> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let onChange: @Sendable (Bool) -> Void

    var isSuspended: Bool { lock.withLock { !reasons.isEmpty } }

    init(
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onChange: @escaping @Sendable (Bool) -> Void
    ) {
        self.onChange = onChange
        observe(distributedCenter, Self.screenLocked) { $0.set(.locked, true) }
        observe(distributedCenter, Self.screenUnlocked) { $0.set(.locked, false) }
        observe(workspaceCenter, NSWorkspace.screensDidSleepNotification) { $0.set(.displaysAsleep, true) }
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification) { $0.set(.displaysAsleep, false) }
        observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification) { $0.set(.sessionInactive, true) }
        observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification) { $0.set(.sessionInactive, false) }
    }

    deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ apply: @escaping @Sendable (CaptureAvailabilityMonitor) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            apply(self)
        }
        observers.append((center, observer))
    }

    private func set(_ reason: Reason, _ active: Bool) {
        let change: Bool? = lock.withLock {
            let before = !reasons.isEmpty
            if active { reasons.insert(reason) } else { reasons.remove(reason) }
            let after = !reasons.isEmpty
            return before == after ? nil : after
        }
        if let change { onChange(change) }
    }
}
