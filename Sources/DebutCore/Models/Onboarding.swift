import Foundation
import Observation

public struct OnboardingPermissionRequirement: Sendable {
    public let isRequired: Bool
    public let detail: String

    public init(isRequired: Bool, detail: String) {
        self.isRequired = isRequired
        self.detail = detail
    }
}

public enum OnboardingPage: Int, CaseIterable, Sendable {
    case welcome
    case permissions
    case tutorial
}

public enum OnboardingTutorialStep: Int, CaseIterable, Sendable {
    case switchWindows
    case createStage
    case moveWindow
}

public struct OnboardingPermissionState: Equatable, Sendable {
    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool

    public init(accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
    }
}

@MainActor
public protocol OnboardingPermissionClient: AnyObject {
    func currentState() -> OnboardingPermissionState
    func requestAccessibility()
    func requestScreenRecording()
}

@MainActor
@Observable
public final class OnboardingViewModel {
    public let introduction = "Debut replaces the system Command–Tab switcher with a visual way to move through your windows and stages."

    public let screenRecordingRequirement = OnboardingPermissionRequirement(
        isRequired: true,
        detail: "Required to read your desktop wallpaper, so stages sit on it instead of a black rectangle, and to draw live window previews. Debut reads the screen on your Mac and never records, stores, or transmits it."
    )

    public private(set) var page: OnboardingPage = .welcome
    public private(set) var tutorialStep: OnboardingTutorialStep = .switchWindows
    public private(set) var permissions: OnboardingPermissionState
    public private(set) var shareAnonymousTelemetry: Bool

    private let permissionClient: any OnboardingPermissionClient
    private let onPermissionStateChanged: @MainActor (OnboardingPermissionState) -> Void
    private let onCompleted: @MainActor () -> Void
    private let onTelemetryChanged: @MainActor (Bool) -> Void
    private var didComplete = false

    public init(
        permissionClient: any OnboardingPermissionClient,
        shareAnonymousTelemetry: Bool = true,
        onTelemetryChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onPermissionStateChanged: @escaping @MainActor (OnboardingPermissionState) -> Void = { _ in },
        onCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.permissionClient = permissionClient
        self.permissions = permissionClient.currentState()
        self.shareAnonymousTelemetry = shareAnonymousTelemetry
        self.onTelemetryChanged = onTelemetryChanged
        self.onPermissionStateChanged = onPermissionStateChanged
        self.onCompleted = onCompleted
    }

    public func setShareAnonymousTelemetry(_ enabled: Bool) {
        shareAnonymousTelemetry = enabled
        onTelemetryChanged(enabled)
    }

    public var canStartTutorial: Bool {
        permissions.accessibilityGranted && permissions.screenRecordingGranted
    }

    public func continueFromWelcome() {
        page = .permissions
        refreshPermissions()
    }

    public func returnToWelcome() {
        page = .welcome
    }

    public func requestAccessibility() {
        permissionClient.requestAccessibility()
        refreshPermissions()
    }

    public func requestScreenRecording() {
        permissionClient.requestScreenRecording()
        refreshPermissions()
    }

    public func refreshPermissions() {
        permissions = permissionClient.currentState()
        onPermissionStateChanged(permissions)
    }

    public func startTutorial() {
        guard canStartTutorial else { return }
        tutorialStep = .switchWindows
        page = .tutorial
    }

    public func returnToPermissions() {
        page = .permissions
        refreshPermissions()
    }

    public func advanceTutorial() {
        guard page == .tutorial, !didComplete else { return }
        let nextRawValue = tutorialStep.rawValue + 1
        if let next = OnboardingTutorialStep(rawValue: nextRawValue) {
            tutorialStep = next
        } else {
            didComplete = true
            onCompleted()
        }
    }
}

public enum OnboardingLaunchPolicy {
    public static let completionKey = "hasCompletedOnboarding"
    public static let legacyLaunchKey = "hasLaunchedBefore"

    public static func shouldPresent(
        defaults: UserDefaults = .standard,
        force: Bool = false
    ) -> Bool {
        if force { return true }
        if defaults.bool(forKey: completionKey) { return false }

        // Builds before onboarding marked a launch immediately. Treat that key as
        // a completed migration so existing users do not get a first-run screen.
        if defaults.bool(forKey: legacyLaunchKey) {
            defaults.set(true, forKey: completionKey)
            return false
        }
        return true
    }

    public static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
        defaults.set(true, forKey: legacyLaunchKey)
    }
}
