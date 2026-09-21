import Foundation
import Observation

public enum OnboardingPage: Int, CaseIterable, Sendable, Codable {
    case welcome, workspace, previews, speed, ready
}

public struct OnboardingCheckpoint: Codable, Sendable {
    public let page: OnboardingPage
}

public enum OnboardingDestination: Sendable {
    case useDebut, tutorial, settings
}

public enum OnboardingPractice: Sendable, Equatable {
    case workspace, allWindows, desktop, moveWindow
}

public enum OnboardingExercise: String, Codable, Sendable {
    case switchWindow, switchDesktop, moveWindow
}

public struct OnboardingTarget: Equatable, Sendable {
    public let windowID: UInt32
    public let originDesktop: Int
    public let destinationDesktop: Int
    public let title: String
    public init(windowID: UInt32, originDesktop: Int, destinationDesktop: Int, title: String) {
        self.windowID = windowID
        self.originDesktop = originDesktop
        self.destinationDesktop = destinationDesktop
        self.title = title
    }
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

/// Setup has no practice targets; its only prerequisite is Accessibility.
@MainActor
@Observable
public final class OnboardingViewModel {
    public private(set) var page: OnboardingPage
    public var features: FeatureSettings
    public private(set) var permissions: OnboardingPermissionState
    public private(set) var desktopCount: Int?
    public var onEnvironmentRefresh: @MainActor () -> Void = {}
    private var didComplete = false
    private let permissionClient: any OnboardingPermissionClient
    private let onFeaturesChanged: @MainActor (FeatureSettings) -> Void
    private let onPermissionStateChanged: @MainActor (OnboardingPermissionState) -> Void
    private let onProgressChanged: @MainActor (OnboardingCheckpoint) -> Void
    private let onCompleted: @MainActor () -> Void
    private let onDestination: @MainActor (OnboardingDestination) -> Void

    public init(
        permissionClient: any OnboardingPermissionClient,
        features: FeatureSettings = FeatureSettings(),
        onFeaturesChanged: @escaping @MainActor (FeatureSettings) -> Void = { _ in },
        onPermissionStateChanged: @escaping @MainActor (OnboardingPermissionState) -> Void = { _ in },
        checkpoint: OnboardingCheckpoint? = nil,
        onProgressChanged: @escaping @MainActor (OnboardingCheckpoint) -> Void = { _ in },
        onCompleted: @escaping @MainActor () -> Void = {},
        onDestination: @escaping @MainActor (OnboardingDestination) -> Void = { _ in }
    ) {
        self.permissionClient = permissionClient
        self.permissions = permissionClient.currentState()
        self.features = features
        self.page = checkpoint?.page ?? .welcome
        self.onFeaturesChanged = onFeaturesChanged
        self.onPermissionStateChanged = onPermissionStateChanged
        self.onProgressChanged = onProgressChanged
        self.onCompleted = onCompleted
        self.onDestination = onDestination
    }

    public var canAdvance: Bool { permissions.accessibilityGranted }
    public var showsDesktopGuidance: Bool { page == .workspace && desktopCount == 1 }
    public var showsWindowPreviews: Bool { features.windowPreviews && permissions.screenRecordingGranted }

    public func updateEnvironment(desktopCount: Int) { self.desktopCount = desktopCount }

    public func advance() {
        refreshPermissions()
        guard canAdvance, !didComplete else { return }
        if page == .ready { finish(.useDebut) }
        else if let next = OnboardingPage(rawValue: page.rawValue + 1) {
            page = next
            onProgressChanged(.init(page: page))
            onEnvironmentRefresh()
        }
    }

    public func back() {
        guard !didComplete, let previous = OnboardingPage(rawValue: page.rawValue - 1) else { return }
        page = previous
        onProgressChanged(.init(page: page))
        onEnvironmentRefresh()
    }

    public func finish(_ destination: OnboardingDestination) {
        refreshPermissions()
        guard page == .ready, canAdvance, !didComplete else { return }
        didComplete = true
        // Persist completion and close setup before opening either destination.
        onCompleted()
        onDestination(destination)
    }

    public func setFeatures(_ features: FeatureSettings) {
        self.features = features
        onFeaturesChanged(features)
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

    /// Reads completion without the migration write `shouldPresent` performs, so
    /// a caller that runs before the first-launch check still sees an existing
    /// user as completed rather than as mid-onboarding.
    public static func hasCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completionKey) || defaults.bool(forKey: legacyLaunchKey)
    }

    public static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
        defaults.set(true, forKey: legacyLaunchKey)
    }
}

public enum OnboardingCapturePolicy {
    public static func isEnabled(previewsRequested: Bool, screenRecordingGranted: Bool) -> Bool {
        previewsRequested && screenRecordingGranted
    }
}

public enum OnboardingLayout {
    public static func contentHeight(visibleHeight: Double, titleBarHeight: Double) -> Double {
        min(650, max(0, visibleHeight - titleBarHeight))
    }
}
