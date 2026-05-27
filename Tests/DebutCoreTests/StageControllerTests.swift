import Testing
import Foundation
@testable import DebutCore

@Suite("StageController")
struct StageControllerTests {

    private func makeController() -> (StageController, MockWindowService, MockKeyboardService) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService
        )
        return (controller, windowService, keyboardService)
    }

    // MARK: - Stage switching

    @Test("Switch stage hides old windows and shows new ones")
    func switchStage() {
        let (controller, windowSvc, _) = makeController()
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(name: "B", position: .below)
        let stageBID = controller.stageManager.stages[1].id

        controller.stageManager.addWindow(
            StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false),
            toStageID: stageAID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 2, appBundleID: "com.b", appName: "B", isShared: false),
            toStageID: stageBID
        )

        controller.switchToStage(id: stageAID)

        #expect(windowSvc.hiddenWindowIDs.contains(2))
        #expect(!windowSvc.hiddenWindowIDs.contains(1))
        #expect(controller.stageManager.activeStageID == stageAID)
    }

    @Test("Switch stage preserves shared windows")
    func switchStageSharedWindows() {
        let (controller, windowSvc, _) = makeController()
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(name: "B", position: .below)
        let stageBID = controller.stageManager.stages[1].id

        let sharedWindow = StageWindow(windowID: 10, appBundleID: "com.shared", appName: "Shared", isShared: true)
        controller.stageManager.addWindow(sharedWindow, toStageID: stageAID)
        controller.stageManager.addWindow(sharedWindow, toStageID: stageBID)
        controller.stageManager.addWindow(
            StageWindow(windowID: 20, appBundleID: "com.only-b", appName: "OnlyB", isShared: false),
            toStageID: stageBID
        )

        controller.switchToStage(id: stageAID)

        #expect(!windowSvc.hiddenWindowIDs.contains(10))
        #expect(windowSvc.hiddenWindowIDs.contains(20))
    }

    @Test("Focus window on stage switch")
    func focusOnSwitch() {
        let (controller, windowSvc, _) = makeController()
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false),
            toStageID: stageAID
        )
        controller.stageManager.createStage(name: "B", position: .below)

        controller.switchToStage(id: stageAID, focusWindowID: 1)

        #expect(windowSvc.focusedWindowID == 1)
    }

    // MARK: - Keyboard event handling

    @Test("Cmd+Tab hold opens Stage Manager state")
    func cmdTabHoldOpens() {
        let (controller, _, keyboardSvc) = makeController()
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.isStageManagerVisible)
    }

    @Test("Escape closes Stage Manager without changes")
    func escapeCloses() {
        let (controller, _, keyboardSvc) = makeController()
        let originalStageID = controller.stageManager.activeStageID
        keyboardSvc.simulateEvent(.cmdTabHold)
        keyboardSvc.simulateEvent(.nextStage)
        keyboardSvc.simulateEvent(.escape)
        #expect(!controller.isStageManagerVisible)
        #expect(controller.stageManager.activeStageID == originalStageID)
    }

    @Test("Cmd release commits selection")
    func cmdReleaseCommits() {
        let (controller, _, keyboardSvc) = makeController()
        controller.stageManager.createStage(name: "B", position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)
        let stageBID = controller.stageManager.stages[1].id

        keyboardSvc.simulateEvent(.cmdTabHold)
        controller.selectedStageIndex = 1
        keyboardSvc.simulateEvent(.cmdRelease)

        #expect(!controller.isStageManagerVisible)
        #expect(controller.stageManager.activeStageID == stageBID)
    }

    // MARK: - Navigation

    @Test("Next app cycles within stage")
    func nextApp() {
        let (controller, _, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false),
            toStageID: stageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 2, appBundleID: "com.b", appName: "B", isShared: false),
            toStageID: stageID
        )

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedAppIndex == 0)
        keyboardSvc.simulateEvent(.nextApp)
        #expect(controller.selectedAppIndex == 1)
        keyboardSvc.simulateEvent(.nextApp)
        #expect(controller.selectedAppIndex == 0) // wraps
    }

    @Test("Previous app cycles within stage")
    func previousApp() {
        let (controller, _, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false),
            toStageID: stageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 2, appBundleID: "com.b", appName: "B", isShared: false),
            toStageID: stageID
        )

        keyboardSvc.simulateEvent(.cmdTabHold)
        keyboardSvc.simulateEvent(.previousApp)
        #expect(controller.selectedAppIndex == 1) // wraps to end
    }

    @Test("Next/previous stage cycles vertically")
    func stageCycling() {
        let (controller, _, keyboardSvc) = makeController()
        controller.stageManager.createStage(name: "B", position: .below)
        controller.stageManager.createStage(name: "C", position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedStageIndex == 0)
        keyboardSvc.simulateEvent(.nextStage)
        #expect(controller.selectedStageIndex == 1)
        keyboardSvc.simulateEvent(.nextStage)
        #expect(controller.selectedStageIndex == 2)
        keyboardSvc.simulateEvent(.nextStage)
        #expect(controller.selectedStageIndex == 0) // wraps
    }

    @Test("Jump to stage by number")
    func jumpToStage() {
        let (controller, _, keyboardSvc) = makeController()
        controller.stageManager.createStage(name: "B", position: .below)
        controller.stageManager.createStage(name: "C", position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        keyboardSvc.simulateEvent(.cmdTabHold)
        keyboardSvc.simulateEvent(.jumpToStage(3))
        #expect(controller.selectedStageIndex == 2)
    }

    // MARK: - Stage management during overlay

    @Test("Create new stage below during overlay")
    func createStageBelow() {
        let (controller, _, keyboardSvc) = makeController()
        keyboardSvc.simulateEvent(.cmdTabHold)
        keyboardSvc.simulateEvent(.newStageBelow)
        #expect(controller.stageManager.stages.count == 2)
    }

    @Test("Delete stage during overlay")
    func deleteStage() {
        let (controller, _, keyboardSvc) = makeController()
        controller.stageManager.createStage(name: "B", position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        keyboardSvc.simulateEvent(.cmdTabHold)
        controller.selectedStageIndex = 1
        keyboardSvc.simulateEvent(.deleteStage)
        #expect(controller.stageManager.stages.count == 1)
    }
}
