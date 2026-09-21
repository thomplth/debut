import Foundation
import Testing
@testable import DebutCore

@MainActor
@Suite("Minimal setup")
struct SetupFlowTests {
    final class Permissions: OnboardingPermissionClient {
        var state = OnboardingPermissionState(accessibilityGranted: false, screenRecordingGranted: false)
        func currentState() -> OnboardingPermissionState { state }
        var accessibilityRequests = 0
        var captureRequests = 0
        func requestAccessibility() { accessibilityRequests += 1 }
        func requestScreenRecording() { captureRequests += 1 }
    }

    @Test("Welcome requires Accessibility and never requires screen capture")
    func welcomePermissions() {
        let permissions = Permissions()
        let model = OnboardingViewModel(permissionClient: permissions)
        #expect(!model.canAdvance)
        model.advance()
        #expect(model.page == .welcome)
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        model.advance()
        #expect(model.page == .workspace)
        #expect(model.canAdvance)
    }

    @Test("Setup finishes all five pages without an exercise or capture permission")
    func finishWithoutPractice() {
        let permissions = Permissions()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        var completed = 0
        let model = OnboardingViewModel(permissionClient: permissions, onCompleted: { completed += 1 })
        for page in OnboardingPage.allCases {
            #expect(model.page == page)
            #expect(model.canAdvance)
            model.advance()
        }
        model.advance()
        #expect(completed == 1)
    }

    @Test("Back and forward preserve disabled feature preferences")
    func preferencesSurviveNavigation() {
        let permissions = Permissions()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        var features = FeatureSettings()
        features.workspaceIsolation = false
        let model = OnboardingViewModel(permissionClient: permissions, features: features)
        model.advance()
        #expect(!model.features.workspaceIsolation)
        model.advance()
        model.back()
        #expect(!model.features.workspaceIsolation)
    }
    @Test("The single desktop callout follows topology and appears only on Command-Tab")
    func guidance() {
        let permissions = Permissions()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        let model = OnboardingViewModel(permissionClient: permissions)
        #expect(!model.showsDesktopGuidance)
        model.advance()
        #expect(!model.showsDesktopGuidance)
        model.updateEnvironment(desktopCount: 1)
        #expect(model.showsDesktopGuidance)
        model.updateEnvironment(desktopCount: 2)
        #expect(!model.showsDesktopGuidance)
        model.updateEnvironment(desktopCount: 1)
        model.advance()
        #expect(!model.showsDesktopGuidance)
    }

    @Test("Every final action completes setup before opening the destination", arguments: [OnboardingDestination.useDebut, .tutorial, .settings])
    func completionBeforeDestination(_ destination: OnboardingDestination) {
        let permissions = Permissions()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        var events: [String] = []
        let model = OnboardingViewModel(permissionClient: permissions, checkpoint: .init(page: .ready),
            onCompleted: { events.append("complete") }, onDestination: { _ in events.append("destination") })
        model.finish(destination)
        model.finish(destination)
        #expect(events == ["complete", "destination"])
    }

    @Test("Master toggle preserves granular desktop choices and independent switchers")
    func masterToggle() {
        var features = FeatureSettings()
        features.numberShortcuts = false
        let model = OnboardingViewModel(permissionClient: Permissions(), features: features)
        features.fasterDesktopSwitching = false
        model.setFeatures(features)
        #expect(!model.features.fasterDesktopSwitching)
        #expect(!model.features.numberShortcuts)
        #expect(model.features.controlArrows && model.features.trackpadSwipes)
        #expect(model.features.workspaceIsolation && model.features.optionTab)
    }

    @Test("New Option-Tab preference round trips and older settings retain the enabled default")
    func optionPreference() throws {
        #expect(try JSONDecoder().decode(FeatureSettings.self, from: Data("{}".utf8)).optionTab)
        var features = FeatureSettings()
        features.optionTab = false
        #expect(try !JSONDecoder().decode(FeatureSettings.self, from: JSONEncoder().encode(features)).optionTab)
    }

    @Test("Tutorial skips and resumes without enabling shortcuts or touching setup completion")
    func independentTutorial() throws {
        let permissions = Permissions()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        var features = FeatureSettings()
        features.workspaceIsolation = false
        features.optionTab = false
        var checkpoint: TutorialCheckpoint?
        let model = TutorialViewModel(permissionClient: permissions, features: features, onProgressChanged: { checkpoint = $0 })
        model.updateEnvironment(desktopCount: 1, windowCount: 2)
        model.skipExercise()
        #expect(model.page == .previews)
        let saved = try JSONDecoder().decode(TutorialCheckpoint.self, from: JSONEncoder().encode(try #require(checkpoint)))
        let resumed = TutorialViewModel(permissionClient: permissions, features: features, checkpoint: saved)
        resumed.back()
        #expect(resumed.features == features)
        model.skipExercise()
        #expect(model.page == .ready)
        #expect(model.features == features)
    }

    @Test("One desktop tutorial can practice both switchers without capture permission")
    func oneDesktopTutorial() {
        let permissions = Permissions()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        let model = TutorialViewModel(permissionClient: permissions)
        model.updateEnvironment(desktopCount: 1, windowCount: 2)
        model.setTarget(.init(windowID: 42, originDesktop: 0, destinationDesktop: 0, title: "Option-Tab"))
        #expect(model.recordPractice(.workspace, windowID: 42, desktopIndex: 0))
        model.setTarget(.init(windowID: 43, originDesktop: 0, destinationDesktop: 0, title: "Complete"))
        #expect(model.recordPractice(.allWindows, windowID: 43, desktopIndex: 0))
        #expect(model.page == .ready)
    }

    @Test("Permission requests are explicit and revocation blocks every setup page")
    func explicitPermissionsAndRevocation() {
        let permissions = Permissions()
        for page in OnboardingPage.allCases {
            var completed = false
            let model = OnboardingViewModel(permissionClient: permissions, checkpoint: .init(page: page),
                onCompleted: { completed = true })
            model.advance()
            model.finish(.tutorial)
            #expect(model.page == page)
            #expect(!completed)
            #expect(!model.canAdvance)
        }
        #expect(permissions.accessibilityRequests == 0 && permissions.captureRequests == 0)
        let model = OnboardingViewModel(permissionClient: permissions)
        model.requestAccessibility()
        model.requestScreenRecording()
        #expect(permissions.accessibilityRequests == 1 && permissions.captureRequests == 1)
    }

    @Test("Setup resumes its own checkpoint after a permission restart")
    func setupResume() throws {
        let permissions = Permissions()
        permissions.state = .init(accessibilityGranted: true, screenRecordingGranted: false)
        var checkpoint: OnboardingCheckpoint?
        let model = OnboardingViewModel(permissionClient: permissions, onProgressChanged: { checkpoint = $0 })
        model.advance()
        model.advance()
        let saved = try JSONDecoder().decode(OnboardingCheckpoint.self, from: JSONEncoder().encode(try #require(checkpoint)))
        let resumed = OnboardingViewModel(permissionClient: permissions, checkpoint: saved)
        #expect(resumed.page == .previews)
        #expect(resumed.canAdvance)
    }

}
