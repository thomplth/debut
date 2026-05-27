import Foundation

public final class MockWindowService: WindowService, @unchecked Sendable {
    public var apps: [AppInfo] = []
    public var hiddenBundleIDs: Set<String> = []
    public var activatedBundleID: String?
    public var accessibilityEnabled: Bool = true

    public init() {}

    public func listRunningApps() -> [AppInfo] { apps }

    public func hideApp(bundleID: String) -> Bool {
        hiddenBundleIDs.insert(bundleID)
        return true
    }

    public func unhideApp(bundleID: String) -> Bool {
        hiddenBundleIDs.remove(bundleID)
        return true
    }

    public func activateApp(bundleID: String) -> Bool {
        activatedBundleID = bundleID
        hiddenBundleIDs.remove(bundleID)
        return true
    }

    public func isAccessibilityEnabled() -> Bool { accessibilityEnabled }
}
