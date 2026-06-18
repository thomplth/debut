import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

@Suite("StageController")
struct StageControllerTests {

    private func makeTestImage() -> CGImage {
        let data: UnsafeMutableRawPointer? = nil
        let ctx = CGContext(
            data: data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeController() -> (StageController, MockWindowService, MockKeyboardService) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService
        )
        return (controller, windowService, keyboardService)
    }

    @Test("Switch stage raises target stage windows")
    func switchStage() {
        let (controller, windowSvc, _) = makeController()
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let stageBID = controller.stageManager.stages[1].id

        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageAID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageBID)

        controller.switchToStage(id: stageAID)

        // Window 101 should have been raised (it's in the target stage)
        #expect(windowSvc.raisedWindowIDs.contains(101))
    }

    @Test("Window switch raises selected window")
    func windowSwitch() {
        let (controller, windowSvc, _) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)

        controller.switchToStage(id: stageID, raiseWindowID: 202)

        #expect(windowSvc.raisedWindowID == 202)
    }

    @Test("Cmd+Tab hold opens overlay")
    func cmdTabHold() {
        let (controller, _, keyboardSvc) = makeController()
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.isStageManagerVisible)
    }

    @Test("Cmd+Option+Tab hold opens overlay in stage mode")
    func cmdOptionTabHold() {
        let (controller, _, keyboardSvc) = makeController()
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)
        keyboardSvc.simulateEvent(.cmdOptionTabHold)
        #expect(controller.isStageManagerVisible)
        #expect(controller.selectedStageIndex == 1)
    }

    @Test("Escape discards")
    func escape() {
        let (controller, _, keyboardSvc) = makeController()
        let originalStageID = controller.stageManager.activeStageID
        keyboardSvc.simulateEvent(.cmdTabHold)
        keyboardSvc.simulateEvent(.escape)
        #expect(!controller.isStageManagerVisible)
        #expect(controller.stageManager.activeStageID == originalStageID)
    }

    @Test("Tab cycles windows, initial selection at index 1")
    func tabCycle() {
        let (controller, _, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toStageID: stageID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 1) // starts at second window like native
        keyboardSvc.simulateEvent(.nextWindow)
        #expect(controller.selectedWindowIndex == 2)
        keyboardSvc.simulateEvent(.nextWindow)
        #expect(controller.selectedWindowIndex == 0) // wraps
    }

    @Test("MRU: recordWindowActivation brings to front")
    func mruTracking() {
        let (controller, _, _) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toStageID: stageID)

        controller.recordWindowActivation(windowID: 303)
        controller.recordWindowActivation(windowID: 101)

        let windowIDs = controller.stageManager.activeStage.windows.map(\.windowID)
        #expect(windowIDs == [101, 303, 202])
    }

    @Test("Cross-stage window activation switches to owning stage")
    func crossStageSwitches() {
        let (controller, _, _) = makeController()
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let stageBID = controller.stageManager.stages[1].id

        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageAID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageBID)

        // Switch to stage B
        controller.switchToStage(id: stageBID)
        #expect(controller.stageManager.activeStageID == stageBID)

        // Activate window from stage A while in stage B — should switch back to A
        controller.recordWindowActivation(windowID: 101)
        #expect(controller.stageManager.activeStageID == stageAID)

        // Window stays only in stage A (no duplication)
        #expect(controller.stageManager.stages[0].windows.contains(where: { $0.windowID == 101 }))
        #expect(!controller.stageManager.stages[1].windows.contains(where: { $0.windowID == 101 }))
    }

    @Test("Cmd+Tab tap switches to second MRU window")
    func cmdTabTap() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)

        keyboardSvc.simulateEvent(.cmdTabTap)

        #expect(windowSvc.raisedWindowID == 202)
        #expect(controller.stageManager.activeStage.windows[0].windowID == 202)
    }

    @Test("Window previews persist for hidden windows")
    func previewPersistsWhenHidden() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)

        // Create a 1x1 test image
        let testImage = makeTestImage()

        // First overlay open — both windows capturable
        windowSvc.capturedImages = [101: testImage, 202: testImage]
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.windowPreviews[101] != nil)
        #expect(controller.windowPreviews[202] != nil)
        keyboardSvc.simulateEvent(.escape)

        // Second overlay open — window 202 is hidden (capture returns nil)
        windowSvc.capturedImages = [101: testImage]  // 202 no longer capturable
        keyboardSvc.simulateEvent(.cmdTabHold)

        // Window 202 should still have its previous preview
        #expect(controller.windowPreviews[101] != nil)
        #expect(controller.windowPreviews[202] != nil, "Hidden window should keep last captured preview")
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("Stale window previews are cleaned up")
    func previewCleanup() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)

        let testImage = makeTestImage()
        windowSvc.capturedImages = [101: testImage]

        // Open overlay to populate previews
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.windowPreviews[101] != nil)
        keyboardSvc.simulateEvent(.escape)

        // Remove window from stage
        controller.stageManager.removeWindow(windowID: 101, fromStageID: stageID)

        // Open overlay again — stale preview should be cleaned up
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.windowPreviews[101] == nil, "Preview for removed window should be cleaned up")
        keyboardSvc.simulateEvent(.escape)
    }
}
