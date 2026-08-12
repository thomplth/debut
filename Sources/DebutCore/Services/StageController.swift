import AppKit
import ApplicationServices
import CoreGraphics

public protocol StageControllerDelegate: AnyObject {
    func stageControllerDidOpenOverlay(_ controller: StageController)
    func stageControllerDidCloseOverlay(_ controller: StageController)
    func stageControllerDidUpdateSelection(_ controller: StageController)
    func stageControllerDidSwitchStage(_ controller: StageController)
    func stageControllerDidMutateState(_ controller: StageController)
}

public final class StageController: KeyboardEventDelegate, @unchecked Sendable {
    public var stageManager: StageManager
    public let windowService: any WindowService
    public let keyboardService: any KeyboardService
    public weak var delegate: StageControllerDelegate?
    public var onCommandUsed: (@Sendable (KeyAction) -> Void)?

    public private(set) var isStageManagerVisible: Bool = false
    public var selectedStageIndex: Int = 0
    public var selectedWindowIndex: Int = 0
    public private(set) var keyboardServiceStarted: Bool = false
    public var overlayPresentationDelay: TimeInterval

    /// Window previews captured when overlay opens
    public private(set) var windowPreviews: [CGWindowID: CGImage] = [:]

    /// Desktop surfaces — one per display, sitting between active and inactive stage windows
    public var desktopSurfaces: DesktopSurfaceCoordinator?

    private var preOverlayStageID: UUID?
    private var previousStageID: UUID?
    private var backtickCycleWindows: [CGWindowID] = []
    private var backtickCycleIndex: Int = 0
    private var overlayPresentationGeneration: UInt = 0
    private var isOverlayPresented: Bool = false
    private let fullscreenAppActiveProvider: (() -> Bool)?
    private let previewCaptureQueue = DispatchQueue(
        label: "com.thomplth.Debut.preview-capture",
        qos: .userInitiated
    )
    private let diag = DiagnosticReporter.shared

    public init(
        windowService: any WindowService,
        keyboardService: any KeyboardService,
        stageManager: StageManager = StageManager(),
        overlayPresentationDelay: TimeInterval = AppSettings.defaultOverlayPresentationDelay,
        fullscreenAppActiveProvider: (() -> Bool)? = nil
    ) {
        self.windowService = windowService
        self.keyboardService = keyboardService
        self.stageManager = stageManager
        self.overlayPresentationDelay = overlayPresentationDelay
        self.fullscreenAppActiveProvider = fullscreenAppActiveProvider

        let started = keyboardService.start(delegate: self)
        self.keyboardServiceStarted = started
        diag.report(started ? "event_tap_created" : "event_tap_failed")

        diag.setStateProvider { [weak self] in
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
            if let targetStage {
                for window in targetStage.windows {
                    _ = windowService.raiseWindow(windowID: window.windowID)
                }
            }

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

    // MARK: - KeyboardEventDelegate

    public func handleKeyEvent(_ event: DebutKeyEvent) {
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
        let matchingWindowID = activeBundleID.flatMap { bundleID in
            targetStage.windows.first(where: { $0.ownerBundleID == bundleID })?.windowID
        }

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

    private func handleCmdBacktick(reverse: Bool) {
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
            backtickCycleIndex = (backtickCycleIndex - 1 + backtickCycleWindows.count)
                % backtickCycleWindows.count
        } else {
            backtickCycleIndex = (backtickCycleIndex + 1) % backtickCycleWindows.count
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
        guard activeStage.windows.count >= 2 else { return }
        let targetWindow = activeStage.windows[1]
        _ = windowService.raiseWindow(windowID: targetWindow.windowID)
        stageManager.bringWindowToFront(windowID: targetWindow.windowID, inStageID: activeStage.id)
        delegate?.stageControllerDidMutateState(self)
    }

    private func openOverlay(selectNextWindow: Bool) {
        setupOverlay()
        let windowCount = stageManager.activeStage.windows.count
        selectedWindowIndex = windowCount >= 2 ? 1 : 0
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
        if isFullscreenAppActive() { return }

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
        desktopSurfaces?.refreshWallpaper()
        scheduleOverlayPresentation()
        refreshWindowPreviews()
    }

    private func scheduleOverlayPresentation() {
        overlayPresentationGeneration &+= 1
        let generation = overlayPresentationGeneration

        let delay = max(0, overlayPresentationDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.overlayPresentationGeneration == generation,
                  self.isStageManagerVisible,
                  !self.isOverlayPresented
            else { return }

            self.isOverlayPresented = true
            self.diag.report("overlay_opened")
            self.delegate?.stageControllerDidOpenOverlay(self)
        }
    }

    private func dismissOverlayPresentation() {
        overlayPresentationGeneration &+= 1
        guard isOverlayPresented else { return }
        isOverlayPresented = false
        delegate?.stageControllerDidCloseOverlay(self)
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

    private func refreshWindowPreviews() {
        let windowIDs = stageManager.stages.flatMap { stage in
            stage.windows.map(\.windowID)
        }

        previewCaptureQueue.async { [weak self] in
            guard let self else { return }

            var refreshedPreviews: [CGWindowID: CGImage] = [:]
            for windowID in windowIDs {
                if let image = self.windowService.captureWindowImage(windowID: windowID) {
                    refreshedPreviews[windowID] = image
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // A missing capture can mean that a window is merely hidden, so
                // retain its last good preview. Remove only windows no longer assigned.
                let liveWindowIDs = Set(
                    self.stageManager.stages.flatMap { $0.windows.map(\.windowID) }
                )
                self.windowPreviews = self.windowPreviews.filter {
                    liveWindowIDs.contains($0.key)
                }
                for (windowID, image) in refreshedPreviews where liveWindowIDs.contains(windowID) {
                    self.windowPreviews[windowID] = image
                }

                if self.isStageManagerVisible {
                    self.notifyOverlayUpdated()
                }
            }
        }
    }

    private func commitSelection() {
        guard isStageManagerVisible else { return }
        isStageManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }

        dismissOverlayPresentation()

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
