import Foundation
import ServiceManagement

public protocol LaunchAtLoginManaging: AnyObject, Sendable {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

/// Wraps the login item so the setting can be exercised without touching the user's real
/// login items in tests.
public final class SystemLaunchAtLoginManager: LaunchAtLoginManaging, @unchecked Sendable {
    public init() {}

    public var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

public final class LaunchAtLoginCoordinator: @unchecked Sendable {
    private let manager: LaunchAtLoginManaging
    private let diag: DiagnosticReporter

    public init(
        manager: LaunchAtLoginManaging = SystemLaunchAtLoginManager(),
        diagnostics: DiagnosticReporter = .shared
    ) {
        self.manager = manager
        self.diag = diagnostics
    }

    /// Returns whether the login item now matches the setting. macOS can refuse registration
    /// for an unapproved or relocated bundle, and a silent failure would leave the toggle lying.
    @discardableResult
    public func apply(enabled: Bool) -> Bool {
        guard manager.isRegistered != enabled else { return true }
        do {
            if enabled {
                try manager.register()
            } else {
                try manager.unregister()
            }
            diag.report("launch_at_login_changed", details: ["enabled": "\(enabled)"])
            return true
        } catch {
            diag.report("launch_at_login_failed", details: [
                "enabled": "\(enabled)",
                "error": String(describing: error),
            ])
            return false
        }
    }
}
