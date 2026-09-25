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

/// Cheap live check for an overview without reading permission-gated window names.
///
/// Through macOS 26 the Dock owns a layer-18 marker. macOS 27 moved Mission Control and App
/// Exposé to a display-sized WindowManager layer-19 overlay, while Show Desktop uses a
/// display-sized WindowManager layer-18 overlay. Requiring display size prevents ordinary
/// WindowManager thumbnails and tiling affordances from blocking navigation.
enum DockOverviewDetector {
    static func isActive() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]]
        else { return false }
        return isActive(
            in: windows,
            operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            displayBounds: activeDisplayBounds()
        )
    }

    static func isActive(
        in windows: [[String: Any]],
        operatingSystemMajor: Int,
        displayBounds: [CGRect]
    ) -> Bool {
        guard operatingSystemMajor >= 27 else {
            return windows.contains { window in
                (window[kCGWindowLayer as String] as? NSNumber)?.int32Value == 18
                    && (window[kCGWindowOwnerName as String] as? String) == "Dock"
            }
        }

        return windows.contains { window in
            guard (window[kCGWindowOwnerName as String] as? String) == "WindowManager",
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.int32Value,
                  layer == 18 || layer == 19,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  )
            else { return false }
            return displayBounds.contains {
                abs($0.width - bounds.width) <= 1 && abs($0.height - bounds.height) <= 1
            }
        }
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }
}

final class DesktopNavigationEligibility: @unchecked Sendable {
    enum BlockReason: String {
        case syntheticSwitchUnsupported
        case dockOverviewActive
        case dockOverviewRecovery
        case dockOverviewStateUnknown
        case selectedStackUnknown
        case currentDesktopUnresolved
    }

    private let lock = NSLock()
    private var stackID: String?
    private var overviewActive: Bool?
    private var overviewRecoveryPending = false
    private var currentDesktopResolved = false
    private let canSwitchSpaces: @Sendable () -> Bool
    private let needsOverviewRecovery: Bool

    init(
        canSwitchSpaces: @escaping @Sendable () -> Bool,
        requiresOverviewRecovery: Bool = DesktopNavigationEligibility.requiresOverviewRecovery(
            operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    ) {
        self.canSwitchSpaces = canSwitchSpaces
        self.needsOverviewRecovery = requiresOverviewRecovery
    }

    /// macOS 26 leaves Dock's gesture carousel unable to accept Debut's first synthetic
    /// horizontal gesture after an overview closes. macOS 27 no longer has that behavior, so
    /// sacrificing its first physical gesture only leaks the user's input to macOS or the
    /// foreground app without serving a recovery purpose.
    static func requiresOverviewRecovery(operatingSystemMajor: Int) -> Bool {
        operatingSystemMajor == 26
    }

    /// Publishes live WindowServer state from outside the event-tap callback. Input ownership
    /// reads only this cache, so a physical gesture never blocks on a cross-process query.
    func update(
        stackID: String?,
        topology: SpaceTopology,
        overviewActive: Bool,
        consumeOverviewRecovery: Bool = false
    ) {
        lock.withLock {
            let previouslyActive = self.overviewActive == true
            let stack = stackID.flatMap { topology.stack(id: $0) }
            self.stackID = stackID
            self.overviewActive = overviewActive
            self.currentDesktopResolved = stack?.currentSpaceIndex != nil
            if consumeOverviewRecovery && previouslyActive && !overviewActive {
                // The candidate gesture that triggered this refresh already stayed entirely
                // native, so it also served as Dock's one post-overview recovery gesture.
                overviewRecoveryPending = false
            }
        }
    }

    /// The overview marker has no balanced close event, and the first synthetic horizontal
    /// gesture after dismissal is ignored on macOS 26. Remember the opening signal instead:
    /// while the marker is present every match stays native, then exactly one match after it
    /// disappears is left to Dock to reset its carousel state before acceleration resumes on
    /// the one affected OS release.
    @discardableResult
    func overviewWillOpen(confirmed: Bool) -> Bool {
        guard confirmed else { return false }
        lock.withLock {
            overviewActive = true
            overviewRecoveryPending = needsOverviewRecovery
            currentDesktopResolved = false
        }
        return true
    }

    func blockReason() -> BlockReason? {
        guard canSwitchSpaces() else { return .syntheticSwitchUnsupported }
        return lock.withLock {
            guard let overviewActive else { return .dockOverviewStateUnknown }
            guard !overviewActive else { return .dockOverviewActive }
            if overviewRecoveryPending {
                overviewRecoveryPending = false
                return .dockOverviewRecovery
            }
            guard stackID != nil else { return .selectedStackUnknown }
            guard currentDesktopResolved else { return .currentDesktopUnresolved }
            return nil
        }
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
