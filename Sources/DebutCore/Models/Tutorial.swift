import Foundation
import Observation

public enum TutorialPage: Int, Sendable, Codable {
    case workspace = 1, previews = 2, ready = 4
}

public struct TutorialCheckpoint: Codable, Sendable {
    public let page: TutorialPage
    public var exercise: OnboardingExercise? = nil
    public let workspacePracticed: Bool
    public let allWindowsPracticed: Bool
}

@MainActor
@Observable
public final class TutorialViewModel {
    public private(set) var page: TutorialPage = .workspace
    public private(set) var exercise: OnboardingExercise = .switchWindow
    public private(set) var target: OnboardingTarget?
    public var targetError: String?
    public private(set) var lastResult: String?
    public var onRestartExercise: @MainActor () -> Void = {}
    public var features: FeatureSettings
    public private(set) var permissions: OnboardingPermissionState
    public private(set) var desktopCount = 1
    public private(set) var windowCount = 0
    public private(set) var workspacePracticed = false
    public private(set) var allWindowsPracticed = false
    private var didComplete = false
    private let permissionClient: any OnboardingPermissionClient
    private let onPermissionStateChanged: @MainActor (OnboardingPermissionState) -> Void
    private let onProgressChanged: @MainActor (TutorialCheckpoint) -> Void
    private let onCompleted: @MainActor () -> Void
    public var onEnvironmentRefresh: @MainActor () -> Void = {}

    public init(
        permissionClient: any OnboardingPermissionClient,
        features: FeatureSettings = FeatureSettings(),
        onPermissionStateChanged: @escaping @MainActor (OnboardingPermissionState) -> Void = { _ in },
        checkpoint: TutorialCheckpoint? = nil,
        onProgressChanged: @escaping @MainActor (TutorialCheckpoint) -> Void = { _ in },
        onCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.permissionClient = permissionClient
        self.permissions = permissionClient.currentState()
        self.features = features
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

    public var canAdvance: Bool { permissions.accessibilityGranted && page == .ready }
    public var shortcutEnabled: Bool {
        page == .previews ? features.optionTab : features.workspaceIsolation
    }

    public func advance() {
        refreshPermissions()
        guard canAdvance, !didComplete else { return }
        didComplete = true
        onCompleted()
    }

    public func skipExercise() {
        guard !didComplete, page != .ready else { return }
        if page == .workspace, desktopCount > 1, exercise != .moveWindow {
            exercise = exercise == .switchWindow ? .switchDesktop : .moveWindow
        } else { page = page == .workspace ? .previews : .ready }
        target = nil
        lastResult = nil
        saveProgress()
        onRestartExercise()
    }

    public func back() {
        guard !didComplete else { return }
        target = nil
        if page == .workspace, exercise != .switchWindow, desktopCount > 1 {
            exercise = exercise == .moveWindow ? .switchDesktop : .switchWindow
        } else if page == .ready { page = .previews }
        else if page == .previews { page = .workspace; exercise = .switchWindow }
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
        guard permissions.accessibilityGranted, shortcutEnabled, desktopCount >= 1,
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
        } else if page == .previews, practice == .allWindows {
            allWindowsPracticed = true
            page = .ready
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

    public func requestAccessibility() {
        permissionClient.requestAccessibility()
        refreshPermissions()
    }
    public func refreshPermissions() {
        permissions = permissionClient.currentState()
        onPermissionStateChanged(permissions)
    }
}

