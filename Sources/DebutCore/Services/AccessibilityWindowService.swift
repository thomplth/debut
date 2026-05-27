import AppKit
import ApplicationServices
import AXPrivate

public final class AccessibilityWindowService: WindowService, @unchecked Sendable {
    public init() {}

    public func listRunningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular
            else { return nil }
            return AppInfo(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                pid: app.processIdentifier,
                isHidden: app.isHidden
            )
        }
    }

    public func hideApp(bundleID: String) -> Bool {
        guard let app = findApp(bundleID: bundleID) else { return false }
        return app.hide()
    }

    public func unhideApp(bundleID: String) -> Bool {
        guard let app = findApp(bundleID: bundleID) else { return false }
        return app.unhide()
    }

    public func activateApp(bundleID: String) -> Bool {
        guard let app = findApp(bundleID: bundleID) else { return false }
        return app.activate()
    }

    public func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    private func findApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
}
