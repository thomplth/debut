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
    }

    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}
