import Foundation

public protocol StageControllerDelegate: AnyObject {
    func stageControllerDidOpenOverlay(_ controller: StageController)
    func stageControllerDidCloseOverlay(_ controller: StageController)
    func stageControllerDidUpdateSelection(_ controller: StageController)
    func stageControllerDidSwitchStage(_ controller: StageController)
}

public final class StageController: KeyboardEventDelegate, @unchecked Sendable {
    public var stageManager: StageManager
    public let windowService: any WindowService
    public let keyboardService: any KeyboardService
    public weak var delegate: StageControllerDelegate?

    public private(set) var isStageManagerVisible: Bool = false
    public var selectedStageIndex: Int = 0
    public var selectedAppIndex: Int = 0
    public private(set) var keyboardServiceStarted: Bool = false

    private var preOverlayStageID: UUID?
    private var preOverlayAppIndex: Int = 0
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
                "stageCount": "\(self.stageManager.stages.count)",
                "activeStageIndex": "\(self.selectedStageIndex)",
                "selectedAppIndex": "\(self.selectedAppIndex)",
                "eventTapRunning": "\(self.keyboardService.isRunning)",
                "eventTapStarted": "\(self.keyboardServiceStarted)",
                "appsInActiveStage": "\(self.stageManager.activeStage.apps.count)",
            ]
        }
    }

    // MARK: - Stage switching

    public func switchToStage(id targetID: UUID, activateBundleID: String? = nil) {
        let previousID = stageManager.activeStageID
        let previousStage = stageManager.stages.first(where: { $0.id == previousID })
        let targetStage = stageManager.stages.first(where: { $0.id == targetID })

        if previousID != targetID {
            if let previousStage {
                for app in previousStage.apps where !app.isShared {
                    _ = windowService.hideApp(bundleID: app.bundleID)
                }
            }
            if let targetStage {
                for app in targetStage.apps where !app.isShared {
                    _ = windowService.unhideApp(bundleID: app.bundleID)
                }
            }
        }

        stageManager.activateStage(id: targetID)

        if let bundleID = activateBundleID {
            _ = windowService.activateApp(bundleID: bundleID)
            stageManager.bringAppToFront(bundleID: bundleID, inStageID: targetID)
        } else if let firstApp = targetStage?.apps.first {
            _ = windowService.activateApp(bundleID: firstApp.bundleID)
        }

        diag.report("stage_switched", details: ["targetStage": targetStage?.name ?? "unknown"])
        delegate?.stageControllerDidSwitchStage(self)
    }

    // MARK: - MRU update

    public func recordAppActivation(bundleID: String) {
        let stageID = stageManager.activeStageID
        stageManager.bringAppToFront(bundleID: bundleID, inStageID: stageID)
    }

    // MARK: - KeyboardEventDelegate

    public func handleKeyEvent(_ event: DebutKeyEvent) {
        diag.report("key_event", details: ["event": "\(event)"])

        switch event {
        case .cmdTabTap:
            handleCmdTabTap()
        case .cmdTabHold:
            openOverlay()
        case .cmdRelease:
            commitSelection()
        case .escape:
            discardSelection()
        case .nextApp:
            cycleApp(forward: true)
        case .previousApp:
            cycleApp(forward: false)
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
            break
        case .saveAsTemplate:
            saveSelectedStageAsTemplate()
        case .moveAppUp:
            moveApp(direction: .up)
        case .moveAppDown:
            moveApp(direction: .down)
        case .swapStageUp:
            swapStage(direction: .up)
        case .swapStageDown:
            swapStage(direction: .down)
        }
    }

    // MARK: - Private

    private func handleCmdTabTap() {
        let activeStage = stageManager.activeStage
        guard activeStage.apps.count >= 2 else { return }
        let targetApp = activeStage.apps[1]
        _ = windowService.activateApp(bundleID: targetApp.bundleID)
        stageManager.bringAppToFront(bundleID: targetApp.bundleID, inStageID: activeStage.id)
    }

    private func openOverlay() {
        isStageManagerVisible = true
        if let index = stageManager.stages.firstIndex(where: { $0.id == stageManager.activeStageID }) {
            selectedStageIndex = index
        }
        selectedAppIndex = 0
        preOverlayStageID = stageManager.activeStageID
        preOverlayAppIndex = 0

        diag.report("overlay_opened")
        delegate?.stageControllerDidOpenOverlay(self)
    }

    private func commitSelection() {
        guard isStageManagerVisible else { return }
        isStageManagerVisible = false

        delegate?.stageControllerDidCloseOverlay(self)

        guard stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let targetStage = stageManager.stages[selectedStageIndex]

        var activateBundleID: String?
        if targetStage.apps.indices.contains(selectedAppIndex) {
            activateBundleID = targetStage.apps[selectedAppIndex].bundleID
        }

        switchToStage(id: targetStage.id, activateBundleID: activateBundleID)

        diag.report("overlay_committed", details: [
            "stageIndex": "\(selectedStageIndex)",
            "appIndex": "\(selectedAppIndex)",
        ])
    }

    private func discardSelection() {
        isStageManagerVisible = false
        selectedStageIndex = stageManager.stages.firstIndex(where: { $0.id == preOverlayStageID }) ?? 0
        selectedAppIndex = preOverlayAppIndex

        diag.report("overlay_discarded")
        delegate?.stageControllerDidCloseOverlay(self)
    }

    private func cycleApp(forward: Bool) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        guard !stage.apps.isEmpty else { return }

        if forward {
            selectedAppIndex = (selectedAppIndex + 1) % stage.apps.count
        } else {
            selectedAppIndex = (selectedAppIndex - 1 + stage.apps.count) % stage.apps.count
        }
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func cycleStage(forward: Bool) {
        guard isStageManagerVisible, !stageManager.stages.isEmpty else { return }

        if forward {
            selectedStageIndex = (selectedStageIndex + 1) % stageManager.stages.count
        } else {
            selectedStageIndex = (selectedStageIndex - 1 + stageManager.stages.count) % stageManager.stages.count
        }
        selectedAppIndex = 0
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func jumpToStage(index: Int) {
        guard isStageManagerVisible, stageManager.stages.indices.contains(index) else { return }
        selectedStageIndex = index
        selectedAppIndex = 0
        delegate?.stageControllerDidUpdateSelection(self)
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
        selectedAppIndex = 0
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func deleteSelectedStage() {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let targetID = stageManager.stages[selectedStageIndex].id
        stageManager.deleteStage(id: targetID)
        selectedStageIndex = min(selectedStageIndex, stageManager.stages.count - 1)
        selectedAppIndex = 0
        delegate?.stageControllerDidUpdateSelection(self)
    }

    private func saveSelectedStageAsTemplate() {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        stageManager.saveStageAsTemplate(stageID: stage.id, templateName: stage.name)
    }

    private func moveApp(direction: SwapDirection) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        guard stage.apps.indices.contains(selectedAppIndex) else { return }
        let app = stage.apps[selectedAppIndex]

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
        stageManager.moveApp(bundleID: app.bundleID, fromStageID: stage.id, toStageID: targetStageID)
        delegate?.stageControllerDidUpdateSelection(self)
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
        delegate?.stageControllerDidUpdateSelection(self)
    }
}
