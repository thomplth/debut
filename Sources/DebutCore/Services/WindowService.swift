import AppKit

public protocol WindowService: Sendable {
    func listRunningApps() -> [AppInfo]
    func hideApp(bundleID: String) -> Bool
    func unhideApp(bundleID: String) -> Bool
    func activateApp(bundleID: String) -> Bool
    func isAccessibilityEnabled() -> Bool
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
