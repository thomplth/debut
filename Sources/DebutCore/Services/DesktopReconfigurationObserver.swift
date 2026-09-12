import CoreGraphics
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
public enum DesktopReconfigurationEvent: Int, CaseIterable, Sendable {
    case overviewWillOpen = 1327
    case desktopListDidSettle = 1328

    var desktopListIsSettled: Bool {
        self == .desktopListDidSettle
    }
}

private func publish(_ event: DesktopReconfigurationEvent) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .debutDesktopLayoutMayHaveChanged,
            object: event
        )
    }
}

private let overviewWillOpenCallback: SLSNotifyCallback = { _, _, _, _ in
    publish(.overviewWillOpen)
}

private let desktopListDidSettleCallback: SLSNotifyCallback = { _, _, _, _ in
    publish(.desktopListDidSettle)
}

public extension Notification.Name {
    static let debutDesktopLayoutMayHaveChanged = Notification.Name(
        "com.thomplth.debut.desktopLayoutMayHaveChanged"
    )
}

/// Cheap live check for a Dock overview.
/// The Dock-owned layer-18 window spans the overview's lifetime and its owner/layer metadata is
/// available without Screen Recording permission. Mission Control, App Exposé, and Show Desktop
/// all stand down: each owns the native navigation gestures while it is visible.
enum DockOverviewDetector {
    static func isActive() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]]
        else { return false }
        return isActive(in: windows)
    }

    static func isActive(in windows: [[String: Any]]) -> Bool {
        windows.contains { window in
            (window[kCGWindowLayer as String] as? NSNumber)?.int32Value == 18
                && (window[kCGWindowOwnerName as String] as? String) == "Dock"
        }
    }
}

final class DesktopNavigationEligibility: @unchecked Sendable {
    enum BlockReason: String {
        case syntheticSwitchUnsupported
        case dockOverviewActive
        case dockOverviewRecovery
        case selectedStackUnknown
        case currentDesktopUnresolved
    }

    private let lock = NSLock()
    private var stackID: String?
    private var overviewRecoveryPending = false
    private let canSwitchSpaces: @Sendable () -> Bool
    private let overviewActive: @Sendable () -> Bool
    private let topology: @Sendable () -> SpaceTopology

    init(
        canSwitchSpaces: @escaping @Sendable () -> Bool,
        overviewActive: @escaping @Sendable () -> Bool,
        topology: @escaping @Sendable () -> SpaceTopology
    ) {
        self.canSwitchSpaces = canSwitchSpaces
        self.overviewActive = overviewActive
        self.topology = topology
    }

    func updateStackID(_ stackID: String?) {
        lock.withLock { self.stackID = stackID }
    }

    /// Dock's layer-18 marker has no balanced close event, and the first synthetic horizontal
    /// gesture after dismissal is ignored on macOS 26. Remember the opening signal instead:
    /// while the marker is present every match stays native, then exactly one match after it
    /// disappears is left to Dock to reset its carousel state before acceleration resumes.
    func overviewWillOpen() {
        lock.withLock { overviewRecoveryPending = true }
    }

    func blockReason() -> BlockReason? {
        guard canSwitchSpaces() else { return .syntheticSwitchUnsupported }
        guard !overviewActive() else { return .dockOverviewActive }
        let needsOverviewRecovery = lock.withLock {
            guard overviewRecoveryPending else { return false }
            overviewRecoveryPending = false
            return true
        }
        guard !needsOverviewRecovery else { return .dockOverviewRecovery }
        guard let stackID = lock.withLock({ stackID }) else { return .selectedStackUnknown }
        guard topology().stack(id: stackID)?.currentDesktopIndex != nil else {
            return .currentDesktopUnresolved
        }
        return nil
    }

    func isAvailable() -> Bool {
        blockReason() == nil
    }
}

/// Notices when the user rearranges desktops behind Debut's back.
///
/// Reordering desktops changes no active space, so `activeSpaceDidChangeNotification` stays
/// silent and nothing else wakes Debut to re-read the desktop list. Mission Control is the
/// only place a desktop can be reordered, so subscribing to its lifecycle catches every
/// reorder. These events are a superset of reordering and are not a balanced open/close pair;
/// reconciling on either is harmless because it is idempotent and a topology read costs
/// ~0.12ms warm.
public enum DesktopReconfigurationObserver {
    /// Measured on macOS 26.5.2 by registering every event in 200...230, 1200...1450 and
    /// 1500...1520 and then performing a real Mission Control drag. 1327 arrived 0.8s before
    /// the reordered list became readable and 1328 arrived 0.1s after it. A plain open/close
    /// may emit only 1327, so 1328 must not be treated as an overview-close signal. The neighbouring
    /// 1507 and 1508 fire constantly during ordinary window activity, so subscribing to those
    /// would reconcile on nearly every focus change for no added coverage.
    public static let subscribedEvents = DesktopReconfigurationEvent.allCases.map(\.rawValue)

    /// - Returns: the events actually subscribed to, empty when the private symbol is gone.
    @discardableResult
    public static func start() -> [Int] {
        guard let slsRegisterNotifyProc else { return [] }
        return [
            (DesktopReconfigurationEvent.overviewWillOpen.rawValue, overviewWillOpenCallback),
            (DesktopReconfigurationEvent.desktopListDidSettle.rawValue, desktopListDidSettleCallback),
        ].compactMap { event, callback in
            slsRegisterNotifyProc(callback, event, nil) == 0 ? event : nil
        }
    }
}
