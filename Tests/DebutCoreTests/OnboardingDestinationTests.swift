import Testing
@testable import DebutCore

@MainActor
@Suite("Onboarding destinations")
struct OnboardingDestinationTests {
    final class Permissions: OnboardingPermissionClient {
        var state = OnboardingPermissionState(accessibilityGranted: true, screenRecordingGranted: true)
        func currentState() -> OnboardingPermissionState { state }
        func requestAccessibility() {}
        func requestScreenRecording() {}
    }

    @Test("Only the named destination reached with the taught action advances a lesson")
    func preciseDestination() {
        let model = OnboardingViewModel(permissionClient: Permissions())
        model.advance()
        model.updateEnvironment(desktopCount: 2, windowCount: 2)
        model.setTarget(.init(windowID: 42, originDesktop: 0, destinationDesktop: 0, title: "Desktop switching"))
        #expect(!model.recordPractice(.workspace, windowID: 7, desktopIndex: 0))
        #expect(!model.recordPractice(.allWindows, windowID: 42, desktopIndex: 0))
        #expect(!model.recordPractice(.workspace, windowID: 42, desktopIndex: 1))
        #expect(model.exercise == .switchWindow)
        #expect(model.recordPractice(.workspace, windowID: 42, desktopIndex: 0))
        #expect(model.exercise == .switchDesktop)
        #expect(model.target == nil)
    }

    @Test("The complete desktop lesson requires a desktop switch and a real window move")
    func completeDesktopLesson() {
        let model = OnboardingViewModel(permissionClient: Permissions())
        model.advance()
        model.updateEnvironment(desktopCount: 2, windowCount: 2)
        for (action, destination) in [(OnboardingPractice.workspace, 0), (.desktop, 1), (.moveWindow, 0)] {
            model.setTarget(.init(windowID: 42, originDesktop: action == .workspace ? destination : 1 - destination, destinationDesktop: destination, title: "Next lesson"))
            #expect(!model.canAdvance)
            #expect(model.recordPractice(action, windowID: 42, desktopIndex: destination))
        }
        #expect(model.page == .previews)
        model.setTarget(.init(windowID: 50, originDesktop: 0, destinationDesktop: 1, title: "Instant desktop switching"))
        #expect(!model.recordPractice(.workspace, windowID: 50, desktopIndex: 1))
        #expect(model.recordPractice(.allWindows, windowID: 50, desktopIndex: 1))
        #expect(model.page == .speed)
    }

    @Test("Permissions and desktop preconditions cannot be bypassed by a target event")
    func permissions() {
        let permissions = Permissions()
        let model = OnboardingViewModel(permissionClient: permissions)
        model.advance()
        model.updateEnvironment(desktopCount: 0, windowCount: 0)
        model.setTarget(.init(windowID: 42, originDesktop: 0, destinationDesktop: 0, title: "Next lesson"))
        #expect(!model.recordPractice(.workspace, windowID: 42, desktopIndex: 0))
        model.updateEnvironment(desktopCount: 2, windowCount: 2)
        permissions.state = .init(accessibilityGranted: false, screenRecordingGranted: true)
        model.refreshPermissions()
        #expect(!model.recordPractice(.workspace, windowID: 42, desktopIndex: 0))
    }
    @Test("Going back to required practice restores the Command-Tab switcher")
    func replayRestoresShortcut() {
        let model = OnboardingViewModel(permissionClient: Permissions(),
            checkpoint: .init(page: .previews, workspacePracticed: true, allWindowsPracticed: false))
        model.setAllOverrides(false)
        model.back()
        #expect(model.features.workspaceIsolation)
    }

    @Test("A desktop exercise cannot complete on its starting desktop")
    func desktopRequiresDifferentDestination() {
        let model = OnboardingViewModel(permissionClient: Permissions(),
            checkpoint: .init(page: .workspace, exercise: .switchDesktop, workspacePracticed: false, allWindowsPracticed: false))
        model.updateEnvironment(desktopCount: 2, windowCount: 2)
        model.setTarget(.init(windowID: 42, originDesktop: 0, destinationDesktop: 0, title: "Next"))
        #expect(!model.recordPractice(.desktop, windowID: 42, desktopIndex: 0))
    }

}
