import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

private final class DelayedCaptureWindowService: WindowService, @unchecked Sendable {
    let captureDelay: TimeInterval
    let capturedImage: CGImage?

    init(captureDelay: TimeInterval, capturedImage: CGImage? = nil) {
        self.captureDelay = captureDelay
        self.capturedImage = capturedImage
    }

    func listRunningApps() -> [AppInfo] { [] }
    func listWindows() -> [WindowInfo] { [] }
    func listAllWindowIDs() -> Set<CGWindowID>? { nil }

    func captureWindowImage(windowID: CGWindowID) -> CGImage? {
        Thread.sleep(forTimeInterval: captureDelay)
        return capturedImage
    }

    func raiseWindow(windowID: CGWindowID) -> Bool { true }
    func activateApp(bundleID: String) -> Bool { true }
    func isAccessibilityEnabled() -> Bool { true }
}

private final class PreviewRefreshDelegate: StageControllerDelegate, @unchecked Sendable {
    let overlayOpened = DispatchSemaphore(value: 0)
    let overlayClosed = DispatchSemaphore(value: 0)
    let overlayUpdated = DispatchSemaphore(value: 0)

    func stageControllerDidOpenOverlay(_ controller: StageController) {
        overlayOpened.signal()
    }

    func stageControllerDidCloseOverlay(_ controller: StageController) {
        overlayClosed.signal()
    }

    func stageControllerDidUpdateSelection(_ controller: StageController) {
        overlayUpdated.signal()
    }

    func stageControllerDidSwitchStage(_ controller: StageController) {}
    func stageControllerDidMutateState(_ controller: StageController) {}
}

// Parallel suites can starve the main queue for seconds, so waits that only
// assert a callback eventually arrives use a generous ceiling. Waits that
// assert timing keep an explicit lower bound instead of a tight ceiling.
private let livenessTimeout: TimeInterval = 10

private final class CommandUsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedActions: [KeyAction] = []

    var actions: [KeyAction] {
        lock.withLock { storedActions }
    }

    func record(_ action: KeyAction) {
        lock.withLock { storedActions.append(action) }
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
        return (controller, windowService, keyboardService)
    }

    @Test("Cross-stage switch raises every target stage window")
    func switchStage() {
        let (controller, windowSvc, _) = makeController()
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let stageBID = controller.stageManager.stages[1].id

        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageAID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageBID)
        controller.stageManager.addWindow(StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toStageID: stageBID)
        controller.stageManager.activateStage(id: stageAID)

        controller.switchToStage(id: stageBID, raiseWindowID: 202)

        #expect(Set(windowSvc.raisedWindowIDs).isSuperset(of: Set<CGWindowID>([202, 303])))
    }

    @Test("Dispatched commands report hint usage")
    func reportsCommandUsage() {
        let (controller, _, keyboardService) = makeController()
        let recorder = CommandUsageRecorder()
        controller.onCommandUsed = { recorder.record($0) }

        keyboardService.simulateEvent(.newStageBelow)
        keyboardService.simulateEvent(.nextWindowRepeat)

        #expect(recorder.actions == [.newStageBelow])
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

    @Test("Clicking a window immediately switches to its stage and window")
    func mouseSelectionCommitsImmediately() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let firstStageID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let secondStageID = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: firstStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toStageID: secondStageID
        )
        controller.stageManager.activateStage(id: firstStageID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        controller.commitOverlaySelection(stageIndex: 1, windowIndex: 0)

        #expect(!controller.isStageManagerVisible)
        #expect(controller.stageManager.activeStageID == secondStageID)
        #expect(windowSvc.raisedWindowID == 202)
        #expect(windowSvc.activatedBundleID == "com.b")
    }

    @Test("Cmd+Tab hold opens overlay")
    func cmdTabHold() {
        let (controller, _, keyboardSvc) = makeController()
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.isStageManagerVisible)
    }

    @Test("Cmd+Tab handling returns before window preview capture finishes")
    func cmdTabReturnsBeforePreviewCaptureFinishes() {
        let windowService = DelayedCaptureWindowService(captureDelay: 0.35)
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            fullscreenAppActiveProvider: { false }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: controller.stageManager.activeStageID
        )

        let start = ContinuousClock.now
        keyboardService.simulateEvent(.cmdTabHold)
        let handlingDuration = ContinuousClock.now - start

        #expect(handlingDuration < .milliseconds(50))
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
    }

    @Test("Quick Cmd+Tab release switches without presenting overlay UI")
    func quickCmdTabReleaseDoesNotPresentOverlay() {
        let (controller, windowService, keyboardService) = makeController()
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        let stageID = controller.stageManager.activeStageID
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: stageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toStageID: stageID
        )

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.cmdRelease)

        #expect(delegate.overlayOpened.wait(timeout: .now() + 0.35) == .timedOut)
        #expect(delegate.overlayClosed.wait(timeout: .now()) == .timedOut)
        #expect(windowService.raisedWindowID == 202)
        #expect(!controller.isStageManagerVisible)
    }

    @Test("Held Cmd+Tab presents overlay UI after a short delay")
    func heldCmdTabPresentsOverlayAfterDelay() {
        let (controller, _, keyboardService) = makeController()
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        controller.overlayPresentationDelay = 0.2

        keyboardService.simulateEvent(.cmdTabHold)

        #expect(delegate.overlayOpened.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        keyboardService.simulateEvent(.escape)
        #expect(delegate.overlayClosed.wait(timeout: .now()) == .success)
    }

    @Test("Configured overlay presentation delay controls the hold threshold")
    func configuredOverlayPresentationDelay() {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            overlayPresentationDelay: 0.5,
            fullscreenAppActiveProvider: { false }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate

        keyboardService.simulateEvent(.cmdTabHold)

        // The injected delay must outlast the default threshold before opening.
        #expect(delegate.overlayOpened.wait(timeout: .now() + 0.25) == .timedOut)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
    }

    @Test("Visible overlay updates after asynchronous preview capture")
    func visibleOverlayUpdatesAfterPreviewCapture() {
        let windowService = DelayedCaptureWindowService(
            captureDelay: 0.35,
            capturedImage: makeTestImage()
        )
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            fullscreenAppActiveProvider: { false }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: controller.stageManager.activeStageID
        )

        keyboardService.simulateEvent(.cmdTabHold)

        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(controller.windowPreviews[101] != nil)
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

    @Test("Overlay last-stage shortcut selects the final plate")
    func overlayLastStageShortcut() {
        let (controller, _, keyboardSvc) = makeController()
        for _ in 0..<3 {
            controller.stageManager.createStage(position: .below)
        }

        keyboardSvc.simulateEvent(.cmdOptionTabHold)
        keyboardSvc.simulateEvent(.jumpToLastStage)

        #expect(controller.isStageManagerVisible)
        #expect(controller.selectedStageIndex == controller.stageManager.stages.count - 1)
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

    @Test("Held Tab stops at the last window and a fresh press wraps")
    func tabCycle() {
        let (controller, _, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toStageID: stageID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 1) // starts at second window like native
        keyboardSvc.simulateEvent(.nextWindowRepeat)
        #expect(controller.selectedWindowIndex == 2)
        keyboardSvc.simulateEvent(.nextWindowRepeat)
        #expect(controller.selectedWindowIndex == 2) // held Tab stops at the end
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 0) // release and press Tab again
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

    @Test("Window cache reset can report diagnostics while rebuilding controller state")
    func windowCacheResetAvoidsExclusiveAccessCrash() {
        let windowService = MockWindowService()
        windowService.windowList = [
            WindowInfo(
                windowID: 202,
                ownerBundleID: "com.live",
                ownerName: "Live",
                ownerPID: 0,
                title: "Current",
                bounds: .zero,
                isOnScreen: true
            ),
        ]
        let discovery = WindowDiscoveryService(windowService: windowService)
        discovery.armingOverride = { _, _ in .armed }

        var manager = StageManager()
        manager.addWindow(
            StageWindow(
                windowID: 101,
                ownerBundleID: "com.ghost",
                ownerName: "Ghost",
                windowTitle: "Stale",
                ownerPID: 10
            ),
            toStageID: manager.activeStageID
        )
        let controller = StageController(
            windowService: windowService,
            keyboardService: MockKeyboardService(),
            stageManager: manager
        )

        controller.rebuildWindowCache(using: discovery)

        #expect(controller.stageManager.stages.count == 1)
        #expect(controller.stageManager.activeStage.windows.map(\.windowID) == [202])
        #expect(controller.selectedStageIndex == 0)
        #expect(controller.selectedWindowIndex == 0)
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
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)

        // Create a 1x1 test image
        let testImage = makeTestImage()

        // First overlay open — both windows capturable
        windowSvc.capturedImages = [101: testImage, 202: testImage]
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(controller.windowPreviews[101] != nil)
        #expect(controller.windowPreviews[202] != nil)
        keyboardSvc.simulateEvent(.escape)

        // Second overlay open — window 202 is hidden (capture returns nil)
        windowSvc.capturedImages = [101: testImage]  // 202 no longer capturable
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)

        // Window 202 should still have its previous preview
        #expect(controller.windowPreviews[101] != nil)
        #expect(controller.windowPreviews[202] != nil, "Hidden window should keep last captured preview")
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("Stale window previews are cleaned up")
    func previewCleanup() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)

        let testImage = makeTestImage()
        windowSvc.capturedImages = [101: testImage]

        // Open overlay to populate previews
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(controller.windowPreviews[101] != nil)
        keyboardSvc.simulateEvent(.escape)

        // Remove window from stage
        controller.stageManager.removeWindow(windowID: 101, fromStageID: stageID)

        // Open overlay again — stale preview should be cleaned up
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(controller.windowPreviews[101] == nil, "Preview for removed window should be cleaned up")
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("The fullscreen probe timeout stays bounded")
    func fullscreenProbeTimeoutIsBounded() {
        // Passing 0 to AXUIElementSetMessagingTimeout means "use the system
        // default", which is seconds long. That would put an unbounded
        // cross-process wait back on the overlay-open path.
        #expect(StageController.fullscreenProbeTimeout > 0)
        #expect(StageController.fullscreenProbeTimeout <= 0.1)
    }
}
