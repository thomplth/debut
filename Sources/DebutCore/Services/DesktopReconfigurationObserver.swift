import Foundation

private typealias SLSNotifyCallback = @convention(c) (
    UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?
) -> Void

private let slsRegisterNotifyProc: (@convention(c) (
    SLSNotifyCallback?, Int, UnsafeMutableRawPointer?
) -> Int32)? = skyLightSymbol("SLSRegisterNotifyProc")

/// The window server calls back on its own thread and the C function pointer can carry no
/// context, so the callback republishes as a notification the main thread picks up. That is
/// also how every other external space signal reaches `AppDelegate`.
private let notifyCallback: SLSNotifyCallback = { _, _, _, _ in
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .debutDesktopLayoutMayHaveChanged,
            object: nil
        )
    }
}

public extension Notification.Name {
    static let debutDesktopLayoutMayHaveChanged = Notification.Name(
        "com.thomplth.debut.desktopLayoutMayHaveChanged"
    )
}

/// Notices when the user rearranges desktops behind Debut's back.
///
/// Reordering desktops changes no active space, so `activeSpaceDidChangeNotification` stays
/// silent and nothing else wakes Debut to re-read the desktop list. Mission Control is the
/// only place a desktop can be reordered, so subscribing to its lifecycle catches every
/// reorder. These events are a superset — they fire whenever Mission Control opens and
/// closes, reorder or not — which is harmless: reconciling is idempotent and a topology read
/// costs ~0.12ms warm.
public enum DesktopReconfigurationObserver {
    /// Measured on macOS 26.5.2 by registering every event in 200...230, 1200...1450 and
    /// 1500...1520 and then performing a real Mission Control drag. 1327 arrived 0.8s before
    /// the reordered list became readable and 1328 arrived 0.1s after it. The neighbouring
    /// 1507 and 1508 fire constantly during ordinary window activity, so subscribing to those
    /// would reconcile on nearly every focus change for no added coverage.
    public static let subscribedEvents: [Int] = [1327, 1328]

    /// - Returns: the events actually subscribed to, empty when the private symbol is gone.
    @discardableResult
    public static func start() -> [Int] {
        guard let slsRegisterNotifyProc else { return [] }
        return subscribedEvents.filter {
            slsRegisterNotifyProc(notifyCallback, $0, nil) == 0
        }
    }
}
