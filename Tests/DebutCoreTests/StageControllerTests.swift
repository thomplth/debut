import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

private final class StageSwitchOperationLog: @unchecked Sendable {
    var entries: [String] = []
}

private final class RecordingDesktopSurface: DesktopSurfacePresenting, @unchecked Sendable {
    let log: StageSwitchOperationLog

    init(log: StageSwitchOperationLog) {
        self.log = log
    }

    func orderToFront() {
        log.entries.append("surface.front")
    }

    func orderBehind(windowID: CGWindowID) -> Bool {
        log.entries.append("surface.behind.\(windowID)")
        return true
    }
}

private final class RecordingStageSwitchWindowService: WindowService, @unchecked Sendable {
    let log: StageSwitchOperationLog

    init(log: StageSwitchOperationLog) {
        self.log = log
    }

    func listRunningApps() -> [AppInfo] { [] }
    func listWindows() -> [WindowInfo] { [] }
    func listAllWindowIDs() -> Set<CGWindowID>? { [] }
    func captureWindowImage(windowID: CGWindowID) -> CGImage? { nil }
    func isAccessibilityEnabled() -> Bool { true }

    func raiseWindow(windowID: CGWindowID) -> Bool {
        log.entries.append("window.raise.\(windowID)")
        return true
    }

    func activateApp(bundleID: String) -> Bool {
        log.entries.append("app.activate.\(bundleID)")
        return true
    }
}

@Suite("StageController", .serialized)
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
            keyboardService: keyboardService,
            fullscreenAppActiveProvider: { false }
        )
        DiagnosticReporter.shared.setStateProvider { [:] }
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

    @Test("Cross-stage switch raises only the selected destination window")
    func stageSwitchRaisesOnlySelectedWindow() {
        let (controller, windowSvc, _) = makeController()
        let sourceStageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 10, ownerBundleID: "com.source", ownerName: "Source", windowTitle: "Source"),
            toStageID: sourceStageID
        )

        controller.stageManager.createStage(position: .below)
        let targetStageID = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "A"),
            toStageID: targetStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "B"),
            toStageID: targetStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "C"),
            toStageID: targetStageID
        )
        controller.stageManager.activateStage(id: sourceStageID)

        controller.switchToStage(id: targetStageID, raiseWindowID: 101)

        #expect(windowSvc.raisedWindowIDs == [101])
        #expect(windowSvc.activatedBundleID == "com.a")
    }

    @Test("Cross-stage switch places the surface behind the selected window")
    func stageSwitchPlacesSurfaceBehindSelection() {
        let log = StageSwitchOperationLog()
        let controller = StageController(
            windowService: RecordingStageSwitchWindowService(log: log),
            keyboardService: MockKeyboardService(),
            fullscreenAppActiveProvider: { false }
        )
        DiagnosticReporter.shared.setStateProvider { [:] }
        controller.desktopSurface = RecordingDesktopSurface(log: log)

        let sourceStageID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let targetStageID = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "A"),
            toStageID: targetStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "B"),
            toStageID: targetStageID
        )
        controller.stageManager.activateStage(id: sourceStageID)

        controller.switchToStage(id: targetStageID, raiseWindowID: 101)

        #expect(log.entries == [
            "app.activate.com.a",
            "window.raise.101",
            "surface.behind.101",
        ])
    }

    @Test("Surface ordering verification requires the target ahead of the surface")
    func surfaceOrderingVerification() {
        #expect(DesktopSurfaceWindow.isOrderedBehind(
            targetWindowID: 101,
            surfaceWindowID: 999,
            orderedWindowIDs: [101, 999, 202]
        ))
        #expect(!DesktopSurfaceWindow.isOrderedBehind(
            targetWindowID: 101,
            surfaceWindowID: 999,
            orderedWindowIDs: [999, 101, 202]
        ))
        #expect(!DesktopSurfaceWindow.isOrderedBehind(
            targetWindowID: 101,
            surfaceWindowID: 999,
            orderedWindowIDs: [101, 202]
        ))
    }

    @Test("Same-stage window selection also moves the surface behind the selection")
    func sameStageSelectionMovesSurface() {
        let log = StageSwitchOperationLog()
        let controller = StageController(
            windowService: RecordingStageSwitchWindowService(log: log),
            keyboardService: MockKeyboardService(),
            fullscreenAppActiveProvider: { false }
        )
        DiagnosticReporter.shared.setStateProvider { [:] }
        controller.desktopSurface = RecordingDesktopSurface(log: log)
        let stageID = controller.stageManager.activeStageID
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "A"),
            toStageID: stageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "B"),
            toStageID: stageID
        )

        controller.switchToStage(id: stageID, raiseWindowID: 202)

        #expect(log.entries == [
            "app.activate.com.b",
            "window.raise.202",
            "surface.behind.202",
        ])
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

    @Test("Quick switch focuses the current app's MRU window in the target stage")
    func quickSwitchKeepsCurrentApp() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let sourceStageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Source"),
            toStageID: sourceStageID
        )

        controller.stageManager.createStage(position: .below)
        let targetStageID = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.other", ownerName: "Other", windowTitle: "Target MRU"),
            toStageID: targetStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 303, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Target Current"),
            toStageID: targetStageID
        )
        controller.stageManager.activateStage(id: sourceStageID)

        keyboardSvc.simulateEvent(.switchToStage(2))

        #expect(controller.stageManager.activeStageID == targetStageID)
        #expect(windowSvc.raisedWindowID == 303)
        #expect(windowSvc.activatedBundleID == "com.current")
        #expect(controller.stageManager.activeStage.windows.first?.windowID == 303)
    }

    @Test("Quick switch falls back to the target stage's MRU window when the current app is absent")
    func quickSwitchFallsBackToTargetMRU() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let sourceStageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Source"),
            toStageID: sourceStageID
        )

        controller.stageManager.createStage(position: .below)
        let targetStageID = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.other", ownerName: "Other", windowTitle: "Target MRU"),
            toStageID: targetStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 303, ownerBundleID: "com.third", ownerName: "Third", windowTitle: "Target Older"),
            toStageID: targetStageID
        )
        controller.stageManager.activateStage(id: sourceStageID)

        keyboardSvc.simulateEvent(.switchToStage(2))

        #expect(controller.stageManager.activeStageID == targetStageID)
        #expect(windowSvc.raisedWindowID == 202)
        #expect(windowSvc.activatedBundleID == "com.other")
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
