import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
public final class SystemOnboardingPermissionClient: OnboardingPermissionClient {
    public init() {}

    public func settingsURL(for permission: OnboardingPermission) -> URL? {
        let anchor: String
        switch permission {
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    public func openSettings(for permission: OnboardingPermission) {
        guard let url = settingsURL(for: permission) else { return }
        NSWorkspace.shared.open(url)
    }

    public func currentState() -> OnboardingPermissionState {
        OnboardingPermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
    }

    /// Resets Debut's own grant for each permission it lacks, so the next prompt or drag in
    /// System Settings adds a grant macOS honors. Returns `tccutil`'s status per reset.
    public func clearStaleGrants(launchedByLaunchServices: Bool = getppid() == 1) -> [OnboardingPermission: Int32] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [:] }
        let permissions = StalePermissionGrants.toReset(
            currentState(), launchedByLaunchServices: launchedByLaunchServices)
        var statuses: [OnboardingPermission: Int32] = [:]
        for permission in permissions {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", StalePermissionGrants.service(for: permission), bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                statuses[permission] = process.terminationStatus
            } catch {
                statuses[permission] = -1
            }
        }
        return statuses
    }

    public func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    public func restartDebut() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// A grant made for a build signed differently (ad-hoc, the self-signed Debut Dev identity,
/// another team) stays listed and switched on in System Settings, but its code requirement no
/// longer matches, so macOS denies this build. Adding Debut again changes nothing because its
/// bundle ID is already listed (KHA-1069). Resetting the row lets the next grant match.
enum StalePermissionGrants {
    /// Only at launch, so no grant made in this process can be lost: Screen Recording granted
    /// now reads as missing until a relaunch. Only when LaunchServices started Debut: a binary
    /// run from a terminal is judged by the terminal's grant, which says nothing about Debut's.
    static func toReset(
        _ state: OnboardingPermissionState,
        launchedByLaunchServices: Bool
    ) -> [OnboardingPermission] {
        guard launchedByLaunchServices else { return [] }
        var permissions: [OnboardingPermission] = []
        if !state.accessibilityGranted { permissions.append(.accessibility) }
        if !state.screenRecordingGranted { permissions.append(.screenRecording) }
        return permissions
    }

    static func service(for permission: OnboardingPermission) -> String {
        switch permission {
        case .accessibility: "Accessibility"
        case .screenRecording: "ScreenCapture"
        }
    }
}
