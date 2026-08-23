import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

private final class DelayedCaptureWindowService: WindowService, @unchecked Sendable {
    let captureDelay: TimeInterval
    let capturedImage: CGImage?
    let perWindowDelay: [CGWindowID: TimeInterval]

    init(
        captureDelay: TimeInterval,
        capturedImage: CGImage? = nil,
        perWindowDelay: [CGWindowID: TimeInterval] = [:]
    ) {
        self.captureDelay = captureDelay
        self.capturedImage = capturedImage
        self.perWindowDelay = perWindowDelay
    }

    func listRunningApps() -> [AppInfo] { [] }
    func listWindows() -> [WindowInfo] { [] }
    func listAllWindowIDs() -> Set<CGWindowID>? { nil }

    func captureWindowImages(
        windowIDs: [CGWindowID],
        onEnumerated: @escaping @Sendable ([CGWindowID]) -> Void,
        onCapture: @escaping @Sendable (WindowImageCapture) -> Void
    ) async {
        onEnumerated(capturedImage == nil ? [] : windowIDs)
        await withTaskGroup(of: WindowImageCapture?.self) { group in
            for windowID in windowIDs {
                group.addTask { [captureDelay, capturedImage, perWindowDelay] in
                    let delay = perWindowDelay[windowID] ?? captureDelay
                    try? await Task.sleep(for: .seconds(delay))
                    return capturedImage.map {
                        WindowImageCapture(windowID: windowID, image: $0)
                    }
                }
            }
            for await capture in group {
                if let capture { onCapture(capture) }
            }
        }
    }

    func raiseWindow(windowID: CGWindowID) -> Bool { true }
    func activateApp(bundleID: String) -> Bool { true }
    func terminateApp(pid: pid_t) -> Bool { true }
    func isAccessibilityEnabled() -> Bool { true }
}

private final class PreviewRefreshDelegate: StageControllerDelegate, @unchecked Sendable {
    let overlayOpened = DispatchSemaphore(value: 0)
    let overlayClosed = DispatchSemaphore(value: 0)
    let overlayUpdated = DispatchSemaphore(value: 0)
    var onOverlayOpened: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var storedPreviewSets: [Set<CGWindowID>] = []
    private var storedPresentationContexts: [OverlayPresentationContext] = []

    var previewSets: [Set<CGWindowID>] {
        lock.withLock { storedPreviewSets }
    }

    var presentationContexts: [OverlayPresentationContext] {
        lock.withLock { storedPresentationContexts }
    }

    func stageControllerDidOpenOverlay(_ controller: StageController) {
        onOverlayOpened?()
        overlayOpened.signal()
    }

    func stageControllerDidOpenOverlay(
        _ controller: StageController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        if let overlayPresentation {
            lock.withLock { storedPresentationContexts.append(overlayPresentation) }
        }
        onOverlayOpened?()
        overlayOpened.signal()
    }

    func stageControllerDidCloseOverlay(_ controller: StageController) {
        overlayClosed.signal()
    }

    func stageControllerDidUpdateSelection(_ controller: StageController) {
        lock.withLock { storedPreviewSets.append(Set(controller.windowPreviews.keys)) }
        overlayUpdated.signal()
    }

    func stageControllerDidSwitchStage(_ controller: StageController) {}
    func stageControllerDidMutateState(_ controller: StageController) {}
}

// Parallel suites can starve the main queue for seconds, so waits that only
// assert a callback eventually arrives use a generous ceiling. Waits that
// assert timing keep an explicit lower bound instead of a tight ceiling.
private let livenessTimeout: TimeInterval = 10

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSinceReferenceDate: 0)

    var now: Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value += interval }
    }
}

/// Polls instead of sleeping a fixed span, so a loaded machine slows the test down
/// rather than failing it.
private func waitUntil(
    timeout: TimeInterval = livenessTimeout,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date() + timeout
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

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

    @Test("Quick release finalizes its correlated presentation as cancelled")
    @MainActor
    func quickReleaseFinalizesPresentationTrace() throws {
        let performance = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader())
        let overlay = OverlayPresentationRecorder(performanceRecorder: performance)
        let controller = StageController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            overlayPresentationDelay: 1,
            focusedWindowSnapshotProvider: { .unfocused },
            overlayPresentationRecorder: overlay
        )
        let context = overlay.begin(configuredDelayMilliseconds: 1_000)

        controller.handleKeyEvent(.cmdTabHold, overlayPresentation: context)
        controller.handleKeyEvent(.cmdRelease)

        let trace = try #require(overlay.snapshot().completed.last)
        #expect(trace.traceID == context.traceID)
        #expect(trace.outcome == .releasedBeforePresentation)
        #expect(trace.phases.contains { $0.phase == .focusProbeCompleted })
        #expect(trace.phases.contains { $0.phase == .presentationScheduled })
        #expect(performance.snapshot().recent.allSatisfy {
            $0.operation != .overlayEndToEndVisible
        })
    }

    @Test("A fullscreen frontmost app still gets the overlay")
    func fullscreenAppStillPresentsOverlay() throws {
        let performance = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader())
        let overlay = OverlayPresentationRecorder(performanceRecorder: performance)
        let controller = StageController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: {
                FocusedWindowSnapshot(
                    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    isFullscreen: true
                )
            },
            overlayPresentationRecorder: overlay
        )
        let context = overlay.begin(configuredDelayMilliseconds: 80)

        controller.handleKeyEvent(.cmdTabHold, overlayPresentation: context)

        #expect(controller.isStageManagerVisible)
        #expect(overlay.snapshot().completed.isEmpty)
        let trace = try #require(overlay.snapshot().active.first)
        #expect(trace.phases.contains { $0.phase == .controllerAccepted })
    }

    @Test("The overlay records that its window was fullscreen")
    @MainActor
    func fullscreenStateIsObservable() {
        // E2E can only tell a fullscreen presentation from an ordinary one through the
        // diagnostic state block, so the probe's answer has to outlive the probe.
        var snapshot = FocusedWindowSnapshot(frame: nil, isFullscreen: true)
        let controller = StageController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            overlayPresentationDelay: 0,
            focusedWindowSnapshotProvider: { snapshot }
        )

        controller.handleKeyEvent(.cmdTabHold)
        #expect(controller.focusedWindowIsFullscreen)

        controller.handleKeyEvent(.cmdRelease)
        snapshot = .unfocused
        controller.handleKeyEvent(.cmdTabHold)
        #expect(!controller.focusedWindowIsFullscreen)
    }

    @Test("Opening the overlay publishes the focused window's frame for display targeting")
    @MainActor
    func overlayPublishesFocusedWindowFrame() {
        let frame = CGRect(x: 1920, y: 200, width: 900, height: 700)
        let controller = StageController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            overlayPresentationDelay: 0,
            focusedWindowSnapshotProvider: {
                FocusedWindowSnapshot(frame: frame, isFullscreen: false)
            }
        )

        controller.handleKeyEvent(.cmdTabHold)

        #expect(controller.focusedWindowFrame == frame)
    }

    @Test("A rejected overlay leaves no stale focused frame behind")
    @MainActor
    func rejectedOverlayClearsFocusedWindowFrame() {
        // The frame decides which display the overlay opens on, so a frame kept from an
        // earlier open would aim the next presentation at the wrong screen.
        var snapshot = FocusedWindowSnapshot(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isFullscreen: false
        )
        let controller = StageController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            overlayPresentationDelay: 0,
            focusedWindowSnapshotProvider: { snapshot }
        )
        controller.handleKeyEvent(.cmdTabHold)
        controller.handleKeyEvent(.cmdRelease)

        snapshot = FocusedWindowSnapshot(frame: nil, isFullscreen: true)
        controller.handleKeyEvent(.cmdTabHold)

        #expect(controller.focusedWindowFrame == nil)
    }

    @Test("Presentation deadline preserves the originating trace")
    func presentationDeadlinePreservesTrace() throws {
        let performance = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader())
        let overlay = OverlayPresentationRecorder(performanceRecorder: performance)
        let controller = StageController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            overlayPresentationDelay: 0,
            focusedWindowSnapshotProvider: { .unfocused },
            overlayPresentationRecorder: overlay
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        let context = overlay.begin(configuredDelayMilliseconds: 0)

        controller.handleKeyEvent(.cmdTabHold, overlayPresentation: context)

        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(delegate.presentationContexts == [context])
        let phases = try #require(overlay.snapshot().active.first).phases.map(\.phase)
        #expect(phases.contains(.presentationDeadlineFired))
    }

    private func makeTestImage() -> CGImage {
        let data: UnsafeMutableRawPointer? = nil
        let ctx = CGContext(
            data: data, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        return ctx.makeImage()!
    }

    private func makeController() -> (StageController, MockWindowService, MockKeyboardService) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        return (controller, windowService, keyboardService)
    }

    // Raising every window was the desktop-surface architecture lifting them above the
    // wallpaper overlay one at a time. Stages are real desktops now, so macOS reveals the
    // whole stage in one transition and only the requested window is touched.
    @Test("Cross-stage switch raises the requested window")
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

        #expect(windowSvc.raisedWindowIDs.contains(202))
        #expect(!windowSvc.raisedWindowIDs.contains(303))
    }

    @Test("Dispatched commands report hint usage")
    func reportsCommandUsage() {
        let (controller, _, keyboardService) = makeController()
        let recorder = CommandUsageRecorder()
        controller.onCommandUsed = { recorder.record($0) }

        keyboardService.simulateEvent(.swapStageUp)
        keyboardService.simulateEvent(.nextWindowRepeat)

        #expect(recorder.actions == [.swapStageUp])
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

    @Test("Dropping a window first in the current stage activates it on commit")
    func currentStageDropSelectionCommitsDroppedWindow() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: stageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toStageID: stageID
        )

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(
            windowID: 202,
            fromStageIndex: 0,
            toStageIndex: 0,
            toWindowIndex: 0
        ))
        keyboardSvc.simulateEvent(.cmdRelease)

        #expect(controller.stageManager.stages[0].windows.map(\.windowID) == [202, 101])
        #expect(windowSvc.raisedWindowID == 202)
        #expect(windowSvc.activatedBundleID == "com.b")
    }

    @Test("Cmd+Tab hold opens overlay")
    func cmdTabHold() {
        let (controller, _, keyboardSvc) = makeController()
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.isStageManagerVisible)
    }

    @Test("Cmd+Tab from an excluded app starts on the stage MRU window")
    func excludedAppCmdTabStartsAtMRU() {
        let (controller, _, keyboardService) = makeController()
        let stageID = controller.stageManager.activeStageID
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "MRU"),
            toStageID: stageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Next"),
            toStageID: stageID
        )
        controller.updateFrontmostApp(isExcluded: true)

        keyboardService.simulateEvent(.cmdTabHold)

        #expect(controller.selectedWindowIndex == 0)
    }

    @Test("Quick Cmd+Tab from an excluded app activates the stage MRU app")
    func excludedAppQuickCmdTabActivatesMRU() {
        let (controller, windowService, keyboardService) = makeController()
        let stageID = controller.stageManager.activeStageID
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "MRU"),
            toStageID: stageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Next"),
            toStageID: stageID
        )
        controller.updateFrontmostApp(isExcluded: true)

        keyboardService.simulateEvent(.cmdTabTap)

        #expect(windowService.raisedWindowID == 101)
        #expect(windowService.activatedBundleID == "com.a")
    }

    @Test("Cmd+Tab handling returns before window preview capture finishes")
    func cmdTabReturnsBeforePreviewCaptureFinishes() {
        let windowService = DelayedCaptureWindowService(captureDelay: 0.35)
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
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

    @Test("Moving a window updates the visible overlay without reopening it")
    func movingWindowDoesNotReopenOverlay() {
        let (controller, _, keyboardService) = makeController()
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        controller.overlayPresentationDelay = 0

        let sourceStageID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        controller.stageManager.addWindow(
            StageWindow(
                windowID: 101,
                ownerBundleID: "com.a",
                ownerName: "A",
                windowTitle: "T1"
            ),
            toStageID: sourceStageID
        )
        controller.stageManager.activateStage(id: sourceStageID)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)

        keyboardService.simulateEvent(.moveWindowDown)

        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(delegate.overlayOpened.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(controller.selectedStageIndex == 1)
        #expect(controller.stageManager.stages[1].windows.map(\.windowID) == [101])
    }

    @Test("Configured overlay presentation delay controls the hold threshold")
    func configuredOverlayPresentationDelay() {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            overlayPresentationDelay: 0.5,
            focusedWindowSnapshotProvider: { .unfocused }
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
            focusedWindowSnapshotProvider: { .unfocused }
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
        let preview = controller.windowPreviews[101]
        #expect(preview != nil)
        if let preview {
            #expect(WindowImageStatistics.hasVariedLuminance(preview))
        }
    }

    @Test("Window previews publish incrementally as concurrent captures finish")
    func previewsPublishIncrementally() {
        let windowService = DelayedCaptureWindowService(
            captureDelay: 0,
            capturedImage: makeTestImage(),
            perWindowDelay: [101: 0.05, 202: 0.3]
        )
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            overlayPresentationDelay: 0,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        for windowID in [CGWindowID(101), 202] {
            controller.stageManager.addWindow(
                StageWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"),
                toStageID: controller.stageManager.activeStageID
            )
        }

        keyboardService.simulateEvent(.cmdTabHold)

        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(delegate.previewSets.contains(Set([101])))
        #expect(delegate.previewSets.last == Set([101, 202]))
    }

    // MARK: - Preview cache

    private func makeCacheController(
        policy: PreviewRefreshPolicy = .lastActiveOnly,
        ttl: TimeInterval = 600,
        clock: TestClock = TestClock()
    ) -> (StageController, MockWindowService, MockKeyboardService, PreviewRefreshDelegate) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused },
            previewRefreshPolicy: policy,
            previewCacheTTL: ttl,
            previewClock: { clock.now }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        return (controller, windowService, keyboardService, delegate)
    }

    @Test("Cached previews are served without re-capturing")
    func cachedPreviewsSkipCapture() throws {
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController()
        let stageID = controller.stageManager.stages[0].id
        for windowID in [CGWindowID(101), 202, 303] {
            controller.stageManager.addWindow(
                StageWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T\(windowID)"),
                toStageID: stageID
            )
        }
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage(), 303: makeTestImage()]

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 3 })
        keyboardSvc.simulateEvent(.escape)

        let frontWindowID = try #require(controller.stageManager.activeStage.windows.first?.windowID)
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { windowSvc.captureRequests.count == 2 })

        let secondRequest = Set(try #require(windowSvc.captureRequests.last))
        #expect(secondRequest == [frontWindowID], "Only the last active window should be re-captured")
        #expect(controller.windowPreviews.count == 3, "Cached previews must survive a partial refresh")
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("An activation with nothing dirty captures nothing at all")
    func fullyCachedActivationIssuesNoCapture() {
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController()
        let activeStageID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let otherStageID = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: activeStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toStageID: otherStageID
        )
        controller.stageManager.activateStage(id: activeStageID)
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage()]

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 2 })
        keyboardSvc.simulateEvent(.escape)

        // With the active stage emptied there is no last-active window left to refresh.
        controller.stageManager.removeWindow(windowID: 101, fromStageID: activeStageID)
        controller.stageManager.activateStage(id: activeStageID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(windowSvc.captureRequests.count == 1, "A fully cached activation must not enumerate or capture")
        #expect(controller.windowPreviews[202] != nil)
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("A title change forces a re-capture")
    func titleChangeForcesRecapture() {
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController()
        let activeStageID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let otherStageID = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: activeStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Inbox"),
            toStageID: otherStageID
        )
        controller.stageManager.activateStage(id: activeStageID)
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage()]

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 2 })
        keyboardSvc.simulateEvent(.escape)

        controller.stageManager.updateWindowTitle(windowID: 202, title: "Inbox (3)")

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { windowSvc.captureRequests.count == 2 })
        #expect(Set(windowSvc.captureRequests[1]).contains(202), "A retitled window is stale")
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("A preview older than the cache TTL is re-captured")
    func ttlExpiryForcesRecapture() {
        let clock = TestClock()
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController(ttl: 60, clock: clock)
        let activeStageID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let otherStageID = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: activeStageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toStageID: otherStageID
        )
        controller.stageManager.activateStage(id: activeStageID)
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage()]

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 2 })
        keyboardSvc.simulateEvent(.escape)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { windowSvc.captureRequests.count == 2 })
        #expect(!Set(windowSvc.captureRequests[1]).contains(202), "A fresh preview is still good")
        keyboardSvc.simulateEvent(.escape)

        clock.advance(by: 61)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { windowSvc.captureRequests.count == 3 })
        #expect(Set(windowSvc.captureRequests[2]).contains(202), "An expired preview must be refreshed")
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("The all-previews policy re-captures every window")
    func allPolicyCapturesEveryWindow() {
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController(policy: .all)
        let stageID = controller.stageManager.stages[0].id
        for windowID in [CGWindowID(101), 202, 303] {
            controller.stageManager.addWindow(
                StageWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T\(windowID)"),
                toStageID: stageID
            )
        }
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage(), 303: makeTestImage()]

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 3 })
        keyboardSvc.simulateEvent(.escape)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { windowSvc.captureRequests.count == 2 })
        #expect(Set(windowSvc.captureRequests[1]) == [101, 202, 303])
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("No preview is captured before the overlay is revealed")
    func capturesWaitForOverlayReveal() {
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController()
        let stageID = controller.stageManager.stages[0].id
        for windowID in [CGWindowID(101), 202] {
            controller.stageManager.addWindow(
                StageWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T\(windowID)"),
                toStageID: stageID
            )
        }
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage()]

        let requestsAtReveal = Locked<Int?>(nil)
        delegate.onOverlayOpened = { requestsAtReveal.set(windowSvc.captureRequests.count) }

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 2 })

        #expect(requestsAtReveal.get() == 0, "Captures must not compete with the reveal for the main queue")
        keyboardSvc.simulateEvent(.escape)
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

    @Test("Desktop selection closes the overlay and requests the real desktop")
    func desktopSelectionRevealsDesktop() {
        let (controller, _, keyboardSvc) = makeController()
        var revealCount = 0
        controller.onDesktopReveal = { revealCount += 1 }

        keyboardSvc.simulateEvent(.cmdTabHold)
        controller.revealDesktop()

        #expect(!controller.isStageManagerVisible)
        #expect(revealCount == 1)
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

    @Test("Left and right arrows reorder the selected window inside its stage")
    func reorderWindowWithinStage() {
        let (controller, _, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toStageID: stageID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 1)

        keyboardSvc.simulateEvent(.moveWindowRight)
        #expect(controller.stageManager.stages[0].windows.map(\.windowID) == [101, 303, 202])
        #expect(controller.selectedWindowIndex == 2)

        keyboardSvc.simulateEvent(.moveWindowRight)
        #expect(controller.stageManager.stages[0].windows.map(\.windowID) == [101, 303, 202])
        #expect(controller.selectedWindowIndex == 2)

        keyboardSvc.simulateEvent(.moveWindowLeft)
        keyboardSvc.simulateEvent(.moveWindowLeft)
        #expect(controller.stageManager.stages[0].windows.map(\.windowID) == [202, 101, 303])
        #expect(controller.selectedWindowIndex == 0)

        keyboardSvc.simulateEvent(.moveWindowLeft)
        #expect(controller.stageManager.stages[0].windows.map(\.windowID) == [202, 101, 303])
        #expect(controller.selectedWindowIndex == 0)
    }

    @Test("A dragged stage lands in its new slot and becomes the current stage")
    func reorderStageByDrag() {
        let (controller, _, _) = makeController()
        let first = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        let second = controller.stageManager.stages[1].id
        let third = controller.stageManager.stages[2].id
        controller.selectedStageIndex = 0

        controller.reorderStage(fromIndex: 2, toIndex: 0)

        #expect(controller.stageManager.stages.map(\.id) == [third, first, second])
        #expect(controller.selectedStageIndex == 0)
        #expect(controller.stageManager.activeStageID == third)
    }

    @Test("A stage dropped back where it started changes nothing")
    func reorderStageToSameSlot() {
        let (controller, _, _) = makeController()
        controller.stageManager.createStage(position: .below)
        let order = controller.stageManager.stages.map(\.id)
        controller.selectedStageIndex = 1

        controller.reorderStage(fromIndex: 0, toIndex: 0)

        #expect(controller.stageManager.stages.map(\.id) == order)
        #expect(controller.selectedStageIndex == 1)
    }

    @Test("Held backward Tab stops at the first window and a fresh press wraps")
    func backwardTabCycle() {
        let (controller, _, keyboardSvc) = makeController()
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageID)
        controller.stageManager.addWindow(StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toStageID: stageID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 1)
        keyboardSvc.simulateEvent(.previousWindowRepeat)
        #expect(controller.selectedWindowIndex == 0)
        keyboardSvc.simulateEvent(.previousWindowRepeat)
        #expect(controller.selectedWindowIndex == 0) // held backward stops at the first window
        keyboardSvc.simulateEvent(.previousWindow)
        #expect(controller.selectedWindowIndex == 2) // a fresh press still wraps
    }

    @Test("Held backward app-window shortcut stops at the first window")
    func heldAppWindowCycleStopsAtStart() {
        let (controller, windowService, keyboardService) = makeController()
        let stageID = controller.stageManager.activeStageID
        for windowID in [CGWindowID(101), 202, 303] {
            controller.stageManager.addWindow(
                StageWindow(
                    windowID: windowID,
                    ownerBundleID: "com.example.App",
                    ownerName: "App",
                    windowTitle: "Window \(windowID)"
                ),
                toStageID: stageID
            )
        }

        keyboardService.simulateEvent(.cmdShiftBacktick) // wraps to the last window
        #expect(windowService.raisedWindowID == 303)
        keyboardService.simulateEvent(.cmdShiftBacktickRepeat)
        #expect(windowService.raisedWindowID == 202)
        keyboardService.simulateEvent(.cmdShiftBacktickRepeat)
        keyboardService.simulateEvent(.cmdShiftBacktickRepeat)

        #expect(windowService.raisedWindowID == 101)
    }

    @Test("Quit terminates the app owning the selected window, not the frontmost app")
    func quitSelectedApp() {
        let (controller, windowService, keyboardService) = makeController()
        let stageID = controller.stageManager.activeStageID
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 11),
            toStageID: stageID
        )
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2", ownerPID: 22),
            toStageID: stageID
        )

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 1)
        keyboardService.simulateEvent(.quitSelectedApp)

        #expect(windowService.terminatedPIDs == [22])
        #expect(controller.isStageManagerVisible)
    }

    @Test("Quit does nothing when the stage has no windows")
    func quitSelectedAppWithoutSelection() {
        let (controller, windowService, keyboardService) = makeController()

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.quitSelectedApp)

        #expect(windowService.terminatedPIDs.isEmpty)
    }

    @Test("A quit app's windows leave the open overlay and pull the selection back in range")
    func liveWindowRemovalRefreshesOpenOverlay() {
        let (controller, _, keyboardService) = makeController()
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        let stageID = controller.stageManager.activeStageID
        for (windowID, pid) in [(CGWindowID(101), pid_t(11)), (202, 22), (303, 22)] {
            controller.stageManager.addWindow(
                StageWindow(
                    windowID: windowID,
                    ownerBundleID: "com.a",
                    ownerName: "A",
                    windowTitle: "T\(windowID)",
                    ownerPID: pid
                ),
                toStageID: stageID
            )
        }
        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.nextWindow)
        #expect(controller.selectedWindowIndex == 2)

        _ = controller.stageManager.makeWindowsDormant(forOwnerPID: 22)
        controller.handleLiveWindowsRemoved()

        #expect(controller.selectedWindowIndex == 0)
        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
    }

    @Test("Removing the last window leaves the selection at zero rather than negative")
    func liveWindowRemovalOfEveryWindow() {
        let (controller, _, keyboardService) = makeController()
        let stageID = controller.stageManager.activeStageID
        controller.stageManager.addWindow(
            StageWindow(
                windowID: 101,
                ownerBundleID: "com.a",
                ownerName: "A",
                windowTitle: "T1",
                ownerPID: 11
            ),
            toStageID: stageID
        )
        keyboardService.simulateEvent(.cmdTabHold)

        _ = controller.stageManager.makeWindowsDormant(forOwnerPID: 11)
        controller.handleLiveWindowsRemoved()

        #expect(controller.selectedWindowIndex == 0)
    }

    @Test("Held app-window shortcut stops at the last window")
    func heldAppWindowCycleStopsAtEnd() {
        let (controller, windowService, keyboardService) = makeController()
        let stageID = controller.stageManager.activeStageID
        for windowID in [CGWindowID(101), 202, 303] {
            controller.stageManager.addWindow(
                StageWindow(
                    windowID: windowID,
                    ownerBundleID: "com.example.App",
                    ownerName: "App",
                    windowTitle: "Window \(windowID)"
                ),
                toStageID: stageID
            )
        }

        keyboardService.simulateEvent(.cmdBacktick)
        keyboardService.simulateEvent(.cmdBacktickRepeat)
        keyboardService.simulateEvent(.cmdBacktickRepeat)

        #expect(windowService.raisedWindowID == 303)
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

    // Stages are desktops, so when macOS reports a focused window on the desktop showing,
    // that outranks whatever Debut recorded earlier. The window moves to the showing stage
    // rather than the user being moved to the window, and it must not end up in both.
    @Test("Cross-stage window activation moves the window, not the user")
    func crossStageActivationMovesTheWindow() {
        let (controller, _, _) = makeController()
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        controller.spaceSwitcher = spaces
        let stageAID = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let stageBID = controller.stageManager.stages[1].id

        controller.stageManager.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: stageAID)
        controller.stageManager.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: stageBID)

        spaces.windowDesktops = [101: 1, 202: 1]
        controller.switchToStage(id: stageBID)
        #expect(controller.stageManager.activeStageID == stageBID)

        controller.recordWindowActivation(windowID: 101)

        #expect(controller.stageManager.activeStageID == stageBID)
        #expect(!controller.stageManager.stages[0].windows.contains(where: { $0.windowID == 101 }))
        #expect(controller.stageManager.stages[1].windows.contains(where: { $0.windowID == 101 }))
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

        keyboardSvc.simulateEvent(.switchToStageKeepingCurrentApplication(2))

        #expect(controller.stageManager.activeStageID == targetStageID)
        #expect(windowSvc.raisedWindowID == 303)
        #expect(windowSvc.activatedBundleID == "com.current")
        #expect(controller.stageManager.activeStage.windows.first?.windowID == 303)
    }

    @Test("Quick switch defaults to the target stage's MRU window")
    func quickSwitchDefaultsToTargetMRU() {
        let (controller, windowService, keyboardService) = makeController()
        let sourceStageID = controller.stageManager.activeStageID
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
            StageWindow(windowID: 303, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Same App"),
            toStageID: targetStageID
        )

        keyboardService.simulateEvent(.switchToStage(2))

        #expect(windowService.raisedWindowID == 202)
        #expect(windowService.activatedBundleID == "com.other")
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

        keyboardSvc.simulateEvent(.switchToStageKeepingCurrentApplication(2))

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

        // Create a test image with real pixel variation.
        let testImage = makeTestImage()

        // First overlay open — both windows capturable
        windowSvc.capturedImages = [101: testImage, 202: testImage]
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews[101] != nil })
        #expect(waitUntil { controller.windowPreviews[202] != nil })
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
        #expect(waitUntil { controller.windowPreviews[101] != nil })
        keyboardSvc.simulateEvent(.escape)

        // Remove window from stage
        controller.stageManager.removeWindow(windowID: 101, fromStageID: stageID)

        // Open overlay again — stale preview should be cleaned up
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(controller.windowPreviews[101] == nil, "Preview for removed window should be cleaned up")
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("The focus probe timeout stays bounded")
    func focusProbeTimeoutIsBounded() {
        // Passing 0 to AXUIElementSetMessagingTimeout means "use the system
        // default", which is seconds long. That would put an unbounded
        // cross-process wait back on the overlay-open path.
        #expect(StageController.focusProbeTimeout > 0)
        #expect(StageController.focusProbeTimeout <= 0.1)
    }
}
