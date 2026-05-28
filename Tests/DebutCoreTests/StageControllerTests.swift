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

    @Test("Switch stage hides old apps and unhides new")
    func switchStage() {
        let (controller, windowSvc, _) = makeController()
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(name: "B", position: .below)
        let stageBID = controller.stageManager.stages[1].id

        controller.stageManager.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: stageAID)
        controller.stageManager.addApp(StageApp(bundleID: "com.b", name: "B"), toStageID: stageBID)

        controller.switchToStage(id: stageAID)

        #expect(windowSvc.hiddenBundleIDs.contains("com.b"))
        #expect(!windowSvc.hiddenBundleIDs.contains("com.a"))
    }

    @Test("App switch only activates selected app")
    func appSwitch() {
        let (controller, windowSvc, _) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: stageID)
        controller.stageManager.addApp(StageApp(bundleID: "com.b", name: "B"), toStageID: stageID)

        controller.switchToStage(id: stageID, activateBundleID: "com.b")

        #expect(windowSvc.activatedBundleID == "com.b")
    }

    @Test("Cmd+Tab hold opens overlay")
    func cmdTabHold() {
        let (controller, _, keyboardSvc) = makeController()
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.isStageManagerVisible)
    }

    @Test("Escape discards")
    func escape() {
        let (controller, _, keyboardSvc) = makeController()
        let originalStageID = controller.stageManager.activeStageID
        keyboardSvc.simulateEvent(.cmdTabHold)
        keyboardSvc.simulateEvent(.nextStage)
        keyboardSvc.simulateEvent(.escape)
        #expect(!controller.isStageManagerVisible)
        #expect(controller.stageManager.activeStageID == originalStageID)
    }

    @Test("Tab cycles apps, initial selection at index 1")
    func tabCycle() {
        let (controller, _, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: stageID)
        controller.stageManager.addApp(StageApp(bundleID: "com.b", name: "B"), toStageID: stageID)
        controller.stageManager.addApp(StageApp(bundleID: "com.c", name: "C"), toStageID: stageID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedAppIndex == 1) // starts at second app like native
        keyboardSvc.simulateEvent(.nextApp)
        #expect(controller.selectedAppIndex == 2)
        keyboardSvc.simulateEvent(.nextApp)
        #expect(controller.selectedAppIndex == 0) // wraps
    }

    @Test("MRU: recordAppActivation brings to front")
    func mruTracking() {
        let (controller, _, _) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: stageID)
        controller.stageManager.addApp(StageApp(bundleID: "com.b", name: "B"), toStageID: stageID)
        controller.stageManager.addApp(StageApp(bundleID: "com.c", name: "C"), toStageID: stageID)

        controller.recordAppActivation(bundleID: "com.c")
        controller.recordAppActivation(bundleID: "com.a")

        let apps = controller.stageManager.activeStage.apps.map(\.bundleID)
        #expect(apps == ["com.a", "com.c", "com.b"])
    }

    @Test("Cross-stage app activation adds as shared")
    func crossStageSharing() {
        let (controller, windowSvc, _) = makeController()
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(name: "B", position: .below)
        let stageBID = controller.stageManager.stages[1].id

        controller.stageManager.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: stageAID)
        controller.stageManager.addApp(StageApp(bundleID: "com.b", name: "B"), toStageID: stageBID)

        windowSvc.apps = [AppInfo(bundleID: "com.a", name: "A", pid: 100, isHidden: false)]

        // Switch to stage B
        controller.switchToStage(id: stageBID)

        // Activate app from stage A while in stage B
        controller.recordAppActivation(bundleID: "com.a")

        // App should now be shared in both stages
        let stageA = controller.stageManager.stages[0]
        let stageB = controller.stageManager.stages[1]
        #expect(stageA.apps.contains(where: { $0.bundleID == "com.a" }))
        #expect(stageB.apps.contains(where: { $0.bundleID == "com.a" }))
    }

    @Test("Cmd+Tab tap switches to second MRU app")
    func cmdTabTap() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: stageID)
        controller.stageManager.addApp(StageApp(bundleID: "com.b", name: "B"), toStageID: stageID)

        keyboardSvc.simulateEvent(.cmdTabTap)

        #expect(windowSvc.activatedBundleID == "com.b")
        #expect(controller.stageManager.activeStage.apps[0].bundleID == "com.b")
    }
}
