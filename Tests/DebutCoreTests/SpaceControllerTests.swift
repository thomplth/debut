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
    func frontWindow(windowID: CGWindowID, ownerPID: pid_t) -> Bool { true }
    func activateApp(pid: pid_t) -> Bool { true }
    func activateApp(bundleID: String) -> Bool { true }
    func terminateApp(pid: pid_t) -> Bool { true }
    func isAccessibilityEnabled() -> Bool { true }
}

private final class PreviewRefreshDelegate: SpaceControllerDelegate, @unchecked Sendable {
    let overlayOpened = DispatchSemaphore(value: 0)
    let overlayClosed = DispatchSemaphore(value: 0)
    let overlayUpdated = DispatchSemaphore(value: 0)
    var onOverlayOpened: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var storedPreviewSets: [Set<CGWindowID>] = []
    private var storedOverlayWindowIDSets: [Set<CGWindowID>] = []
    private var storedPresentationContexts: [OverlayPresentationContext] = []

    var previewSets: [Set<CGWindowID>] {
        lock.withLock { storedPreviewSets }
    }

    var presentationContexts: [OverlayPresentationContext] {
        lock.withLock { storedPresentationContexts }
    }

    var overlayWindowIDSets: [Set<CGWindowID>] {
        lock.withLock { storedOverlayWindowIDSets }
    }

    func spaceControllerDidOpenOverlay(_ controller: SpaceController) {
        onOverlayOpened?()
        overlayOpened.signal()
    }

    func spaceControllerDidOpenOverlay(
        _ controller: SpaceController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        if let overlayPresentation {
            lock.withLock { storedPresentationContexts.append(overlayPresentation) }
        }
        onOverlayOpened?()
        overlayOpened.signal()
    }

    func spaceControllerDidCloseOverlay(_ controller: SpaceController) {
        overlayClosed.signal()
    }

    func spaceControllerDidUpdateSelection(_ controller: SpaceController) {
        lock.withLock {
            storedPreviewSets.append(Set(controller.windowPreviews.keys))
            storedOverlayWindowIDSets.append(Set(
                controller.overlaySpaceManager.allSpaces.flatMap { $0.windows.map(\.windowID) }
            ))
        }
        overlayUpdated.signal()
    }

    func spaceControllerDidSwitchSpace(_ controller: SpaceController) {}
    func spaceControllerDidMutateState(_ controller: SpaceController) {}
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

@Suite("SpaceController", .serialized)
struct SpaceControllerTests {

    @Test("Quick release finalizes its correlated presentation as cancelled")
    @MainActor
    func quickReleaseFinalizesPresentationTrace() throws {
        let performance = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader())
        let overlay = OverlayPresentationRecorder(performanceRecorder: performance)
        let controller = SpaceController(
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

    /// E2E observes a running session only through the snapshot's state block, and a held-Tab
    /// sequence reports nothing else. Filing that block with the `key_event` that precedes the
    /// handler leaves every reading one keystroke behind, which reads as a selection that never
    /// moved — and then as one that moves the wrong way when the next keystroke publishes it.
    @Test("The state block reflects the selection the key event just produced")
    @MainActor
    func keyEventPublishesTheSelectionItProduced() throws {
        let controller = SpaceController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .unfocused }
        )
        let spaceID = controller.spaceManager.spaces[0].id
        for id in 1...3 {
            controller.spaceManager.addWindow(
                SpaceWindow(
                    windowID: CGWindowID(id),
                    ownerBundleID: "com.test.\(id)",
                    ownerName: "App \(id)",
                    windowTitle: "W\(id)"
                ),
                toSpaceID: spaceID
            )
        }

        controller.handleKeyEvent(.cmdTabHold)
        controller.handleKeyEvent(.cmdTabHold)
        DiagnosticReporter.shared.flush()

        #expect(controller.selectedWindowIndex == 2)
        #expect(publishedState()["selectedWindowIndex"] == "2")
    }

    private func publishedState() -> [String: String] {
        guard let data = try? Data(contentsOf: DiagnosticReporter.diagnosticFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? [String: String]
        else { return [:] }
        return state
    }

    @Test("A fullscreen frontmost app still gets the overlay")
    func fullscreenAppStillPresentsOverlay() throws {
        let performance = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader())
        let overlay = OverlayPresentationRecorder(performanceRecorder: performance)
        let controller = SpaceController(
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

        #expect(controller.isSpaceManagerVisible)
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
        let controller = SpaceController(
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
        let controller = SpaceController(
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
        let controller = SpaceController(
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
        let controller = SpaceController(
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

    private func makeUniformTestImage() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        return ctx.makeImage()!
    }

    private func makeController() -> (SpaceController, MockWindowService, MockKeyboardService) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        return (controller, windowService, keyboardService)
    }

    // Raising every window was the desktop-surface architecture lifting them above the
    // wallpaper overlay one at a time. Spaces are real desktops now, so macOS reveals the
    // whole space in one transition and only the requested window is touched.
    @Test("Cross-space switch raises the requested window")
    func switchSpace() {
        let (controller, windowSvc, _) = makeController()
        let spaceAID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let spaceBID = controller.spaceManager.spaces[1].id

        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceAID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceBID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toSpaceID: spaceBID)
        controller.spaceManager.activateSpace(id: spaceAID)

        controller.switchToSpace(id: spaceBID, raiseWindowID: 202)

        #expect(windowSvc.raisedWindowIDs.contains(202))
        #expect(!windowSvc.raisedWindowIDs.contains(303))
    }

    @Test("Window switch raises selected window")
    func windowSwitch() {
        let (controller, windowSvc, _) = makeController()
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceID)

        controller.switchToSpace(id: spaceID, raiseWindowID: 202)

        #expect(windowSvc.raisedWindowID == 202)
    }

    @Test("A hosted window activates its owning process instead of its host bundle")
    func hostedWindowActivatesOwnerProcess() {
        let (controller, windowService, _) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(
                windowID: 31117,
                ownerBundleID: "com.codeweavers.CrossOver",
                ownerName: "王様恋愛【体験版】.exe",
                windowTitle: "王様恋愛 Ver1.00",
                ownerPID: 79240
            ),
            toSpaceID: spaceID
        )

        controller.switchToSpace(id: spaceID, raiseWindowID: 31117)

        #expect(windowService.raisedWindowID == 31117)
        #expect(windowService.frontedWindows
            == [FrontWindowRequest(windowID: 31117, ownerPID: 79240)])
        #expect(windowService.activatedBundleID == nil)
    }

    @Test("Focusing a window fronts it through the window server")
    func focusFrontsWindowThroughWindowServer() {
        let (controller, windowService, _) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B",
                        windowTitle: "T2", ownerPID: 4242),
            toSpaceID: spaceID
        )

        controller.switchToSpace(id: spaceID, raiseWindowID: 202)

        #expect(windowService.frontedWindows
            == [FrontWindowRequest(windowID: 202, ownerPID: 4242)])
        // AppKit's request is advisory and macOS declines it for a background regular app, so a
        // successful fronting must not be followed by one that can silently do nothing.
        #expect(windowService.activatedPID == nil)
        #expect(windowService.activatedBundleID == nil)
    }

    @Test("A refused fronting falls back to the AppKit activation request")
    func refusedFrontingFallsBackToActivation() {
        let (controller, windowService, _) = makeController()
        windowService.frontWindowResult = false
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B",
                        windowTitle: "T2", ownerPID: 4242),
            toSpaceID: spaceID
        )

        controller.switchToSpace(id: spaceID, raiseWindowID: 202)

        #expect(windowService.frontedWindows
            == [FrontWindowRequest(windowID: 202, ownerPID: 4242)])
        #expect(windowService.activatedPID == 4242)
    }

    /// A pid that has gone stale answers no running application, and a fronting request for a
    /// window the server has forgotten is declined. Neither is a reason to leave the app behind.
    @Test("A refused process activation falls back to the owning bundle")
    func refusedProcessActivationFallsBackToBundle() {
        let (controller, windowService, _) = makeController()
        windowService.frontWindowResult = false
        windowService.activateAppResult = false
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B",
                        windowTitle: "T2", ownerPID: 4242),
            toSpaceID: spaceID
        )

        controller.switchToSpace(id: spaceID, raiseWindowID: 202)

        #expect(windowService.activatedPID == 4242)
        #expect(windowService.activatedBundleID == "com.b")
    }

    @Test("A window with no owning process is activated by bundle")
    func windowWithoutOwnerProcessActivatesByBundle() {
        let (controller, windowService, _) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: spaceID
        )

        controller.switchToSpace(id: spaceID, raiseWindowID: 202)

        #expect(windowService.frontedWindows.isEmpty)
        #expect(windowService.activatedBundleID == "com.b")
    }

    @Test("Clicking a window immediately switches to its space and window")
    func mouseSelectionCommitsImmediately() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let firstSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let secondSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: firstSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: secondSpaceID
        )
        controller.spaceManager.activateSpace(id: firstSpaceID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        controller.commitOverlaySelection(spaceIndex: 1, windowIndex: 0)

        #expect(!controller.isSpaceManagerVisible)
        #expect(controller.spaceManager.activeSpaceID == secondSpaceID)
        #expect(windowSvc.raisedWindowID == 202)
        #expect(windowSvc.activatedBundleID == "com.b")
    }

    @Test("Dropping a window first in the current space activates it on commit")
    func currentSpaceDropSelectionCommitsDroppedWindow() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: spaceID
        )

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(
            windowID: 202,
            fromSpaceIndex: 0,
            toSpaceIndex: 0,
            toWindowIndex: 0
        ))
        keyboardSvc.simulateEvent(.cmdRelease)

        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [202, 101])
        #expect(windowSvc.raisedWindowID == 202)
        #expect(windowSvc.activatedBundleID == "com.b")
    }

    @Test("Cmd+Tab hold opens overlay")
    func cmdTabHold() {
        let (controller, _, keyboardSvc) = makeController()
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.isSpaceManagerVisible)
    }

    @Test("Cmd+Tab from an excluded app starts on the space MRU window")
    func excludedAppCmdTabStartsAtMRU() {
        let (controller, _, keyboardService) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "MRU"),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Next"),
            toSpaceID: spaceID
        )
        controller.excludedBundleIDs = ["com.excluded"]
        controller.updateFrontmostApp(bundleID: "com.excluded")

        keyboardService.simulateEvent(.cmdTabHold)

        #expect(controller.selectedWindowIndex == 0)
    }

    @Test("Quick Cmd+Tab from an excluded app activates the space MRU app")
    func excludedAppQuickCmdTabActivatesMRU() {
        let (controller, windowService, keyboardService) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "MRU"),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Next"),
            toSpaceID: spaceID
        )
        controller.excludedBundleIDs = ["com.excluded"]
        controller.updateFrontmostApp(bundleID: "com.excluded")

        keyboardService.simulateEvent(.cmdTabTap)

        #expect(windowService.raisedWindowID == 101)
        #expect(windowService.activatedBundleID == "com.a")
    }

    @Test("Cmd+Tab handling returns before window preview capture finishes")
    func cmdTabReturnsBeforePreviewCaptureFinishes() {
        let windowService = DelayedCaptureWindowService(captureDelay: 0.35)
        let keyboardService = MockKeyboardService()
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: controller.spaceManager.activeSpaceID
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
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: spaceID
        )

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.cmdRelease)

        #expect(delegate.overlayOpened.wait(timeout: .now() + 0.35) == .timedOut)
        #expect(delegate.overlayClosed.wait(timeout: .now()) == .timedOut)
        #expect(windowService.raisedWindowID == 202)
        #expect(!controller.isSpaceManagerVisible)
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

        let sourceSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "com.a",
                ownerName: "A",
                windowTitle: "T1"
            ),
            toSpaceID: sourceSpaceID
        )
        controller.spaceManager.activateSpace(id: sourceSpaceID)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)

        keyboardService.simulateEvent(.moveWindowDown)

        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(delegate.overlayOpened.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(controller.selectedSpaceIndex == 1)
        #expect(controller.spaceManager.spaces[1].windows.isEmpty)
        #expect(controller.overlaySpaceManager.spaces[1].windows.map(\.windowID) == [101])
    }

    @Test("Configured overlay presentation delay controls the hold threshold")
    func configuredOverlayPresentationDelay() {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = SpaceController(
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
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: controller.spaceManager.activeSpaceID
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
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            overlayPresentationDelay: 0,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        for windowID in [CGWindowID(101), 202] {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"),
                toSpaceID: controller.spaceManager.activeSpaceID
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
    ) -> (SpaceController, MockWindowService, MockKeyboardService, PreviewRefreshDelegate) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused },
            previewRefreshPolicy: policy,
            previewCacheTTL: ttl,
            clock: { clock.now }
        )
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        return (controller, windowService, keyboardService, delegate)
    }

    @Test("Hidden startup prewarm fills the cold preview cache")
    func hiddenStartupPrewarmFillsColdCache() throws {
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController()
        let firstSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let secondSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: firstSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: secondSpaceID
        )
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage()]

        controller.prewarmWindowPreviews()

        #expect(waitUntil { controller.windowPreviews.count == 2 })
        #expect(Set(try #require(windowSvc.captureRequests.first)) == [101, 202])
        #expect(!controller.isSpaceManagerVisible)
        #expect(delegate.overlayOpened.wait(timeout: .now()) == .timedOut)
        #expect(delegate.overlayUpdated.wait(timeout: .now()) == .timedOut)

        let activeWindowID = try #require(
            controller.spaceManager.activeSpace.windows.first?.windowID
        )
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { windowSvc.captureRequests.count == 2 })
        #expect(Set(try #require(windowSvc.captureRequests.last)) == [activeWindowID],
                "The first overlay should reuse every prewarmed preview except the active window")
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("Cached previews are served without re-capturing")
    func cachedPreviewsSkipCapture() throws {
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController()
        let spaceID = controller.spaceManager.spaces[0].id
        for windowID in [CGWindowID(101), 202, 303] {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T\(windowID)"),
                toSpaceID: spaceID
            )
        }
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage(), 303: makeTestImage()]

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 3 })
        keyboardSvc.simulateEvent(.escape)

        let frontWindowID = try #require(controller.spaceManager.activeSpace.windows.first?.windowID)
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
        let activeSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let otherSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: activeSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: otherSpaceID
        )
        controller.spaceManager.activateSpace(id: activeSpaceID)
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage()]

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 2 })
        keyboardSvc.simulateEvent(.escape)

        // With the active space emptied there is no last-active window left to refresh.
        controller.spaceManager.removeWindow(windowID: 101, fromSpaceID: activeSpaceID)
        controller.spaceManager.activateSpace(id: activeSpaceID)

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
        let activeSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let otherSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: activeSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Inbox"),
            toSpaceID: otherSpaceID
        )
        controller.spaceManager.activateSpace(id: activeSpaceID)
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeTestImage()]

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews.count == 2 })
        keyboardSvc.simulateEvent(.escape)

        controller.spaceManager.updateWindowTitle(windowID: 202, title: "Inbox (3)")

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
        let activeSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let otherSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: activeSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: otherSpaceID
        )
        controller.spaceManager.activateSpace(id: activeSpaceID)
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

    @Test("An expired preview stays visible until a valid refresh replaces it")
    func expiredPreviewUsesStaleWhileRevalidate() throws {
        let clock = TestClock()
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController(ttl: 60, clock: clock)
        let activeSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let otherSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: activeSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: otherSpaceID
        )
        controller.spaceManager.activateSpace(id: activeSpaceID)

        let staleImage = makeTestImage()
        windowSvc.capturedImages = [101: staleImage, 202: staleImage]
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews[202] === staleImage })
        keyboardSvc.simulateEvent(.escape)

        clock.advance(by: 61)
        windowSvc.capturedImages = [101: makeTestImage(), 202: makeUniformTestImage()]
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { windowSvc.captureRequests.count == 2 })
        #expect(waitUntil { Set(windowSvc.captureRequests[1]).contains(202) })
        #expect(controller.windowPreviews[202] === staleImage,
                "A corrupt refresh must not evict the last good preview")
        keyboardSvc.simulateEvent(.escape)

        let refreshedImage = makeTestImage()
        windowSvc.capturedImages = [101: makeTestImage(), 202: refreshedImage]
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { windowSvc.captureRequests.count == 3 })
        #expect(Set(try #require(windowSvc.captureRequests.last)).contains(202),
                "A failed refresh must leave the stale preview eligible for retry")
        #expect(waitUntil { controller.windowPreviews[202] === refreshedImage })
        keyboardSvc.simulateEvent(.escape)
    }

    @Test("The all-previews policy re-captures every window")
    func allPolicyCapturesEveryWindow() {
        let (controller, windowSvc, keyboardSvc, delegate) = makeCacheController(policy: .all)
        let spaceID = controller.spaceManager.spaces[0].id
        for windowID in [CGWindowID(101), 202, 303] {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T\(windowID)"),
                toSpaceID: spaceID
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
        let spaceID = controller.spaceManager.spaces[0].id
        for windowID in [CGWindowID(101), 202] {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T\(windowID)"),
                toSpaceID: spaceID
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

    @Test("Cmd+Option+Tab hold opens overlay in space mode")
    func cmdOptionTabHold() {
        let (controller, _, keyboardSvc) = makeController()
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)
        keyboardSvc.simulateEvent(.cmdOptionTabHold)
        #expect(controller.isSpaceManagerVisible)
        #expect(controller.selectedSpaceIndex == 1)
    }

    @Test("Overlay last-space shortcut selects the final stage")
    func overlayLastSpaceShortcut() {
        let (controller, _, keyboardSvc) = makeController()
        for _ in 0..<3 {
            controller.spaceManager.createSpace(position: .below)
        }

        keyboardSvc.simulateEvent(.cmdOptionTabHold)
        keyboardSvc.simulateEvent(.jumpToLastSpace)

        #expect(controller.isSpaceManagerVisible)
        #expect(controller.selectedSpaceIndex == controller.spaceManager.spaces.count - 1)
    }

    @Test("Escape discards")
    func escape() {
        let (controller, _, keyboardSvc) = makeController()
        let originalSpaceID = controller.spaceManager.activeSpaceID
        keyboardSvc.simulateEvent(.cmdTabHold)
        keyboardSvc.simulateEvent(.escape)
        #expect(!controller.isSpaceManagerVisible)
        #expect(controller.spaceManager.activeSpaceID == originalSpaceID)
    }

    @Test("Desktop selection closes the overlay and requests the real desktop")
    func desktopSelectionRevealsDesktop() {
        let (controller, _, keyboardSvc) = makeController()
        var revealCount = 0
        controller.onDesktopReveal = { revealCount += 1 }

        keyboardSvc.simulateEvent(.cmdTabHold)
        controller.revealDesktop()

        #expect(!controller.isSpaceManagerVisible)
        #expect(revealCount == 1)
    }

    @Test("Held Tab stops at the last window and a fresh press wraps")
    func tabCycle() {
        let (controller, _, keyboardSvc) = makeController()
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toSpaceID: spaceID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 1) // starts at second window like native
        keyboardSvc.simulateEvent(.nextWindowRepeat)
        #expect(controller.selectedWindowIndex == 2)
        keyboardSvc.simulateEvent(.nextWindowRepeat)
        #expect(controller.selectedWindowIndex == 2) // held Tab stops at the end
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 0) // release and press Tab again
    }

    @Test("Left and right arrows preview a reorder and apply it only on commit")
    func reorderWindowWithinSpace() {
        let (controller, _, keyboardSvc) = makeController()
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toSpaceID: spaceID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 1)

        keyboardSvc.simulateEvent(.moveWindowRight)
        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101, 202, 303])
        #expect(controller.overlaySpaceManager.spaces[0].windows.map(\.windowID) == [101, 303, 202])
        #expect(controller.selectedWindowIndex == 2)

        keyboardSvc.simulateEvent(.moveWindowRight)
        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101, 202, 303])
        #expect(controller.selectedWindowIndex == 2)

        keyboardSvc.simulateEvent(.moveWindowLeft)
        keyboardSvc.simulateEvent(.moveWindowLeft)
        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101, 202, 303])
        #expect(controller.overlaySpaceManager.spaces[0].windows.map(\.windowID) == [202, 101, 303])
        #expect(controller.selectedWindowIndex == 0)

        keyboardSvc.simulateEvent(.moveWindowLeft)
        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101, 202, 303])
        #expect(controller.selectedWindowIndex == 0)

        keyboardSvc.simulateEvent(.cmdRelease)
        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [202, 101, 303])
    }

    @Test("Escape discards pending stage-stack moves")
    func escapeDiscardsPendingStageStackMoves() {
        let (controller, _, keyboardSvc) = makeController()
        let firstSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: firstSpaceID
        )
        controller.spaceManager.activateSpace(id: firstSpaceID)

        keyboardSvc.simulateEvent(.cmdTabHold)
        keyboardSvc.simulateEvent(.moveWindowDown)

        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101])
        #expect(controller.overlaySpaceManager.spaces[1].windows.map(\.windowID) == [101])

        keyboardSvc.simulateEvent(.escape)

        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101])
        #expect(controller.spaceManager.spaces[1].windows.isEmpty)
    }

    @Test("Held backward Tab stops at the first window and a fresh press wraps")
    func backwardTabCycle() {
        let (controller, _, keyboardSvc) = makeController()
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toSpaceID: spaceID)

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
        let spaceID = controller.spaceManager.activeSpaceID
        for windowID in [CGWindowID(101), 202, 303] {
            controller.spaceManager.addWindow(
                SpaceWindow(
                    windowID: windowID,
                    ownerBundleID: "com.example.App",
                    ownerName: "App",
                    windowTitle: "Window \(windowID)"
                ),
                toSpaceID: spaceID
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

    @Test("Quit hides every window owned by the terminating app without making it dormant")
    func quitSelectedApp() {
        let (controller, windowService, keyboardService) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 11),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2", ownerPID: 22),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 303, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3", ownerPID: 22),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 404, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T4", ownerPID: 33),
            toSpaceID: spaceID
        )

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.selectedWindowIndex == 1)
        keyboardService.simulateEvent(.quitSelectedApp)

        #expect(windowService.terminatedPIDs == [22])
        #expect(controller.isSpaceManagerVisible)
        #expect(controller.spaceManager.activeSpace.windows.map(\.windowID) == [101, 202, 303, 404])
        #expect(controller.spaceManager.dormantWindowAssignments.isEmpty)
        #expect(controller.overlaySpaceManager.activeSpace.windows.map(\.windowID) == [101, 404])
        #expect(controller.selectedWindowIndex == 1)

        keyboardService.simulateEvent(.cmdRelease)

        #expect(windowService.raisedWindowID == 404)
        #expect(windowService.frontedWindows == [FrontWindowRequest(windowID: 404, ownerPID: 33)])
    }

    @Test("A rejected quit leaves the selected app available")
    func rejectedQuitLeavesAppAvailable() {
        let (controller, windowService, keyboardService) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 11),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2", ownerPID: 22),
            toSpaceID: spaceID
        )
        windowService.terminateAppResult = false

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.quitSelectedApp)

        #expect(controller.overlaySpaceManager.activeSpace.windows.map(\.windowID) == [101, 202])

        keyboardService.simulateEvent(.cmdRelease)

        #expect(windowService.raisedWindowID == 202)
        #expect(windowService.frontedWindows == [FrontWindowRequest(windowID: 202, ownerPID: 22)])
    }

    @Test("External activation restores an app whose quit is still pending")
    func activationResolvesPendingQuit() {
        let (controller, _, keyboardService) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 11),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2", ownerPID: 22),
            toSpaceID: spaceID
        )

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.quitSelectedApp)
        #expect(controller.overlaySpaceManager.activeSpace.windows.map(\.windowID) == [101])

        controller.recordWindowActivation(windowID: 202)

        #expect(controller.overlaySpaceManager.activeSpace.windows.map(\.windowID) == [202, 101])
    }

    @Test("Process exit releases termination state before its PID can be reused")
    func processExitResolvesPendingQuit() {
        let (controller, _, keyboardService) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 11),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2", ownerPID: 22),
            toSpaceID: spaceID
        )

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.quitSelectedApp)
        #expect(controller.overlaySpaceManager.activeSpace.windows.map(\.windowID) == [101])

        _ = controller.spaceManager.removeAllWindows(forOwnerPID: 22)
        controller.recordAppTermination(ownerPID: 22)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3", ownerPID: 22),
            toSpaceID: spaceID
        )

        #expect(controller.overlaySpaceManager.activeSpace.windows.map(\.windowID) == [101, 303])
    }

    @Test("Quit does nothing when the space has no windows")
    func quitSelectedAppWithoutSelection() {
        let (_, windowService, keyboardService) = makeController()

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.quitSelectedApp)

        #expect(windowService.terminatedPIDs.isEmpty)
    }

    @Test("Close requests the selected window, not its owning app")
    func closeSelectedWindow() {
        let (controller, windowService, keyboardService) = makeController()
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 11),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2", ownerPID: 22),
            toSpaceID: spaceID
        )

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(controller.selectedWindowIndex == 1)
        keyboardService.simulateEvent(.closeSelectedWindow)

        #expect(windowService.closedWindowIDs == [202])
        #expect(windowService.terminatedPIDs.isEmpty)
        #expect(controller.isSpaceManagerVisible)
        #expect(controller.spaceManager.activeSpace.windows.map(\.windowID) == [101])
        #expect(controller.overlaySpaceManager.activeSpace.windows.map(\.windowID) == [101])
        #expect(controller.selectedWindowIndex == 0)
        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { delegate.overlayWindowIDSets.last == [101] })
    }

    @Test("Close does nothing when the space has no windows")
    func closeSelectedWindowWithoutSelection() {
        let (_, windowService, keyboardService) = makeController()

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.closeSelectedWindow)

        #expect(windowService.closedWindowIDs.isEmpty)
    }

    @Test("A rejected close keeps the selected window in the overlay")
    func rejectedCloseSelectedWindowKeepsAssignment() {
        let (controller, windowService, keyboardService) = makeController()
        windowService.closeWindowResult = false
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceID
        )

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.closeSelectedWindow)

        #expect(controller.spaceManager.activeSpace.windows.map(\.windowID) == [101])
        #expect(controller.overlaySpaceManager.activeSpace.windows.map(\.windowID) == [101])
        #expect(controller.selectedWindowIndex == 0)
    }

    @Test("A quit app's windows leave the open overlay and pull the selection back in range")
    func liveWindowRemovalRefreshesOpenOverlay() {
        let (controller, _, keyboardService) = makeController()
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        let spaceID = controller.spaceManager.activeSpaceID
        for (windowID, pid) in [(CGWindowID(101), pid_t(11)), (202, 22), (303, 22)] {
            controller.spaceManager.addWindow(
                SpaceWindow(
                    windowID: windowID,
                    ownerBundleID: "com.a",
                    ownerName: "A",
                    windowTitle: "T\(windowID)",
                    ownerPID: pid
                ),
                toSpaceID: spaceID
            )
        }
        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.nextWindow)
        #expect(controller.selectedWindowIndex == 2)

        _ = controller.spaceManager.makeWindowsDormant(forOwnerPID: 22)
        controller.handleLiveWindowsRemoved()

        #expect(controller.selectedWindowIndex == 0)
        #expect(delegate.overlayUpdated.wait(timeout: .now() + livenessTimeout) == .success)
    }

    @Test("Removing the last window leaves the selection at zero rather than negative")
    func liveWindowRemovalOfEveryWindow() {
        let (controller, _, keyboardService) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "com.a",
                ownerName: "A",
                windowTitle: "T1",
                ownerPID: 11
            ),
            toSpaceID: spaceID
        )
        keyboardService.simulateEvent(.cmdTabHold)

        _ = controller.spaceManager.makeWindowsDormant(forOwnerPID: 11)
        controller.handleLiveWindowsRemoved()

        #expect(controller.selectedWindowIndex == 0)
    }

    @Test("Held app-window shortcut stops at the last window")
    func heldAppWindowCycleStopsAtEnd() {
        let (controller, windowService, keyboardService) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        for windowID in [CGWindowID(101), 202, 303] {
            controller.spaceManager.addWindow(
                SpaceWindow(
                    windowID: windowID,
                    ownerBundleID: "com.example.App",
                    ownerName: "App",
                    windowTitle: "Window \(windowID)"
                ),
                toSpaceID: spaceID
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
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toSpaceID: spaceID)

        controller.recordWindowActivation(windowID: 303)
        controller.recordWindowActivation(windowID: 101)

        let windowIDs = controller.spaceManager.activeSpace.windows.map(\.windowID)
        #expect(windowIDs == [101, 303, 202])
    }

    // MARK: - Front verification

    /// The window server accepts a front request and reports success whether or not the app comes
    /// forward, so the return value alone cannot tell a working switch from a dead one. These
    /// cover the only check that can: reading back who is actually in front afterwards.
    private func makeFrontedController() -> (SpaceController, MockWindowService) {
        let (controller, windowService, _) = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B",
                        windowTitle: "T2", ownerPID: 4242),
            toSpaceID: spaceID
        )
        controller.switchToSpace(id: spaceID, raiseWindowID: 202)
        return (controller, windowService)
    }

    @Test("A front request the window server took but did not honour is caught")
    func unhonouredFrontIsCaught() {
        let (controller, windowService) = makeFrontedController()
        windowService.frontmostPID = 11

        #expect(controller.verifyPendingFront() == false)
    }

    @Test("A front request that landed is not reported as a failure")
    func honouredFrontIsNotCaught() {
        let (controller, windowService) = makeFrontedController()
        windowService.frontmostPID = 4242

        #expect(controller.verifyPendingFront() == true)
    }

    @Test("There is nothing to verify when no window was fronted")
    func noFrontRequestVerifiesNothing() {
        let (controller, _, _) = makeController()

        #expect(controller.verifyPendingFront() == nil)
    }

    @Test("A front request is verified once")
    func frontRequestIsVerifiedOnce() {
        let (controller, windowService) = makeFrontedController()
        windowService.frontmostPID = 11

        #expect(controller.verifyPendingFront() == false)
        #expect(controller.verifyPendingFront() == nil)
    }

    // MARK: - Focus attribution

    /// Two windows of one app, one per space, as the reported Dia case had them.
    private func makeSameAppTwoSpaceController(
        clock: TestClock
    ) -> (SpaceController, UUID, UUID) {
        let controller = SpaceController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .unfocused },
            clock: { clock.now }
        )
        let spaceAID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let spaceBID = controller.spaceManager.spaces[1].id

        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 888, ownerBundleID: "com.other", ownerName: "Other",
                        windowTitle: "Other A", ownerPID: 11),
            toSpaceID: spaceAID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "com.dia", ownerName: "Dia",
                        windowTitle: "Dia A", ownerPID: 40694),
            toSpaceID: spaceAID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 4795, ownerBundleID: "com.dia", ownerName: "Dia",
                        windowTitle: "Dia B", ownerPID: 40694),
            toSpaceID: spaceBID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 999, ownerBundleID: "com.other", ownerName: "Other",
                        windowTitle: "Other B", ownerPID: 11),
            toSpaceID: spaceBID
        )

        // Put both spaces in a state a wrong credit would visibly disturb: the app's window is
        // second in each, so it reaching the head is evidence of an activation rather than the
        // order it was added in.
        controller.spaceManager.activateSpace(id: spaceAID)
        controller.recordWindowActivation(windowID: 999)
        controller.recordWindowActivation(windowID: 888)
        return (controller, spaceAID, spaceBID)
    }

    // Fronting a process makes macOS report focus on *a* window of that app, not necessarily
    // the one that was named. For a multi-window app it regularly names one on another space,
    // and read literally that is a user activation of a window the user never touched: it takes
    // the MRU head, so the next Option-Tab offers a window on a space they were never on.
    @Test("A same-app focus report is credited to the window Debut asked for")
    func focusReportForAnotherWindowIsCreditedToTheRequestedWindow() {
        let clock = TestClock()
        let (controller, spaceAID, spaceBID) = makeSameAppTwoSpaceController(clock: clock)

        controller.switchToSpace(id: spaceAID, raiseWindowID: 4794)
        controller.recordWindowActivation(windowID: 4795)

        let spaceA = controller.spaceManager.allSpaces.first { $0.id == spaceAID }
        let spaceB = controller.spaceManager.allSpaces.first { $0.id == spaceBID }
        #expect(spaceA?.windows.map(\.windowID) == [4794, 888])
        #expect(spaceB?.windows.map(\.windowID) == [999, 4795])
    }

    // The correction is one-shot. A genuine later move between the app's own windows is a real
    // user choice and has to be recorded as itself.
    @Test("Only the first focus report after a request is re-credited")
    func onlyTheFirstFocusReportIsReattributed() {
        let clock = TestClock()
        let (controller, spaceAID, spaceBID) = makeSameAppTwoSpaceController(clock: clock)

        controller.switchToSpace(id: spaceAID, raiseWindowID: 4794)
        controller.recordWindowActivation(windowID: 4795)
        controller.recordWindowActivation(windowID: 4795)

        let spaceB = controller.spaceManager.allSpaces.first { $0.id == spaceBID }
        #expect(spaceB?.windows.map(\.windowID) == [4795, 999])
    }

    // Fronting a window that is already focused produces no report to consume the request, so
    // the request has to lapse on its own or it would misread a later click as Debut's own.
    @Test("A focus request stops applying once it goes stale")
    func staleFocusRequestStopsApplying() {
        let clock = TestClock()
        let (controller, spaceAID, spaceBID) = makeSameAppTwoSpaceController(clock: clock)

        controller.switchToSpace(id: spaceAID, raiseWindowID: 4794)
        clock.advance(by: 5)
        controller.recordWindowActivation(windowID: 4795)

        let spaceB = controller.spaceManager.allSpaces.first { $0.id == spaceBID }
        #expect(spaceB?.windows.map(\.windowID) == [4795, 999])
    }

    @Test("A focus report from another app is credited as reported")
    func focusReportFromAnotherAppIsCreditedAsReported() {
        let clock = TestClock()
        let (controller, spaceAID, spaceBID) = makeSameAppTwoSpaceController(clock: clock)

        controller.switchToSpace(id: spaceAID, raiseWindowID: 4794)
        controller.recordWindowActivation(windowID: 999)
        controller.recordWindowActivation(windowID: 4795)

        let spaceB = controller.spaceManager.allSpaces.first { $0.id == spaceBID }
        #expect(spaceB?.windows.map(\.windowID) == [4795, 999])
    }

    // Activation is the one path that admits a window without consulting the exclusion list:
    // discovery filters its snapshots, but the focus callback carries a bare window ID and the
    // controller resolved the owner from an unfiltered window list. That is how an excluded
    // Finder window reached a space at all.
    @Test("Activation does not admit a window belonging to an excluded app")
    func activationRefusesExcludedWindow() {
        let (controller, windowService, _) = makeController()
        windowService.windowList = [WindowInfo(
            windowID: 40915,
            ownerBundleID: "com.apple.finder",
            ownerName: "Finder",
            ownerPID: 20,
            title: "Debut",
            bounds: .zero,
            isOnScreen: true
        )]
        controller.excludedBundleIDs = ["com.apple.finder"]

        controller.recordWindowActivation(windowID: 40915)

        #expect(controller.spaceManager.allSpaces.flatMap(\.windows).isEmpty)
    }

    // Spaces are desktops, so when macOS reports a focused window on the desktop showing,
    // that outranks whatever Debut recorded earlier. The window moves to the showing space
    // rather than the user being moved to the window, and it must not end up in both.
    @Test("Cross-space window activation moves the window, not the user")
    func crossSpaceActivationMovesTheWindow() {
        let (controller, _, _) = makeController()
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        controller.spaceSwitcher = spaces
        let spaceAID = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let spaceBID = controller.spaceManager.spaces[1].id

        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceAID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceBID)

        spaces.windowDesktops = [101: 1, 202: 1]
        controller.spaceManager.activateSpace(id: spaceAID)
        controller.switchToSpace(id: spaceBID)
        #expect(controller.spaceManager.activeSpaceID == spaceBID)

        controller.recordWindowActivation(windowID: 101)

        #expect(controller.spaceManager.activeSpaceID == spaceBID)
        #expect(!controller.spaceManager.spaces[0].windows.contains(where: { $0.windowID == 101 }))
        #expect(controller.spaceManager.spaces[1].windows.contains(where: { $0.windowID == 101 }))
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

        var manager = SpaceManager()
        manager.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "com.ghost",
                ownerName: "Ghost",
                windowTitle: "Stale",
                ownerPID: 10
            ),
            toSpaceID: manager.activeSpaceID
        )
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: MockKeyboardService(),
            spaceManager: manager
        )

        controller.rebuildWindowCache(using: discovery)

        #expect(controller.spaceManager.spaces.count == 1)
        #expect(controller.spaceManager.activeSpace.windows.map(\.windowID) == [202])
        #expect(controller.selectedSpaceIndex == 0)
        #expect(controller.selectedWindowIndex == 0)
    }

    @Test("Cmd+Tab tap switches to second MRU window")
    func cmdTabTap() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceID)

        keyboardSvc.simulateEvent(.cmdTabTap)

        #expect(windowSvc.raisedWindowID == 202)
        #expect(controller.spaceManager.activeSpace.windows[0].windowID == 202)
    }

    @Test("Quick switch focuses the current app's MRU window in the target space")
    func quickSwitchKeepsCurrentApp() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let sourceSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Source"),
            toSpaceID: sourceSpaceID
        )

        controller.spaceManager.createSpace(position: .below)
        let targetSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.other", ownerName: "Other", windowTitle: "Target MRU"),
            toSpaceID: targetSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 303, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Target Current"),
            toSpaceID: targetSpaceID
        )
        controller.spaceManager.activateSpace(id: sourceSpaceID)

        keyboardSvc.simulateEvent(.switchToSpaceKeepingCurrentApplication(2))

        #expect(controller.spaceManager.activeSpaceID == targetSpaceID)
        #expect(windowSvc.raisedWindowID == 303)
        #expect(windowSvc.activatedBundleID == "com.current")
        #expect(controller.spaceManager.activeSpace.windows.first?.windowID == 303)
    }

    // Debut and macOS both write focus within a few milliseconds of the Space flip, so the
    // winner varies run to run, and `recordWindowActivation` then writes a lost race into the
    // space's MRU head — making a single loss permanent. Plain quick switch therefore moves the
    // desktop and leaves the choice of app to macOS.
    @Test("Quick switch moves the desktop without focusing anything")
    func quickSwitchDefaultsToTargetMRU() {
        let (controller, windowService, keyboardService) = makeController()
        let sourceSpaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Source"),
            toSpaceID: sourceSpaceID
        )
        controller.spaceManager.createSpace(position: .below)
        let targetSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.other", ownerName: "Other", windowTitle: "Target MRU"),
            toSpaceID: targetSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 303, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Same App"),
            toSpaceID: targetSpaceID
        )

        keyboardService.simulateEvent(.switchToSpace(2))

        #expect(controller.spaceManager.activeSpaceID == targetSpaceID)
        #expect(windowService.raisedWindowID == nil)
        #expect(windowService.activatedBundleID == nil)
    }

    @Test("Quick switch falls back to the target space's MRU window when the current app is absent")
    func quickSwitchFallsBackToTargetMRU() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let sourceSpaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.current", ownerName: "Current", windowTitle: "Source"),
            toSpaceID: sourceSpaceID
        )

        controller.spaceManager.createSpace(position: .below)
        let targetSpaceID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.other", ownerName: "Other", windowTitle: "Target MRU"),
            toSpaceID: targetSpaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 303, ownerBundleID: "com.third", ownerName: "Third", windowTitle: "Target Older"),
            toSpaceID: targetSpaceID
        )
        controller.spaceManager.activateSpace(id: sourceSpaceID)

        keyboardSvc.simulateEvent(.switchToSpaceKeepingCurrentApplication(2))

        #expect(controller.spaceManager.activeSpaceID == targetSpaceID)
        #expect(windowSvc.raisedWindowID == 202)
        #expect(windowSvc.activatedBundleID == "com.other")
    }

    @Test("Window previews persist for hidden windows")
    func previewPersistsWhenHidden() {
        let (controller, windowSvc, keyboardSvc) = makeController()
        let delegate = PreviewRefreshDelegate()
        controller.delegate = delegate
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)
        controller.spaceManager.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceID)

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
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)

        let testImage = makeTestImage()
        windowSvc.capturedImages = [101: testImage]

        // Open overlay to populate previews
        keyboardSvc.simulateEvent(.cmdTabHold)
        #expect(delegate.overlayOpened.wait(timeout: .now() + livenessTimeout) == .success)
        #expect(waitUntil { controller.windowPreviews[101] != nil })
        keyboardSvc.simulateEvent(.escape)

        // Remove window from space
        controller.spaceManager.removeWindow(windowID: 101, fromSpaceID: spaceID)

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
        #expect(SpaceController.focusProbeTimeout > 0)
        #expect(SpaceController.focusProbeTimeout <= 0.1)
    }
}

/// Card shapes come from the sizes discovery reports, and stop coming while the overlay is up:
/// a window resized behind the overlay must not reflow the grid under the cursor.
@Suite("Window sizes behind the card shapes")
struct SpaceControllerWindowSizeTests {

    private func info(_ id: CGWindowID, _ size: CGSize) -> WindowInfo {
        WindowInfo(
            windowID: id,
            ownerBundleID: "com.a",
            ownerName: "A",
            ownerPID: 1,
            title: "W\(id)",
            bounds: CGRect(origin: .zero, size: size),
            isOnScreen: true
        )
    }

    private func makeController() -> (SpaceController, MockKeyboardService) {
        let keyboardService = MockKeyboardService()
        let controller = SpaceController(
            windowService: MockWindowService(),
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        return (controller, keyboardService)
    }

    @Test("Discovery records the size each window was found at")
    func recordsDiscoveredSizes() {
        let (controller, _) = makeController()

        controller.recordWindowSizes([
            info(101, CGSize(width: 1_600, height: 800)),
            info(102, CGSize(width: 600, height: 1_200)),
        ])

        #expect(controller.windowSizes[101] == CGSize(width: 1_600, height: 800))
        #expect(controller.windowSizes[102] == CGSize(width: 600, height: 1_200))
    }

    @Test("Sizes freeze for as long as the overlay is up")
    func sizesFreezeWhileOverlayIsVisible() {
        let (controller, keyboardService) = makeController()
        // Both windows are assigned, so a size that goes missing went missing to the freeze
        // rather than to the pruning that follows every window a space no longer holds.
        for id in [CGWindowID(101), CGWindowID(999)] {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: id, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W\(id)"),
                toSpaceID: controller.spaceManager.spaces[0].id
            )
        }
        controller.recordWindowSizes([info(101, CGSize(width: 1_600, height: 800))])

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.isSpaceManagerVisible)
        controller.recordWindowSizes([
            info(101, CGSize(width: 400, height: 400)),
            info(999, CGSize(width: 500, height: 500)),
        ])

        #expect(controller.windowSizes[101] == CGSize(width: 1_600, height: 800))
        #expect(controller.windowSizes[999] == nil)
    }

    @Test("Resizing a window reshapes its card without waiting for an app switch")
    func resizeUpdatesTheRecordedSize() {
        let (controller, _) = makeController()
        controller.recordWindowSizes([info(101, CGSize(width: 1_600, height: 800))])

        controller.recordWindowSize(windowID: 101, size: CGSize(width: 600, height: 1_200))

        #expect(controller.windowSizes[101] == CGSize(width: 600, height: 1_200))
    }

    @Test("A resize that lands while the overlay is up is dropped")
    func resizeFreezesWhileOverlayIsVisible() {
        let (controller, keyboardService) = makeController()
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W101"),
            toSpaceID: controller.spaceManager.spaces[0].id
        )
        controller.recordWindowSizes([info(101, CGSize(width: 1_600, height: 800))])

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.isSpaceManagerVisible)
        controller.recordWindowSize(windowID: 101, size: CGSize(width: 400, height: 400))

        #expect(controller.windowSizes[101] == CGSize(width: 1_600, height: 800))
    }
}
