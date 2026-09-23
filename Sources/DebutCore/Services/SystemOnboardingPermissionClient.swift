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
