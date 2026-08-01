import Foundation
import CoreGraphics

public final class MockWindowService: WindowService, @unchecked Sendable {
    public var apps: [AppInfo] = []
    public var windowList: [WindowInfo] = []
    public var untrackableWindowIDList: Set<CGWindowID> = []
    public var allWindowIDList: Set<CGWindowID>?
    public var raisedWindowIDs: [CGWindowID] = []
    public var raisedWindowID: CGWindowID?
    public var activatedBundleID: String?
    public var capturedImages: [CGWindowID: CGImage] = [:]
    public var accessibilityEnabled: Bool = true

    public init() {}

    public func listRunningApps() -> [AppInfo] { apps }
    public func listWindows() -> [WindowInfo] { windowList }
    public func listUntrackableWindowIDs() -> Set<CGWindowID> { untrackableWindowIDList }
    public func listAllWindowIDs() -> Set<CGWindowID>? { allWindowIDList }

    public func captureWindowImage(windowID: CGWindowID) -> CGImage? {
        capturedImages[windowID]
    }

    public func raiseWindow(windowID: CGWindowID) -> Bool {
        raisedWindowID = windowID
        raisedWindowIDs.append(windowID)
        return true
    }

    public func activateApp(bundleID: String) -> Bool {
        activatedBundleID = bundleID
        return true
    }

    public func isAccessibilityEnabled() -> Bool { accessibilityEnabled }
}
