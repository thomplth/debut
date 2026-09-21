import Foundation
import Testing
@testable import DebutCore

@MainActor
@Suite("Onboarding lifecycle")
struct OnboardingTests {
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
