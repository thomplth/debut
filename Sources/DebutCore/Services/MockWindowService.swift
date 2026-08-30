import Foundation
import CoreGraphics

public final class MockWindowService: WindowService, @unchecked Sendable {
    public var apps: [AppInfo] = []
    public var windowList: [WindowInfo] = []
    public var untrackableWindowIDList: Set<CGWindowID> = []
    public var allWindowIDList: Set<CGWindowID>?
    public var raisedWindowIDs: [CGWindowID] = []
    public var raisedWindowID: CGWindowID?
    public var closedWindowIDs: [CGWindowID] = []
    public var closeWindowResult: Bool = true
    public var activatedBundleID: String?
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

    public func activateApp(bundleID: String) -> Bool {
        activatedBundleID = bundleID
        return true
    }

    public func terminateApp(pid: pid_t) -> Bool {
        terminatedPIDs.append(pid)
        return terminateAppResult
    }

    public func isAccessibilityEnabled() -> Bool { accessibilityEnabled }
}
