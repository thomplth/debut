import Foundation
import Observation

public enum OnboardingPage: Int, CaseIterable, Sendable, Codable {
    case welcome, workspace, previews, speed, ready
}

public enum OnboardingPermission: String, Codable, Sendable {
    case accessibility
    case screenRecording
}

public struct OnboardingPermissionReturn: Codable, Equatable, Sendable {
    public let version: Int
    public let permission: OnboardingPermission
    public let page: OnboardingPage
    public let processID: String

    public init(
        version: Int = 1,
        permission: OnboardingPermission,
        page: OnboardingPage,
        processID: String
    ) {
        self.version = version
        self.permission = permission
        self.page = page
        self.processID = processID
    }
}

public enum OnboardingPermissionReturnStore {
    public static let key = "setupPermissionReturn"

    @discardableResult
    public static func save(
        permission: OnboardingPermission,
        page: OnboardingPage,
        processID: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(OnboardingPermissionReturn(
            permission: permission,
            page: page,
            processID: processID
        )) else { return false }
        defaults.set(data, forKey: key)
        return defaults.synchronize()
    }

    public static func pending(defaults: UserDefaults = .standard) -> OnboardingPermissionReturn? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let intent = try? JSONDecoder().decode(OnboardingPermissionReturn.self, from: data),
              intent.version == 1 else {
            clear(defaults: defaults)
            return nil
        }
        return intent
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        _ = defaults.synchronize()
    }
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
    public var spaceSwitchDuration: TimeInterval
    public private(set) var permissions: OnboardingPermissionState
    public private(set) var desktopCount: Int?
    public private(set) var screenRecordingRequiresRelaunch = false
    public var onEnvironmentRefresh: @MainActor () -> Void = {}
    private var didComplete = false
    private let permissionClient: any OnboardingPermissionClient
    private let onSpaceSwitchDurationChanged: @MainActor (TimeInterval) -> Void
    private let onFeaturesChanged: @MainActor (FeatureSettings) -> Void
    private let onPermissionStateChanged: @MainActor (OnboardingPermissionState) -> Void
    private let onPermissionRequestWillStart: @MainActor (OnboardingPermission, OnboardingPage) -> Bool
    private let onPermissionRequestDidStart: @MainActor (OnboardingPermission) -> Void
    private let onPermissionHandoffCancelled: @MainActor (OnboardingPermission) -> Void
    private let onRestartDebut: @MainActor () -> Void
    private let onProgressChanged: @MainActor (OnboardingCheckpoint) -> Void
    private let onCompleted: @MainActor () -> Void
    private let onDestination: @MainActor (OnboardingDestination) -> Void
    private var requestedScreenRecordingInThisProcess = false

    public init(
        permissionClient: any OnboardingPermissionClient,
        features: FeatureSettings = FeatureSettings(),
        spaceSwitchDuration: TimeInterval = AppSettings.defaultSpaceSwitchDuration,
        onSpaceSwitchDurationChanged: @escaping @MainActor (TimeInterval) -> Void = { _ in },
        onFeaturesChanged: @escaping @MainActor (FeatureSettings) -> Void = { _ in },
        onPermissionStateChanged: @escaping @MainActor (OnboardingPermissionState) -> Void = { _ in },
        onPermissionRequestWillStart: @escaping @MainActor (OnboardingPermission, OnboardingPage) -> Bool = { _, _ in true },
        onPermissionRequestDidStart: @escaping @MainActor (OnboardingPermission) -> Void = { _ in },
        onPermissionHandoffCancelled: @escaping @MainActor (OnboardingPermission) -> Void = { _ in },
        onRestartDebut: @escaping @MainActor () -> Void = {},
        checkpoint: OnboardingCheckpoint? = nil,
        onProgressChanged: @escaping @MainActor (OnboardingCheckpoint) -> Void = { _ in },
        onCompleted: @escaping @MainActor () -> Void = {},
        onDestination: @escaping @MainActor (OnboardingDestination) -> Void = { _ in }
    ) {
        self.permissionClient = permissionClient
        self.permissions = permissionClient.currentState()
        self.features = features
        self.spaceSwitchDuration = spaceSwitchDuration
        self.onSpaceSwitchDurationChanged = onSpaceSwitchDurationChanged
        self.page = checkpoint?.page ?? .welcome
        self.onFeaturesChanged = onFeaturesChanged
        self.onPermissionStateChanged = onPermissionStateChanged
        self.onPermissionRequestWillStart = onPermissionRequestWillStart
        self.onPermissionRequestDidStart = onPermissionRequestDidStart
        self.onPermissionHandoffCancelled = onPermissionHandoffCancelled
        self.onRestartDebut = onRestartDebut
        self.onProgressChanged = onProgressChanged
        self.onCompleted = onCompleted
        self.onDestination = onDestination
    }

    public var canAdvance: Bool { permissions.accessibilityGranted }
    public var showsDesktopGuidance: Bool { page == .workspace && desktopCount == 1 }
    public var showsWindowPreviews: Bool {
        features.windowPreviews && permissions.screenRecordingGranted && !screenRecordingRequiresRelaunch
    }

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

    public func setSpaceSwitchDuration(_ duration: TimeInterval) {
        guard duration.isFinite else { return }
        let value = min(AppSettings.maximumSpaceSwitchDuration, max(AppSettings.minimumSpaceSwitchDuration, duration))
        guard spaceSwitchDuration != value else { return }
        spaceSwitchDuration = value
        onSpaceSwitchDurationChanged(value)
    }

    public func requestAccessibility() {
        onProgressChanged(.init(page: page))
        guard onPermissionRequestWillStart(.accessibility, page) else { return }
        permissionClient.requestAccessibility()
        onPermissionRequestDidStart(.accessibility)
        refreshPermissions()
    }

    public func requestScreenRecording() {
        onProgressChanged(.init(page: page))
        guard onPermissionRequestWillStart(.screenRecording, page) else { return }
        requestedScreenRecordingInThisProcess = true
        permissionClient.requestScreenRecording()
        onPermissionRequestDidStart(.screenRecording)
        refreshPermissions()
    }

    public func cancelPermissionHandoff(_ permission: OnboardingPermission) {
        onPermissionHandoffCancelled(permission)
    }

    public func restartDebut() {
        guard screenRecordingRequiresRelaunch else { return }
        onRestartDebut()
    }

    public func refreshPermissions() {
        permissions = permissionClient.currentState()
        screenRecordingRequiresRelaunch = requestedScreenRecordingInThisProcess
            && permissions.screenRecordingGranted
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
        if OnboardingPermissionReturnStore.pending(defaults: defaults) != nil { return true }
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
