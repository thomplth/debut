import Foundation
import Observation

public enum OnboardingPage: Int, CaseIterable, Sendable, Codable {
    case welcome, workspace, previews, speed, ready
}

public struct OnboardingCheckpoint: Codable, Sendable {
    public let page: OnboardingPage
    public let workspacePracticed: Bool
    public let allWindowsPracticed: Bool
}

public enum OnboardingPractice: Sendable, Equatable {
    case workspace, allWindows
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
    public private(set) var page: OnboardingPage = .welcome
    public var features: FeatureSettings
    public var duration: TimeInterval
    public private(set) var permissions: OnboardingPermissionState
    public private(set) var desktopCount = 1
    public private(set) var windowCount = 0
    public private(set) var workspacePracticed = false
    public private(set) var allWindowsPracticed = false
    public private(set) var shareAnonymousTelemetry: Bool
    private var didComplete = false
    private let permissionClient: any OnboardingPermissionClient
    private let onFeaturesChanged: @MainActor (FeatureSettings) -> Void
    private let onDurationChanged: @MainActor (TimeInterval) -> Void
    private let onPermissionStateChanged: @MainActor (OnboardingPermissionState) -> Void
    private let onProgressChanged: @MainActor (OnboardingCheckpoint) -> Void
    private let onCompleted: @MainActor () -> Void
    private let onTelemetryChanged: @MainActor (Bool) -> Void
    public var onEnvironmentRefresh: @MainActor () -> Void = {}
    public var onOpenMissionControl: @MainActor () -> Void = {}

    public init(
        permissionClient: any OnboardingPermissionClient,
        features: FeatureSettings = FeatureSettings(),
        onFeaturesChanged: @escaping @MainActor (FeatureSettings) -> Void = { _ in },
        duration: TimeInterval = 0,
        onDurationChanged: @escaping @MainActor (TimeInterval) -> Void = { _ in },
        shareAnonymousTelemetry: Bool = true,
        onTelemetryChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onPermissionStateChanged: @escaping @MainActor (OnboardingPermissionState) -> Void = { _ in },
        checkpoint: OnboardingCheckpoint? = nil,
        onProgressChanged: @escaping @MainActor (OnboardingCheckpoint) -> Void = { _ in },
        onCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.permissionClient = permissionClient
        self.permissions = permissionClient.currentState()
        self.features = features
        self.duration = duration
        self.onFeaturesChanged = onFeaturesChanged
        self.onDurationChanged = onDurationChanged
        self.shareAnonymousTelemetry = shareAnonymousTelemetry
        self.onTelemetryChanged = onTelemetryChanged
        self.onPermissionStateChanged = onPermissionStateChanged
        self.onCompleted = onCompleted
        self.onProgressChanged = onProgressChanged
        if let checkpoint {
            page = checkpoint.page
            workspacePracticed = checkpoint.workspacePracticed
            allWindowsPracticed = checkpoint.allWindowsPracticed
        }
    }

    public var canAdvance: Bool {
        if page == .welcome { return true }
        guard permissions.accessibilityGranted else { return false }
        switch page {
        case .workspace: return desktopCount >= 2 && workspacePracticed
        case .previews: return allWindowsPracticed && (!features.windowPreviews || permissions.screenRecordingGranted)
        case .speed, .ready: return true
        case .welcome: return true
        }
    }

    public func advance() {
        refreshPermissions()
        guard canAdvance, !didComplete else { return }
        if page == .ready {
            didComplete = true
            onCompleted()
        } else if let next = OnboardingPage(rawValue: page.rawValue + 1) {
            page = next
            if next == .workspace {
                var enabled = features
                enabled.workspaceIsolation = true
                setFeatures(enabled)
            }
            onEnvironmentRefresh()
            saveProgress()
        }
    }

    public func back() {
        if let previous = OnboardingPage(rawValue: page.rawValue - 1) { page = previous }
        refreshPermissions()
        onEnvironmentRefresh()
        saveProgress()
    }

    public func updateEnvironment(desktopCount: Int, windowCount: Int) {
        self.desktopCount = desktopCount
        self.windowCount = windowCount
    }

    /// Called only after an actual switcher selection has passed front-process verification.
    public func recordPractice(_ practice: OnboardingPractice) {
        guard permissions.accessibilityGranted else { return }
        if page == .workspace, practice == .workspace, desktopCount >= 2, windowCount > 0 {
            workspacePracticed = true
        }
        if page == .previews, practice == .allWindows { allWindowsPracticed = true }
        saveProgress()
    }

    private func saveProgress() {
        onProgressChanged(.init(page: page, workspacePracticed: workspacePracticed,
                                allWindowsPracticed: allWindowsPracticed))
    }

    public func setFeatures(_ features: FeatureSettings) {
        self.features = features
        onFeaturesChanged(features)
    }
    public func setAllOverrides(_ enabled: Bool) {
        var updated = features
        updated.workspaceIsolation = enabled
        updated.numberShortcuts = enabled
        updated.controlArrows = enabled
        updated.trackpadSwipes = enabled
        setFeatures(updated)
    }
    public func setDuration(_ duration: TimeInterval) {
        self.duration = min(AppSettings.maximumSpaceSwitchDuration, max(AppSettings.minimumSpaceSwitchDuration, duration))
        onDurationChanged(self.duration)
    }
    public func useWithoutPreviews() {
        var updated = features
        updated.windowPreviews = false
        setFeatures(updated)
    }
    public func setShareAnonymousTelemetry(_ enabled: Bool) {
        shareAnonymousTelemetry = enabled
        onTelemetryChanged(enabled)
    }
    public func requestAccessibility() {
        permissionClient.requestAccessibility()
        refreshPermissions()
    }
    public func requestScreenRecording() {
        permissionClient.requestScreenRecording()
        refreshPermissions()
        if permissions.screenRecordingGranted {
            var updated = features
            updated.windowPreviews = true
            setFeatures(updated)
        }
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
        min(700, max(0, visibleHeight - titleBarHeight))
    }
}
