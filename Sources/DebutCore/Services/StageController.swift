import AppKit
import ApplicationServices
import CoreGraphics

public protocol StageControllerDelegate: AnyObject {
    func stageControllerDidOpenOverlay(_ controller: StageController)
    func stageControllerDidCloseOverlay(_ controller: StageController)
    func stageControllerDidUpdateSelection(_ controller: StageController)
    func stageControllerDidSwitchStage(_ controller: StageController)
    func stageControllerDidEnterRenameMode(_ controller: StageController)
    func stageControllerDidExitRenameMode(_ controller: StageController)
}

public final class StageController: KeyboardEventDelegate, @unchecked Sendable {
    public var stageManager: StageManager
    public let windowService: any WindowService
    public let keyboardService: any KeyboardService
    public weak var delegate: StageControllerDelegate?

    public private(set) var isStageManagerVisible: Bool = false
    public private(set) var isRenaming: Bool = false
    public var selectedStageIndex: Int = 0
    public var selectedWindowIndex: Int = 0
    public private(set) var keyboardServiceStarted: Bool = false

    /// Window previews captured when overlay opens
    public private(set) var windowPreviews: [CGWindowID: CGImage] = [:]

    /// Desktop surface window — sits between active and inactive stage windows
    public var desktopSurface: DesktopSurfaceWindow?

    private var preOverlayStageID: UUID?
    private var previousStageID: UUID?
    private let diag = DiagnosticReporter.shared

    public init(
        windowService: any WindowService,
        keyboardService: any KeyboardService,
        stageManager: StageManager = StageManager()
    ) {
        self.windowService = windowService
        self.keyboardService = keyboardService
        self.stageManager = stageManager

        let started = keyboardService.start(delegate: self)
        self.keyboardServiceStarted = started
        diag.report(started ? "event_tap_created" : "event_tap_failed")

        diag.setStateProvider { [weak self] in
            guard let self else { return ["error": "controller deallocated"] }
            return [
                "overlayVisible": "\(self.isStageManagerVisible)",
                "isRenaming": "\(self.isRenaming)",
                "stageCount": "\(self.stageManager.stages.count)",
                "activeStageIndex": "\(self.selectedStageIndex)",
                "selectedWindowIndex": "\(self.selectedWindowIndex)",
                "eventTapRunning": "\(self.keyboardService.isRunning)",
                "eventTapStarted": "\(self.keyboardServiceStarted)",
                "windowsInActiveStage": "\(self.stageManager.activeStage.windows.count)",
            ]
        }
    }

    // MARK: - Stage switching

    public func switchToStage(id targetID: UUID, raiseWindowID: CGWindowID? = nil) {
        let previousID = stageManager.activeStageID

        if previousID != targetID {
            let previousStage = stageManager.stages.first(where: { $0.id == previousID })
            let targetStage = stageManager.stages.first(where: { $0.id == targetID })

            self.previousStageID = previousID
            stageManager.activateStage(id: targetID)

            // 1. Bring desktop surface to front — covers all inactive windows
            desktopSurface?.orderToFront()

            // 2. Raise all windows in the target stage above the surface (no app activation yet)
            if let targetStage {
                for window in targetStage.windows {
                    _ = windowService.raiseWindow(windowID: window.windowID)
                }
            }

            diag.report("stage_switched", details: [
                "from": previousStage?.name ?? "?",
                "to": targetStage?.name ?? "?",
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

        delegate?.stageControllerDidSwitchStage(self)
    }

    // MARK: - Window ownership

    public func stageOwningWindow(windowID: CGWindowID) -> UUID? {
        stageManager.stageContainingWindow(windowID: windowID)
    }

    public func recordWindowActivation(windowID: CGWindowID) {
        let activeStageID = stageManager.activeStageID
        let ownerStageID = stageOwningWindow(windowID: windowID)

        if ownerStageID == activeStageID {
            // Window is in the active stage — update MRU
            stageManager.bringWindowToFront(windowID: windowID, inStageID: activeStageID)
        } else if let ownerStageID {
            // Window belongs to another stage — switch to that stage
            diag.report("switching_to_window_stage", details: [
                "windowID": "\(windowID)",
                "targetStage": stageManager.stages.first(where: { $0.id == ownerStageID })?.name ?? "?",
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
            }
        }
    }

    // MARK: - KeyboardEventDelegate

    public func handleKeyEvent(_ event: DebutKeyEvent) {
        diag.report("key_event", details: ["event": "\(event)"])

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
        case .cmdRelease:
            commitSelection()
        case .escape:
            discardOverlay()
        case .nextWindow:
            cycleWindow(forward: true)
        case .previousWindow:
            cycleWindow(forward: false)
        case .nextStage:
            cycleStage(forward: true)
        case .previousStage:
            cycleStage(forward: false)
        case .jumpToStage(let index):
            jumpToStage(index: index - 1)
        case .newStageBelow:
            createStage(position: .below)
        case .newStageAbove:
            createStage(position: .above)
        case .deleteStage:
            deleteSelectedStage()
        case .renameStage:
            enterRenameMode()
        case .renameCommit:
            break // Rename commit handled via distributed notification from text field
        case .renameCancel:
            exitRenameMode(commit: false)
        case .saveAsTemplate:
            saveSelectedStageAsTemplate()
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

    // MARK: - Rename mode

    private var renameObserver: Any?

    private func enterRenameMode() {
        guard isStageManagerVisible, !isRenaming else { return }
        isRenaming = true
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.isLocked = true
        }

        renameObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.thomplth.Debut.renameCommit"),
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.isRenaming else { return }
            if let newName = notification.object as? String, !newName.isEmpty {
                self.commitRename(newName: newName)
            }
        }

        delegate?.stageControllerDidEnterRenameMode(self)
    }

    private func commitRename(newName: String) {
        guard isRenaming, stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stageID = stageManager.stages[selectedStageIndex].id
        stageManager.renameStage(id: stageID, to: newName)
        exitRenameMode(commit: true)
    }

    private func exitRenameMode(commit: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.isLocked = false
        }
        if let observer = renameObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            renameObserver = nil
        }
        delegate?.stageControllerDidExitRenameMode(self)
        delegate?.stageControllerDidUpdateSelection(self)
    }

    // MARK: - Private

    private func handleCmdTabTap() {
        let activeStage = stageManager.activeStage
        guard activeStage.windows.count >= 2 else { return }
        let targetWindow = activeStage.windows[1]
        _ = windowService.raiseWindow(windowID: targetWindow.windowID)
        stageManager.bringWindowToFront(windowID: targetWindow.windowID, inStageID: activeStage.id)
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

        isStageManagerVisible = true
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = true
        }
        if let index = stageManager.stages.firstIndex(where: { $0.id == stageManager.activeStageID }) {
            selectedStageIndex = index
        }
        preOverlayStageID = stageManager.activeStageID
        captureWindowPreviews()
        diag.report("overlay_opened")
        delegate?.stageControllerDidOpenOverlay(self)
    }

    private func isFullscreenAppActive() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != "com.thomplth.Debut"
        else { return false }

        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowsRef) == .success else {
            return false
        }
        let axWindow = windowsRef as! AXUIElement
        var fullscreenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullscreenRef) == .success else {
            return false
        }
        return (fullscreenRef as? Bool) == true
    }

    private func captureWindowPreviews() {
        // Don't clear — keep last good capture for hidden windows
        for stage in stageManager.stages {
            for window in stage.windows {
                if let image = windowService.captureWindowImage(windowID: window.windowID) {
                    windowPreviews[window.windowID] = image
                }
                // else: keep previous capture in windowPreviews (if any)
            }
        }

        // Remove entries for windows no longer in any stage
        let allWindowIDs = Set(stageManager.stages.flatMap { $0.windows.map(\.windowID) })
        windowPreviews = windowPreviews.filter { allWindowIDs.contains($0.key) }
    }

    private func commitSelection() {
        guard isStageManagerVisible, !isRenaming else { return }
        isStageManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }

        delegate?.stageControllerDidCloseOverlay(self)

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
            "targetStage": targetStage.name,
        ])
    }

    /// Close the overlay but keep the Cmd session alive.
    /// Next Cmd+Tab or Cmd+Option+Tab reopens the overlay.
    private func discardOverlay() {
        guard isStageManagerVisible else { return }
        if isRenaming {
            exitRenameMode(commit: false)
            return
        }
        isStageManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }
        selectedStageIndex = stageManager.stages.firstIndex(where: { $0.id == preOverlayStageID }) ?? 0
        selectedWindowIndex = 0
        delegate?.stageControllerDidCloseOverlay(self)
        // stageManagerActive stays true — session continues until Cmd release
        // But overlayVisible is false — ` passes through to system as Cmd+`
    }

    private func cycleWindow(forward: Bool) {
        guard isStageManagerVisible, !isRenaming,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        guard !stage.windows.isEmpty else { return }

        if forward {
            selectedWindowIndex = (selectedWindowIndex + 1) % stage.windows.count
        } else {
            selectedWindowIndex = (selectedWindowIndex - 1 + stage.windows.count) % stage.windows.count
        }
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func cycleStage(forward: Bool) {
        guard isStageManagerVisible, !isRenaming, !stageManager.stages.isEmpty else { return }

        if forward {
            selectedStageIndex = (selectedStageIndex + 1) % stageManager.stages.count
        } else {
            selectedStageIndex = (selectedStageIndex - 1 + stageManager.stages.count) % stageManager.stages.count
        }
        selectedWindowIndex = 0
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func jumpToStage(index: Int) {
        guard isStageManagerVisible, !isRenaming,
              stageManager.stages.indices.contains(index) else { return }
        selectedStageIndex = index
        selectedWindowIndex = 0
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func createStage(position: StageInsertPosition) {
        guard isStageManagerVisible, !isRenaming else { return }
        let currentID = stageManager.stages.indices.contains(selectedStageIndex)
            ? stageManager.stages[selectedStageIndex].id : stageManager.activeStageID
        stageManager.activateStage(id: currentID)
        stageManager.createStage(position: position)
        if let newIndex = stageManager.stages.firstIndex(where: { $0.id == stageManager.activeStageID }) {
            selectedStageIndex = newIndex
        }
        selectedWindowIndex = 0
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func deleteSelectedStage() {
        guard isStageManagerVisible, !isRenaming,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let targetID = stageManager.stages[selectedStageIndex].id
        stageManager.deleteStage(id: targetID)
        selectedStageIndex = min(selectedStageIndex, stageManager.stages.count - 1)
        selectedWindowIndex = 0
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func saveSelectedStageAsTemplate() {
        guard isStageManagerVisible, !isRenaming,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        stageManager.saveStageAsTemplate(stageID: stage.id, templateName: stage.name)
    }

    private func moveWindow(direction: SwapDirection) {
        guard isStageManagerVisible, !isRenaming,
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

        delegate?.stageControllerDidUpdateSelection(self)
        // Force overlay rebuild since stage contents changed
        delegate?.stageControllerDidOpenOverlay(self)
    }

    private func swapStage(direction: SwapDirection) {
        guard isStageManagerVisible, !isRenaming,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stageID = stageManager.stages[selectedStageIndex].id
        stageManager.swapStage(id: stageID, direction: direction)

        switch direction {
        case .up where selectedStageIndex > 0: selectedStageIndex -= 1
        case .down where selectedStageIndex < stageManager.stages.count - 1: selectedStageIndex += 1
        default: break
        }
        delegate?.stageControllerDidUpdateSelection(self)
    }
}
