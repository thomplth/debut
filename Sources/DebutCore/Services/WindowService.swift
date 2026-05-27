import Foundation

public struct WindowInfo: Sendable, Equatable {
    public let windowID: Int
    public let appBundleID: String
    public let appName: String
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
    public let ownerPID: pid_t

    public init(
        windowID: Int,
        appBundleID: String,
        appName: String,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        ownerPID: pid_t
    ) {
        self.windowID = windowID
        self.appBundleID = appBundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.ownerPID = ownerPID
    }
}

public protocol WindowService: Sendable {
    func listWindows() -> [WindowInfo]
    func hideWindow(windowID: Int) -> Bool
    func showWindow(windowID: Int) -> Bool
    func focusWindow(windowID: Int) -> Bool
    func closeWindow(windowID: Int) -> Bool
    func getWindowFrame(windowID: Int) -> CGRect?
    func isAccessibilityEnabled() -> Bool
}
