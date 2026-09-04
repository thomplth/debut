import Foundation
import CoreGraphics

public struct FrontWindowRequest: Equatable, Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t

    public init(windowID: CGWindowID, ownerPID: pid_t) {
        self.windowID = windowID
        self.ownerPID = ownerPID
    }
}

public final class MockWindowService: WindowService, @unchecked Sendable {
    public var apps: [AppInfo] = []
    public var windowList: [WindowInfo] = []
    public var untrackableWindowIDList: Set<CGWindowID> = []
    public var disqualifiedWindowIDList: Set<CGWindowID> = []
    public var axContradictedWindowIDList: Set<CGWindowID> = []
    public var allWindowIDList: Set<CGWindowID>?
    public var raisedWindowIDs: [CGWindowID] = []
    public var raisedWindowID: CGWindowID?
    public var closedWindowIDs: [CGWindowID] = []
    public var closeWindowResult: Bool = true
    public var activatedBundleID: String?
    public var activatedPID: pid_t?
    public var frontedWindows: [FrontWindowRequest] = []
    /// The window server declines a fronting request for a window it no longer knows. A mock that
    /// cannot refuse can only ever prove Debut asked, never that it noticed the answer — which is
    /// how an activation that macOS had stopped honouring stayed green for a day.
    public var frontWindowResult: Bool = true
    /// Who macOS reports as frontmost afterwards, which is a separate answer from the one above:
    /// the window server takes a request it then does not honour, and reports success either way.
    public var frontmostPID: pid_t?
    public var activateAppResult: Bool = true
    public var terminatedPIDs: [pid_t] = []
    public var terminateAppResult: Bool = true
    public var capturedImages: [CGWindowID: CGImage] = [:]
    public var accessibilityEnabled: Bool = true

    private let captureLock = NSLock()
    private var recordedCaptureRequests: [[CGWindowID]] = []

    /// One entry per `captureWindowImages` call, in call order.
    public var captureRequests: [[CGWindowID]] {
        captureLock.withLock { recordedCaptureRequests }
    }

    public init() {}

    public func listRunningApps() -> [AppInfo] { apps }
    public func listWindows() -> [WindowInfo] { windowList }
    public func listUntrackableWindowIDs() -> Set<CGWindowID> { untrackableWindowIDList }
    public func listDisqualifiedWindowIDs() -> Set<CGWindowID> { disqualifiedWindowIDList }
    public func listAXContradictedWindowIDs() -> Set<CGWindowID> { axContradictedWindowIDList }
    public func listAllWindowIDs() -> Set<CGWindowID>? { allWindowIDList }

    public func captureWindowImages(
        windowIDs: [CGWindowID],
        onEnumerated: @escaping @Sendable ([CGWindowID]) -> Void,
        onCapture: @escaping @Sendable (WindowImageCapture) -> Void
    ) async {
        captureLock.withLock { recordedCaptureRequests.append(windowIDs) }
        onEnumerated(windowIDs.filter { capturedImages[$0] != nil })
        for windowID in windowIDs {
            guard let image = capturedImages[windowID] else { continue }
            onCapture(WindowImageCapture(windowID: windowID, image: image))
        }
    }

    public func raiseWindow(windowID: CGWindowID) -> Bool {
        raisedWindowID = windowID
        raisedWindowIDs.append(windowID)
        return true
    }

    public func closeWindow(windowID: CGWindowID) -> Bool {
        closedWindowIDs.append(windowID)
        return closeWindowResult
    }

    public func frontWindow(windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        frontedWindows.append(FrontWindowRequest(windowID: windowID, ownerPID: ownerPID))
        return frontWindowResult
    }

    public func frontmostApplicationPID() -> pid_t? { frontmostPID }

    public func activateApp(bundleID: String) -> Bool {
        activatedBundleID = bundleID
        return activateAppResult
    }

    public func activateApp(pid: pid_t) -> Bool {
        activatedPID = pid
        return activateAppResult
    }

    public func terminateApp(pid: pid_t) -> Bool {
        terminatedPIDs.append(pid)
        return terminateAppResult
    }

    public func isAccessibilityEnabled() -> Bool { accessibilityEnabled }
}
