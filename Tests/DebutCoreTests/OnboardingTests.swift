import Foundation
import Testing
@testable import DebutCore

@MainActor
private final class MockOnboardingPermissionClient: OnboardingPermissionClient {
    var state = OnboardingPermissionState(
        accessibilityGranted: false,
        screenRecordingGranted: false
    )
    var accessibilityRequestCount = 0
    var screenRecordingRequestCount = 0

    func currentState() -> OnboardingPermissionState {
        state
    }

    func requestAccessibility() {
        accessibilityRequestCount += 1
    }

    func requestScreenRecording() {
        screenRecordingRequestCount += 1
    }
}

@MainActor
@Suite("Onboarding")
struct OnboardingTests {
    @Test("Welcome explains that Debut replaces the system app switcher")
    func startsWithIntroduction() {
        let viewModel = OnboardingViewModel(permissionClient: MockOnboardingPermissionClient())

        #expect(viewModel.page == .welcome)
        #expect(viewModel.introduction.contains("Command–Tab"))
        #expect(viewModel.introduction.contains("windows and stages"))
    }

    @Test("Accessibility and screen recording are both required")
    func permissionGate() {
        let permissions = MockOnboardingPermissionClient()
        let viewModel = OnboardingViewModel(permissionClient: permissions)
        viewModel.continueFromWelcome()

        #expect(viewModel.page == .permissions)
        #expect(!viewModel.canStartTutorial)
        viewModel.startTutorial()
        #expect(viewModel.page == .permissions)

        // Accessibility alone is not enough: without screen recording the desktop
        // surface cannot read the wallpaper and renders as a black rectangle.
        permissions.state = OnboardingPermissionState(
            accessibilityGranted: true,
            screenRecordingGranted: false
        )
        viewModel.refreshPermissions()

        #expect(!viewModel.canStartTutorial)
        viewModel.startTutorial()
        #expect(viewModel.page == .permissions)

        permissions.state = OnboardingPermissionState(
            accessibilityGranted: true,
            screenRecordingGranted: true
        )
        viewModel.refreshPermissions()

        #expect(viewModel.canStartTutorial)
        viewModel.startTutorial()
        #expect(viewModel.page == .tutorial)
    }

    @Test("Screen recording is presented as required and explains the wallpaper")
    func screenRecordingIsRequired() {
        let viewModel = OnboardingViewModel(permissionClient: MockOnboardingPermissionClient())

        #expect(viewModel.screenRecordingRequirement.isRequired)
        #expect(viewModel.screenRecordingRequirement.detail.contains("wallpaper"))
        #expect(viewModel.screenRecordingRequirement.detail.contains("never"))
    }

    @Test("Permission requests are explicit user actions")
    func requestsPermissions() {
        let permissions = MockOnboardingPermissionClient()
        let viewModel = OnboardingViewModel(permissionClient: permissions)

        viewModel.requestAccessibility()
        viewModel.requestScreenRecording()

        #expect(permissions.accessibilityRequestCount == 1)
        #expect(permissions.screenRecordingRequestCount == 1)
    }

    @Test("Anonymous sharing choice is visible and immediately reversible")
    func anonymousSharingChoice() {
        let permissions = MockOnboardingPermissionClient()
        var observed: [Bool] = []
        let viewModel = OnboardingViewModel(
            permissionClient: permissions,
            shareAnonymousTelemetry: true,
            onTelemetryChanged: { observed.append($0) }
        )

        #expect(viewModel.shareAnonymousTelemetry)
        viewModel.setShareAnonymousTelemetry(false)
        #expect(!viewModel.shareAnonymousTelemetry)
        #expect(observed == [false])
    }

    @Test("Permission state changes are published immediately")
    func publishesPermissionChanges() {
        let permissions = MockOnboardingPermissionClient()
        var observedState: OnboardingPermissionState?
        let viewModel = OnboardingViewModel(
            permissionClient: permissions,
            onPermissionStateChanged: { observedState = $0 }
        )
        permissions.state = OnboardingPermissionState(
            accessibilityGranted: true,
            screenRecordingGranted: false
        )

        viewModel.refreshPermissions()

        #expect(observedState?.accessibilityGranted == true)
    }

    @Test("Tutorial walks through switching, stage creation, and moving a window")
    func tutorialSequence() {
        let permissions = MockOnboardingPermissionClient()
        permissions.state = OnboardingPermissionState(
            accessibilityGranted: true,
            screenRecordingGranted: true
        )
        var completionCount = 0
        let viewModel = OnboardingViewModel(
            permissionClient: permissions,
            onCompleted: { completionCount += 1 }
        )

        viewModel.continueFromWelcome()
        viewModel.startTutorial()
        #expect(viewModel.tutorialStep == .switchWindows)

        viewModel.advanceTutorial()
        #expect(viewModel.tutorialStep == .createStage)

        viewModel.advanceTutorial()
        #expect(viewModel.tutorialStep == .moveWindow)

        viewModel.advanceTutorial()
        #expect(completionCount == 1)
        viewModel.advanceTutorial()
        #expect(completionCount == 1)
    }

    @Test("A new install resumes onboarding until completion")
    func launchPolicy() throws {
        let suiteName = "DebutOnboardingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(OnboardingLaunchPolicy.shouldPresent(defaults: defaults))
        #expect(defaults.object(forKey: OnboardingLaunchPolicy.completionKey) == nil)

        OnboardingLaunchPolicy.markCompleted(defaults: defaults)

        #expect(!OnboardingLaunchPolicy.shouldPresent(defaults: defaults))
    }

    @Test("Existing users migrate without seeing first-launch onboarding")
    func legacyLaunchMigration() throws {
        let suiteName = "DebutOnboardingLegacyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: OnboardingLaunchPolicy.legacyLaunchKey)

        #expect(!OnboardingLaunchPolicy.shouldPresent(defaults: defaults))
        #expect(defaults.bool(forKey: OnboardingLaunchPolicy.completionKey))
        #expect(OnboardingLaunchPolicy.shouldPresent(defaults: defaults, force: true))
    }
}
