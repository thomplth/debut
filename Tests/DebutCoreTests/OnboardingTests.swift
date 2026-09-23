import Foundation
import Testing
@testable import DebutCore

@MainActor
@Suite("Onboarding lifecycle")
struct OnboardingTests {
    final class ScreenRecordingGrant: OnboardingPermissionClient {
        var state = OnboardingPermissionState(accessibilityGranted: true, screenRecordingGranted: false)
        func currentState() -> OnboardingPermissionState { state }
        func requestAccessibility() {}
        func requestScreenRecording() {
            state = OnboardingPermissionState(accessibilityGranted: true, screenRecordingGranted: true)
        }
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

        // Reading completion must not depend on `shouldPresent` having run first.
        #expect(OnboardingLaunchPolicy.hasCompleted(defaults: defaults))
    }

    @Test("A pending permission return reopens setup for a completed user")
    func permissionReturnOverridesCompletion() throws {
        let suiteName = "DebutOnboardingPermissionReturnTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let marker = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "permission": "screenRecording",
            "page": OnboardingPage.previews.rawValue,
            "processID": "previous-process",
        ])
        defaults.set(true, forKey: OnboardingLaunchPolicy.completionKey)
        defaults.set(marker, forKey: "setupPermissionReturn")

        #expect(OnboardingLaunchPolicy.shouldPresent(defaults: defaults))
    }

    @Test("A newly granted Screen Recording permission waits for a new process before previews")
    func screenRecordingRequiresRelaunch() {
        let permissions = ScreenRecordingGrant()
        let model = OnboardingViewModel(permissionClient: permissions)

        #expect(!model.showsWindowPreviews)
        model.requestScreenRecording()
        #expect(permissions.currentState().screenRecordingGranted)
        #expect(!model.showsWindowPreviews)
    }

    @Test("Permission guides open the matching System Settings panes")
    func permissionSettingsURLs() throws {
        let client = SystemOnboardingPermissionClient()

        #expect(try #require(client.settingsURL(for: .accessibility)?.absoluteString)
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(try #require(client.settingsURL(for: .screenRecording)?.absoluteString)
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test("Capture is optional and never requested without consent")
    func captureGate() {
        #expect(!OnboardingCapturePolicy.isEnabled(previewsRequested: true, screenRecordingGranted: false))
        #expect(!OnboardingCapturePolicy.isEnabled(previewsRequested: false, screenRecordingGranted: true))
        #expect(OnboardingCapturePolicy.isEnabled(previewsRequested: true, screenRecordingGranted: true))
    }
}

@Test("Onboarding leaves its title bar and footer inside a small visible screen")
func onboardingSmallScreen() {
    #expect(OnboardingLayout.contentHeight(visibleHeight: 670, titleBarHeight: 28) == 642)
    #expect(OnboardingLayout.contentHeight(visibleHeight: 900, titleBarHeight: 28) == 650)
}
