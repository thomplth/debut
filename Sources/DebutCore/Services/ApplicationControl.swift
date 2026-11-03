import AppKit
import Carbon.HIToolbox

public protocol ApplicationControlling: Sendable {
    func runningTarget(bundleID: String) -> ApplicationShortcutTarget?
    func open(bundleID: String, path: String)
    func hide(pid: pid_t)
    func unhide(pid: pid_t)
    func sendNewWindowShortcut(pid: pid_t)
}

public struct WorkspaceApplicationControl: ApplicationControlling {
    public init() {}

    public func runningTarget(bundleID: String) -> ApplicationShortcutTarget? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated })
        else { return nil }
        return ApplicationShortcutTarget(
            pid: app.processIdentifier,
            isActive: NSWorkspace.shared.frontmostApplication?.processIdentifier
                == app.processIdentifier,
            isHidden: app.isHidden
        )
    }

    /// `NSRunningApplication.activate()` is declined while Debut is a background regular app;
    /// a LaunchServices open is not. A running app receives the reopen event, which is what
    /// makes most apps with no windows open one, as a Dock click does.
    public func open(bundleID: String, path: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? (FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil)
        else {
            DiagnosticReporter.shared.report("application_shortcut_open_failed", details: [
                "bundleID": bundleID, "reason": "not_found",
            ])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                DiagnosticReporter.shared.report("application_shortcut_open_failed", details: [
                    "bundleID": bundleID, "reason": error.localizedDescription,
                ])
            }
        }
    }

    public func hide(pid: pid_t) {
        _ = NSRunningApplication(processIdentifier: pid)?.hide()
    }

    public func unhide(pid: pid_t) {
        _ = NSRunningApplication(processIdentifier: pid)?.unhide()
    }

    public func sendNewWindowShortcut(pid: pid_t) {
        for keyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_ANSI_N),
                keyDown: keyDown
            ) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: DesktopSwipeService.syntheticMarker)
            event.postToPid(pid)
        }
    }
}
