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
    @Test("Preview warmup never asks for a permission before its lesson")
    func captureGate() {
        #expect(!OnboardingCapturePolicy.isEnabled(previewsRequested: true, screenRecordingGranted: false))
        #expect(!OnboardingCapturePolicy.isEnabled(previewsRequested: false, screenRecordingGranted: true))
        #expect(OnboardingCapturePolicy.isEnabled(previewsRequested: true, screenRecordingGranted: true))
    }

    private func finishWorkspace(_ model: OnboardingViewModel) {
        for action in [OnboardingPractice.workspace, .desktop, .moveWindow] {
            model.setTarget(.init(windowID: 42, originDesktop: action == .workspace ? 1 : 0, destinationDesktop: 1, title: "Next lesson"))
            model.recordPractice(action, windowID: 42, desktopIndex: 1)
        }
    }
    private func finishPreviews(_ model: OnboardingViewModel) {
        model.setTarget(.init(windowID: 43, originDesktop: 0, destinationDesktop: 1, title: "Instant desktop switching"))
        model.recordPractice(.allWindows, windowID: 43, desktopIndex: 1)
    }

    @Test("A permission restart resumes the exact exercise without bypassing permission checks")
    func resumesAfterPermissionRestart() throws {
        let permissions = MockOnboardingPermissionClient()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        var checkpoint: OnboardingCheckpoint?
        let model = OnboardingViewModel(permissionClient: permissions, onProgressChanged: { checkpoint = $0 })
        model.advance()
        model.updateEnvironment(desktopCount: 2, windowCount: 2)
        model.setTarget(.init(windowID: 42, originDesktop: 0, destinationDesktop: 0, title: "Desktop switching"))
        model.recordPractice(.workspace, windowID: 42, desktopIndex: 0)
        let restored = try JSONDecoder().decode(OnboardingCheckpoint.self, from: JSONEncoder().encode(try #require(checkpoint)))
        let resumed = OnboardingViewModel(permissionClient: permissions, checkpoint: restored)
        #expect(resumed.page == .workspace)
        #expect(resumed.exercise == .switchDesktop)
        #expect(resumed.target == nil)
        permissions.state = .init(accessibilityGranted: false, screenRecordingGranted: true)
        resumed.refreshPermissions()
        #expect(!resumed.canAdvance)
    }

    @Test("Accessibility is mandatory, while capture can be declined")
    func permissionGate() {
        let permissions = MockOnboardingPermissionClient()
        let model = OnboardingViewModel(permissionClient: permissions)
        model.advance()
        model.updateEnvironment(desktopCount: 2, windowCount: 2)
        finishWorkspace(model)
        #expect(model.page == .workspace)
        #expect(model.exercise == .switchWindow)
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        model.refreshPermissions()
        finishWorkspace(model)
        #expect(model.page == .previews)
        finishPreviews(model)
        #expect(model.page == .previews)
        model.useWithoutPreviews()
        #expect(!model.features.windowPreviews)
        finishPreviews(model)
        #expect(model.page == .speed)
    }

    @Test("Revoking Accessibility blocks every later page")
    func revokedPermission() {
        for page in [OnboardingPage.previews, .speed, .ready] {
            let permissions = MockOnboardingPermissionClient()
            let model = OnboardingViewModel(permissionClient: permissions,
                checkpoint: .init(page: page, workspacePracticed: true, allWindowsPracticed: true))
            model.updateEnvironment(desktopCount: 2, windowCount: 2)
            finishPreviews(model)
            model.advance()
            #expect(model.page == page)
            #expect(!model.canAdvance)
        }
    }

    @Test("Live feature and duration choices publish immediately and completion is explicit")
    func liveSettingsAndCompletion() {
        let permissions = MockOnboardingPermissionClient()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: true)
        var changes: [FeatureSettings] = []
        var durations: [TimeInterval] = []
        var completed = 0
        let model = OnboardingViewModel(permissionClient: permissions,
            onFeaturesChanged: { changes.append($0) },
            onDurationChanged: { durations.append($0) },
            onCompleted: { completed += 1 })
        model.advance()
        model.updateEnvironment(desktopCount: 2, windowCount: 2)
        finishWorkspace(model)
        finishPreviews(model)
        #expect(model.page == .speed)
        model.setDuration(0.25)
        #expect(durations == [0.25])
        model.setAllOverrides(false)
        #expect(changes.last?.workspaceIsolation == false)
        #expect(changes.last?.numberShortcuts == false)
        #expect(changes.last?.controlArrows == false)
        #expect(changes.last?.trackpadSwipes == false)
        model.advance()
        #expect(model.page == .ready)
        #expect(completed == 0)
        model.advance()
        model.advance()
        #expect(completed == 1)
    }

    @Test("Permission and telemetry requests remain explicit")
    func explicitChoices() {
        let permissions = MockOnboardingPermissionClient()
        var sharing: [Bool] = []
        let model = OnboardingViewModel(permissionClient: permissions,
            onTelemetryChanged: { sharing.append($0) })
        #expect(permissions.accessibilityRequestCount == 0)
        #expect(permissions.screenRecordingRequestCount == 0)
        model.requestAccessibility()
        model.requestScreenRecording()
        #expect(permissions.accessibilityRequestCount == 1)
        #expect(permissions.screenRecordingRequestCount == 1)
        model.setShareAnonymousTelemetry(false)
        #expect(sharing == [false])
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

    @Test("Completion is only reported once onboarding has actually finished")
    func completionIsReportedAfterFinishing() throws {
        let suiteName = "DebutOnboardingCompletionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!OnboardingLaunchPolicy.hasCompleted(defaults: defaults))
        OnboardingLaunchPolicy.markCompleted(defaults: defaults)
        #expect(OnboardingLaunchPolicy.hasCompleted(defaults: defaults))
    }

    @Test("A migrated user counts as completed without re-running onboarding")
    func migratedUserCountsAsCompleted() throws {
        let suiteName = "DebutOnboardingMigratedTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: OnboardingLaunchPolicy.legacyLaunchKey)

        // Reading completion must not depend on `shouldPresent` having run first,
        // or an existing user's telemetry stays gated until the next launch.
        #expect(OnboardingLaunchPolicy.hasCompleted(defaults: defaults))
    }
}

@Suite("TelemetryActivationPolicy")
struct TelemetryActivationPolicyTests {

    @Test("Nothing is sent before onboarding completes, even with the setting on")
    func onboardingGatesSending() {
        #expect(!TelemetryActivationPolicy.shouldSend(setting: true, onboardingCompleted: false))
    }

    @Test("Proceeding through onboarding without opting out starts sending")
    func completingOnboardingEnablesSending() {
        #expect(TelemetryActivationPolicy.shouldSend(setting: true, onboardingCompleted: true))
    }

    @Test("Opting out wins regardless of onboarding state")
    func optingOutWins() {
        #expect(!TelemetryActivationPolicy.shouldSend(setting: false, onboardingCompleted: true))
        #expect(!TelemetryActivationPolicy.shouldSend(setting: false, onboardingCompleted: false))
    }
}

@Test("Onboarding leaves its title bar and footer inside a small visible screen")
func onboardingSmallScreen() {
    #expect(OnboardingLayout.contentHeight(visibleHeight: 670, titleBarHeight: 28) == 642)
    #expect(OnboardingLayout.contentHeight(visibleHeight: 900, titleBarHeight: 28) == 650)
}
