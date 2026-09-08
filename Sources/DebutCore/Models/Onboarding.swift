import Foundation
import Observation

public enum OnboardingPage: Int, CaseIterable, Sendable, Codable {
    case welcome, workspace, previews, speed, ready
}

public struct OnboardingCheckpoint: Codable, Sendable {
    public let page: OnboardingPage
    public var exercise: OnboardingExercise? = nil
    public let workspacePracticed: Bool
    public let allWindowsPracticed: Bool
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

@MainActor
@Observable
public final class OnboardingViewModel {
    public private(set) var page: OnboardingPage = .welcome
    public private(set) var exercise: OnboardingExercise = .switchWindow
    public private(set) var target: OnboardingTarget?
    public var targetError: String?
    public private(set) var lastResult: String?
    public var onRestartExercise: @MainActor () -> Void = {}
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
            exercise = checkpoint.exercise ?? .switchWindow
            workspacePracticed = checkpoint.workspacePracticed
            allWindowsPracticed = checkpoint.allWindowsPracticed
        }
    }

    public var canAdvance: Bool {
        if page == .welcome { return true }
        guard permissions.accessibilityGranted else { return false }
        switch page {
        case .workspace: return false
        case .previews: return false
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
        target = nil
        if page == .workspace, exercise != .switchWindow, desktopCount > 1 {
            exercise = exercise == .moveWindow ? .switchDesktop : .switchWindow
        } else if let previous = OnboardingPage(rawValue: page.rawValue - 1) { page = previous }
        if page == .workspace {
            if desktopCount < 2 { exercise = .switchWindow }
            var enabled = features
            enabled.workspaceIsolation = true
            setFeatures(enabled)
        }
        lastResult = nil
        refreshPermissions()
        onRestartExercise()
        onEnvironmentRefresh()
        saveProgress()
    }

    public func updateEnvironment(desktopCount: Int, windowCount: Int) {
        self.desktopCount = desktopCount
        self.windowCount = windowCount
        if desktopCount < 2, page == .workspace, exercise != .switchWindow {
            exercise = .switchWindow
            target = nil
            targetError = nil
        }
    }

    public func setTarget(_ target: OnboardingTarget?) {
        self.target = target
        targetError = nil
    }

    /// The app supplies the selected window, confirmed desktop and actual switcher action.
    /// Merely opening the overlay, clicking a destination, or choosing another window cannot pass.
    @discardableResult
    public func recordPractice(_ practice: OnboardingPractice, windowID: UInt32, desktopIndex: Int) -> Bool {
        guard permissions.accessibilityGranted, desktopCount >= 1,
              let target, target.windowID == windowID,
              target.destinationDesktop == desktopIndex else { return false }
        let changesDesktop = target.originDesktop != target.destinationDesktop
        switch practice {
        case .workspace: guard !changesDesktop else { return false }
        case .allWindows: guard changesDesktop || desktopCount == 1 else { return false }
        case .desktop, .moveWindow: guard desktopCount > 1, changesDesktop else { return false }
        }
        if page == .workspace {
            switch (exercise, practice) {
            case (.switchWindow, .workspace):
                if desktopCount == 1 {
                    workspacePracticed = true
                    page = .previews
                } else { exercise = .switchDesktop }
            case (.switchDesktop, .desktop): exercise = .moveWindow
            case (.moveWindow, .moveWindow):
                workspacePracticed = true
                page = .previews
            default: return false
            }
        } else if page == .previews, practice == .allWindows,
                  !features.windowPreviews || permissions.screenRecordingGranted {
            allWindowsPracticed = true
            page = .speed
        } else { return false }
        lastResult = switch practice {
        case .workspace: "You selected this window with Command-Tab."
        case .desktop: "You switched from Desktop \(target.originDesktop + 1) to Desktop \(desktopIndex + 1)."
        case .moveWindow: "You moved this window from Desktop \(target.originDesktop + 1) to Desktop \(desktopIndex + 1)."
        case .allWindows: "You opened this window on Desktop \(desktopIndex + 1) with Option-Tab."
        }
        self.target = nil
        saveProgress()
        return true
    }

    private func saveProgress() {
        onProgressChanged(.init(page: page, exercise: exercise, workspacePracticed: workspacePracticed,
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
        min(650, max(0, visibleHeight - titleBarHeight))
    }
}
