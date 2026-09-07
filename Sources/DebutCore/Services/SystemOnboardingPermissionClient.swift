import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
public final class SystemOnboardingPermissionClient: OnboardingPermissionClient {
    public init() {}

    public func currentState() -> OnboardingPermissionState {
        OnboardingPermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
    }

    public func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}
