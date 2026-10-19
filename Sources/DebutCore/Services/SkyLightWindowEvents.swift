import CoreGraphics
import Foundation

/// Window events the WindowServer sends a connection, by the ids AltTab mapped on macOS 26 and
/// Debut confirmed on macOS 27 (KHA-1166). The per-window ones arrive only for windows the
/// connection asked about; the Space ones carry no window.
public enum WindowServerWindowEvent: UInt32, CaseIterable, Sendable {
    case windowFocused = 808
    case windowOrderedIn = 815
    case windowOrderedOut = 816
    case currentSpaceChanged = 1329
    case activeSpaceChanged = 1401

    var diagnosticName: String {
        switch self {
        case .windowFocused: "focused"
        case .windowOrderedIn: "ordered_in"
        case .windowOrderedOut: "ordered_out"
        case .currentSpaceChanged: "current_space_changed"
        case .activeSpaceChanged: "active_space_changed"
        }
    }
}

/// Where window focus comes from when the app being asked is too slow to say. Handlers run on
/// the main queue.
public protocol WindowServerWindowEventSource: AnyObject {
    typealias Handler = (WindowServerWindowEvent, CGWindowID, TimeInterval) -> Void

    /// - Returns: the events the WindowServer accepted, empty when SkyLight is unavailable.
    func start(handler: @escaping Handler) -> [WindowServerWindowEvent]
    /// Replaces the windows per-window events are sent for.
    func watch(_ windowIDs: Set<CGWindowID>)
    /// A cross-process read; call it off the main queue.
    func onScreenWindowIDs() -> Set<CGWindowID>
}

private typealias ConnectionNotifyProc = @convention(c) (
    UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, CGSConnectionID
) -> Void

private let mainConnectionID: (@convention(c) () -> CGSConnectionID)? =
    skyLightSymbol("CGSMainConnectionID")
private let registerConnectionNotifyProc: (@convention(c) (
    CGSConnectionID, ConnectionNotifyProc, UInt32, UnsafeMutableRawPointer?
) -> Int32)? = skyLightSymbol("SLSRegisterConnectionNotifyProc")
private let requestNotificationsForWindows: (@convention(c) (
    CGSConnectionID, UnsafeMutablePointer<CGWindowID>?, Int32
) -> Int32)? = skyLightSymbol("SLSRequestNotificationsForWindows")

/// The WindowServer calls back on whichever thread reads the datagram, and the payload is only
/// valid for the call, so the window ID is copied before hopping to main. The arrival is stamped
/// there too: the hop can queue behind Debut's own work and stretch the gap between a focus
/// event and the raises that follow it.
private let notifyProc: ConnectionNotifyProc = { rawEvent, data, length, context, _ in
    guard let context, let event = WindowServerWindowEvent(rawValue: rawEvent) else { return }
    let arrivedAt = ProcessInfo.processInfo.systemUptime
    var windowID: CGWindowID = 0
    if let data, length >= MemoryLayout<CGWindowID>.size {
        memcpy(&windowID, data, MemoryLayout<CGWindowID>.size)
    }
    let source = Unmanaged<SkyLightWindowEvents>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async(
        qos: EventTapKeyboardService.deliveryQualityOfService,
        flags: .enforceQoS
    ) {
        source.handler?(event, windowID, arrivedAt)
    }
}

public final class SkyLightWindowEvents: WindowServerWindowEventSource, @unchecked Sendable {
    fileprivate var handler: Handler?
    private var watched: Set<CGWindowID> = []
    private var requested: Set<CGWindowID> = []
    private var requestScheduled = false

    public init() {}

    public func start(handler: @escaping Handler) -> [WindowServerWindowEvent] {
        guard self.handler == nil,
              let mainConnectionID,
              let registerConnectionNotifyProc,
              requestNotificationsForWindows != nil
        else { return [] }
        self.handler = handler
        let connection = mainConnectionID()
        // SkyLight has no call that unregisters a connection proc, so the context it is handed
        // must outlive every callback: this source is retained for the process's life.
        let context = Unmanaged.passRetained(self).toOpaque()
        return WindowServerWindowEvent.allCases.filter {
            registerConnectionNotifyProc(connection, notifyProc, $0.rawValue, context) == 0
        }
    }

    /// Coalesced to one request per main-queue turn. The request replaces the connection's whole
    /// watch list, so it always carries every window: sending only new ones left the rest deaf
    /// (AltTab #5785).
    public func watch(_ windowIDs: Set<CGWindowID>) {
        watched = windowIDs
        guard !requestScheduled else { return }
        requestScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requestScheduled = false
            guard self.watched != self.requested,
                  let mainConnectionID,
                  let requestNotificationsForWindows
            else { return }
            self.requested = self.watched
            var list = Array(self.watched)
            _ = list.withUnsafeMutableBufferPointer {
                requestNotificationsForWindows(mainConnectionID(), $0.baseAddress, Int32($0.count))
            }
        }
    }

    public func onScreenWindowIDs() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]]
        else { return [] }
        return Set(windows.compactMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value })
    }
}
