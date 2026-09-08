import Testing
import CoreGraphics
@testable import DebutCore

@Suite("Tutorial switcher", .serialized)
@MainActor
struct TutorialSwitcherTests {
    func fixture(practice: OnboardingPractice = .workspace, focused: CGWindowID = 10) -> (SpaceController, MockWindowService, TutorialSwitcherScope) {
        let service = MockWindowService()
        let controller = SpaceController(windowService: service, keyboardService: MockKeyboardService(),
            overlayPresentationDelay: 10,
            focusedWindowSnapshotProvider: { .init(windowID: focused, frame: nil, isFullscreen: false) })
        for _ in 0..<4 { controller.spaceManager.createSpace(position: .below) }
        let spaces = controller.spaceManager.spaces
        for i in 0..<50 {
            controller.spaceManager.addWindow(.init(windowID: UInt32(100 + i), ownerBundleID: "com.other", ownerName: "Other", windowTitle: "Real \(i)"), toSpaceID: spaces[i % 5].id)
        }
        controller.spaceManager.addWindow(.init(windowID: 10, ownerBundleID: "com.thomplth.Debut", ownerName: "Debut", windowTitle: "Debut Tutorial"), toSpaceID: spaces[2].id)
        let destination = practice == .workspace ? 2 : 3
        let placement = practice == .moveWindow ? 2 : destination
        controller.spaceManager.addWindow(.init(windowID: 20, ownerBundleID: "com.thomplth.Debut", ownerName: "Debut", windowTitle: "Next lesson"), toSpaceID: spaces[placement].id)
        controller.spaceManager.activateSpace(id: spaces[2].id)
        let scope = TutorialSwitcherScope(lessonWindowID: 10, target: .init(windowID: 20, originDesktop: 2, destinationDesktop: destination, title: "Next lesson"), practice: practice)
        controller.tutorialScope = scope
        return (controller, service, scope)
    }

    @Test("Crowded desktops are filtered only in the tutorial presentation")
    func isolation() {
        let (controller, _, _) = fixture()
        let before = controller.spaceManager
        controller.handleKeyEvent(.cmdTabHold)
        #expect(controller.activeTutorialScope != nil)
        #expect(Set(controller.overlaySpaceManager.allSpaces.flatMap { $0.windowIDs }) == [10, 20])
        #expect(controller.overlaySpaceManager.spaces.map(\.id) == before.spaces.map(\.id))
        #expect(controller.spaceManager.liveWindowCount == 52)
        controller.handleKeyEvent(.escape)
        #expect(controller.activeTutorialScope == nil)
        #expect(controller.overlaySpaceManager.liveWindowCount == 52)
    }

    @Test("A shortcut from another app remains an ordinary switcher")
    func normalSwitching() {
        let (controller, _, _) = fixture(focused: 100)
        controller.handleKeyEvent(.cmdTabHold)
        #expect(controller.activeTutorialScope == nil)
        #expect(controller.overlaySpaceManager.liveWindowCount == 52)
        controller.handleKeyEvent(.escape)
    }

    @Test("Option-Tab also includes only tutorial windows")
    func previews() {
        let (controller, _, _) = fixture(practice: .allWindows)
        controller.handleKeyEvent(.altTabHold)
        #expect(Set(controller.altTabEntries.map { $0.window.windowID }) == [10, 20])
        controller.handleKeyEvent(.escape)
    }

    @Test("Space cycling stays on the two lesson desktops and leaves user windows alone")
    func desktopCycle() {
        let (controller, _, _) = fixture(practice: .desktop)
        controller.handleKeyEvent(.cmdOptionTabHold)
        #expect(controller.selectedSpaceIndex == 3)
        controller.handleKeyEvent(.nextSpace)
        #expect(controller.selectedSpaceIndex == 2)
        controller.handleKeyEvent(.nextSpace)
        #expect(controller.selectedSpaceIndex == 3)
        controller.handleKeyEvent(.quitSelectedApp)
        controller.handleKeyEvent(.closeSelectedWindow)
        #expect(controller.spaceManager.liveWindowCount == 52)
        controller.handleKeyEvent(.escape)
    }

    @Test("A filtered selection commits its window ID, never a real window at the same index")
    func commitsIdentity() {
        let (controller, service, _) = fixture()
        controller.handleKeyEvent(.cmdTabHold)
        while controller.overlaySpaceManager.spaces[2].windows[controller.selectedWindowIndex].windowID != 20 {
            controller.handleKeyEvent(.nextWindow)
        }
        controller.handleKeyEvent(.cmdRelease)
        #expect(service.raisedWindowIDs.contains(20))
        #expect(service.raisedWindowIDs.allSatisfy { $0 == 20 })
        #expect(controller.activeTutorialScope == nil)
    }

    @Test("The move coach teaches selection, movement and release one action at a time")
    func coachSteps() {
        let (_, _, scope) = fixture(practice: .moveWindow)
        #expect(scope.coachmark(mode: .stages, selectedWindowID: 10, selectedDesktop: 2, targetDesktop: 2).action.contains("Tab"))
        #expect(scope.coachmark(mode: .stages, selectedWindowID: 20, selectedDesktop: 2, targetDesktop: 2).action.contains("Down Arrow"))
        #expect(scope.coachmark(mode: .stages, selectedWindowID: 20, selectedDesktop: 3, targetDesktop: 3).action.contains("Release Command"))
        #expect(scope.coachmark(mode: .altTab, selectedWindowID: 20, selectedDesktop: 2, targetDesktop: 2).action.contains("Esc"))
    }
    @Test("Preparation and empty desktop recovery never ask for an unreachable window")
    func preparationAndRecovery() {
        let (_, _, scope) = fixture(practice: .moveWindow)
        #expect(scope.coachmark(mode: .stages, selectedWindowID: 10, selectedDesktop: 2, targetDesktop: nil).action.contains("Esc"))
        #expect(scope.coachmark(mode: .stages, selectedWindowID: nil, selectedDesktop: 3, targetDesktop: 2).action.contains("Option"))
    }

    @Test("Moving a practice target leaves all unrelated assignments unchanged")
    func moveIsolation() {
        let (controller, _, _) = fixture(practice: .moveWindow)
        let before = controller.spaceManager
        controller.handleKeyEvent(.cmdTabHold)
        while controller.overlaySpaceManager.spaces[2].windows[controller.selectedWindowIndex].windowID != 10 {
            controller.handleKeyEvent(.nextWindow)
        }
        controller.handleKeyEvent(.moveWindowDown)
        #expect(controller.selectedSpaceIndex == 2)
        controller.handleKeyEvent(.nextWindow)
        controller.handleKeyEvent(.moveWindowDown)
        #expect(controller.selectedSpaceIndex == 3)
        #expect(controller.overlaySpaceManager.spaces[3].windowIDs == [20])
        #expect(controller.spaceManager.spaces.map(\.windowIDs) == before.spaces.map(\.windowIDs))
        controller.handleKeyEvent(.escape)
        #expect(controller.spaceManager.spaces.map(\.windowIDs) == before.spaces.map(\.windowIDs))
    }

    @Test("A quick Command-Tab from the lesson never chooses an unrelated window")
    func quickTap() {
        let (controller, service, _) = fixture()
        controller.handleKeyEvent(.cmdTabTap)
        #expect(service.raisedWindowIDs == [20])
        #expect(controller.activeTutorialScope == nil)
    }

}
