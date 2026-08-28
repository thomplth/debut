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

/// Completes a space commit only after every asynchronous window relocation has answered.
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

public protocol SpaceControllerDelegate: AnyObject {
    func spaceControllerDidOpenOverlay(_ controller: SpaceController)
    func spaceControllerDidOpenOverlay(
        _ controller: SpaceController,
        overlayPresentation: OverlayPresentationContext?
    )
    func spaceControllerDidCloseOverlay(_ controller: SpaceController)
    func spaceControllerDidCloseOverlay(
        _ controller: SpaceController,
        overlayPresentation: OverlayPresentationContext?
    )
    func spaceControllerDidUpdateSelection(_ controller: SpaceController)
    func spaceControllerDidSwitchSpace(_ controller: SpaceController)
    func spaceControllerDidMutateState(_ controller: SpaceController)
}

public extension SpaceControllerDelegate {
    func spaceControllerDidOpenOverlay(
        _ controller: SpaceController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        spaceControllerDidOpenOverlay(controller)
    }

    func spaceControllerDidCloseOverlay(
        _ controller: SpaceController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        spaceControllerDidCloseOverlay(controller)
    }
}

public final class SpaceController: KeyboardEventDelegate, @unchecked Sendable {
    public var spaceManager: SpaceManager
    public let windowService: any WindowService
    public let keyboardService: any KeyboardService
    public weak var delegate: SpaceControllerDelegate?
    public var onCommandUsed: (@Sendable (KeyAction) -> Void)?
    public var onDesktopReveal: (() -> Void)?

    private var pendingSpaceFocus: (spaceID: UUID, windowID: CGWindowID)?
    private var stageStackTransaction = StageStackTransaction()
    private var isStageStackCommitInFlight = false

    public private(set) var isSpaceManagerVisible: Bool = false
    public var selectedSpaceIndex: Int = 0
    public var selectedWindowIndex: Int = 0
    public private(set) var keyboardServiceStarted: Bool = false
    public var overlayPresentationDelay: TimeInterval
    public var previewRefreshPolicy: PreviewRefreshPolicy
    public var previewCacheTTL: TimeInterval

    /// The model rendered by the overlay, including interactions that are still waiting for
    /// the session commit. The persisted `spaceManager` remains the last committed state.
    public var overlaySpaceManager: SpaceManager {
        stageStackTransaction.preview(applyingTo: spaceManager)
    }

    /// Window previews captured when overlay opens
    public private(set) var windowPreviews: [CGWindowID: CGImage] = [:]
    public private(set) var variedWindowPreviewIDs: Set<CGWindowID> = []

    /// The macOS desktops that back the spaces. The space at index N is desktop N.
    public var spaceSwitcher: (any SpaceSwitching)?

    /// Where the frontmost app's focused window sat when the overlay last opened, in Quartz
    /// global coordinates. The delegate resolves it to the display it presents the stages on.
    public private(set) var focusedWindowFrame: CGRect?

    /// Whether that window owned a fullscreen Space. The stages are presented either way; this
    /// is what tells a diagnostic reader which of the two presentations it is looking at.
    public private(set) var focusedWindowIsFullscreen: Bool = false

    private var preOverlaySpaceID: UUID?
    private var preOverlaySpaceStackID: String?
    private var previousSpaceID: UUID?
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
        spaceManager: SpaceManager = SpaceManager(),
        overlayPresentationDelay: TimeInterval = AppSettings.defaultOverlayPresentationDelay,
        focusedWindowSnapshotProvider: (() -> FocusedWindowSnapshot)? = nil,
        overlayPresentationRecorder: OverlayPresentationRecorder = .shared,
        previewRefreshPolicy: PreviewRefreshPolicy = .lastActiveOnly,
        previewCacheTTL: TimeInterval = AppSettings.defaultPreviewCacheTTL,
        previewClock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.windowService = windowService
        self.keyboardService = keyboardService
        self.spaceManager = spaceManager
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
    /// `activeSpaceIndex` is the desktop showing and `selectedSpaceIndex` is the overlay's
    /// cursor. They are only the same while the overlay drives the switch — a desktop the
    /// user changes themselves moves one and not the other.
    public var diagnosticState: [String: String] {
        let visibleSpaceManager = isSpaceManagerVisible ? overlaySpaceManager : spaceManager
        let activeSpaceIndex = visibleSpaceManager.spaces
            .firstIndex(where: { $0.id == visibleSpaceManager.activeSpaceID }) ?? 0
        return [
            "overlayVisible": "\(isSpaceManagerVisible)",
            "focusedWindowFullscreen": "\(focusedWindowIsFullscreen)",
            "spaceCount": "\(visibleSpaceManager.spaces.count)",
            "spaceStackCount": "\(visibleSpaceManager.connectedSpaceStacks.count)",
            "selectedSpaceStackID": visibleSpaceManager.selectedSpaceStackID,
            "selectedDisplayName": visibleSpaceManager.selectedSpaceStack?.displayName ?? "unknown",
            "spaceCountsByStack": visibleSpaceManager.connectedSpaceStacks
                .map { "\($0.displayName):\($0.spaces.count)" }
                .joined(separator: ","),
            "activeSpaceIndex": "\(activeSpaceIndex)",
            "selectedSpaceIndex": "\(selectedSpaceIndex)",
            "selectedWindowIndex": "\(selectedWindowIndex)",
            "eventTapRunning": "\(keyboardService.isRunning)",
            "eventTapStarted": "\(keyboardServiceStarted)",
            "windowsInActiveSpace": "\(visibleSpaceManager.activeSpace.windows.count)",
            "maxWindowsInSpace": "\(visibleSpaceManager.spaces.map(\.windows.count).max() ?? 0)",
            "windowCountsBySpace": visibleSpaceManager.spaces
                .map { String($0.windows.count) }
                .joined(separator: ","),
            "windowPreviewCount": "\(windowPreviews.count)",
            "variedWindowPreviewCount": "\(variedWindowPreviewIDs.count)",
        ]
    }

    // MARK: - Space switching

    /// Makes the space list match the desktops macOS actually has.
    ///
    /// Spaces are desktops now, and only the user can create a desktop — `SLSSpaceCreate`
    /// returns an id no display manages, so a Debut-created Space would be unreachable from
    /// Mission Control. A space with no desktop behind it is therefore a switch target that
    /// silently does nothing, and a desktop with no space is invisible to the switcher.
    /// Called on launch and whenever the desktop set may have changed.
    public func reconcileSpacesWithDesktops() {
        guard let spaceSwitcher else {
            diag.report("spaces_reconcile_refused", details: ["reason": "noSpaceSwitcher"])
            return
        }
        let topology = spaceSwitcher.spaceTopology()
        guard !topology.stacks.isEmpty else {
            diag.report("spaces_reconcile_refused", details: ["reason": "noDesktopsReported"])
            return
        }
        // Compared whole rather than by count: reordering desktops in Mission Control leaves
        // both counts identical, so a count check calls a reorder a no-op and nothing persists
        // or redraws the new order.
        let stacksBefore = spaceManager.spaceStacks
        let stackCountBefore = spaceManager.connectedSpaceStacks.count
        let spaceCountBefore = spaceManager.allSpaces.count
        spaceManager.reconcileSpaceStacks(with: topology)
        let stackCountAfter = spaceManager.connectedSpaceStacks.count
        let spaceCountAfter = spaceManager.allSpaces.count
        if stacksBefore != spaceManager.spaceStacks {
            diag.report("spaces_reconciled", details: [
                "separateSpaces": "\(topology.separateSpaces)",
                "stackCountBefore": "\(stackCountBefore)",
                "stackCountAfter": "\(stackCountAfter)",
                "spacesBefore": "\(spaceCountBefore)",
                "spacesAfter": "\(spaceCountAfter)",
            ])
            delegate?.spaceControllerDidMutateState(self)
        }
    }

    /// What a reconcile saw and did.
    ///
    /// Refusing to act on a zero desktop count is right — an empty answer from the window
    /// server is not evidence the desktops are gone — but a silent refusal is indistinguishable
    /// from a host that really has one desktop, and that ambiguity hid a launch where Debut
    /// built one space against three real desktops.
    public struct SpaceReconciliation: Equatable {
        public let desktopCount: Int
        public let spacesBefore: Int
        public let spacesAfter: Int

        public var refused: Bool { desktopCount <= 0 }

        public var didChange: Bool { spacesBefore != spacesAfter }

        var diagnosticEvent: String { refused ? "spaces_reconcile_refused" : "spaces_reconciled" }

        var diagnosticDetails: [String: String] {
            var details = [
                "desktopCount": "\(desktopCount)",
                "spacesBefore": "\(spacesBefore)",
                "spacesAfter": "\(spacesAfter)",
            ]
            if refused { details["reason"] = "noDesktopsReported" }
            return details
        }
    }

    /// Exposed separately because startup has to grow the space list before windows are
    /// reconciled, which happens before any controller exists.
    @discardableResult
    public static func reconcileSpaces(_ spaceManager: inout SpaceManager,
                                       desktopCount: Int) -> SpaceReconciliation {
        let before = spaceManager.spaces.count
        guard desktopCount > 0 else {
            return SpaceReconciliation(desktopCount: desktopCount,
                                       spacesBefore: before,
                                       spacesAfter: before)
        }

        while spaceManager.spaces.count > desktopCount {
            spaceManager.deleteSpace(id: spaceManager.spaces[spaceManager.spaces.count - 1].id)
        }
        while spaceManager.spaces.count < desktopCount {
            spaceManager.createSpace(position: .below)
        }
        return SpaceReconciliation(desktopCount: desktopCount,
                                   spacesBefore: before,
                                   spacesAfter: spaceManager.spaces.count)
    }

    /// Call whenever macOS reports the active Space changed.
    ///
    /// The desktop set is rechecked first, not only the active index. Mission Control can add
    /// or remove a desktop at any moment, and reconciling solely at launch left the space list
    /// wrong for the rest of the session — windows on a desktop past the end of the space array
    /// have nowhere to go. The notification fires once the Space change has settled, so this is
    /// the earliest honest point to re-ask.
    public func desktopDidChange() {
        // Let the switcher confirm the completed hop before reconciling the model. A far
        // target may start its next adjacent hop here, which also tells deferred focus that
        // an intermediate desktop is expected rather than a user overtaking the switch.
        spaceSwitcher?.spaceDidChange()
        let previousActiveSpaceID = spaceManager.activeSpaceID
        reconcileSpacesWithDesktops()
        if spaceManager.activeSpaceID != previousActiveSpaceID {
            previousSpaceID = previousActiveSpaceID
            diag.report("active_space_synced", details: [
                "to": spaceLabel(forID: spaceManager.activeSpaceID),
                "reason": "desktop_changed_externally",
            ])
            delegate?.spaceControllerDidMutateState(self)
            delegate?.spaceControllerDidSwitchSpace(self)
        }
        applyPendingSpaceFocus()
    }

    /// Focuses the window a space switch asked for, now that its desktop is showing.
    ///
    /// A switch that focused its target straight away was focusing it on the desktop it was
    /// leaving, because the Dock consumes the forged swipe asynchronously. macOS then
    /// restored its own idea of focus as the Space settled and overwrote the choice.
    private func applyPendingSpaceFocus() {
        guard let pending = pendingSpaceFocus else { return }
        guard let stackID = spaceManager.spaceStackID(containingSpaceID: pending.spaceID),
              let index = spaceManager.spaceIndex(id: pending.spaceID),
              let switcher = spaceSwitcher,
              let stack = switcher.spaceTopology().stack(id: stackID)
        else {
            pendingSpaceFocus = nil
            return
        }

        guard stack.currentDesktopIndex == index else {
            // A confirmed intermediate hop is still on the way to this focus target. Only
            // discard the request once the coordinator has stopped somewhere else; that is
            // the signal that the user overtook the switch or Dock landed unexpectedly.
            if switcher.isSwitchInFlight(stackID: stackID) { return }
            pendingSpaceFocus = nil
            return
        }
        pendingSpaceFocus = nil
        focusWindow(pending.windowID, inSpaceID: pending.spaceID)
        delegate?.spaceControllerDidMutateState(self)
    }

    private func focusWindow(_ windowID: CGWindowID, inSpaceID spaceID: UUID) {
        _ = windowService.raiseWindow(windowID: windowID)
        spaceManager.bringWindowToFront(windowID: windowID, inSpaceID: spaceID)
        if let bundleID = spaceManager.allSpaces.first(where: { $0.id == spaceID })?
            .windows.first(where: { $0.windowID == windowID })?.ownerBundleID {
            _ = windowService.activateApp(bundleID: bundleID)
        }
    }

    /// Adopts the desktop currently showing as the active space.
    ///
    /// The user can switch desktop without Debut — Mission Control, Control+Arrow, or
    /// clicking a window on another desktop all do it — and until this runs, Debut's active
    /// space is simply wrong. Call it whenever macOS reports the active Space changed.
    public func syncActiveSpaceWithCurrentDesktop() {
        guard let topology = spaceSwitcher?.spaceTopology(),
              let stack = topology.stack(id: spaceManager.selectedSpaceStackID),
              let index = stack.currentDesktopIndex,
              let spaceID = spaceManager.spaceID(stackID: stack.id, at: index),
              spaceID != spaceManager.activeSpaceID
        else { return }
        previousSpaceID = spaceManager.activeSpaceID
        spaceManager.activateSpace(id: spaceID)
        diag.report("active_space_synced", details: [
            "to": spaceLabel(forID: spaceID),
            "reason": "desktop_changed_externally",
        ])
        delegate?.spaceControllerDidMutateState(self)
        delegate?.spaceControllerDidSwitchSpace(self)
    }

    /// Position-based label for a space, e.g. "Space 2". Used for diagnostics only.
    private func spaceLabel(forID id: UUID) -> String {
        guard let index = spaceManager.spaceIndex(id: id),
              let stackID = spaceManager.spaceStackID(containingSpaceID: id),
              let stack = spaceManager.spaceStacks.first(where: { $0.id == stackID })
        else { return "?" }
        return "\(stack.displayName) Space \(index + 1)"
    }

    /// - Parameter focusesWindow: When false the desktop moves without Debut focusing anything,
    ///   leaving the choice of frontmost app to macOS. Debut's own focus lands within a few
    ///   milliseconds of the Space flip, so the two race, and `recordWindowActivation` writes a
    ///   lost race into the space's MRU head — which makes a single loss permanent.
    public func switchToSpace(id targetID: UUID, raiseWindowID: CGWindowID? = nil,
                              focusesWindow: Bool = true) {
        let targetSpace = spaceManager.allSpaces.first(where: { $0.id == targetID })
        let workload = PerformanceWorkload(
            spaces: spaceManager.spaces.count,
            windows: targetSpace?.windows.count ?? 0
        )
        let performanceID = PerformanceRecorder.shared.begin(.spaceSwitch, workload: workload)
        defer { PerformanceRecorder.shared.end(performanceID) }
        backtickCycleWindows = []
        backtickCycleIndex = 0

        let previousID = spaceManager.activeSpaceID
        var desktopIsSettling = false

        if previousID != targetID {
            let fromLabel = spaceLabel(forID: previousID)
            let toLabel = spaceLabel(forID: targetID)

            self.previousSpaceID = previousID
            spaceManager.activateSpace(id: targetID)

            // The space's windows already live on the target desktop, so macOS reveals all
            // of them in one composited transition. The surface architecture instead covered
            // the screen and AX-raised each window in turn, and that staggered raise is the
            // flash this migration exists to remove — so there is deliberately no per-window
            // raise here.
            let raiseID = PerformanceRecorder.shared.begin(
                .spaceRaise,
                workload: .init(windows: targetSpace?.windows.count ?? 0)
            )
            if let index = spaceManager.spaceIndex(id: targetID),
               let stackID = spaceManager.spaceStackID(containingSpaceID: targetID),
               let location = spaceSwitcher?.spaceTopology().stack(id: stackID)?.location(at: index),
               let switcher = spaceSwitcher {
                desktopIsSettling = switcher.switchToDesktop(location)
            }
            _ = PerformanceRecorder.shared.end(raiseID)

            diag.report("space_switched", details: [
                "from": fromLabel,
                "to": toLabel,
                "windowsInTarget": "\(targetSpace?.windows.count ?? 0)",
            ])
        }

        // Focus the selected window and activate its app (single activation, no flash).
        // A desktop still settling cannot be focused yet — see `applyPendingSpaceFocus`.
        if focusesWindow, let focusWindowID = raiseWindowID ?? targetSpace?.windows.first?.windowID {
            if desktopIsSettling {
                pendingSpaceFocus = (spaceID: targetID, windowID: focusWindowID)
            } else {
                pendingSpaceFocus = nil
                focusWindow(focusWindowID, inSpaceID: targetID)
            }
        } else {
            // A focus queued by an earlier switch to this same space would otherwise still fire.
            pendingSpaceFocus = nil
        }

        delegate?.spaceControllerDidMutateState(self)
        delegate?.spaceControllerDidSwitchSpace(self)
    }

    // MARK: - Window ownership

    /// Rebuilds assignments in a local value so discovery diagnostics can read
    /// the controller's current state without overlapping an inout access to
    /// `spaceManager`. Assign only after discovery has completed successfully.
    func rebuildWindowCache(using discovery: WindowDiscoveryService) {
        discovery.resetWindowTracking()
        var rebuiltManager = spaceManager
        rebuiltManager.resetWindowCache()
        discovery.populateDefaultSpace(&rebuiltManager)
        spaceManager = rebuiltManager
        selectedSpaceIndex = 0
        selectedWindowIndex = 0
    }

    public func spaceOwningWindow(windowID: CGWindowID) -> UUID? {
        spaceManager.spaceContainingWindow(windowID: windowID)
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
        // cross-space activation by switching spaces, which now means switching desktops,
        // and that fought the user in a loop: the switch changed the Space, the Space
        // change resynced the active space, and the next focus event switched back.
        //
        // Only a positive answer moves a window that already belongs somewhere. A window on
        // every desktop — Finder's, typically — resolves to no single one, and reading that
        // silence as "the desktop showing" dragged its stage onto whichever space was last
        // visited. Silence leaves the assignment for a later real answer to correct.
        let ownerSpaceID = spaceOwningWindow(windowID: windowID)
        let desktopLocation = spaceSwitcher?.desktopLocation(forWindow: windowID)
        let desktopSpaceID = desktopLocation.flatMap {
            spaceManager.spaceID(stackID: $0.stackID, at: $0.index)
        }
        let targetSpaceID = desktopSpaceID ?? ownerSpaceID ?? spaceManager.activeSpaceID

        if !isSpaceManagerVisible, let stackID = desktopLocation?.stackID {
            spaceManager.selectSpaceStack(id: stackID)
        }

        if ownerSpaceID == targetSpaceID {
            spaceManager.bringWindowToFront(windowID: windowID, inSpaceID: targetSpaceID)
            delegate?.spaceControllerDidMutateState(self)
            return
        }

        if let ownerSpaceID,
           let window = spaceManager.allSpaces.first(where: { $0.id == ownerSpaceID })?
               .windows.first(where: { $0.windowID == windowID }) {
            diag.report("window_reassigned", details: [
                "windowID": "\(windowID)",
                "bundleID": window.ownerBundleID,
                "windowTitle": window.windowTitle,
                "fromSpace": spaceLabel(forID: ownerSpaceID),
                "toSpace": spaceLabel(forID: targetSpaceID),
                "reason": "activated_on_other_desktop",
            ])
            spaceManager.removeLiveWindowFromAllSpaces(windowID: windowID)
            spaceManager.addWindow(window, toSpaceID: targetSpaceID)
        } else if let info = windowService.listWindows().first(where: { $0.windowID == windowID }) {
            // Genuinely new — "code ." opening a window while the app's other windows sit
            // on another desktop.
            spaceManager.addWindow(
                SpaceWindow(
                    windowID: info.windowID,
                    ownerBundleID: info.ownerBundleID,
                    ownerName: info.ownerName,
                    windowTitle: info.title,
                    ownerPID: info.ownerPID
                ),
                toSpaceID: targetSpaceID
            )
        } else {
            return
        }

        spaceManager.bringWindowToFront(windowID: windowID, inSpaceID: targetSpaceID)
        delegate?.spaceControllerDidMutateState(self)
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
            if isSpaceManagerVisible {
                cycleWindow(forward: true)
            } else {
                openOverlay(selectNextWindow: true)
            }
        case .cmdShiftTabHold:
            if isSpaceManagerVisible {
                cycleWindow(forward: false)
            } else {
                openOverlay(selectLastWindow: true)
            }
        case .cmdOptionTabHold:
            if isSpaceManagerVisible {
                cycleSpace(forward: true)
            } else {
                openOverlay(selectNextSpace: true)
            }
        case .cmdOptionShiftTabHold:
            if isSpaceManagerVisible {
                cycleSpace(forward: false)
            } else {
                openOverlay(selectPreviousSpace: true)
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
        case .nextSpace:
            cycleSpace(forward: true)
        case .previousSpace:
            cycleSpace(forward: false)
        case .nextDisplayStack:
            cycleDisplayStack()
        case .jumpToSpace(let index):
            jumpToSpace(index: index - 1)
        case .jumpToLastSpace:
            jumpToSpace(index: spaceManager.spaces.count - 1)
        case .switchToSpace(let position):
            quickSwitchToSpace(index: position - 1, keepingCurrentApplication: false)
        case .switchToSpaceKeepingCurrentApplication(let position):
            quickSwitchToSpace(index: position - 1, keepingCurrentApplication: true)
        case .moveWindowUp:
            moveWindow(direction: .up)
        case .moveWindowDown:
            moveWindow(direction: .down)
        case .moveWindowLeft:
            moveWindowWithinSpace(offset: -1)
        case .moveWindowRight:
            moveWindowWithinSpace(offset: 1)
        case .quitSelectedApp:
            quitSelectedApp()
        case .closeSelectedWindow:
            closeSelectedWindow()
        }
    }

    // MARK: - Quick switch

    /// Immediately switch to the space at the given index (configured modifier + 1-9).
    /// Works whether or not the overlay is open; if open, it is dismissed first.
    private func quickSwitchToSpace(index: Int, keepingCurrentApplication: Bool) {
        guard !isStageStackCommitInFlight,
              spaceManager.spaces.indices.contains(index) else { return }

        // Space window order is MRU. Capture the active app before switching,
        // then prefer that app's most-recent window in the destination space.
        let activeBundleID = spaceManager.activeSpace.windows.first?.ownerBundleID
        let targetSpace = spaceManager.spaces[index]
        let matchingWindowID = keepingCurrentApplication
            ? activeBundleID.flatMap { bundleID in
                targetSpace.windows.first(where: { $0.ownerBundleID == bundleID })?.windowID
            }
            : nil

        backtickCycleWindows = []
        backtickCycleIndex = 0

        if isSpaceManagerVisible {
            stageStackTransaction.discard()
            isSpaceManagerVisible = false
            if let tapService = keyboardService as? EventTapKeyboardService {
                tapService.overlayVisible = false
            }
            dismissOverlayPresentation()
        }

        // Keeping the current application is the whole point of that chord, so it still focuses.
        switchToSpace(id: targetSpace.id, raiseWindowID: matchingWindowID,
                      focusesWindow: keepingCurrentApplication)
        selectedSpaceIndex = index
        selectedWindowIndex = 0
    }

    // MARK: - Private

    private func handleCmdBacktick(reverse: Bool, wraps: Bool = true) {
        let activeSpace = spaceManager.activeSpace
        guard let frontWindow = activeSpace.windows.first else { return }

        let bundleID = frontWindow.ownerBundleID
        let sameAppWindows = activeSpace.windows.filter { $0.ownerBundleID == bundleID }
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
        spaceManager.bringWindowToFront(
            windowID: finalWindowID,
            inSpaceID: spaceManager.activeSpaceID
        )
        backtickCycleWindows = []
        backtickCycleIndex = 0
        delegate?.spaceControllerDidMutateState(self)
    }

    private func handleCmdTabTap() {
        let activeSpace = spaceManager.activeSpace
        guard !activeSpace.windows.isEmpty else { return }
        let targetIndex = frontmostAppIsExcluded ? 0 : 1
        guard activeSpace.windows.indices.contains(targetIndex) else { return }
        let targetWindow = activeSpace.windows[targetIndex]
        _ = windowService.raiseWindow(windowID: targetWindow.windowID)
        _ = windowService.activateApp(bundleID: targetWindow.ownerBundleID)
        spaceManager.bringWindowToFront(windowID: targetWindow.windowID, inSpaceID: activeSpace.id)
        delegate?.spaceControllerDidMutateState(self)
    }

    private func openOverlay(selectNextWindow: Bool) {
        setupOverlay()
        let windowCount = spaceManager.activeSpace.windows.count
        selectedWindowIndex = !frontmostAppIsExcluded && windowCount >= 2 ? 1 : 0
    }

    private func openOverlay(selectLastWindow: Bool) {
        setupOverlay()
        let windowCount = spaceManager.activeSpace.windows.count
        selectedWindowIndex = windowCount > 0 ? windowCount - 1 : 0
    }

    private func openOverlay(selectNextSpace: Bool) {
        setupOverlay()
        selectedWindowIndex = 0
        if spaceManager.spaces.count > 1 {
            selectedSpaceIndex = (selectedSpaceIndex + 1) % spaceManager.spaces.count
        }
    }

    private func openOverlay(selectPreviousSpace: Bool) {
        setupOverlay()
        selectedWindowIndex = 0
        if spaceManager.spaces.count > 1 {
            selectedSpaceIndex = (selectedSpaceIndex - 1 + spaceManager.spaces.count) % spaceManager.spaces.count
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
        stageStackTransaction.discard()

        // Removing an inactive desktop need not change the Space currently showing, so there
        // may be no active-space notification. Recheck at the point where a stale space would
        // otherwise become visible; this is event-driven by the user's overlay command.
        reconcileSpacesWithDesktops()

        isSpaceManagerVisible = true
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = true
        }
        if let index = spaceManager.spaces.firstIndex(where: { $0.id == spaceManager.activeSpaceID }) {
            selectedSpaceIndex = index
        }
        preOverlaySpaceID = spaceManager.activeSpaceID
        preOverlaySpaceStackID = spaceManager.selectedSpaceStackID
        let assignedWindowIDs = spaceManager.allSpaces.flatMap { $0.windows.map(\.windowID) }
        pruneWindowPreviews(assignedWindowIDs: Set(assignedWindowIDs))
        let cachedCount = variedWindowPreviewIDs.intersection(assignedWindowIDs).count
        pendingPreviewCaptureIDs = windowIDsNeedingCapture()
        if let presentation {
            let workload = PerformanceWorkload(
                spaces: spaceManager.spaces.count,
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
                  self.isSpaceManagerVisible,
                  !self.isOverlayPresented
            else { return }

            self.isOverlayPresented = true
            let presentation = self.activeOverlayPresentation
            if let presentation {
                self.overlayPresentationRecorder.mark(.presentationDeadlineFired, for: presentation)
            }
            self.diag.report("overlay_opened")
            self.delegate?.spaceControllerDidOpenOverlay(
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
        delegate?.spaceControllerDidCloseOverlay(
            self,
            overlayPresentation: activeOverlayPresentation
        )
    }

    private func notifyOverlayUpdated() {
        guard isOverlayPresented else { return }
        delegate?.spaceControllerDidUpdateSelection(self)
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
        let assignedWindows = spaceManager.allSpaces.flatMap(\.windows)
        guard previewRefreshPolicy == .lastActiveOnly else {
            return assignedWindows.map(\.windowID)
        }

        // The window in front of the active space is the one that was just being used, so its
        // content is the one most likely to have moved on since the last capture.
        let lastActiveWindowID = spaceManager.activeSpace.windows.first?.windowID
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

    /// Fills a cold preview cache without presenting the overlay. Startup calls this after live
    /// assignments have been reconciled, so the first visible presentation can use screenshots
    /// immediately instead of revealing application-icon placeholders while capture begins.
    func prewarmWindowPreviews() {
        guard !isSpaceManagerVisible else { return }
        let assignedWindowIDs = spaceManager.allSpaces.flatMap { $0.windows.map(\.windowID) }
        pruneWindowPreviews(assignedWindowIDs: Set(assignedWindowIDs))
        let missingWindowIDs = assignedWindowIDs.filter { windowPreviews[$0] == nil }
        captureWindowPreviews(
            windowIDs: missingWindowIDs,
            reason: "startup_prewarm"
        )
    }

    private func captureDirtyWindowPreviews(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        let windowIDs = pendingPreviewCaptureIDs
        pendingPreviewCaptureIDs = []

        captureWindowPreviews(
            windowIDs: windowIDs,
            overlayPresentation: overlayPresentation,
            reason: "overlay_refresh"
        )
    }

    private func captureWindowPreviews(
        windowIDs: [CGWindowID],
        overlayPresentation: OverlayPresentationContext? = nil,
        reason: String
    ) {
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
                "reason": reason,
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
                guard hasVariedLuminance else {
                    // Durable: discarding a capture the window server did return is the one
                    // outcome no other event records, so an unreported drop is unfalsifiable
                    // afterwards. A silent one hid every sparse window being thrown away
                    // behind a `preview_capture_completed` that looked like a clean run.
                    DiagnosticReporter.shared.report("preview_capture_discarded", details: [
                        "height": "\(capture.image.height)",
                        "reason": "uniform_luminance",
                        "width": "\(capture.image.width)",
                        "windowID": "\(capture.windowID)",
                    ])
                    return
                }
                let capturedAt = clock()
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.previewCaptureGeneration == generation,
                          let window = self.spaceManager.allSpaces
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
                "reason": reason,
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
        guard isSpaceManagerVisible, !pendingPreviewFlush else { return }
        pendingPreviewFlush = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.pendingPreviewFlush = false
            guard self.isSpaceManagerVisible else { return }
            self.notifyOverlayUpdated()
        }
    }

    private func commitSelection() {
        guard isSpaceManagerVisible, !isStageStackCommitInFlight else { return }
        isStageStackCommitInFlight = true
        commitStageStackTransaction { [weak self] in
            self?.finishSelectionCommit()
        }
    }

    private func finishSelectionCommit() {
        guard isSpaceManagerVisible, isStageStackCommitInFlight else { return }
        isStageStackCommitInFlight = false
        isSpaceManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }

        dismissOverlayPresentation(beforePresentationOutcome: .releasedBeforePresentation)

        guard spaceManager.spaces.indices.contains(selectedSpaceIndex) else { return }
        let targetSpace = spaceManager.spaces[selectedSpaceIndex]

        var raiseWindowID: CGWindowID?
        if targetSpace.windows.indices.contains(selectedWindowIndex) {
            raiseWindowID = targetSpace.windows[selectedWindowIndex].windowID
        }

        switchToSpace(id: targetSpace.id, raiseWindowID: raiseWindowID)

        diag.report("overlay_committed", details: [
            "spaceIndex": "\(selectedSpaceIndex)",
            "windowIndex": "\(selectedWindowIndex)",
            "targetSpace": spaceLabel(forID: targetSpace.id),
        ])
    }

    /// Commit a window chosen with the pointer without waiting for Command release.
    public func commitOverlaySelection(spaceIndex: Int, windowIndex: Int) {
        let preview = overlaySpaceManager
        guard isSpaceManagerVisible, !isStageStackCommitInFlight,
              preview.spaces.indices.contains(spaceIndex),
              preview.spaces[spaceIndex].windows.indices.contains(windowIndex)
        else { return }

        selectedSpaceIndex = spaceIndex
        selectedWindowIndex = windowIndex
        commitSelection()
    }

    /// Close the switcher and expose Finder's real desktop surface.
    public func revealDesktop() {
        guard isSpaceManagerVisible, !isStageStackCommitInFlight else { return }
        stageStackTransaction.discard()
        isSpaceManagerVisible = false
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
        fromSpaceIndex: Int,
        toSpaceIndex: Int,
        toWindowIndex: Int
    ) -> Bool {
        let preview = overlaySpaceManager
        guard isSpaceManagerVisible, !isStageStackCommitInFlight,
              preview.spaces.indices.contains(fromSpaceIndex),
              preview.spaces.indices.contains(toSpaceIndex),
              canRelocate(from: fromSpaceIndex, to: toSpaceIndex),
              preview.spaces[fromSpaceIndex].windows.contains(where: {
                  $0.windowID == windowID
              })
        else { return false }

        let fromSpaceID = preview.spaces[fromSpaceIndex].id
        let toSpaceID = preview.spaces[toSpaceIndex].id
        stageStackTransaction.spaceMove(
            windowID: windowID,
            fromSpaceID: fromSpaceID,
            toSpaceID: toSpaceID,
            windowIndex: toWindowIndex,
            source: .pointer
        )

        if selectedSpaceIndex == toSpaceIndex,
           let movedIndex = overlaySpaceManager.spaces[toSpaceIndex].windows.firstIndex(where: {
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
        guard isSpaceManagerVisible, !isStageStackCommitInFlight else { return }
        stageStackTransaction.discard()
        isSpaceManagerVisible = false
        if let tapService = keyboardService as? EventTapKeyboardService {
            tapService.overlayVisible = false
        }
        if let preOverlaySpaceStackID {
            spaceManager.selectSpaceStack(id: preOverlaySpaceStackID)
        }
        selectedSpaceIndex = spaceManager.spaces.firstIndex(where: { $0.id == preOverlaySpaceID }) ?? 0
        selectedWindowIndex = 0
        dismissOverlayPresentation()
        // spaceManagerActive stays true — session continues until Cmd release
        // Cmd+` still space-isolated (intercepted before the overlay gate)
    }

    private func cycleWindow(forward: Bool, wraps: Bool = true) {
        guard isSpaceManagerVisible,
              overlaySpaceManager.spaces.indices.contains(selectedSpaceIndex) else { return }
        let space = overlaySpaceManager.spaces[selectedSpaceIndex]
        guard !space.windows.isEmpty else { return }

        if wraps {
            let step = forward ? 1 : -1
            selectedWindowIndex =
                (selectedWindowIndex + step + space.windows.count) % space.windows.count
        } else {
            let nextIndex = forward
                ? min(selectedWindowIndex + 1, space.windows.count - 1)
                : max(selectedWindowIndex - 1, 0)
            guard nextIndex != selectedWindowIndex else { return }
            selectedWindowIndex = nextIndex
        }
        notifyOverlayUpdated()
    }

    private func cycleSpace(forward: Bool) {
        guard isSpaceManagerVisible, !spaceManager.spaces.isEmpty else { return }

        if forward {
            selectedSpaceIndex = (selectedSpaceIndex + 1) % spaceManager.spaces.count
        } else {
            selectedSpaceIndex = (selectedSpaceIndex - 1 + spaceManager.spaces.count) % spaceManager.spaces.count
        }
        selectedWindowIndex = 0
        notifyOverlayUpdated()
    }

    private func cycleDisplayStack() {
        guard isSpaceManagerVisible else { return }
        let previous = spaceManager.selectedSpaceStackID
        spaceManager.selectNextSpaceStack()
        guard spaceManager.selectedSpaceStackID != previous else { return }
        selectedSpaceIndex = spaceManager.spaces.firstIndex(where: {
            $0.id == spaceManager.activeSpaceID
        }) ?? 0
        selectedWindowIndex = 0
        diag.report("display_stack_selected", details: [
            "stackID": spaceManager.selectedSpaceStackID,
            "displayName": spaceManager.selectedSpaceStack?.displayName ?? "unknown",
        ])
        delegate?.spaceControllerDidMutateState(self)
        notifyOverlayUpdated()
    }

    /// Aligns the initially shown stack with the display holding the focused window.
    public func selectSpaceStack(forDisplayID displayID: CGDirectDisplayID) {
        guard let stackID = spaceSwitcher?.spaceTopology().stack(displayID: displayID)?.id,
              stackID != spaceManager.selectedSpaceStackID
        else { return }
        spaceManager.selectSpaceStack(id: stackID)
        selectedSpaceIndex = spaceManager.spaceIndex(id: spaceManager.activeSpaceID) ?? 0
        selectedWindowIndex = 0
    }

    public func jumpToSpace(index: Int) {
        guard isSpaceManagerVisible,
              spaceManager.spaces.indices.contains(index) else { return }
        selectedSpaceIndex = index
        selectedWindowIndex = 0
        notifyOverlayUpdated()
    }

    /// Windows can vanish while the overlay is on screen — an app quits, a window closes — and
    /// the selection is an index, so it has to be pulled back in range before the overlay is
    /// redrawn against the shorter space.
    public func handleLiveWindowsRemoved() {
        let windowCount = overlaySpaceManager.spaces[safe: selectedSpaceIndex]?.windows.count ?? 0
        selectedWindowIndex = max(0, min(selectedWindowIndex, windowCount - 1))
        notifyOverlayUpdated()
    }

    /// Whether the space model may record a window changing spaces.
    ///
    /// The transport is a private-API bridge that fails by doing nothing, so a move it cannot
    /// perform must not update the model either: the stage would sit on one space while the
    /// window stayed on another desktop, persisted, with nothing to correct it. A controller
    /// with no space switcher at all is not backed by desktops, so nothing constrains it.
    private func canRelocate(from: Int, to: Int) -> Bool {
        from == to || spaceSwitcher.map(\.canMoveWindows) ?? true
    }

    /// Puts the window on the desktop backing its new space.
    ///
    /// The space model is the user's intent and has already been updated, so a refused move is
    /// reported rather than rolled back — the next reconcile reads the window's real desktop
    /// and corrects the assignment either way.
    private func relocateToSpaceDesktop(
        windowID: CGWindowID,
        fromSpaceIndex: Int,
        toSpaceIndex: Int,
        completion: @escaping @Sendable () -> Void
    ) {
        guard fromSpaceIndex != toSpaceIndex, let spaceSwitcher else {
            completion()
            return
        }

        guard let stackID = spaceManager.spaceStackID(containingSpaceID: spaceManager.spaces[toSpaceIndex].id),
              let location = spaceSwitcher.spaceTopology().stack(id: stackID)?.location(at: toSpaceIndex)
        else { return }
        spaceSwitcher.moveWindow(windowID: windowID, to: location) {
            [weak self] moved in
            let diag = self?.diag
            let finish: @Sendable () -> Void = {
                if !moved {
                    diag?.report("window_move_failed", details: [
                        "windowID": "\(windowID)",
                        "toDesktop": "\(toSpaceIndex)",
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
        guard isSpaceManagerVisible,
              overlaySpaceManager.spaces.indices.contains(selectedSpaceIndex) else { return }
        let preview = overlaySpaceManager
        let space = preview.spaces[selectedSpaceIndex]
        guard space.windows.indices.contains(selectedWindowIndex) else { return }
        let window = space.windows[selectedWindowIndex]

        let targetSpaceIndex: Int
        switch direction {
        case .up:
            guard selectedSpaceIndex > 0 else { return }
            targetSpaceIndex = selectedSpaceIndex - 1
        case .down:
            guard selectedSpaceIndex < preview.spaces.count - 1 else { return }
            targetSpaceIndex = selectedSpaceIndex + 1
        }
        guard canRelocate(from: selectedSpaceIndex, to: targetSpaceIndex) else {
            diag.report("window_move_refused", details: [
                "windowID": "\(window.windowID)",
                "fromSpaceIndex": "\(selectedSpaceIndex)",
                "toSpaceIndex": "\(targetSpaceIndex)",
            ])
            return
        }

        let targetSpaceID = preview.spaces[targetSpaceIndex].id
        let targetIndex = preview.spaces[targetSpaceIndex].windows.count
        stageStackTransaction.spaceMove(
            windowID: window.windowID,
            fromSpaceID: space.id,
            toSpaceID: targetSpaceID,
            windowIndex: targetIndex,
            source: .keyboard
        )
        diag.report("window_move_previewed_by_key", level: .transient, details: [
            "windowID": "\(window.windowID)",
            "fromSpaceIndex": "\(selectedSpaceIndex)",
            "toSpaceIndex": "\(targetSpaceIndex)",
        ])

        // Follow the moved window to the target space
        selectedSpaceIndex = targetSpaceIndex
        let targetWindows = overlaySpaceManager.spaces[targetSpaceIndex].windows
        selectedWindowIndex = targetWindows.firstIndex(where: { $0.windowID == window.windowID }) ?? 0

        notifyOverlayUpdated()
    }

    private func moveWindowWithinSpace(offset: Int) {
        guard isSpaceManagerVisible,
              overlaySpaceManager.spaces.indices.contains(selectedSpaceIndex) else { return }
        let space = overlaySpaceManager.spaces[selectedSpaceIndex]
        guard space.windows.indices.contains(selectedWindowIndex) else { return }
        let targetIndex = selectedWindowIndex + offset
        guard space.windows.indices.contains(targetIndex) else { return }

        stageStackTransaction.spaceMove(
            windowID: space.windows[selectedWindowIndex].windowID,
            fromSpaceID: space.id,
            toSpaceID: space.id,
            windowIndex: targetIndex,
            source: .keyboard
        )
        selectedWindowIndex = targetIndex

        notifyOverlayUpdated()
    }

    /// The only path from stage-stack preview state to the persisted assignment model.
    private func commitStageStackTransaction(
        completion: @escaping @Sendable () -> Void
    ) {
        let commit = stageStackTransaction.commit(to: &spaceManager)
        guard commit.didMutate else {
            completion()
            return
        }

        guard !commit.relocations.isEmpty else {
            delegate?.spaceControllerDidMutateState(self)
            completion()
            return
        }

        let barrier = WindowRelocationBarrier(
            count: commit.relocations.count,
            completion: { [weak self] in
                guard let self else { return }
                self.delegate?.spaceControllerDidMutateState(self)
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
            relocateToSpaceDesktop(
                windowID: relocation.windowID,
                fromSpaceIndex: relocation.fromSpaceIndex,
                toSpaceIndex: relocation.toSpaceIndex,
                completion: { [weak self] in
                    self?.diag.report(event, details: [
                        "windowID": "\(relocation.windowID)",
                        "fromSpaceIndex": "\(relocation.fromSpaceIndex)",
                        "toSpaceIndex": "\(relocation.toSpaceIndex)",
                    ])
                    barrier.arrive()
                }
            )
        }
    }

    /// The overlay stays open so the user can keep working through the space. Assignments are
    /// left alone here: the process-exit monitor makes them dormant once the app actually goes.
    private func quitSelectedApp() {
        guard isSpaceManagerVisible,
              overlaySpaceManager.spaces.indices.contains(selectedSpaceIndex) else { return }
        let space = overlaySpaceManager.spaces[selectedSpaceIndex]
        guard space.windows.indices.contains(selectedWindowIndex) else { return }
        let window = space.windows[selectedWindowIndex]

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
        guard isSpaceManagerVisible,
              overlaySpaceManager.spaces.indices.contains(selectedSpaceIndex) else { return }
        let space = overlaySpaceManager.spaces[selectedSpaceIndex]
        guard space.windows.indices.contains(selectedWindowIndex) else { return }
        let window = space.windows[selectedWindowIndex]

        let requested = windowService.closeWindow(windowID: window.windowID)
        if requested {
            stageStackTransaction.removeWindow(windowID: window.windowID)
            if let spaceID = spaceManager.spaceContainingWindow(windowID: window.windowID) {
                spaceManager.removeWindow(windowID: window.windowID, fromSpaceID: spaceID)
            } else {
                spaceManager.removeLiveWindowFromAllSpaces(windowID: window.windowID)
            }
            delegate?.spaceControllerDidMutateState(self)
        }
        diag.report("close_selected_window", details: [
            "windowID": "\(window.windowID)",
            "bundleID": window.ownerBundleID,
            "cardLabel": window.displayTitle,
            "requested": "\(requested)",
            "removed": "\(requested)",
        ])
        if requested { handleLiveWindowsRemoved() }
    }
}
