import AppKit
import ApplicationServices
import CoreGraphics

final class PreviewCaptureMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private let batchID: UUID
    private let firstID: UUID
    private var enumerationID: UUID?
    private var captureIDs: [CGWindowID: UUID] = [:]
    private var capturedCount = 0
    private var recordedFirst = false
    private let overlayPresentation: OverlayPresentationContext?
    private let overlayPresentationRecorder: OverlayPresentationRecorder
    private let performanceRecorder: PerformanceRecorder

    init(
        windowIDs: [CGWindowID],
        overlayPresentation: OverlayPresentationContext? = nil,
        overlayPresentationRecorder: OverlayPresentationRecorder = .shared,
        performanceRecorder: PerformanceRecorder = .shared
    ) {
        self.overlayPresentation = overlayPresentation
        self.overlayPresentationRecorder = overlayPresentationRecorder
        self.performanceRecorder = performanceRecorder
        batchID = performanceRecorder.begin(
            .previewAll,
            workload: .init(windows: windowIDs.count, captures: windowIDs.count),
            traceID: overlayPresentation?.traceID
        )
        firstID = performanceRecorder.begin(
            .previewFirst,
            workload: .init(windows: windowIDs.count, captures: min(1, windowIDs.count)),
            traceID: overlayPresentation?.traceID
        )
        enumerationID = performanceRecorder.begin(
            .previewEnumeration,
            workload: .init(windows: windowIDs.count),
            traceID: overlayPresentation?.traceID,
            sampleResources: false
        )
    }

    /// Per-window timers only start here. Beginning them in `init` charged every
    /// window for the shared enumeration wait that precedes any capture.
    func recordEnumeration(matchedWindowIDs: [CGWindowID]) {
        lock.withLock {
            endEnumerationLocked()
            for windowID in matchedWindowIDs where captureIDs[windowID] == nil {
                captureIDs[windowID] = performanceRecorder.begin(
                    .previewCapture,
                    workload: .init(captures: 1),
                    traceID: overlayPresentation?.traceID,
                    sampleResources: false
                )
            }
        }
    }

    func recordCapture(windowID: CGWindowID) {
        lock.withLock {
            if let captureID = captureIDs.removeValue(forKey: windowID) {
                _ = performanceRecorder.end(captureID)
            }
            capturedCount += 1
            if !recordedFirst {
                recordedFirst = true
                _ = performanceRecorder.end(firstID)
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
            endEnumerationLocked()
            for captureID in captureIDs.values {
                _ = performanceRecorder.end(captureID)
            }
            captureIDs.removeAll()
            if !recordedFirst {
                recordedFirst = true
                _ = performanceRecorder.end(firstID)
                if let overlayPresentation {
                    overlayPresentationRecorder.mark(
                        .firstPreviewCompleted,
                        for: overlayPresentation
                    )
                }
            }
            _ = performanceRecorder.end(batchID)
            if let overlayPresentation {
                overlayPresentationRecorder.mark(.allPreviewsCompleted, for: overlayPresentation)
            }
            return capturedCount
        }
    }

    /// Must be called with `lock` held.
    private func endEnumerationLocked() {
        guard let enumerationID else { return }
        self.enumerationID = nil
        _ = performanceRecorder.end(enumerationID)
    }
}

/// What a cached preview was captured from, so the next activation can tell whether it is
/// still trustworthy without re-capturing to find out.
private struct PreviewCacheEntry {
    let capturedAt: Date
    let windowTitle: String
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

    private var pendingStageFocus: (stageID: UUID, windowID: CGWindowID)?

    public private(set) var isStageManagerVisible: Bool = false
    public var selectedStageIndex: Int = 0
    public var selectedWindowIndex: Int = 0
    public private(set) var keyboardServiceStarted: Bool = false
    public var overlayPresentationDelay: TimeInterval
    public var previewRefreshPolicy: PreviewRefreshPolicy
    public var previewCacheTTL: TimeInterval

    /// Window previews captured when overlay opens
    public private(set) var windowPreviews: [CGWindowID: CGImage] = [:]
    public private(set) var variedWindowPreviewIDs: Set<CGWindowID> = []

    /// The macOS desktops that back the stages. The stage at index N is desktop N.
    public var spaceSwitcher: (any SpaceSwitching)?

    /// Where the frontmost app's focused window sat when the overlay last opened, in Quartz
    /// global coordinates. The delegate resolves it to the display it presents the plates on.
    public private(set) var focusedWindowFrame: CGRect?

    /// Whether that window owned a fullscreen Space. The plates are presented either way; this
    /// is what tells a diagnostic reader which of the two presentations it is looking at.
    public private(set) var focusedWindowIsFullscreen: Bool = false

    private var preOverlayStageID: UUID?
    private var previousStageID: UUID?
    private var backtickCycleWindows: [CGWindowID] = []
    private var backtickCycleIndex: Int = 0
    private var overlayPresentationGeneration: UInt = 0
    private var isOverlayPresented: Bool = false
    private let focusedWindowSnapshotProvider: (() -> FocusedWindowSnapshot)?
    private var previewCaptureTask: Task<Void, Never>?
    private var previewCaptureGeneration: UInt = 0
    private var previewCacheEntries: [CGWindowID: PreviewCacheEntry] = [:]
    private var pendingPreviewCaptureIDs: [CGWindowID] = []
    private let previewClock: @Sendable () -> Date
    private var pendingPreviewFlush = false
    private var frontmostAppIsExcluded = false
    private let diag = DiagnosticReporter.shared
    private let overlayPresentationRecorder: OverlayPresentationRecorder
    private var activeOverlayPresentation: OverlayPresentationContext?

    public init(
        windowService: any WindowService,
        keyboardService: any KeyboardService,
        stageManager: StageManager = StageManager(),
        overlayPresentationDelay: TimeInterval = AppSettings.defaultOverlayPresentationDelay,
        focusedWindowSnapshotProvider: (() -> FocusedWindowSnapshot)? = nil,
        overlayPresentationRecorder: OverlayPresentationRecorder = .shared,
        previewRefreshPolicy: PreviewRefreshPolicy = .lastActiveOnly,
        previewCacheTTL: TimeInterval = AppSettings.defaultPreviewCacheTTL,
        previewClock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.windowService = windowService
        self.keyboardService = keyboardService
        self.stageManager = stageManager
        self.overlayPresentationDelay = overlayPresentationDelay
        self.focusedWindowSnapshotProvider = focusedWindowSnapshotProvider
        self.overlayPresentationRecorder = overlayPresentationRecorder
        self.previewRefreshPolicy = previewRefreshPolicy
        self.previewCacheTTL = previewCacheTTL
        self.previewClock = previewClock

        let started = keyboardService.start(delegate: self)
        self.keyboardServiceStarted = started
        diag.report(started ? "event_tap_created" : "event_tap_failed")

        diag.setMainQueueStateProvider { [weak self] in
            self?.diagnosticState ?? ["error": "controller deallocated"]
        }
    }

    /// The state block E2E reads out of `diagnostic.json`.
    ///
    /// `activeStageIndex` is the desktop showing and `selectedStageIndex` is the overlay's
    /// cursor. They are only the same while the overlay drives the switch — a desktop the
    /// user changes themselves moves one and not the other.
    public var diagnosticState: [String: String] {
        let activeStageIndex = stageManager.stages
            .firstIndex(where: { $0.id == stageManager.activeStageID }) ?? 0
        return [
            "overlayVisible": "\(isStageManagerVisible)",
            "focusedWindowFullscreen": "\(focusedWindowIsFullscreen)",
            "stageCount": "\(stageManager.stages.count)",
            "activeStageIndex": "\(activeStageIndex)",
            "selectedStageIndex": "\(selectedStageIndex)",
            "selectedWindowIndex": "\(selectedWindowIndex)",
            "eventTapRunning": "\(keyboardService.isRunning)",
            "eventTapStarted": "\(keyboardServiceStarted)",
            "windowsInActiveStage": "\(stageManager.activeStage.windows.count)",
            "maxWindowsInStage": "\(stageManager.stages.map(\.windows.count).max() ?? 0)",
            "windowCountsByStage": stageManager.stages
                .map { String($0.windows.count) }
                .joined(separator: ","),
            "windowPreviewCount": "\(windowPreviews.count)",
            "variedWindowPreviewCount": "\(variedWindowPreviewIDs.count)",
        ]
    }

    // MARK: - Stage switching

    /// Makes the stage list match the desktops macOS actually has.
    ///
    /// Stages are desktops now, and only the user can create a desktop — `SLSSpaceCreate`
    /// returns an id no display manages, so a Debut-created Space would be unreachable from
    /// Mission Control. A stage with no desktop behind it is therefore a switch target that
    /// silently does nothing, and a desktop with no stage is invisible to the switcher.
    /// Called on launch and whenever the desktop set may have changed.
    public func reconcileStagesWithDesktops() {
        guard let spaceSwitcher else { return }
        Self.reconcileStages(&stageManager, desktopCount: spaceSwitcher.desktopCount())
    }

    /// Exposed separately because startup has to grow the stage list before windows are
    /// reconciled, which happens before any controller exists.
    public static func reconcileStages(_ stageManager: inout StageManager, desktopCount: Int) {
        guard desktopCount > 0 else { return }

        while stageManager.stages.count > desktopCount {
            stageManager.deleteStage(id: stageManager.stages[stageManager.stages.count - 1].id)
        }
        while stageManager.stages.count < desktopCount {
            stageManager.createStage(position: .below)
        }
    }

    /// Call whenever macOS reports the active Space changed.
    public func desktopDidChange() {
        syncActiveStageWithCurrentDesktop()
        applyPendingStageFocus()
    }

    /// Focuses the window a stage switch asked for, now that its desktop is showing.
    ///
    /// A switch that focused its target straight away was focusing it on the desktop it was
    /// leaving, because the Dock consumes the forged swipe asynchronously. macOS then
    /// restored its own idea of focus as the Space settled and overwrote the choice.
    private func applyPendingStageFocus() {
        guard let pending = pendingStageFocus else { return }
        guard let index = spaceSwitcher?.currentDesktopIndex(),
              stageManager.stages.indices.contains(index),
              stageManager.stages[index].id == pending.stageID
        else {
            // The user overtook the switch. Dragging focus back to the stage they left is
            // worse than leaving it wherever they landed.
            pendingStageFocus = nil
            return
        }
        pendingStageFocus = nil
        focusWindow(pending.windowID, inStageID: pending.stageID)
        delegate?.stageControllerDidMutateState(self)
    }

    private func focusWindow(_ windowID: CGWindowID, inStageID stageID: UUID) {
        _ = windowService.raiseWindow(windowID: windowID)
        stageManager.bringWindowToFront(windowID: windowID, inStageID: stageID)
        if let bundleID = stageManager.stages.first(where: { $0.id == stageID })?
            .windows.first(where: { $0.windowID == windowID })?.ownerBundleID {
            _ = windowService.activateApp(bundleID: bundleID)
        }
    }

    /// Adopts the desktop currently showing as the active stage.
    ///
    /// The user can switch desktop without Debut — Mission Control, Control+Arrow, or
    /// clicking a window on another desktop all do it — and until this runs, Debut's active
    /// stage is simply wrong. Call it whenever macOS reports the active Space changed.
    public func syncActiveStageWithCurrentDesktop() {
        guard let index = spaceSwitcher?.currentDesktopIndex(),
              stageManager.stages.indices.contains(index)
        else { return }
        let stageID = stageManager.stages[index].id
        guard stageID != stageManager.activeStageID else { return }

        previousStageID = stageManager.activeStageID
        stageManager.activateStage(id: stageID)
        diag.report("active_stage_synced", details: [
            "to": stageLabel(forID: stageID),
            "reason": "desktop_changed_externally",
        ])
        delegate?.stageControllerDidMutateState(self)
        delegate?.stageControllerDidSwitchStage(self)
    }

    /// Position-based label for a stage, e.g. "Stage 2". Used for diagnostics only.
    private func stageLabel(forID id: UUID) -> String {
        guard let index = stageManager.stages.firstIndex(where: { $0.id == id }) else { return "?" }
        return "Stage \(index + 1)"
    }

    public func switchToStage(id targetID: UUID, raiseWindowID: CGWindowID? = nil) {
        let targetStage = stageManager.stages.first(where: { $0.id == targetID })
        let workload = PerformanceWorkload(
            stages: stageManager.stages.count,
            windows: targetStage?.windows.count ?? 0
        )
        let performanceID = PerformanceRecorder.shared.begin(.stageSwitch, workload: workload)
        defer { PerformanceRecorder.shared.end(performanceID) }
        backtickCycleWindows = []
        backtickCycleIndex = 0

        let previousID = stageManager.activeStageID
        var desktopIsSettling = false

        if previousID != targetID {
            let fromLabel = stageLabel(forID: previousID)
            let toLabel = stageLabel(forID: targetID)

            self.previousStageID = previousID
            stageManager.activateStage(id: targetID)

            // The stage's windows already live on the target desktop, so macOS reveals all
            // of them in one composited transition. The surface architecture instead covered
            // the screen and AX-raised each window in turn, and that staggered raise is the
            // flash this migration exists to remove — so there is deliberately no per-window
            // raise here.
            let raiseID = PerformanceRecorder.shared.begin(
                .stageRaise,
                workload: .init(windows: targetStage?.windows.count ?? 0)
            )
            if let index = stageManager.stages.firstIndex(where: { $0.id == targetID }),
               let switcher = spaceSwitcher {
                desktopIsSettling = switcher.switchToDesktop(index: index)
            }
            _ = PerformanceRecorder.shared.end(raiseID)

            diag.report("stage_switched", details: [
                "from": fromLabel,
                "to": toLabel,
                "windowsInTarget": "\(targetStage?.windows.count ?? 0)",
            ])
        }

        // Focus the selected window and activate its app (single activation, no flash).
        // A desktop still settling cannot be focused yet — see `applyPendingStageFocus`.
        if let focusWindowID = raiseWindowID ?? targetStage?.windows.first?.windowID {
            if desktopIsSettling {
                pendingStageFocus = (stageID: targetID, windowID: focusWindowID)
            } else {
                pendingStageFocus = nil
                focusWindow(focusWindowID, inStageID: targetID)
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

        // A window cannot take focus on a desktop that is not showing, so the desktop is
        // already right here and only the assignment can be wrong. Debut used to answer a
        // cross-stage activation by switching stages, which now means switching desktops,
        // and that fought the user in a loop: the switch changed the Space, the Space
        // change resynced the active stage, and the next focus event switched back.
        //
        // Only a positive answer moves a window that already belongs somewhere. A window on
        // every desktop — Finder's, typically — resolves to no single one, and reading that
        // silence as "the desktop showing" dragged its plate onto whichever stage was last
        // visited. Silence leaves the assignment for a later real answer to correct.
        let ownerStageID = stageOwningWindow(windowID: windowID)
        let desktopStageID = spaceSwitcher?.desktopIndex(forWindow: windowID)
            .flatMap { stageManager.stages.indices.contains($0) ? stageManager.stages[$0].id : nil }
        let targetStageID = desktopStageID ?? ownerStageID ?? stageManager.activeStageID

        if ownerStageID == targetStageID {
            stageManager.bringWindowToFront(windowID: windowID, inStageID: targetStageID)
            delegate?.stageControllerDidMutateState(self)
            return
        }

        if let ownerStageID,
           let window = stageManager.stages.first(where: { $0.id == ownerStageID })?
               .windows.first(where: { $0.windowID == windowID }) {
            diag.report("window_reassigned", details: [
                "windowID": "\(windowID)",
                "bundleID": window.ownerBundleID,
                "windowTitle": window.windowTitle,
                "fromStage": stageLabel(forID: ownerStageID),
                "toStage": stageLabel(forID: targetStageID),
                "reason": "activated_on_other_desktop",
            ])
            stageManager.removeLiveWindowFromAllStages(windowID: windowID)
            stageManager.addWindow(window, toStageID: targetStageID)
        } else if let info = windowService.listWindows().first(where: { $0.windowID == windowID }) {
            // Genuinely new — "code ." opening a window while the app's other windows sit
            // on another desktop.
            stageManager.addWindow(
                StageWindow(
                    windowID: info.windowID,
                    ownerBundleID: info.ownerBundleID,
                    ownerName: info.ownerName,
                    windowTitle: info.title,
                    ownerPID: info.ownerPID
                ),
                toStageID: targetStageID
            )
        } else {
            return
        }

        stageManager.bringWindowToFront(windowID: windowID, inStageID: targetStageID)
        delegate?.stageControllerDidMutateState(self)
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
        case .cmdShiftBacktickRepeat:
            handleCmdBacktick(reverse: true, wraps: false)
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
        case .previousWindowRepeat:
            cycleWindow(forward: false, wraps: false)
        case .nextStage:
            cycleStage(forward: true)
        case .previousStage:
            cycleStage(forward: false)
        case .jumpToStage(let index):
            jumpToStage(index: index - 1)
        case .jumpToLastStage:
            jumpToStage(index: stageManager.stages.count - 1)
        case .switchToStage(let position):
            quickSwitchToStage(index: position - 1, keepingCurrentApplication: false)
        case .switchToStageKeepingCurrentApplication(let position):
            quickSwitchToStage(index: position - 1, keepingCurrentApplication: true)
        case .moveWindowUp:
            moveWindow(direction: .up)
        case .moveWindowDown:
            moveWindow(direction: .down)
        case .moveWindowLeft:
            moveWindowWithinStage(offset: -1)
        case .moveWindowRight:
            moveWindowWithinStage(offset: 1)
        case .swapStageUp:
            swapStage(direction: .up)
        case .swapStageDown:
            swapStage(direction: .down)
        case .quitSelectedApp:
            quitSelectedApp()
        }
    }

    // MARK: - Quick switch

    /// Immediately switch to the stage at the given index (configured modifier + 1-9).
    /// Works whether or not the overlay is open; if open, it is dismissed first.
    private func quickSwitchToStage(index: Int, keepingCurrentApplication: Bool) {
        guard stageManager.stages.indices.contains(index) else { return }

        // Stage window order is MRU. Capture the active app before switching,
        // then prefer that app's most-recent window in the destination stage.
        let activeBundleID = stageManager.activeStage.windows.first?.ownerBundleID
        let targetStage = stageManager.stages[index]
        let matchingWindowID = keepingCurrentApplication
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
        let presentation = activeOverlayPresentation
        let focusedWindow = probeFocusedWindow()
        focusedWindowFrame = focusedWindow.frame
        focusedWindowIsFullscreen = focusedWindow.isFullscreen
        if let presentation {
            overlayPresentationRecorder.mark(.focusProbeCompleted, for: presentation)
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
        let assignedWindowIDs = stageManager.stages.flatMap { $0.windows.map(\.windowID) }
        pruneWindowPreviews(assignedWindowIDs: Set(assignedWindowIDs))
        let cachedCount = variedWindowPreviewIDs.intersection(assignedWindowIDs).count
        pendingPreviewCaptureIDs = windowIDsNeedingCapture()
        if let presentation {
            let workload = PerformanceWorkload(
                stages: stageManager.stages.count,
                windows: assignedWindowIDs.count,
                captures: pendingPreviewCaptureIDs.count
            )
            overlayPresentationRecorder.updateEnvironment(
                for: presentation,
                previewCache: .classify(cached: cachedCount, assigned: assignedWindowIDs.count),
                // Debut no longer draws a wallpaper of its own — the real desktop is the
                // backdrop now, so there is no captured wallpaper whose state to report.
                wallpaperState: .unavailable,
                workload: workload,
                cachedPreviewCount: cachedCount
            )
        }
        scheduleOverlayPresentation()
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
            // Capturing before this point puts SCK enumeration, capture completions and the
            // resulting view rebuilds on the main queue ahead of the overlay's first frame,
            // which measured as ~37ms of render-submission delay for a two-line block.
            self.captureDirtyWindowPreviews(overlayPresentation: presentation)
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
    static let focusProbeTimeout: TimeInterval = 0.05

    private func probeFocusedWindow() -> FocusedWindowSnapshot {
        if let focusedWindowSnapshotProvider {
            return focusedWindowSnapshotProvider()
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != "com.thomplth.DebutSpace"
        else { return .unfocused }

        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, Float(Self.focusProbeTimeout))
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowsRef) == .success else {
            return .unfocused
        }
        let axWindow = windowsRef as! AXUIElement
        AXUIElementSetMessagingTimeout(axWindow, Float(Self.focusProbeTimeout))
        var fullscreenRef: CFTypeRef?
        let isFullscreen = AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullscreenRef) == .success
            && (fullscreenRef as? Bool) == true
        return FocusedWindowSnapshot(
            frame: axFrame(of: axWindow),
            isFullscreen: isFullscreen
        )
    }

    private func axFrame(of axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// A missing capture can mean that a window is merely hidden, so a preview is retained until
    /// its assignment is gone. Per AGENTS.md, absence from AX or CGWindowList never proves
    /// destruction.
    private func pruneWindowPreviews(assignedWindowIDs: Set<CGWindowID>) {
        windowPreviews = windowPreviews.filter { assignedWindowIDs.contains($0.key) }
        variedWindowPreviewIDs.formIntersection(assignedWindowIDs)
        previewCacheEntries = previewCacheEntries.filter { assignedWindowIDs.contains($0.key) }
    }

    /// The windows whose cached preview cannot be trusted for this activation. Everything else
    /// is served from `windowPreviews` without a capture.
    private func windowIDsNeedingCapture() -> [CGWindowID] {
        let assignedWindows = stageManager.stages.flatMap(\.windows)
        guard previewRefreshPolicy == .lastActiveOnly else {
            return assignedWindows.map(\.windowID)
        }

        // The window in front of the active stage is the one that was just being used, so its
        // content is the one most likely to have moved on since the last capture.
        let lastActiveWindowID = stageManager.activeStage.windows.first?.windowID
        let now = previewClock()
        return assignedWindows.compactMap { window in
            if window.windowID == lastActiveWindowID { return window.windowID }
            guard windowPreviews[window.windowID] != nil,
                  let entry = previewCacheEntries[window.windowID]
            else { return window.windowID }
            if entry.windowTitle != window.windowTitle { return window.windowID }
            // Dirty tracking alone goes stale for windows that change without ever being
            // activated — video, chat, dashboards.
            if now.timeIntervalSince(entry.capturedAt) >= previewCacheTTL { return window.windowID }
            return nil
        }
    }

    private func captureDirtyWindowPreviews(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        let windowIDs = pendingPreviewCaptureIDs
        pendingPreviewCaptureIDs = []

        previewCaptureTask?.cancel()
        previewCaptureGeneration &+= 1
        let generation = previewCaptureGeneration
        let metrics = PreviewCaptureMetrics(
            windowIDs: windowIDs,
            overlayPresentation: overlayPresentation,
            overlayPresentationRecorder: overlayPresentationRecorder
        )

        guard !windowIDs.isEmpty else {
            _ = metrics.finish()
            diag.report("preview_capture_skipped", level: .transient, details: [
                "cached": "\(windowPreviews.count)",
            ])
            return
        }

        let clock = previewClock
        previewCaptureTask = Task { [weak self, windowService] in
            await windowService.captureWindowImages(
                windowIDs: windowIDs,
                onEnumerated: { matchedWindowIDs in
                    metrics.recordEnumeration(matchedWindowIDs: matchedWindowIDs)
                }
            ) { [weak self] capture in
                metrics.recordCapture(windowID: capture.windowID)
                // Luminance analysis draws the capture through Core Graphics. Doing it here
                // rather than in the main-queue hop keeps the render path free.
                let hasVariedLuminance = WindowImageStatistics.hasVariedLuminance(capture.image)
                let capturedAt = clock()
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.previewCaptureGeneration == generation,
                          let window = self.stageManager.stages
                              .flatMap(\.windows)
                              .first(where: { $0.windowID == capture.windowID })
                    else { return }

                    self.windowPreviews[capture.windowID] = capture.image
                    self.previewCacheEntries[capture.windowID] = PreviewCacheEntry(
                        capturedAt: capturedAt,
                        windowTitle: window.windowTitle
                    )
                    if hasVariedLuminance {
                        self.variedWindowPreviewIDs.insert(capture.windowID)
                    } else {
                        self.variedWindowPreviewIDs.remove(capture.windowID)
                    }
                    self.scheduleOverlayPreviewFlush()
                }
            }
            let capturedCount = metrics.finish()
            DiagnosticReporter.shared.report("preview_capture_completed", level: .transient, details: [
                "requested": "\(windowIDs.count)",
                "captured": "\(capturedCount)",
            ])

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.previewCaptureGeneration == generation
                else { return }
                self.scheduleOverlayPreviewFlush()
            }
        }
    }

    /// Concurrent captures land in a burst, and each one otherwise rebuilt the whole overlay
    /// view model. Coalescing to one rebuild per frame keeps previews streaming in without
    /// turning a 15-window refresh into 15 full SwiftUI diffs.
    private func scheduleOverlayPreviewFlush() {
        guard isStageManagerVisible, !pendingPreviewFlush else { return }
        pendingPreviewFlush = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.pendingPreviewFlush = false
            guard self.isStageManagerVisible else { return }
            self.notifyOverlayUpdated()
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
              canRelocate(from: fromStageIndex, to: toStageIndex),
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
        relocateToStageDesktop(windowID: windowID,
                               fromStageIndex: fromStageIndex,
                               toStageIndex: toStageIndex)

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

        if wraps {
            let step = forward ? 1 : -1
            selectedWindowIndex =
                (selectedWindowIndex + step + stage.windows.count) % stage.windows.count
        } else {
            let nextIndex = forward
                ? min(selectedWindowIndex + 1, stage.windows.count - 1)
                : max(selectedWindowIndex - 1, 0)
            guard nextIndex != selectedWindowIndex else { return }
            selectedWindowIndex = nextIndex
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

    public func jumpToStage(index: Int) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(index) else { return }
        selectedStageIndex = index
        selectedWindowIndex = 0
        notifyOverlayUpdated()
    }

    /// A committed plate drag also moves focus: the plate the user was holding is the one they
    /// are looking at, and the magnification during the drag already promised it would stay.
    public func reorderStage(fromIndex: Int, toIndex: Int) {
        guard stageManager.stages.indices.contains(fromIndex),
              stageManager.stages.indices.contains(toIndex),
              fromIndex != toIndex else { return }
        let movedID = stageManager.stages[fromIndex].id
        stageManager.moveStage(fromIndex: fromIndex, toIndex: toIndex)
        stageManager.activateStage(id: movedID)
        selectedStageIndex = stageManager.stages.firstIndex(where: { $0.id == movedID }) ?? toIndex
        selectedWindowIndex = 0
        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
    }

    /// Windows can vanish while the overlay is on screen — an app quits, a window closes — and
    /// the selection is an index, so it has to be pulled back in range before the overlay is
    /// redrawn against the shorter stage.
    public func handleLiveWindowsRemoved() {
        let windowCount = stageManager.stages[safe: selectedStageIndex]?.windows.count ?? 0
        selectedWindowIndex = max(0, min(selectedWindowIndex, windowCount - 1))
        notifyOverlayUpdated()
    }

    /// Whether the stage model may record a window changing stages.
    ///
    /// The transport is a private-API bridge that fails by doing nothing, so a move it cannot
    /// perform must not update the model either: the plate would sit on one stage while the
    /// window stayed on another desktop, persisted, with nothing to correct it. A controller
    /// with no space switcher at all is not backed by desktops, so nothing constrains it.
    private func canRelocate(from: Int, to: Int) -> Bool {
        from == to || spaceSwitcher.map(\.canMoveWindows) ?? true
    }

    /// Puts the window on the desktop backing its new stage.
    ///
    /// The stage model is the user's intent and has already been updated, so a refused move is
    /// reported rather than rolled back — the next reconcile reads the window's real desktop
    /// and corrects the assignment either way.
    private func relocateToStageDesktop(windowID: CGWindowID,
                                        fromStageIndex: Int,
                                        toStageIndex: Int) {
        guard fromStageIndex != toStageIndex, let spaceSwitcher else { return }

        spaceSwitcher.moveWindow(windowID: windowID, toDesktop: toStageIndex) {
            [weak self] moved in
            guard !moved else { return }
            DispatchQueue.main.async {
                self?.diag.report("window_move_failed",
                                  details: ["windowID": "\(windowID)",
                                            "toDesktop": "\(toStageIndex)"])
            }
        }
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
        guard canRelocate(from: selectedStageIndex, to: targetStageIndex) else { return }

        let targetStageID = stageManager.stages[targetStageIndex].id
        stageManager.moveWindow(windowID: window.windowID, fromStageID: stage.id, toStageID: targetStageID)
        relocateToStageDesktop(windowID: window.windowID,
                               fromStageIndex: selectedStageIndex,
                               toStageIndex: targetStageIndex)

        // Follow the moved window to the target stage
        selectedStageIndex = targetStageIndex
        let targetWindows = stageManager.stages[targetStageIndex].windows
        selectedWindowIndex = targetWindows.firstIndex(where: { $0.windowID == window.windowID }) ?? 0

        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
    }

    private func moveWindowWithinStage(offset: Int) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        guard stage.windows.indices.contains(selectedWindowIndex) else { return }
        let targetIndex = selectedWindowIndex + offset
        guard stage.windows.indices.contains(targetIndex) else { return }

        stageManager.moveWindow(
            windowID: stage.windows[selectedWindowIndex].windowID,
            fromStageID: stage.id,
            toStageID: stage.id,
            at: targetIndex
        )
        selectedWindowIndex = targetIndex

        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
    }

    /// The overlay stays open so the user can keep working through the stage. Assignments are
    /// left alone here: the process-exit monitor makes them dormant once the app actually goes.
    private func quitSelectedApp() {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = stageManager.stages[selectedStageIndex]
        guard stage.windows.indices.contains(selectedWindowIndex) else { return }
        let window = stage.windows[selectedWindowIndex]

        guard let ownerPID = window.ownerPID else {
            diag.report("quit_selected_app_skipped", details: [
                "windowID": "\(window.windowID)",
                "bundleID": window.ownerBundleID,
                "reason": "no_pid",
            ])
            return
        }

        let requested = windowService.terminateApp(pid: ownerPID)
        diag.report("quit_selected_app", details: [
            "windowID": "\(window.windowID)",
            "bundleID": window.ownerBundleID,
            "ownerPID": "\(ownerPID)",
            "requested": "\(requested)",
        ])
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
