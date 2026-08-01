import AppKit
import CoreGraphics

public struct WindowInfo: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerBundleID: String
    public let ownerName: String
    public let ownerPID: pid_t
    public let title: String
    public let bounds: CGRect
    public let isOnScreen: Bool

    public init(windowID: CGWindowID, ownerBundleID: String, ownerName: String, ownerPID: pid_t, title: String, bounds: CGRect, isOnScreen: Bool) {
        self.windowID = windowID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
    }
}

public struct AppInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let pid: pid_t
    public let isHidden: Bool

    public init(bundleID: String, name: String, pid: pid_t, isHidden: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.isHidden = isHidden
    }
}

public protocol WindowService: Sendable {
    func listRunningApps() -> [AppInfo]
    func listWindows() -> [WindowInfo]
    func listUntrackableWindowIDs() -> Set<CGWindowID>
    func listAllWindowIDs() -> Set<CGWindowID>?
    func captureWindowImage(windowID: CGWindowID) -> CGImage?
    func raiseWindow(windowID: CGWindowID) -> Bool
    func activateApp(bundleID: String) -> Bool
    func isAccessibilityEnabled() -> Bool
}
