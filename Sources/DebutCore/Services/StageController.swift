import AppKit
import ApplicationServices
import CoreGraphics

private final class PreviewCaptureMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private let batchID: UUID
    private let firstID: UUID
    private var captureIDs: [CGWindowID: UUID]
    private var capturedCount = 0
    private var recordedFirst = false
    private let overlayPresentation: OverlayPresentationContext?
    private let overlayPresentationRecorder: OverlayPresentationRecorder

    init(
        windowIDs: [CGWindowID],
        overlayPresentation: OverlayPresentationContext? = nil,
        overlayPresentationRecorder: OverlayPresentationRecorder = .shared
    ) {
        self.overlayPresentation = overlayPresentation
        self.overlayPresentationRecorder = overlayPresentationRecorder
        batchID = PerformanceRecorder.shared.begin(
            .previewAll,
            workload: .init(windows: windowIDs.count, captures: windowIDs.count),
            traceID: overlayPresentation?.traceID
        )
        firstID = PerformanceRecorder.shared.begin(
            .previewFirst,
            workload: .init(windows: windowIDs.count, captures: min(1, windowIDs.count)),
            traceID: overlayPresentation?.traceID
        )
        captureIDs = Dictionary(uniqueKeysWithValues: windowIDs.map { windowID in
            (
                windowID,
                PerformanceRecorder.shared.begin(
                    .previewCapture,
                    workload: .init(captures: 1),
                    traceID: overlayPresentation?.traceID
                )
            )
        })
    }

    func recordCapture(windowID: CGWindowID) {
        lock.withLock {
            if let captureID = captureIDs.removeValue(forKey: windowID) {
                _ = PerformanceRecorder.shared.end(captureID, sampleResources: false)
            }
            capturedCount += 1
            if !recordedFirst {
                recordedFirst = true
                _ = PerformanceRecorder.shared.end(firstID)
                if let overlayPresentation {
                    overlayPresentationRecorder.mark(
                        .firstPreviewCompleted,
                        for: overlayPresentation
                    )
                }
            }
        }
    }

    func finish() -> Int {
        lock.withLock {
            for captureID in captureIDs.values {
                _ = PerformanceRecorder.shared.end(captureID, sampleResources: false)
            }
            captureIDs.removeAll()
            if !recordedFirst {
                recordedFirst = true
                _ = PerformanceRecorder.shared.end(firstID)
                if let overlayPresentation {
                    overlayPresentationRecorder.mark(
                        .firstPreviewCompleted,
                        for: overlayPresentation
                    )
                }
            }
            _ = PerformanceRecorder.shared.end(batchID)
            if let overlayPresentation {
                overlayPresentationRecorder.mark(.allPreviewsCompleted, for: overlayPresentation)
            }
            return capturedCount
        }
    }
}

public protocol StageControllerDelegate: AnyObject {
    func stageControllerDidOpenOverlay(_ controller: StageController)
    func stageControllerDidOpenOverlay(
        _ controller: StageController,
        overlayPresentation: OverlayPresentationContext?
    )
    func stageControllerDidCloseOverlay(_ controller: StageController)
    func stageControllerDidCloseOverlay(
        _ controller: StageController,
        overlayPresentation: OverlayPresentationContext?
    )
    func stageControllerDidUpdateSelection(_ controller: StageController)
    func stageControllerDidSwitchStage(_ controller: StageController)
    func stageControllerDidMutateState(_ controller: StageController)
}

public extension StageControllerDelegate {
    func stageControllerDidOpenOverlay(
        _ controller: StageController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        stageControllerDidOpenOverlay(controller)
    }

    func stageControllerDidCloseOverlay(
        _ controller: StageController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        stageControllerDidCloseOverlay(controller)
    }
}

public final class StageController: KeyboardEventDelegate, @unchecked Sendable {
    public var stageManager: StageManager
    public let windowService: any WindowService
    public let keyboardService: any KeyboardService
    public weak var delegate: StageControllerDelegate?
    public var onCommandUsed: (@Sendable (KeyAction) -> Void)?
    public var onDesktopReveal: (() -> Void)?

    public private(set) var isStageManagerVisible: Bool = false
    public var selectedStageIndex: Int = 0
    public var selectedWindowIndex: Int = 0
    public private(set) var keyboardServiceStarted: Bool = false
    public var overlayPresentationDelay: TimeInterval
    public var quickSwitchBehavior: QuickSwitchBehavior

    /// Window previews captured when overlay opens
    public private(set) var windowPreviews: [CGWindowID: CGImage] = [:]
    public private(set) var variedWindowPreviewIDs: Set<CGWindowID> = []

    /// Desktop surfaces — one per display, sitting between active and inactive stage windows
    public var desktopSurfaces: DesktopSurfaceCoordinator?

    private var preOverlayStageID: UUID?
    private var previousStageID: UUID?
    private var backtickCycleWindows: [CGWindowID] = []
    private var backtickCycleIndex: Int = 0
    private var overlayPresentationGeneration: UInt = 0
    private var isOverlayPresented: Bool = false
    private let fullscreenAppActiveProvider: (() -> Bool)?
    private var previewCaptureTask: Task<Void, Never>?
    private var previewCaptureGeneration: UInt = 0
    private var frontmostAppIsExcluded = false
    private let diag = DiagnosticReporter.shared
    private let overlayPresentationRecorder: OverlayPresentationRecorder
    private var activeOverlayPresentation: OverlayPresentationContext?

    public init(
        windowService: any WindowService,
        keyboardService: any KeyboardService,
        stageManager: StageManager = StageManager(),
        overlayPresentationDelay: TimeInterval = AppSettings.defaultOverlayPresentationDelay,
        quickSwitchBehavior: QuickSwitchBehavior = .stage,
        fullscreenAppActiveProvider: (() -> Bool)? = nil,
        overlayPresentationRecorder: OverlayPresentationRecorder = .shared
    ) {
        self.windowService = windowService
        self.keyboardService = keyboardService
        self.stageManager = stageManager
        self.overlayPresentationDelay = overlayPresentationDelay
        self.quickSwitchBehavior = quickSwitchBehavior
        self.fullscreenAppActiveProvider = fullscreenAppActiveProvider
        self.overlayPresentationRecorder = overlayPresentationRecorder

        let started = keyboardService.start(delegate: self)
        self.keyboardServiceStarted = started
        diag.report(started ? "event_tap_created" : "event_tap_failed")

        diag.setMainQueueStateProvider { [weak self] in
            guard let self else { return ["error": "controller deallocated"] }
            return [
                "overlayVisible": "\(self.isStageManagerVisible)",
                "stageCount": "\(self.stageManager.stages.count)",
                "activeStageIndex": "\(self.selectedStageIndex)",
                "selectedWindowIndex": "\(self.selectedWindowIndex)",
                "eventTapRunning": "\(self.keyboardService.isRunning)",
                "eventTapStarted": "\(self.keyboardServiceStarted)",
                "windowsInActiveStage": "\(self.stageManager.activeStage.windows.count)",
                "maxWindowsInStage": "\(self.stageManager.stages.map(\.windows.count).max() ?? 0)",
                "windowCountsByStage": self.stageManager.stages
                    .map { String($0.windows.count) }
                    .joined(separator: ","),
                "windowPreviewCount": "\(self.windowPreviews.count)",
                "variedWindowPreviewCount": "\(self.variedWindowPreviewIDs.count)",
            ]
        }
    }

    // MARK: - Stage switching

    /// Position-based label for a stage, e.g. "Stage 2". Used for diagnostics only.
    private func stageLabel(forID id: UUID) -> String {
        guard let index = stageManager.stages.firstIndex(where: { $0.id == id }) else { return "?" }
        return "Stage \(index + 1)"
    }

    public func switchToStage(id targetID: UUID, raiseWindowID: CGWindowID? = nil) {
        let workload = PerformanceWorkload(
            stages: stageManager.stages.count,
            windows: stageManager.stages.first(where: { $0.id == targetID })?.windows.count ?? 0
        )
        let performanceID = PerformanceRecorder.shared.begin(.stageSwitch, workload: workload)
        defer { PerformanceRecorder.shared.end(performanceID) }
        backtickCycleWindows = []
        backtickCycleIndex = 0

        let previousID = stageManager.activeStageID

        if previousID != targetID {
            let fromLabel = stageLabel(forID: previousID)
            let toLabel = stageLabel(forID: targetID)
            let targetStage = stageManager.stages.first(where: { $0.id == targetID })

            self.previousStageID = previousID
            stageManager.activateStage(id: targetID)

            // 1. Bring desktop surfaces to front — covers all inactive windows
            desktopSurfaces?.orderToFront()

            // 2. Raise all windows in the target stage above the surface (no app activation yet)
            let raiseID = PerformanceRecorder.shared.begin(
                .stageRaise,
                workload: .init(windows: targetStage?.windows.count ?? 0)
            )
            if let targetStage {
                for window in targetStage.windows {
                    _ = windowService.raiseWindow(windowID: window.windowID)
                }
            }
            _ = PerformanceRecorder.shared.end(raiseID)

            diag.report("stage_switched", details: [
                "from": fromLabel,
                "to": toLabel,
                "windowsInTarget": "\(targetStage?.windows.count ?? 0)",
            ])
        }

        // Focus the selected window and activate its app (single activation, no flash)
        let targetWindows = stageManager.stages.first(where: { $0.id == targetID })?.windows
        let focusWindowID = raiseWindowID ?? targetWindows?.first?.windowID
        if let focusWindowID {
            _ = windowService.raiseWindow(windowID: focusWindowID)
            stageManager.bringWindowToFront(windowID: focusWindowID, inStageID: targetID)
            if let bundleID = targetWindows?.first(where: { $0.windowID == focusWindowID })?.ownerBundleID {
                _ = windowService.activateApp(bundleID: bundleID)
            }
        }

        delegate?.stageControllerDidMutateState(self)
        delegate?.stageControllerDidSwitchStage(self)
    }

    // MARK: - Window ownership

    /// Rebuilds assignments in a local value so discovery diagnostics can read
    /// the controller's current state without overlapping an inout access to
    /// `stageManager`. Assign only after discovery has completed successfully.
    func rebuildWindowCache(using discovery: WindowDiscoveryService) {
        discovery.resetWindowTracking()
        var rebuiltManager = stageManager
        rebuiltManager.resetWindowCache()
        discovery.populateDefaultStage(&rebuiltManager)
        stageManager = rebuiltManager
        selectedStageIndex = 0
        selectedWindowIndex = 0
    }

    public func stageOwningWindow(windowID: CGWindowID) -> UUID? {
        stageManager.stageContainingWindow(windowID: windowID)
    }

    public func recordWindowActivation(windowID: CGWindowID) {
        if !backtickCycleWindows.isEmpty {
            if backtickCycleWindows.contains(windowID) {
                return
            }
            commitBacktickCycle()
        }

        let activeStageID = stageManager.activeStageID
        let ownerStageID = stageOwningWindow(windowID: windowID)

        if ownerStageID == activeStageID {
            // Window is in the active stage — update MRU
            stageManager.bringWindowToFront(windowID: windowID, inStageID: activeStageID)
            delegate?.stageControllerDidMutateState(self)
        } else if let ownerStageID {
            // Window belongs to another stage — switch to that stage
            diag.report("switching_to_window_stage", details: [
                "windowID": "\(windowID)",
                "targetStage": stageLabel(forID: ownerStageID),
            ])
            switchToStage(id: ownerStageID, raiseWindowID: windowID)
        } else {
            // Window not in any stage — new window, add to active stage.
            // This handles "code ." creating a new VSCode window while
            // other VSCode windows are in a different stage.
            let windows = windowService.listWindows()
            if let info = windows.first(where: { $0.windowID == windowID }) {
                let window = StageWindow(
                    windowID: info.windowID,
                    ownerBundleID: info.ownerBundleID,
                    ownerName: info.ownerName,
                    windowTitle: info.title,
                    ownerPID: info.ownerPID
                )
                stageManager.addWindow(window, toStageID: activeStageID)
                stageManager.bringWindowToFront(windowID: windowID, inStageID: activeStageID)
                delegate?.stageControllerDidMutateState(self)
            }
        }
    }

    public func updateFrontmostApp(isExcluded: Bool) {
        frontmostAppIsExcluded = isExcluded
    }

    public func markOverlayPresentation(
        _ phase: OverlayPresentationPhase,
        context: OverlayPresentationContext
    ) {
        overlayPresentationRecorder.mark(phase, for: context)
    }

    public func updateOverlayHostingView(
        _ state: OverlayHostingViewState,
        context: OverlayPresentationContext
    ) {
        overlayPresentationRecorder.updateHostingView(state, for: context)
    }

    public func completeOverlayPresentation(
        _ context: OverlayPresentationContext,
        outcome: OverlayPresentationOutcome
    ) {
        overlayPresentationRecorder.complete(context, outcome: outcome)
        if activeOverlayPresentation == context {
            activeOverlayPresentation = nil
        }
    }

    // MARK: - KeyboardEventDelegate

    public func handleKeyEvent(_ event: DebutKeyEvent) {
        handleKeyEvent(event, overlayPresentation: nil)
    }

    public func handleKeyEvent(
        _ event: DebutKeyEvent,
        overlayPresentation: OverlayPresentationContext?
    ) {
        if let overlayPresentation {
            activeOverlayPresentation = overlayPresentation
            overlayPresentationRecorder.updateConfiguredDelay(
                milliseconds: max(0, overlayPresentationDelay) * 1_000,
                for: overlayPresentation
            )
        }
        diag.report("key_event", level: .transient, details: ["keyEvent": "\(event)"])
        if let action = event.commandHintAction {
            onCommandUsed?(action)
        }

        switch event {
        case .cmdTabTap:
            handleCmdTabTap()
        case .cmdTabHold:
            if isStageManagerVisible {
                cycleWindow(forward: true)
            } else {
                openOverlay(selectNextWindow: true)
            }
        case .cmdShiftTabHold:
            if isStageManagerVisible {
                cycleWindow(forward: false)
            } else {
                openOverlay(selectLastWindow: true)
            }
        case .cmdOptionTabHold:
            if isStageManagerVisible {
                cycleStage(forward: true)
            } else {
                openOverlay(selectNextStage: true)
            }
        case .cmdOptionShiftTabHold:
            if isStageManagerVisible {
                cycleStage(forward: false)
            } else {
                openOverlay(selectPreviousStage: true)
            }
        case .cmdBacktick:
            handleCmdBacktick(reverse: false)
        case .cmdBacktickRepeat:
            handleCmdBacktick(reverse: false, wraps: false)
        case .cmdShiftBacktick:
            handleCmdBacktick(reverse: true)
        case .cmdRelease:
            commitBacktickCycle()
            commitSelection()
        case .escape:
            discardOverlay()
        case .nextWindow:
            cycleWindow(forward: true)
        case .nextWindowRepeat:
            cycleWindow(forward: true, wraps: false)
        case .previousWindow:
            cycleWindow(forward: false)
        case .nextStage:
            cycleStage(forward: true)
        case .previousStage:
            cycleStage(forward: false)
        case .jumpToStage(let index):
            jumpToStage(index: index - 1)
        case .jumpToLastStage:
            jumpToStage(index: stageManager.stages.count - 1)
        case .switchToStage(let position):
            quickSwitchToStage(index: position - 1)
        case .newStageBelow:
            createStage(position: .below)
        case .newStageAbove:
            createStage(position: .above)
        case .deleteStage:
            deleteSelectedStage()
        case .moveWindowUp:
            moveWindow(direction: .up)
        case .moveWindowDown:
            moveWindow(direction: .down)
        case .swapStageUp:
            swapStage(direction: .up)
        case .swapStageDown:
            swapStage(direction: .down)
        }
    }

    // MARK: - Quick switch

    /// Immediately switch to the stage at the given index (Ctrl+<0-9>).
    /// Works whether or not the overlay is open; if open, it is dismissed first.
    private func quickSwitchToStage(index: Int) {
        guard stageManager.stages.indices.contains(index) else { return }

        // Stage window order is MRU. Capture the active app before switching,
        // then prefer that app's most-recent window in the destination stage.
        let activeBundleID = stageManager.activeStage.windows.first?.ownerBundleID
        let targetStage = stageManager.stages[index]
        let matchingWindowID = quickSwitchBehavior == .sameApplication
            ? activeBundleID.flatMap { bundleID in
                targetStage.windows.first(where: { $0.ownerBundleID == bundleID })?.windowID
            }
            : nil

        backtickCycleWindows = []
        backtickCycleIndex = 0

        if isStageManagerVisible {
            isStageManagerVisible = false
            if let tapService = keyboardService as? EventTapKeyboardService {
                tapService.overlayVisible = false
            }
            dismissOverlayPresentation()
        }

        switchToStage(id: targetStage.id, raiseWindowID: matchingWindowID)
        selectedStageIndex = index
        selectedWindowIndex = 0
    }

    // MARK: - Private

    private func handleCmdBacktick(reverse: Bool, wraps: Bool = true) {
        let activeStage = stageManager.activeStage
        guard let frontWindow = activeStage.windows.first else { return }

        let bundleID = frontWindow.ownerBundleID
        let sameAppWindows = activeStage.windows.filter { $0.ownerBundleID == bundleID }
        guard sameAppWindows.count >= 2 else { return }

        let windowIDs = sameAppWindows.map(\.windowID)

        if backtickCycleWindows != windowIDs {
            backtickCycleWindows = windowIDs
            backtickCycleIndex = 0
        }

        if reverse {
            backtickCycleIndex = wraps
                ? (backtickCycleIndex - 1 + backtickCycleWindows.count) % backtickCycleWindows.count
                : max(0, backtickCycleIndex - 1)
        } else {
            backtickCycleIndex = wraps
                ? (backtickCycleIndex + 1) % backtickCycleWindows.count
                : min(backtickCycleWindows.count - 1, backtickCycleIndex + 1)
        }

        let targetID = backtickCycleWindows[backtickCycleIndex]
        _ = windowService.raiseWindow(windowID: targetID)
        _ = windowService.activateApp(bundleID: bundleID)
    }

    private func commitBacktickCycle() {
        guard !backtickCycleWindows.isEmpty else { return }
        let finalWindowID = backtickCycleWindows[backtickCycleIndex]
        stageManager.bringWindowToFront(
            windowID: finalWindowID,
            inStageID: stageManager.activeStageID
        )
        backtickCycleWindows = []
        backtickCycleIndex = 0
        delegate?.stageControllerDidMutateState(self)
    }

    private func handleCmdTabTap() {
        let activeStage = stageManager.activeStage
        guard !activeStage.windows.isEmpty else { return }
        let targetIndex = frontmostAppIsExcluded ? 0 : 1
        guard activeStage.windows.indices.contains(targetIndex) else { return }
        let targetWindow = activeStage.windows[targetIndex]
        _ = windowService.raiseWindow(windowID: targetWindow.windowID)
        _ = windowService.activateApp(bundleID: targetWindow.ownerBundleID)
        stageManager.bringWindowToFront(windowID: targetWindow.windowID, inStageID: activeStage.id)
        delegate?.stageControllerDidMutateState(self)
    }

    private func openOverlay(selectNextWindow: Bool) {
        setupOverlay()
        let windowCount = stageManager.activeStage.windows.count
        selectedWindowIndex = !frontmostAppIsExcluded && windowCount >= 2 ? 1 : 0
    }

    private func openOverlay(selectLastWindow: Bool) {
        setupOverlay()
        let windowCount = stageManager.activeStage.windows.count
        selectedWindowIndex = windowCount > 0 ? windowCount - 1 : 0
    }

    private func openOverlay(selectNextStage: Bool) {
        setupOverlay()
        selectedWindowIndex = 0
        if stageManager.stages.count > 1 {
            selectedStageIndex = (selectedStageIndex + 1) % stageManager.stages.count
        }
    }

    private func openOverlay(selectPreviousStage: Bool) {
        setupOverlay()
        selectedWindowIndex = 0
        if stageManager.stages.count > 1 {
            selectedStageIndex = (selectedStageIndex - 1 + stageManager.stages.count) % stageManager.stages.count
        }
    }

    private func setupOverlay() {
        // Don't show overlay when a fullscreen app is active
        let presentation = activeOverlayPresentation
        let fullscreen = isFullscreenAppActive()
        if let presentation {
            overlayPresentationRecorder.mark(.fullscreenProbeCompleted, for: presentation)
        }
        if fullscreen {
            if let presentation {
                overlayPresentationRecorder.complete(presentation, outcome: .fullscreenRejected)
                activeOverlayPresentation = nil
            }
            return
        }
        if let presentation {
            overlayPresentationRecorder.mark(.controllerAccepted, for: presentation)
        }

        backtickCycleWindows = []
        backtickCycleIndex = 0

        isStageManagerVisible = true
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = true
        }
        if let index = stageManager.stages.firstIndex(where: { $0.id == stageManager.activeStageID }) {
            selectedStageIndex = index
        }
        preOverlayStageID = stageManager.activeStageID
        // The surface may already be on screen from an earlier stage switch, so opening the
        // overlay is its own reason to recapture.
        let assignedWindowIDs = stageManager.stages.flatMap { $0.windows.map(\.windowID) }
        let cachedCount = variedWindowPreviewIDs.intersection(assignedWindowIDs).count
        if let presentation {
            let workload = PerformanceWorkload(
                stages: stageManager.stages.count,
                windows: assignedWindowIDs.count,
                captures: assignedWindowIDs.count
            )
            overlayPresentationRecorder.updateEnvironment(
                for: presentation,
                previewCache: .classify(cached: cachedCount, assigned: assignedWindowIDs.count),
                wallpaperState: desktopSurfaces?.overlayWallpaperState ?? .unavailable,
                workload: workload,
                cachedPreviewCount: cachedCount
            )
        }
        desktopSurfaces?.refreshWallpaper(overlayPresentation: presentation)
        scheduleOverlayPresentation()
        refreshWindowPreviews(overlayPresentation: presentation)
    }

    private func scheduleOverlayPresentation() {
        overlayPresentationGeneration &+= 1
        let generation = overlayPresentationGeneration

        let delay = max(0, overlayPresentationDelay)
        if let presentation = activeOverlayPresentation {
            overlayPresentationRecorder.mark(.presentationScheduled, for: presentation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.overlayPresentationGeneration == generation,
                  self.isStageManagerVisible,
                  !self.isOverlayPresented
            else { return }

            self.isOverlayPresented = true
            let presentation = self.activeOverlayPresentation
            if let presentation {
                self.overlayPresentationRecorder.mark(.presentationDeadlineFired, for: presentation)
            }
            self.diag.report("overlay_opened")
            self.delegate?.stageControllerDidOpenOverlay(
                self,
                overlayPresentation: presentation
            )
        }
    }

    private func dismissOverlayPresentation(
        beforePresentationOutcome: OverlayPresentationOutcome = .hiddenBeforeReveal
    ) {
        overlayPresentationGeneration &+= 1
        guard isOverlayPresented else {
            if let presentation = activeOverlayPresentation {
                overlayPresentationRecorder.complete(
                    presentation,
                    outcome: beforePresentationOutcome
                )
                activeOverlayPresentation = nil
            }
            return
        }
        isOverlayPresented = false
        delegate?.stageControllerDidCloseOverlay(
            self,
            overlayPresentation: activeOverlayPresentation
        )
    }

    private func notifyOverlayUpdated() {
        guard isOverlayPresented else { return }
        delegate?.stageControllerDidUpdateSelection(self)
    }

    /// Caps the blocking cross-process waits on the overlay-open path. An unresponsive app
    /// would otherwise stall the probe for the seconds-long system default; falling back to
    /// "not fullscreen" costs nothing.
    ///
    /// The bound has to be applied to each element the probe messages: it is scoped to the
    /// element ref it is set on, not to the app's connection.
    static let fullscreenProbeTimeout: TimeInterval = 0.05

    private func isFullscreenAppActive() -> Bool {
        if let fullscreenAppActiveProvider {
            return fullscreenAppActiveProvider()
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != "com.thomplth.Debut"
        else { return false }

        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, Float(Self.fullscreenProbeTimeout))
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowsRef) == .success else {
            return false
        }
        let axWindow = windowsRef as! AXUIElement
        AXUIElementSetMessagingTimeout(axWindow, Float(Self.fullscreenProbeTimeout))
        var fullscreenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullscreenRef) == .success else {
            return false
        }
        return (fullscreenRef as? Bool) == true
    }

    private func refreshWindowPreviews(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        let windowIDs = stageManager.stages.flatMap { stage in
            stage.windows.map(\.windowID)
        }

        previewCaptureTask?.cancel()
        previewCaptureGeneration &+= 1
        let generation = previewCaptureGeneration
        let assignedWindowIDs = Set(windowIDs)
        let metrics = PreviewCaptureMetrics(
            windowIDs: windowIDs,
            overlayPresentation: overlayPresentation,
            overlayPresentationRecorder: overlayPresentationRecorder
        )

        // A missing capture can mean that a window is merely hidden, so retain its last good
        // preview. Only assignments that no longer exist are removed.
        windowPreviews = windowPreviews.filter { assignedWindowIDs.contains($0.key) }
        variedWindowPreviewIDs.formIntersection(assignedWindowIDs)

        previewCaptureTask = Task { [weak self, windowService] in
            await windowService.captureWindowImages(windowIDs: windowIDs) { [weak self] capture in
                metrics.recordCapture(windowID: capture.windowID)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.previewCaptureGeneration == generation,
                          self.stageManager.stages.contains(where: { stage in
                              stage.windows.contains(where: { $0.windowID == capture.windowID })
                          })
                    else { return }

                    self.windowPreviews[capture.windowID] = capture.image
                    if WindowImageStatistics.hasVariedLuminance(capture.image) {
                        self.variedWindowPreviewIDs.insert(capture.windowID)
                    } else {
                        self.variedWindowPreviewIDs.remove(capture.windowID)
                    }
                    if self.isStageManagerVisible {
                        self.notifyOverlayUpdated()
                    }
                }
            }
            let capturedCount = metrics.finish()
            DiagnosticReporter.shared.report("preview_capture_completed", level: .transient, details: [
                "requested": "\(windowIDs.count)",
                "captured": "\(capturedCount)",
            ])

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.previewCaptureGeneration == generation,
                      self.isStageManagerVisible
                else { return }
                self.notifyOverlayUpdated()
            }
        }
    }

    private func commitSelection() {
        guard isStageManagerVisible else { return }
        isStageManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }

        dismissOverlayPresentation(beforePresentationOutcome: .releasedBeforePresentation)

        guard stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let targetStage = stageManager.stages[selectedStageIndex]

        var raiseWindowID: CGWindowID?
        if targetStage.windows.indices.contains(selectedWindowIndex) {
            raiseWindowID = targetStage.windows[selectedWindowIndex].windowID
        }

        switchToStage(id: targetStage.id, raiseWindowID: raiseWindowID)

        diag.report("overlay_committed", details: [
            "stageIndex": "\(selectedStageIndex)",
            "windowIndex": "\(selectedWindowIndex)",
            "targetStage": stageLabel(forID: targetStage.id),
        ])
    }

    /// Commit a window chosen with the pointer without waiting for Command release.
    public func commitOverlaySelection(stageIndex: Int, windowIndex: Int) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(stageIndex),
              stageManager.stages[stageIndex].windows.indices.contains(windowIndex)
        else { return }

        selectedStageIndex = stageIndex
        selectedWindowIndex = windowIndex
        commitSelection()
    }

    /// Close the switcher and expose Finder's real desktop surface.
    public func revealDesktop() {
        guard isStageManagerVisible else { return }
        isStageManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }
        dismissOverlayPresentation()
        onDesktopReveal?()
        diag.report("desktop_revealed_from_overlay")
    }

    @discardableResult
    public func moveWindowByDrag(
        windowID: CGWindowID,
        fromStageIndex: Int,
        toStageIndex: Int,
        toWindowIndex: Int
    ) -> Bool {
        guard stageManager.stages.indices.contains(fromStageIndex),
              stageManager.stages.indices.contains(toStageIndex),
              stageManager.stages[fromStageIndex].windows.contains(where: {
                  $0.windowID == windowID
              })
        else { return false }

        let fromStageID = stageManager.stages[fromStageIndex].id
        let toStageID = stageManager.stages[toStageIndex].id
        stageManager.moveWindow(
            windowID: windowID,
            fromStageID: fromStageID,
            toStageID: toStageID,
            at: toWindowIndex
        )

        if selectedStageIndex == toStageIndex,
           let movedIndex = stageManager.stages[toStageIndex].windows.firstIndex(where: {
               $0.windowID == windowID
           }) {
            selectedWindowIndex = movedIndex
        }

        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
        return true
    }

    /// Close the overlay but keep the Cmd session alive.
    /// Next Cmd+Tab or Cmd+Option+Tab reopens the overlay.
    private func discardOverlay() {
        guard isStageManagerVisible else { return }
        isStageManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }
        selectedStageIndex = stageManager.stages.firstIndex(where: { $0.id == preOverlayStageID }) ?? 0
        selectedWindowIndex = 0
        dismissOverlayPresentation()
        // stageManagerActive stays true — session continues until Cmd release
        // Cmd+` still stage-isolated (intercepted before the overlay gate)
    }

    private func cycleWindow(forward: Bool, wraps: Bool = true) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        guard !stage.windows.isEmpty else { return }

        if forward {
            if wraps {
                selectedWindowIndex = (selectedWindowIndex + 1) % stage.windows.count
            } else {
                let nextIndex = min(selectedWindowIndex + 1, stage.windows.count - 1)
                guard nextIndex != selectedWindowIndex else { return }
                selectedWindowIndex = nextIndex
            }
        } else {
            selectedWindowIndex = (selectedWindowIndex - 1 + stage.windows.count) % stage.windows.count
        }
        notifyOverlayUpdated()
    }

    private func cycleStage(forward: Bool) {
        guard isStageManagerVisible, !stageManager.stages.isEmpty else { return }

        if forward {
            selectedStageIndex = (selectedStageIndex + 1) % stageManager.stages.count
        } else {
            selectedStageIndex = (selectedStageIndex - 1 + stageManager.stages.count) % stageManager.stages.count
        }
        selectedWindowIndex = 0
        notifyOverlayUpdated()
    }

    private func jumpToStage(index: Int) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(index) else { return }
        selectedStageIndex = index
        selectedWindowIndex = 0
        notifyOverlayUpdated()
    }

    private func createStage(position: StageInsertPosition) {
        guard isStageManagerVisible else { return }
        let currentID = stageManager.stages.indices.contains(selectedStageIndex)
            ? stageManager.stages[selectedStageIndex].id : stageManager.activeStageID
        stageManager.activateStage(id: currentID)
        stageManager.createStage(position: position)
        if let newIndex = stageManager.stages.firstIndex(where: { $0.id == stageManager.activeStageID }) {
            selectedStageIndex = newIndex
        }
        selectedWindowIndex = 0
        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
    }

    private func deleteSelectedStage() {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let targetID = stageManager.stages[selectedStageIndex].id
        stageManager.deleteStage(id: targetID)
        selectedStageIndex = min(selectedStageIndex, stageManager.stages.count - 1)
        selectedWindowIndex = 0
        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
    }

    private func moveWindow(direction: SwapDirection) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        guard stage.windows.indices.contains(selectedWindowIndex) else { return }
        let window = stage.windows[selectedWindowIndex]

        let targetStageIndex: Int
        switch direction {
        case .up:
            guard selectedStageIndex > 0 else { return }
            targetStageIndex = selectedStageIndex - 1
        case .down:
            guard selectedStageIndex < stageManager.stages.count - 1 else { return }
            targetStageIndex = selectedStageIndex + 1
        }

        let targetStageID = stageManager.stages[targetStageIndex].id
        stageManager.moveWindow(windowID: window.windowID, fromStageID: stage.id, toStageID: targetStageID)

        // Follow the moved window to the target stage
        selectedStageIndex = targetStageIndex
        let targetWindows = stageManager.stages[targetStageIndex].windows
        selectedWindowIndex = targetWindows.firstIndex(where: { $0.windowID == window.windowID }) ?? 0

        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
        // Force overlay rebuild since stage contents changed
        if isOverlayPresented {
            delegate?.stageControllerDidOpenOverlay(self)
        }
    }

    private func swapStage(direction: SwapDirection) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stageID = stageManager.stages[selectedStageIndex].id
        stageManager.swapStage(id: stageID, direction: direction)

        switch direction {
        case .up where selectedStageIndex > 0: selectedStageIndex -= 1
        case .down where selectedStageIndex < stageManager.stages.count - 1: selectedStageIndex += 1
        default: break
        }
        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
    }
}
