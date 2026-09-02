import AppKit

public protocol ActivationPolicyManaging: AnyObject, Sendable {
    var policy: NSApplication.ActivationPolicy { get }
    func setPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
}

public final class SystemActivationPolicyManager: ActivationPolicyManaging, @unchecked Sendable {
    public init() {}

    public var policy: NSApplication.ActivationPolicy {
        MainActor.assumeIsolated { NSApp.activationPolicy() }
    }

    public func setPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        MainActor.assumeIsolated { NSApp.setActivationPolicy(policy) }
    }
}

/// Switches Debut between a regular Dock application and a menu-bar agent.
///
/// The policy is decided here rather than by `LSUIElement`, which stays `true` so a menu-bar-only
/// user never sees a Dock icon appear during launch.
public final class ActivationPolicyCoordinator: @unchecked Sendable {
    private let manager: ActivationPolicyManaging
    private let diag: DiagnosticReporter

    public init(
        manager: ActivationPolicyManaging = SystemActivationPolicyManager(),
        diagnostics: DiagnosticReporter = .shared
    ) {
        self.manager = manager
        self.diag = diagnostics
    }

    /// Returns whether the app now runs under the requested policy. macOS refuses some
    /// transitions, and a silent failure would leave the toggle lying.
    @discardableResult
    public func apply(showsDockIcon: Bool) -> Bool {
        let target: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard manager.policy != target else { return true }
        let applied = manager.setPolicy(target)
        diag.report("activation_policy_changed", details: [
            "applied": "\(applied)",
            "policy": showsDockIcon ? "regular" : "accessory",
        ])
        return applied
    }
}
