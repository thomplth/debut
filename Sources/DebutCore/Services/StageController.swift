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

/// Completes a stage commit only after every asynchronous window relocation has answered.
private final class WindowRelocationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var completion: (@Sendable () -> Void)?

    init(count: Int, completion: @escaping @Sendable () -> Void) {
        remaining = count
        self.completion = completion
    }

    func arrive() {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            remaining -= 1
            guard remaining == 0 else { return nil }
            defer { self.completion = nil }
            return self.completion
        }
        completion?()
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

    private var pendingStageFocus: (stageID: UUID, windowID: CGWindowID)?
    private var plateStackTransaction = PlateStackTransaction()
    private var isPlateStackCommitInFlight = false

    public private(set) var isStageManagerVisible: Bool = false
    public var selectedStageIndex: Int = 0
    public var selectedWindowIndex: Int = 0
    public private(set) var keyboardServiceStarted: Bool = false
    public var overlayPresentationDelay: TimeInterval
    public var previewRefreshPolicy: PreviewRefreshPolicy
    public var previewCacheTTL: TimeInterval

    /// The model rendered by the overlay, including interactions that are still waiting for
    /// the session commit. The persisted `stageManager` remains the last committed state.
    public var overlayStageManager: StageManager {
        plateStackTransaction.preview(applyingTo: stageManager)
    }

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
    private var preOverlayStageStackID: String?
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
        let visibleStageManager = isStageManagerVisible ? overlayStageManager : stageManager
        let activeStageIndex = visibleStageManager.stages
            .firstIndex(where: { $0.id == visibleStageManager.activeStageID }) ?? 0
        return [
            "overlayVisible": "\(isStageManagerVisible)",
            "focusedWindowFullscreen": "\(focusedWindowIsFullscreen)",
            "stageCount": "\(visibleStageManager.stages.count)",
            "stageStackCount": "\(visibleStageManager.connectedStageStacks.count)",
            "selectedStageStackID": visibleStageManager.selectedStageStackID,
            "selectedDisplayName": visibleStageManager.selectedStageStack?.displayName ?? "unknown",
            "stageCountsByStack": visibleStageManager.connectedStageStacks
                .map { "\($0.displayName):\($0.stages.count)" }
                .joined(separator: ","),
            "activeStageIndex": "\(activeStageIndex)",
            "selectedStageIndex": "\(selectedStageIndex)",
            "selectedWindowIndex": "\(selectedWindowIndex)",
            "eventTapRunning": "\(keyboardService.isRunning)",
            "eventTapStarted": "\(keyboardServiceStarted)",
            "windowsInActiveStage": "\(visibleStageManager.activeStage.windows.count)",
            "maxWindowsInStage": "\(visibleStageManager.stages.map(\.windows.count).max() ?? 0)",
            "windowCountsByStage": visibleStageManager.stages
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
        guard let spaceSwitcher else {
            diag.report("stages_reconcile_refused", details: ["reason": "noSpaceSwitcher"])
            return
        }
        let topology = spaceSwitcher.spaceTopology()
        guard !topology.stacks.isEmpty else {
            diag.report("stages_reconcile_refused", details: ["reason": "noDesktopsReported"])
            return
        }
        let stackCountBefore = stageManager.connectedStageStacks.count
        let stageCountBefore = stageManager.allStages.count
        stageManager.reconcileStageStacks(with: topology)
        let stackCountAfter = stageManager.connectedStageStacks.count
        let stageCountAfter = stageManager.allStages.count
        if stackCountBefore != stackCountAfter || stageCountBefore != stageCountAfter {
            diag.report("stages_reconciled", details: [
                "separateSpaces": "\(topology.separateSpaces)",
                "stackCountBefore": "\(stackCountBefore)",
                "stackCountAfter": "\(stackCountAfter)",
                "stagesBefore": "\(stageCountBefore)",
                "stagesAfter": "\(stageCountAfter)",
            ])
            delegate?.stageControllerDidMutateState(self)
        }
    }

    /// What a reconcile saw and did.
    ///
    /// Refusing to act on a zero desktop count is right — an empty answer from the window
    /// server is not evidence the desktops are gone — but a silent refusal is indistinguishable
    /// from a host that really has one desktop, and that ambiguity hid a launch where Debut
    /// built one stage against three real desktops.
    public struct StageReconciliation: Equatable {
        public let desktopCount: Int
        public let stagesBefore: Int
        public let stagesAfter: Int

        public var refused: Bool { desktopCount <= 0 }

        public var didChange: Bool { stagesBefore != stagesAfter }

        var diagnosticEvent: String { refused ? "stages_reconcile_refused" : "stages_reconciled" }

        var diagnosticDetails: [String: String] {
            var details = [
                "desktopCount": "\(desktopCount)",
                "stagesBefore": "\(stagesBefore)",
                "stagesAfter": "\(stagesAfter)",
            ]
            if refused { details["reason"] = "noDesktopsReported" }
            return details
        }
    }

    /// Exposed separately because startup has to grow the stage list before windows are
    /// reconciled, which happens before any controller exists.
    @discardableResult
    public static func reconcileStages(_ stageManager: inout StageManager,
                                       desktopCount: Int) -> StageReconciliation {
        let before = stageManager.stages.count
        guard desktopCount > 0 else {
            return StageReconciliation(desktopCount: desktopCount,
                                       stagesBefore: before,
                                       stagesAfter: before)
        }

        while stageManager.stages.count > desktopCount {
            stageManager.deleteStage(id: stageManager.stages[stageManager.stages.count - 1].id)
        }
        while stageManager.stages.count < desktopCount {
            stageManager.createStage(position: .below)
        }
        return StageReconciliation(desktopCount: desktopCount,
                                   stagesBefore: before,
                                   stagesAfter: stageManager.stages.count)
    }

    /// Call whenever macOS reports the active Space changed.
    ///
    /// The desktop set is rechecked first, not only the active index. Mission Control can add
    /// or remove a desktop at any moment, and reconciling solely at launch left the stage list
    /// wrong for the rest of the session — windows on a desktop past the end of the stage array
    /// have nowhere to go. The notification fires once the Space change has settled, so this is
    /// the earliest honest point to re-ask.
    public func desktopDidChange() {
        // Let the switcher confirm the completed hop before reconciling the model. A far
        // target may start its next adjacent hop here, which also tells deferred focus that
        // an intermediate desktop is expected rather than a user overtaking the switch.
        spaceSwitcher?.spaceDidChange()
        let previousActiveStageID = stageManager.activeStageID
        reconcileStagesWithDesktops()
        if stageManager.activeStageID != previousActiveStageID {
            previousStageID = previousActiveStageID
            diag.report("active_stage_synced", details: [
                "to": stageLabel(forID: stageManager.activeStageID),
                "reason": "desktop_changed_externally",
            ])
            delegate?.stageControllerDidMutateState(self)
            delegate?.stageControllerDidSwitchStage(self)
        }
        applyPendingStageFocus()
    }

    /// Focuses the window a stage switch asked for, now that its desktop is showing.
    ///
    /// A switch that focused its target straight away was focusing it on the desktop it was
    /// leaving, because the Dock consumes the forged swipe asynchronously. macOS then
    /// restored its own idea of focus as the Space settled and overwrote the choice.
    private func applyPendingStageFocus() {
        guard let pending = pendingStageFocus else { return }
        guard let stackID = stageManager.stageStackID(containingStageID: pending.stageID),
              let index = stageManager.stageIndex(id: pending.stageID),
              let switcher = spaceSwitcher,
              let stack = switcher.spaceTopology().stack(id: stackID)
        else {
            pendingStageFocus = nil
            return
        }

        guard stack.currentDesktopIndex == index else {
            // A confirmed intermediate hop is still on the way to this focus target. Only
            // discard the request once the coordinator has stopped somewhere else; that is
            // the signal that the user overtook the switch or Dock landed unexpectedly.
            if switcher.isSwitchInFlight(stackID: stackID) { return }
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
        if let bundleID = stageManager.allStages.first(where: { $0.id == stageID })?
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
        guard let topology = spaceSwitcher?.spaceTopology(),
              let stack = topology.stack(id: stageManager.selectedStageStackID),
              let index = stack.currentDesktopIndex,
              let stageID = stageManager.stageID(stackID: stack.id, at: index),
              stageID != stageManager.activeStageID
        else { return }
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
        guard let index = stageManager.stageIndex(id: id),
              let stackID = stageManager.stageStackID(containingStageID: id),
              let stack = stageManager.stageStacks.first(where: { $0.id == stackID })
        else { return "?" }
        return "\(stack.displayName) Stage \(index + 1)"
    }

    /// - Parameter focusesWindow: When false the desktop moves without Debut focusing anything,
    ///   leaving the choice of frontmost app to macOS. Debut's own focus lands within a few
    ///   milliseconds of the Space flip, so the two race, and `recordWindowActivation` writes a
    ///   lost race into the stage's MRU head — which makes a single loss permanent.
    public func switchToStage(id targetID: UUID, raiseWindowID: CGWindowID? = nil,
                              focusesWindow: Bool = true) {
        let targetStage = stageManager.allStages.first(where: { $0.id == targetID })
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
            if let index = stageManager.stageIndex(id: targetID),
               let stackID = stageManager.stageStackID(containingStageID: targetID),
               let location = spaceSwitcher?.spaceTopology().stack(id: stackID)?.location(at: index),
               let switcher = spaceSwitcher {
                desktopIsSettling = switcher.switchToDesktop(location)
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
        if focusesWindow, let focusWindowID = raiseWindowID ?? targetStage?.windows.first?.windowID {
            if desktopIsSettling {
                pendingStageFocus = (stageID: targetID, windowID: focusWindowID)
            } else {
                pendingStageFocus = nil
                focusWindow(focusWindowID, inStageID: targetID)
            }
        } else {
            // A focus queued by an earlier switch to this same stage would otherwise still fire.
            pendingStageFocus = nil
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
        let desktopLocation = spaceSwitcher?.desktopLocation(forWindow: windowID)
        let desktopStageID = desktopLocation.flatMap {
            stageManager.stageID(stackID: $0.stackID, at: $0.index)
        }
        let targetStageID = desktopStageID ?? ownerStageID ?? stageManager.activeStageID

        if !isStageManagerVisible, let stackID = desktopLocation?.stackID {
            stageManager.selectStageStack(id: stackID)
        }

        if ownerStageID == targetStageID {
            stageManager.bringWindowToFront(windowID: windowID, inStageID: targetStageID)
            delegate?.stageControllerDidMutateState(self)
            return
        }

        if let ownerStageID,
           let window = stageManager.allStages.first(where: { $0.id == ownerStageID })?
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
        case .nextDisplayStack:
            cycleDisplayStack()
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
        case .quitSelectedApp:
            quitSelectedApp()
        case .closeSelectedWindow:
            closeSelectedWindow()
        }
    }

    // MARK: - Quick switch

    /// Immediately switch to the stage at the given index (configured modifier + 1-9).
    /// Works whether or not the overlay is open; if open, it is dismissed first.
    private func quickSwitchToStage(index: Int, keepingCurrentApplication: Bool) {
        guard !isPlateStackCommitInFlight,
              stageManager.stages.indices.contains(index) else { return }

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
            plateStackTransaction.discard()
            isStageManagerVisible = false
            if let tapService = keyboardService as? EventTapKeyboardService {
                tapService.overlayVisible = false
            }
            dismissOverlayPresentation()
        }

        // Keeping the current application is the whole point of that chord, so it still focuses.
        switchToStage(id: targetStage.id, raiseWindowID: matchingWindowID,
                      focusesWindow: keepingCurrentApplication)
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
        plateStackTransaction.discard()

        // Removing an inactive desktop need not change the Space currently showing, so there
        // may be no active-space notification. Recheck at the point where a stale stage would
        // otherwise become visible; this is event-driven by the user's overlay command.
        reconcileStagesWithDesktops()

        isStageManagerVisible = true
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = true
        }
        if let index = stageManager.stages.firstIndex(where: { $0.id == stageManager.activeStageID }) {
            selectedStageIndex = index
        }
        preOverlayStageID = stageManager.activeStageID
        preOverlayStageStackID = stageManager.selectedStageStackID
        let assignedWindowIDs = stageManager.allStages.flatMap { $0.windows.map(\.windowID) }
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
              frontApp.bundleIdentifier != "com.thomplth.Debut"
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
        let assignedWindows = stageManager.allStages.flatMap(\.windows)
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
                // A non-nil image is not proof that ScreenCaptureKit returned window content.
                // Keep the last good bitmap and its original timestamp when validation fails,
                // so an expired entry remains visible and eligible for another refresh.
                guard hasVariedLuminance else { return }
                let capturedAt = clock()
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.previewCaptureGeneration == generation,
                          let window = self.stageManager.allStages
                              .flatMap(\.windows)
                              .first(where: { $0.windowID == capture.windowID })
                    else { return }

                    self.windowPreviews[capture.windowID] = capture.image
                    self.previewCacheEntries[capture.windowID] = PreviewCacheEntry(
                        capturedAt: capturedAt,
                        windowTitle: window.windowTitle
                    )
                    self.variedWindowPreviewIDs.insert(capture.windowID)
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
        guard isStageManagerVisible, !isPlateStackCommitInFlight else { return }
        isPlateStackCommitInFlight = true
        commitPlateStackTransaction { [weak self] in
            self?.finishSelectionCommit()
        }
    }

    private func finishSelectionCommit() {
        guard isStageManagerVisible, isPlateStackCommitInFlight else { return }
        isPlateStackCommitInFlight = false
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
        let preview = overlayStageManager
        guard isStageManagerVisible, !isPlateStackCommitInFlight,
              preview.stages.indices.contains(stageIndex),
              preview.stages[stageIndex].windows.indices.contains(windowIndex)
        else { return }

        selectedStageIndex = stageIndex
        selectedWindowIndex = windowIndex
        commitSelection()
    }

    /// Close the switcher and expose Finder's real desktop surface.
    public func revealDesktop() {
        guard isStageManagerVisible, !isPlateStackCommitInFlight else { return }
        plateStackTransaction.discard()
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
        let preview = overlayStageManager
        guard isStageManagerVisible, !isPlateStackCommitInFlight,
              preview.stages.indices.contains(fromStageIndex),
              preview.stages.indices.contains(toStageIndex),
              canRelocate(from: fromStageIndex, to: toStageIndex),
              preview.stages[fromStageIndex].windows.contains(where: {
                  $0.windowID == windowID
              })
        else { return false }

        let fromStageID = preview.stages[fromStageIndex].id
        let toStageID = preview.stages[toStageIndex].id
        plateStackTransaction.stageMove(
            windowID: windowID,
            fromStageID: fromStageID,
            toStageID: toStageID,
            windowIndex: toWindowIndex,
            source: .pointer
        )

        if selectedStageIndex == toStageIndex,
           let movedIndex = overlayStageManager.stages[toStageIndex].windows.firstIndex(where: {
               $0.windowID == windowID
           }) {
            selectedWindowIndex = movedIndex
        }

        notifyOverlayUpdated()
        return true
    }

    /// Close the overlay but keep the Cmd session alive.
    /// Next Cmd+Tab or Cmd+Option+Tab reopens the overlay.
    private func discardOverlay() {
        guard isStageManagerVisible, !isPlateStackCommitInFlight else { return }
        plateStackTransaction.discard()
        isStageManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }
        if let preOverlayStageStackID {
            stageManager.selectStageStack(id: preOverlayStageStackID)
        }
        selectedStageIndex = stageManager.stages.firstIndex(where: { $0.id == preOverlayStageID }) ?? 0
        selectedWindowIndex = 0
        dismissOverlayPresentation()
        // stageManagerActive stays true — session continues until Cmd release
        // Cmd+` still stage-isolated (intercepted before the overlay gate)
    }

    private func cycleWindow(forward: Bool, wraps: Bool = true) {
        guard isStageManagerVisible,
              overlayStageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = overlayStageManager.stages[selectedStageIndex]
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

    private func cycleDisplayStack() {
        guard isStageManagerVisible else { return }
        let previous = stageManager.selectedStageStackID
        stageManager.selectNextStageStack()
        guard stageManager.selectedStageStackID != previous else { return }
        selectedStageIndex = stageManager.stages.firstIndex(where: {
            $0.id == stageManager.activeStageID
        }) ?? 0
        selectedWindowIndex = 0
        diag.report("display_stack_selected", details: [
            "stackID": stageManager.selectedStageStackID,
            "displayName": stageManager.selectedStageStack?.displayName ?? "unknown",
        ])
        delegate?.stageControllerDidMutateState(self)
        notifyOverlayUpdated()
    }

    /// Aligns the initially shown stack with the display holding the focused window.
    public func selectStageStack(forDisplayID displayID: CGDirectDisplayID) {
        guard let stackID = spaceSwitcher?.spaceTopology().stack(displayID: displayID)?.id,
              stackID != stageManager.selectedStageStackID
        else { return }
        stageManager.selectStageStack(id: stackID)
        selectedStageIndex = stageManager.stageIndex(id: stageManager.activeStageID) ?? 0
        selectedWindowIndex = 0
    }

    public func jumpToStage(index: Int) {
        guard isStageManagerVisible,
              stageManager.stages.indices.contains(index) else { return }
        selectedStageIndex = index
        selectedWindowIndex = 0
        notifyOverlayUpdated()
    }

    /// Windows can vanish while the overlay is on screen — an app quits, a window closes — and
    /// the selection is an index, so it has to be pulled back in range before the overlay is
    /// redrawn against the shorter stage.
    public func handleLiveWindowsRemoved() {
        let windowCount = overlayStageManager.stages[safe: selectedStageIndex]?.windows.count ?? 0
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
    private func relocateToStageDesktop(
        windowID: CGWindowID,
        fromStageIndex: Int,
        toStageIndex: Int,
        completion: @escaping @Sendable () -> Void
    ) {
        guard fromStageIndex != toStageIndex, let spaceSwitcher else {
            completion()
            return
        }

        guard let stackID = stageManager.stageStackID(containingStageID: stageManager.stages[toStageIndex].id),
              let location = spaceSwitcher.spaceTopology().stack(id: stackID)?.location(at: toStageIndex)
        else { return }
        spaceSwitcher.moveWindow(windowID: windowID, to: location) {
            [weak self] moved in
            let diag = self?.diag
            let finish: @Sendable () -> Void = {
                if !moved {
                    diag?.report("window_move_failed", details: [
                        "windowID": "\(windowID)",
                        "toDesktop": "\(toStageIndex)",
                    ])
                }
                completion()
            }
            if Thread.isMainThread {
                finish()
            } else {
                DispatchQueue.main.async(execute: finish)
            }
        }
    }

    private func moveWindow(direction: SwapDirection) {
        guard isStageManagerVisible,
              overlayStageManager.stages.indices.contains(selectedStageIndex) else { return }
        let preview = overlayStageManager
        let stage = preview.stages[selectedStageIndex]
        guard stage.windows.indices.contains(selectedWindowIndex) else { return }
        let window = stage.windows[selectedWindowIndex]

        let targetStageIndex: Int
        switch direction {
        case .up:
            guard selectedStageIndex > 0 else { return }
            targetStageIndex = selectedStageIndex - 1
        case .down:
            guard selectedStageIndex < preview.stages.count - 1 else { return }
            targetStageIndex = selectedStageIndex + 1
        }
        guard canRelocate(from: selectedStageIndex, to: targetStageIndex) else {
            diag.report("window_move_refused", details: [
                "windowID": "\(window.windowID)",
                "fromStageIndex": "\(selectedStageIndex)",
                "toStageIndex": "\(targetStageIndex)",
            ])
            return
        }

        let targetStageID = preview.stages[targetStageIndex].id
        let targetIndex = preview.stages[targetStageIndex].windows.count
        plateStackTransaction.stageMove(
            windowID: window.windowID,
            fromStageID: stage.id,
            toStageID: targetStageID,
            windowIndex: targetIndex,
            source: .keyboard
        )
        diag.report("window_move_previewed_by_key", level: .transient, details: [
            "windowID": "\(window.windowID)",
            "fromStageIndex": "\(selectedStageIndex)",
            "toStageIndex": "\(targetStageIndex)",
        ])

        // Follow the moved window to the target stage
        selectedStageIndex = targetStageIndex
        let targetWindows = overlayStageManager.stages[targetStageIndex].windows
        selectedWindowIndex = targetWindows.firstIndex(where: { $0.windowID == window.windowID }) ?? 0

        notifyOverlayUpdated()
    }

    private func moveWindowWithinStage(offset: Int) {
        guard isStageManagerVisible,
              overlayStageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = overlayStageManager.stages[selectedStageIndex]
        guard stage.windows.indices.contains(selectedWindowIndex) else { return }
        let targetIndex = selectedWindowIndex + offset
        guard stage.windows.indices.contains(targetIndex) else { return }

        plateStackTransaction.stageMove(
            windowID: stage.windows[selectedWindowIndex].windowID,
            fromStageID: stage.id,
            toStageID: stage.id,
            windowIndex: targetIndex,
            source: .keyboard
        )
        selectedWindowIndex = targetIndex

        notifyOverlayUpdated()
    }

    /// The only path from plate-stack preview state to the persisted assignment model.
    private func commitPlateStackTransaction(
        completion: @escaping @Sendable () -> Void
    ) {
        let commit = plateStackTransaction.commit(to: &stageManager)
        guard commit.didMutate else {
            completion()
            return
        }

        guard !commit.relocations.isEmpty else {
            delegate?.stageControllerDidMutateState(self)
            completion()
            return
        }

        let barrier = WindowRelocationBarrier(
            count: commit.relocations.count,
            completion: { [weak self] in
                guard let self else { return }
                self.delegate?.stageControllerDidMutateState(self)
                completion()
            }
        )
        for relocation in commit.relocations {
            let event: String
            if commit.keyboardWindowIDs.contains(relocation.windowID) {
                event = "window_moved_by_key"
            } else if commit.pointerWindowIDs.contains(relocation.windowID) {
                event = "window_moved_by_drag"
            } else {
                event = "window_move_committed"
            }
            relocateToStageDesktop(
                windowID: relocation.windowID,
                fromStageIndex: relocation.fromStageIndex,
                toStageIndex: relocation.toStageIndex,
                completion: { [weak self] in
                    self?.diag.report(event, details: [
                        "windowID": "\(relocation.windowID)",
                        "fromStageIndex": "\(relocation.fromStageIndex)",
                        "toStageIndex": "\(relocation.toStageIndex)",
                    ])
                    barrier.arrive()
                }
            )
        }
    }

    /// The overlay stays open so the user can keep working through the stage. Assignments are
    /// left alone here: the process-exit monitor makes them dormant once the app actually goes.
    private func quitSelectedApp() {
        guard isStageManagerVisible,
              overlayStageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = overlayStageManager.stages[selectedStageIndex]
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

    /// The accessibility close action belongs to the selected window, not its owning app. Remove
    /// a successfully requested close from both the committed model and the open overlay at
    /// once; the later AX destruction notification is then harmlessly idempotent.
    private func closeSelectedWindow() {
        guard isStageManagerVisible,
              overlayStageManager.stages.indices.contains(selectedStageIndex) else { return }
        let stage = overlayStageManager.stages[selectedStageIndex]
        guard stage.windows.indices.contains(selectedWindowIndex) else { return }
        let window = stage.windows[selectedWindowIndex]

        let requested = windowService.closeWindow(windowID: window.windowID)
        if requested {
            plateStackTransaction.removeWindow(windowID: window.windowID)
            if let stageID = stageManager.stageContainingWindow(windowID: window.windowID) {
                stageManager.removeWindow(windowID: window.windowID, fromStageID: stageID)
            } else {
                stageManager.removeLiveWindowFromAllStages(windowID: window.windowID)
            }
            delegate?.stageControllerDidMutateState(self)
        }
        diag.report("close_selected_window", details: [
            "windowID": "\(window.windowID)",
            "bundleID": window.ownerBundleID,
            "requested": "\(requested)",
            "removed": "\(requested)",
        ])
        if requested { handleLiveWindowsRemoved() }
    }
}
