import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics

/// Result of trying to arm a window's lifecycle notifications. An assignment
/// may only be trusted to be removable while its destroy notification is armed.
public enum WindowArmingOutcome: Equatable, Sendable {
    case armed
    case observerUnavailable
    case notificationRejected(Int32)
}

public enum FrontmostAppObservationSource: String, Sendable {
    case startupSnapshot = "startup_snapshot"
    case workspaceActivation = "workspace_activation"
}

struct AXWindowCreationMetadata: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let role: String
    let subrole: String
    let isModal: Bool
}

/// One window a destroy notification proved gone, named together with the process that owned
/// it. The bundle ID is only there to survive being written to disk: on reload it is what
/// distinguishes the original owner from whatever process inherited its PID.
struct RetiredWindowRecord: Codable, Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerBundleID: String
}

public final class WindowDiscoveryService: NSObject, @unchecked Sendable {
    typealias FocusProbeScheduler = @Sendable (
        pid_t,
        @escaping @Sendable (CGWindowID?) -> Void
    ) -> Void

    static let focusProbeTimeout: TimeInterval = 0.05
    static let windowCreationRetryDelays: [TimeInterval] = [0.05, 0.1, 0.25, 0.5]
    private static let windowCreationObserverRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2]
    private let diag: DiagnosticReporter
    private let windowService: any WindowService
    public var onWindowsDiscovered: (([WindowInfo]) -> Void)?
    public var onWindowClosed: ((CGWindowID) -> Void)?
    public var onWindowActivated: ((CGWindowID) -> Void)?
    /// Publishes one standard window found from its creation event. This is separate from the
    /// app-launch batch because a creation event is a targeted update, not a complete app list.
    public var onWindowCreated: ((RuntimeWindowSnapshot) -> Void)?
    /// Focus/creation events carry their process identity so an outstanding overlay action can
    /// recognize system UI that needs the interaction without admitting that UI to the model.
    public var onSystemAttentionRequested: ((CGWindowID, pid_t) -> Void)?
    public var onWindowTitleChanged: ((CGWindowID, String) -> Void)?
    public var onWindowResized: ((CGWindowID, CGSize) -> Void)?
    public var onFrontmostAppChanged: ((String?, FrontmostAppObservationSource) -> Void)?
    public var onAppActivated: ((RuntimeWindowSnapshot) -> Void)?
    public var onDesktopsChanged: ((RuntimeWindowSnapshot) -> Void)?
    public var onAppTerminated: ((pid_t) -> Void)?
    public var excludedBundleIDs: Set<String> = []
    /// Spaces are desktops, so every snapshot carries the desktop macOS reports for each
    /// window. Without it the reconciler falls back to guessing from the active space.
    public var spaceSwitcher: (any SpaceSwitching)?

    private let focusProbeScheduler: FocusProbeScheduler
    private let frontmostPIDProvider: @Sendable () -> pid_t?
    private let launchDiscoveryDelay: TimeInterval
    private let processExitMonitor: any ProcessExitMonitoring

    private var knownWindowIDs: Set<CGWindowID> = []
    private var monitoredProcessIDs: Set<pid_t> = []
    private var handledExitedProcessIDs: Set<pid_t> = []

    /// Windows confirmed to have a destroy notification armed, and those whose
    /// arming failed. Runtime-only: every window re-arms from scratch on launch,
    /// so this never reaches state.json.
    public private(set) var armedWindowIDs: Set<CGWindowID> = []
    public private(set) var unarmedWindowIDs: Set<CGWindowID> = []
    private var windowOwnerPIDs: [CGWindowID: pid_t] = [:]

    /// Windows a destroy notification confirmed are gone, and the process that owned them.
    ///
    /// An app can keep a dismissed window's backing surface in `CGWindowList` for the rest of
    /// its life — Preview's open panel was still listed four minutes after it closed — so the
    /// CG heuristic in `listWindows()` re-admits a window that was just retired unless
    /// something remembers the destruction. The owner is kept because the window server
    /// recycles IDs: the same ID under a different process is a different window and must not
    /// inherit this one's tombstone.
    private var retiredWindowOwners: [CGWindowID: RetiredWindowRecord] = [:] {
        didSet {
            guard retiredWindowOwners != oldValue else { return }
            onRetiredWindowsChanged?(retiredWindowRecords)
        }
    }

    /// Publishes the tombstones as they change so they can be stored on the session's own
    /// schedule. A verdict written only when Debut terminates cleanly is absent from every
    /// kill, while the assignment it overrules is saved throughout the session — so the next
    /// startup reconcile restores a window this service already knows is gone.
    var onRetiredWindowsChanged: (([RetiredWindowRecord]) -> Void)?

    public var retiredWindowIDs: Set<CGWindowID> { Set(retiredWindowOwners.keys) }

    /// The tombstone as a question, for the admission paths that never take a discovery snapshot
    /// and so cannot be covered by `excludingRetired`.
    public func isRetired(windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        retiredWindowOwners[windowID]?.ownerPID == ownerPID
    }

    /// The tombstones worth carrying to the next launch. The leaked surface outlives Debut, not
    /// just the window, so a verdict scoped to one run lets the startup reconcile bind the dead
    /// surface to a dormant assignment and the ghost returns on every launch.
    var retiredWindowRecords: [RetiredWindowRecord] { Array(retiredWindowOwners.values) }

    /// Restores tombstones written by an earlier run. A window ID and a PID both mean nothing on
    /// their own across a relaunch — macOS reissues both from low numbers — so a record is only
    /// honoured while the PID it names is still running the app it named. Anything else is a
    /// different window that must not inherit this verdict.
    func restoreRetiredWindows(
        _ records: [RetiredWindowRecord],
        runningBundleIDsByPID: [pid_t: String]
    ) {
        retiredWindowOwners = Dictionary(
            uniqueKeysWithValues: records
                .filter { runningBundleIDsByPID[$0.ownerPID] == $0.ownerBundleID }
                .map { ($0.windowID, $0) }
        )
    }

    public var diagnosticTrackingSnapshot: WindowTrackingDiagnosticSnapshot {
        WindowTrackingDiagnosticSnapshot(
            knownWindowIDs: knownWindowIDs,
            armedWindowIDs: armedWindowIDs,
            unarmedWindowIDs: unarmedWindowIDs,
            monitoredProcessIDs: monitoredProcessIDs,
            observedPID: observedPID,
            observerProcessIDs: Set(perAppObservers.keys),
            windowOwners: windowOwnerPIDs.map {
                WindowTrackingDiagnosticSnapshot.WindowOwner(
                    windowID: $0.key,
                    ownerPID: $0.value
                )
            }
        )
    }

    /// Replaces the AX arming step in tests. Production leaves this nil.
    var armingOverride: ((CGWindowID, pid_t) -> WindowArmingOutcome)?

    /// Replaces the AX element lookup in tests. Production leaves this nil.
    var windowElementOverride: ((CGWindowID, pid_t) -> AXUIElement?)?

    /// Replaces the AX size read in tests. Production leaves this nil.
    var windowSizeReader: ((AXUIElement) -> CGSize?)?

    /// Replaces the AX focus-observer registration in tests. Production leaves this nil.
    var focusObserverRegistrationOverride: ((pid_t) -> AXError)?

    /// Replaces app-level window-creation registration in tests. Production leaves this nil.
    var windowCreationObserverRegistrationOverride: ((pid_t) -> AXError)?

    /// Replaces retry scheduling in tests so a refused registration can be re-driven
    /// without waiting on wall time. Production leaves this nil.
    var focusObserverRetryScheduler: ((TimeInterval, @escaping () -> Void) -> Void)?

    /// Replaces retry scheduling for app-level window-creation observation in tests.
    /// Production leaves this nil.
    var windowCreationObserverRetryScheduler: ((TimeInterval, @escaping () -> Void) -> Void)?

    /// Replaces the bounded creation-readiness delay in tests. Production leaves this nil.
    var windowCreationRetryScheduler: ((TimeInterval, @escaping () -> Void) -> Void)?

    // AXObserver for tracking focused window changes within the frontmost app
    private var focusObserver: AXObserver?
    private var observedPID: pid_t?

    /// The app a refused registration is still retrying for, and how many retries it has spent.
    private var pendingFocusObserverPID: pid_t?
    private var focusObserverAttempt = 0
    private var activationProbeGeneration = 0
    private var activatedPID: pid_t?
    private var focusChangeProbeGeneration = 0
    private var launchProbeGeneration = 0
    private var destructionProbeGeneration = 0
    private var desktopRefreshGeneration = 0

    private struct WindowOwnerIdentity: Hashable {
        let windowID: CGWindowID
        let ownerPID: pid_t
    }

    private struct PendingWindowCreation {
        let element: AXUIElement?
        let fixedMetadata: AXWindowCreationMetadata?
        let startedAt: UInt64
        var identity: WindowOwnerIdentity?
        var systemAttentionRequested: Bool
    }

    private var pendingWindowCreations: [UUID: PendingWindowCreation] = [:]
    private var creationNotificationsSeen: Set<WindowOwnerIdentity> = []
    private var creationDetectionFailures: [WindowOwnerIdentity: (reason: String, attempts: Int)] = [:]

    // Per-app AXObservers for window lifecycle (destroyed, title changed)
    private var perAppObservers: [pid_t: AXObserver] = [:]
    private var windowCreationObservedPIDs: Set<pid_t> = []
    private var pendingWindowCreationObserverAttempts: [pid_t: Int] = [:]

    /// The AX element behind every armed window, keyed by window ID.
    ///
    /// Raising a window otherwise costs a walk of every running app's window list, so this
    /// doubles as the lookup table that `AccessibilityWindowService` raises through. It is
    /// keyed flat rather than per-app because callers know only the window ID.
    private var trackedWindowElements: [CGWindowID: AXUIElement] = [:]

    public convenience init(
        windowService: any WindowService,
        focusedWindowProvider: (@Sendable (pid_t) -> CGWindowID?)? = nil,
        frontmostPIDProvider: (@Sendable () -> pid_t?)? = nil,
        launchDiscoveryDelay: TimeInterval = 0.5
    ) {
        self.init(
            windowService: windowService,
            focusedWindowProvider: focusedWindowProvider,
            frontmostPIDProvider: frontmostPIDProvider,
            launchDiscoveryDelay: launchDiscoveryDelay,
            processExitMonitor: ProcessExitMonitor()
        )
    }

    init(
        windowService: any WindowService,
        focusedWindowProvider: (@Sendable (pid_t) -> CGWindowID?)? = nil,
        focusProbeScheduler: FocusProbeScheduler? = nil,
        frontmostPIDProvider: (@Sendable () -> pid_t?)? = nil,
        launchDiscoveryDelay: TimeInterval = 0.5,
        processExitMonitor: any ProcessExitMonitoring,
        diagnosticReporter: DiagnosticReporter = .shared
    ) {
        self.diag = diagnosticReporter
        self.windowService = windowService
        if let focusProbeScheduler {
            self.focusProbeScheduler = focusProbeScheduler
        } else if let focusedWindowProvider {
            // Test providers are deterministic and preserve the synchronous semantics used by
            // the service's unit tests. Production always takes the worker-queue path below.
            self.focusProbeScheduler = { pid, completion in
                completion(focusedWindowProvider(pid))
            }
        } else {
            self.focusProbeScheduler = { pid, completion in
                ExternalCallScheduler.shared.schedule(on: .accessibility) {
                    let windowID = Self.boundedFocusedWindowID(for: pid)
                    DispatchQueue.main.async(
                        qos: EventTapKeyboardService.deliveryQualityOfService,
                        flags: .enforceQoS
                    ) { completion(windowID) }
                }
            }
        }
        self.frontmostPIDProvider = frontmostPIDProvider ?? {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        self.launchDiscoveryDelay = launchDiscoveryDelay
        self.processExitMonitor = processExitMonitor
        super.init()
    }

    /// Retired windows are excluded from every discovery path, not just the one that observed
    /// the destruction — otherwise the CG-only heuristic re-admits the leftover surface on the
    /// very next snapshot, and the window returns as new.
    private func excludingRetired(_ windows: [WindowInfo]) -> [WindowInfo] {
        retiredWindowOwners.isEmpty
            ? windows
            : windows.filter { retiredWindowOwners[$0.windowID]?.ownerPID != $0.ownerPID }
    }

    private func reportEviction(
        _ window: SpaceWindow,
        fromSpaceID spaceID: UUID,
        in spaceManager: SpaceManager
    ) {
        diag.report("window_evicted", details: [
            "windowID": "\(window.windowID)",
            "bundleID": window.ownerBundleID,
            "windowTitle": window.windowTitle,
            "fromSpace": "\(spaceManager.spaceIndex(id: spaceID) ?? -1)",
            "reason": "excluded",
        ])
    }

    public func discoverRunningWindows() -> [SpaceWindow] {
        excludingRetired(windowService.listWindows())
            .filter { !excludedBundleIDs.contains($0.ownerBundleID) }.map { info in
            SpaceWindow(
                windowID: info.windowID,
                ownerBundleID: info.ownerBundleID,
                ownerName: info.ownerName,
                windowTitle: info.title,
                ownerPID: info.ownerPID
            )
        }
    }

    public func populateDefaultSpace(_ spaceManager: inout SpaceManager) {
        let windows = discoverRunningWindows()
        let liveIDs = Set(windows.map(\.windowID))
        let desktopLocations = (spaceSwitcher?.windowLocations() ?? [:])
            .filter { liveIDs.contains($0.key) }

        for window in windows {
            // This path never reaches the reconciler, so the desktop rule is applied here
            // too — otherwise a first run collapses every desktop onto space 1.
            let desktopSpaceID = desktopLocations[window.windowID].flatMap {
                spaceManager.spaceID(stackID: $0.stackID, at: $0.index)
            }
            spaceManager.addWindow(window, toSpaceID: desktopSpaceID ?? spaceManager.spaces[0].id)
            trackAndRegister(windowID: window.windowID, pid: window.ownerPID ?? 0)
        }

        DiagnosticReporter.shared.report("windows_discovered", details: [
            "count": "\(windows.count)",
        ])
    }

    /// Reconcile persisted space windows against live windows.
    /// CGWindowIDs and PIDs are ephemeral — match by (bundleID, title).
    /// Assignments from stopped processes become dormant rather than being deleted.
    /// Unmatched live windows go to the first space.
    public func reconcileWindows(_ spaceManager: inout SpaceManager) {
        let discoveryID = PerformanceRecorder.shared.begin(.windowDiscovery)
        let liveWindows = excludingRetired(windowService.listWindows()).filter {
            !excludedBundleIDs.contains($0.ownerBundleID)
        }
        let untrackableWindowIDs = windowService.listUntrackableWindowIDs()
        let disqualifiedWindowIDs = windowService.listDisqualifiedWindowIDs()
        let axContradictedWindowIDs = windowService.listAXContradictedWindowIDs()
        let windowServerVerdicts = windowService.listWindowServerVerdicts()
        let runningApps = windowService.listRunningApps()
        _ = PerformanceRecorder.shared.end(discoveryID)

        // Explicit AX classification identifies modal, floating, and other
        // auxiliary UI — but it is a snapshot, not a verdict. An app still
        // warming up can describe a user-manageable window this way, and deleting
        // the assignment would make that momentary misreport permanent. Park the
        // placement instead; a later snapshot reclaims it.
        //
        // Core Graphics gets the same treatment for the same reason. Plausibility gates
        // admission, but nothing re-tested a window once it was already assigned, so a window
        // that degraded into a tiny off-layer surface stayed live for as long as its app ran —
        // it is still in CGWindowList, its process is alive, and no destroy notification ever
        // arrives, which is every eviction path there was.
        //
        // Accessibility gets a third channel because its evidence only exists for the desktop
        // on screen. A popup admitted while its desktop was hidden cannot be refused at
        // admission — there was nothing to contradict it with yet — so it has to be reclaimed
        // once the user brings that desktop forward.
        //
        // Parentage gets a fourth because the other three can all miss indefinitely. A dismissed
        // sheet keeps a layer-0 surface on a resolved desktop for the life of its app, so nothing
        // degrades for Core Graphics to catch, no destroy notification arrives, and the AX verdict
        // waits on the user visiting that desktop. The window server names the window it was
        // raised over, from anywhere, and that is the only signal that arrives on its own.
        //
        // The ordered-in bit gets a fifth because not every ghost is parented. Chrome's dismissed
        // omnibox popup names no host window, and the AX verdict that eventually catches it is
        // learned state — so on a first launch, before any verdict has been recorded, this is the
        // only channel that refuses it.
        let classificationID = PerformanceRecorder.shared.begin(
            .windowClassification,
            workload: .init(windows: liveWindows.count)
        )
        // A restored tombstone has to evict, not just refuse. Excluding the dead surface from
        // the snapshot stops it being re-admitted, but the assignment the state file brought
        // back is already live, and no later evidence can reach it: its process is alive, Core
        // Graphics still lists the surface, and the destroy notification it would need has
        // already been and gone.
        for space in spaceManager.allSpaces {
            for window in space.windows where window.ownerPID != nil
                && retiredWindowOwners[window.windowID]?.ownerPID == window.ownerPID {
                spaceManager.removeWindow(windowID: window.windowID, fromSpaceID: space.id)
                diag.report("window_retired", details: [
                    "windowID": "\(window.windowID)",
                    "bundleID": window.ownerBundleID,
                    "windowTitle": window.windowTitle,
                    "fromSpace": "\(spaceManager.spaceIndex(id: space.id) ?? -1)",
                    "reason": "destroyed",
                    "trigger": "startup_restore",
                ])
            }
        }

        // Exclusion has to evict for the same reason. Filtering it out of the snapshot refuses
        // admission but cannot reach an assignment that is already live: absent from every later
        // snapshot, the window is invisible to reconciliation, desktop refreshes and activation
        // alike, so nothing can move it and nothing can remove it. Delete rather than park —
        // dormancy exists to reclaim a placement later, and an excluded app has none to reclaim.
        var evictedBundleIDs: Set<String> = []
        for space in spaceManager.allSpaces {
            for window in space.windows where excludedBundleIDs.contains(window.ownerBundleID) {
                reportEviction(window, fromSpaceID: space.id, in: spaceManager)
                evictedBundleIDs.insert(window.ownerBundleID)
            }
        }
        for assignment in spaceManager.dormantWindowAssignments
        where excludedBundleIDs.contains(assignment.window.ownerBundleID) {
            reportEviction(assignment.window, fromSpaceID: assignment.spaceID, in: spaceManager)
            evictedBundleIDs.insert(assignment.window.ownerBundleID)
        }
        for bundleID in evictedBundleIDs {
            spaceManager.removeAllWindows(forBundleID: bundleID)
        }

        // A verdict that parks an assigned window also refuses an unassigned one, and the same
        // pass has to apply both readings or it disagrees with itself. Parking a window the pass
        // still offers as live undoes the park, because the dormant assignment it creates carries
        // the window's own ID, PID and bundle — the strongest recovery match the reconciler has —
        // so the window is restored before the pass ends. Admitting one that carries a verdict but
        // no assignment yet is the same loop a pass later: it enters as `new`, is parked next
        // pass, and is admitted again on the one after. `listWindows` refuses these too, but it is
        // a separate window-server query taken at a different instant — a sheet dismissed between
        // the two calls is named by one and not the other — so the verdicts read here are what
        // make this pass self-consistent.
        let transientWindowIDs = Set(liveWindows.filter(\.isTransientFullscreen).map(\.windowID))
            .union(spaceManager.allSpaces.flatMap(\.windows).filter {
                TransientWindowIdentity.isTransient($0.ownerBundleID)
            }.map(\.windowID))
        let refusedWindowIDs = untrackableWindowIDs
            .union(disqualifiedWindowIDs)
            .union(axContradictedWindowIDs)
            .union(windowServerVerdicts.parented)
            .union(windowServerVerdicts.orderedOut)
            .subtracting(transientWindowIDs)

        var parkedDormantCount = 0
        for space in spaceManager.allSpaces {
            for windowID in space.windowIDs {
                let reason: String
                if transientWindowIDs.contains(windowID) {
                    continue
                } else if untrackableWindowIDs.contains(windowID) {
                    reason = "untrackable"
                } else if disqualifiedWindowIDs.contains(windowID) {
                    reason = "disqualified"
                } else if axContradictedWindowIDs.contains(windowID) {
                    reason = "ax_contradicted"
                } else if windowServerVerdicts.parented.contains(windowID) {
                    reason = "parented"
                } else if windowServerVerdicts.orderedOut.contains(windowID) {
                    reason = "ordered_out"
                } else {
                    continue
                }
                guard let assignment = spaceManager.makeWindowDormant(windowID: windowID) else { continue }
                parkedDormantCount += 1
                diag.report("window_made_dormant", details: [
                    "windowID": "\(windowID)",
                    "bundleID": assignment.window.ownerBundleID,
                    "windowTitle": assignment.window.windowTitle,
                    "fromSpace": "\(spaceManager.spaceIndex(id: assignment.spaceID) ?? -1)",
                    "reason": reason,
                ])
            }
        }
        _ = PerformanceRecorder.shared.end(classificationID)

        // An empty snapshot while regular apps are running usually means AX window
        // enumeration failed. Treating it as authoritative would erase every saved
        // space assignment, so leave persisted state intact for runtime PID cleanup.
        let persistedWindowCount = spaceManager.liveWindowCount
        if liveWindows.isEmpty,
           persistedWindowCount > 0,
           !runningApps.isEmpty {
            DiagnosticReporter.shared.report("windows_reconcile_skipped", details: [
                "persistedCount": "\(persistedWindowCount)",
                "reason": "empty_snapshot_with_running_apps",
            ])
            return
        }

        let runningPIDs = Set(runningApps.map(\.pid))
        let runningBundleIDs = Set(runningApps.map(\.bundleID))
        let stoppedPIDs: Set<pid_t> = Set(spaceManager.allSpaces.flatMap(\.windows).compactMap { window -> pid_t? in
            guard let ownerPID = window.ownerPID,
                  !runningPIDs.contains(ownerPID),
                  !runningBundleIDs.contains(window.ownerBundleID)
            else { return nil }
            return ownerPID
        })
        for ownerPID in stoppedPIDs {
            _ = spaceManager.makeWindowsDormant(forOwnerPID: ownerPID)
        }

        // Tracking still covers the parked windows: arming them is what lets a destroy
        // notification retire one for good, and only what the reconciler is offered as live
        // decides what gets an assignment.
        let admittedWindows = liveWindows.filter { !refusedWindowIDs.contains($0.windowID) }

        let firstSpaceID = spaceManager.spaces[0].id
        var reconciler = RuntimeWindowReconciler()
        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: admittedWindows,
                allWindowIDs: windowService.listAllWindowIDs(),
                desktopIndexes: desktopIndexes(for: admittedWindows),
                desktopLocations: desktopLocations(for: admittedWindows),
                skyLightWindowIDs: skyLightWindowIDs()
            ),
            spaceManager: &spaceManager,
            newWindowSpaceID: firstSpaceID
        )
        for info in liveWindows {
            trackAndRegister(windowID: info.windowID, pid: info.ownerPID)
        }

        diag.report("windows_reconciled", details: [
            "liveCount": "\(liveWindows.count)",
            "windowIDsBySpace": SpaceController.encode(spaceManager.spaces.map { $0.windows.map(\.windowID) }),
            "refused": "\(liveWindows.count - admittedWindows.count)",
            "added": "\(result.addedCount)",
            "reassigned": "\(result.reassignedCount)",
            "dormant": "\(spaceManager.dormantWindowAssignments.count)",
            "parked": "\(parkedDormantCount)",
        ])
        for event in result.events {
            var details = event.diagnosticDetails
            details["trigger"] = "startup_reconcile"
            diag.report("window_\(event.kind.rawValue)", details: details)
        }
    }

    public func startObserving() {
        let ws = NSWorkspace.shared
        let nc = ws.notificationCenter

        nc.addObserver(self, selector: #selector(appDidLaunch(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidTerminate(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidActivate(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Seed frontmost-app state outside the keyboard event-tap callback.
        let front = NSWorkspace.shared.frontmostApplication
        onFrontmostAppChanged?(front?.bundleIdentifier, .startupSnapshot)

        // Install focus observer on the current frontmost app
        if let front, let info = appInfo(for: front) {
            installWindowCreationObserver(for: info.pid, bundleID: info.bundleID)
            installFocusObserver(for: info.pid, bundleID: info.bundleID)
        }
    }

    /// Clears runtime-only observer and process caches without unregistering
    /// workspace notifications. A cache reset can then re-arm every freshly
    /// discovered window as if Debut had just launched.
    public func resetWindowTracking() {
        removeFocusObserver()
        for pid in Array(perAppObservers.keys) {
            removeAppObserver(for: pid)
        }
        processExitMonitor.stopMonitoringAll()
        knownWindowIDs.removeAll()
        armedWindowIDs.removeAll()
        unarmedWindowIDs.removeAll()
        windowOwnerPIDs.removeAll()
        trackedWindowElements.removeAll()
        monitoredProcessIDs.removeAll()
        retiredWindowOwners.removeAll()
        handledExitedProcessIDs.removeAll()
        pendingWindowCreations.removeAll()
        creationNotificationsSeen.removeAll()
        creationDetectionFailures.removeAll()
        windowCreationObservedPIDs.removeAll()
        pendingWindowCreationObserverAttempts.removeAll()
    }

    // MARK: - Per-window lifecycle tracking

    /// Registers process-exit monitoring and arms window lifecycle notifications.
    /// PID monitoring must not depend on per-window AX success.
    private func trackAndRegister(windowID: CGWindowID, pid: pid_t) {
        registerProcessExitMonitoring(for: pid)
        trackWindow(windowID: windowID, pid: pid)
    }

    /// Public entry point for external callers (e.g., SpaceController adding new windows)
    public func registerTracking(windowID: CGWindowID, pid: pid_t) {
        trackAndRegister(windowID: windowID, pid: pid)
    }

    private func registerProcessExitMonitoring(for pid: pid_t) {
        guard pid > 0, monitoredProcessIDs.insert(pid).inserted else { return }
        handledExitedProcessIDs.remove(pid)
        processExitMonitor.startMonitoring(pid: pid) { [weak self] exitedPID in
            self?.handleProcessExit(pid: exitedPID)
        }
    }

    private func trackWindow(windowID: CGWindowID, pid: pid_t) {
        if retiredWindowOwners[windowID]?.ownerPID == pid { return }
        // A window ID reused by a different process must still be armed: matching by ID
        // alone would trust bookkeeping left over from a process whose exit was missed.
        // An armed window with no element yet must also fall through, because a destroy
        // notification is resolved back to a window ID through its stored element alone;
        // arming succeeds without one, so the lookup has to be retried until it lands.
        if armedWindowIDs.contains(windowID), windowOwnerPIDs[windowID] == pid,
           trackedWindowElements[windowID] != nil { return }

        windowOwnerPIDs[windowID] = pid
        let element = windowElementOverride?(windowID, pid) ?? axWindowElement(for: windowID, pid: pid)
        let outcome = armingOverride?(windowID, pid) ?? armWindow(windowID: windowID, pid: pid)
        guard outcome == .armed else {
            // Leaving the window out of armedWindowIDs is what allows the next
            // activation to retry. Recording it as tracked regardless is what
            // previously made a transient AX failure permanent.
            unarmedWindowIDs.insert(windowID)
            knownWindowIDs.remove(windowID)
            reportTrackingFailure(windowID: windowID, pid: pid, outcome: outcome)
            return
        }
        if let element { trackedWindowElements[windowID] = element }
        armedWindowIDs.insert(windowID)
        unarmedWindowIDs.remove(windowID)
        knownWindowIDs.insert(windowID)
    }

    /// Arming needs no per-window element: the registration below is on the application, and
    /// `kAXWindows` cannot see a window on a desktop that is not showing, so requiring one
    /// would fail on exactly the windows that are hardest to discover.
    private func armWindow(windowID: CGWindowID, pid: pid_t) -> WindowArmingOutcome {
        guard let observer = getOrCreateObserver(for: pid) else { return .observerUnavailable }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let lifecycleTarget = Self.lifecycleNotificationTarget(for: pid)
        let destroyed = AXObserverAddNotification(
            observer,
            lifecycleTarget,
            kAXUIElementDestroyedNotification as CFString,
            selfPtr
        )
        // Unlike a disposable child-window registration, an existing application-level
        // registration remains authoritative when macOS recycles a window identity.
        guard destroyed == .success || destroyed == .notificationAlreadyRegistered else {
            return .notificationRejected(destroyed.rawValue)
        }
        // A stale title is cosmetic, so it never gates tracking. Neither is a stale size,
        // which only decides how wide the window's card is drawn.
        _ = AXObserverAddNotification(
            observer,
            lifecycleTarget,
            kAXTitleChangedNotification as CFString,
            selfPtr
        )
        _ = AXObserverAddNotification(
            observer,
            lifecycleTarget,
            kAXWindowResizedNotification as CFString,
            selfPtr
        )
        _ = registerWindowCreationNotifications(for: pid)
        return .armed
    }

    private func reportOptionalLifecycleRegistration(
        _ result: AXError,
        notification: String,
        pid: pid_t
    ) {
        guard result != .success, result != .notificationAlreadyRegistered else { return }
        diag.report("window_lifecycle_notification_registration_failed", details: [
            "error": "\(result.rawValue)",
            "notification": notification,
            "ownerPID": "\(pid)",
        ])
    }

    /// Observe descendants through the stable application element. Preview can dispose an
    /// Open panel, keep its CG backing surface, and immediately reuse the same window ID for
    /// another panel; tying lifecycle delivery to either transient child misses the second
    /// disposal. The application-scoped observer survives both child identities.
    static func lifecycleNotificationTarget(for pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// The AX element for an armed window, or nil when it was never armed or has since been
    /// destroyed. Lets the raise path skip scanning every running app.
    public func trackedWindowElement(windowID: CGWindowID) -> AXUIElement? {
        trackedWindowElements[windowID]
    }

    private func reportTrackingFailure(
        windowID: CGWindowID,
        pid: pid_t,
        outcome: WindowArmingOutcome
    ) {
        let step: String
        var axError = "none"
        switch outcome {
        case .armed: return
        case .observerUnavailable: step = "observer_create"
        case .notificationRejected(let error):
            step = "add_destroy_notification"
            axError = "\(error)"
        }
        diag.report("tracking_failed", details: [
            "windowID": "\(windowID)",
            "pid": "\(pid)",
            "step": step,
            "axError": axError,
        ])
    }

    private func getOrCreateObserver(for pid: pid_t) -> AXObserver? {
        if let existing = perAppObservers[pid] {
            return existing
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, windowLifecycleCallback, &observer) == .success,
              let observer else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        perAppObservers[pid] = observer
        return observer
    }

    /// A replacement process can activate before it publishes any windows. Observing creation
    /// cannot depend on first finding a window, because the creation event is precisely what
    /// must make that first window discoverable. Fresh AX servers temporarily refuse the
    /// registration, so use the same bounded backoff shape as focused-window observation.
    private func installWindowCreationObserver(for pid: pid_t, bundleID: String) {
        guard pid > 0,
              bundleID != "com.thomplth.Debut",
              !excludedBundleIDs.contains(bundleID),
              !windowCreationObservedPIDs.contains(pid),
              pendingWindowCreationObserverAttempts[pid] == nil
        else { return }

        registerProcessExitMonitoring(for: pid)
        pendingWindowCreationObserverAttempts[pid] = 0
        attemptWindowCreationObserverInstall(for: pid)
    }

    private func attemptWindowCreationObserverInstall(for pid: pid_t) {
        guard let attempt = pendingWindowCreationObserverAttempts[pid],
              !windowCreationObservedPIDs.contains(pid)
        else { return }

        let result = windowCreationObserverRegistrationOverride?(pid)
            ?? registerWindowCreationNotifications(for: pid)
        guard result != .success, result != .notificationAlreadyRegistered else {
            windowCreationObservedPIDs.insert(pid)
            pendingWindowCreationObserverAttempts.removeValue(forKey: pid)
            if attempt > 0 {
                diag.report("window_creation_observer_registered", details: [
                    "ownerPID": "\(pid)",
                    "attempts": "\(attempt + 1)",
                ])
            }
            return
        }

        guard attempt < Self.windowCreationObserverRetryDelays.count else {
            diag.report("window_creation_observer_registration_failed", details: [
                "ownerPID": "\(pid)",
                "error": "\(result.rawValue)",
                "attempts": "\(attempt + 1)",
            ])
            pendingWindowCreationObserverAttempts.removeValue(forKey: pid)
            return
        }

        let delay = Self.windowCreationObserverRetryDelays[attempt]
        pendingWindowCreationObserverAttempts[pid] = attempt + 1
        let retry: @Sendable () -> Void = { [weak self] in
            self?.attemptWindowCreationObserverInstall(for: pid)
        }
        if let windowCreationObserverRetryScheduler {
            windowCreationObserverRetryScheduler(delay, retry)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
        }
    }

    private func registerWindowCreationNotifications(for pid: pid_t) -> AXError {
        guard let observer = getOrCreateObserver(for: pid) else { return .cannotComplete }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let lifecycleTarget = Self.lifecycleNotificationTarget(for: pid)
        let windowCreated = AXObserverAddNotification(
            observer,
            lifecycleTarget,
            kAXWindowCreatedNotification as CFString,
            selfPtr
        )
        reportOptionalLifecycleRegistration(
            windowCreated,
            notification: kAXWindowCreatedNotification,
            pid: pid
        )
        let sheetCreated = AXObserverAddNotification(
            observer,
            lifecycleTarget,
            kAXSheetCreatedNotification as CFString,
            selfPtr
        )
        reportOptionalLifecycleRegistration(
            sheetCreated,
            notification: kAXSheetCreatedNotification,
            pid: pid
        )
        if windowCreated == .success || windowCreated == .notificationAlreadyRegistered {
            windowCreationObservedPIDs.insert(pid)
            pendingWindowCreationObserverAttempts.removeValue(forKey: pid)
        }
        return windowCreated
    }

    private func removeAppObserver(for pid: pid_t) {
        // Arming records are keyed by window, not by observer, so they must be
        // cleared even when no observer was ever created for this app.
        // The tombstones go too: the process that leaked those surfaces is gone, so any
        // future window carrying one of its IDs belongs to something else.
        for windowID in retiredWindowOwners.filter({ $0.value.ownerPID == pid }).keys {
            retiredWindowOwners.removeValue(forKey: windowID)
        }
        let ownedWindowIDs = Set(windowOwnerPIDs.filter { $0.value == pid }.keys)
        knownWindowIDs.subtract(ownedWindowIDs)
        armedWindowIDs.subtract(ownedWindowIDs)
        unarmedWindowIDs.subtract(ownedWindowIDs)
        for windowID in ownedWindowIDs {
            windowOwnerPIDs.removeValue(forKey: windowID)
            trackedWindowElements.removeValue(forKey: windowID)
        }

        windowCreationObservedPIDs.remove(pid)
        pendingWindowCreationObserverAttempts.removeValue(forKey: pid)

        guard let observer = perAppObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func pruneTracking(runningPIDs: Set<pid_t>) {
        if let pendingFocusObserverPID, !runningPIDs.contains(pendingFocusObserverPID) {
            self.pendingFocusObserverPID = nil
        }
        if let observedPID, !runningPIDs.contains(observedPID) {
            removeFocusObserver()
        }
        for pid in Array(pendingWindowCreationObserverAttempts.keys) where !runningPIDs.contains(pid) {
            pendingWindowCreationObserverAttempts.removeValue(forKey: pid)
        }
        let stoppedPIDs = perAppObservers.keys.filter { !runningPIDs.contains($0) }
        for pid in stoppedPIDs {
            removeAppObserver(for: pid)
        }
    }

    private func axWindowElement(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }
        for axWindow in axWindows {
            var cgID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &cgID) == .success, cgID == windowID {
                return axWindow
            }
        }
        return nil
    }

    func handleWindowDestroyed(element: AXUIElement) {
        guard let windowID = trackedWindowID(for: element) else { return }
        let ownerPID = windowOwnerPIDs[windowID]
        if let ownerPID {
            retiredWindowOwners[windowID] = RetiredWindowRecord(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerBundleID: windowService.listRunningApps()
                    .first { $0.pid == ownerPID }?.bundleID ?? ""
            )
        }
        trackedWindowElements.removeValue(forKey: windowID)
        knownWindowIDs.remove(windowID)
        armedWindowIDs.remove(windowID)
        unarmedWindowIDs.remove(windowID)
        windowOwnerPIDs.removeValue(forKey: windowID)
        onWindowClosed?(windowID)

        if let ownerPID {
            recoverFocus(afterDestroying: windowID, ownerPID: ownerPID)
        }
    }

    /// Closing a key window does not reliably produce a usable focused-window notification.
    /// Dictionary is a measured case: it restores Settings as key beside its main window, then
    /// silently returns focus to the main window when Settings closes. The destroy notification
    /// is the event that makes that transfer observable, so sample once after retiring the old
    /// identity and credit only a still-live successor in the same still-frontmost process.
    private func recoverFocus(afterDestroying windowID: CGWindowID, ownerPID: pid_t) {
        guard frontmostPIDProvider() == ownerPID else { return }

        destructionProbeGeneration += 1
        let generation = destructionProbeGeneration
        let activationGeneration = activationProbeGeneration
        let focusGeneration = focusChangeProbeGeneration
        focusProbeScheduler(ownerPID) { [weak self] focusedWindowID in
            guard let self,
                  self.destructionProbeGeneration == generation,
                  self.activationProbeGeneration == activationGeneration,
                  self.focusChangeProbeGeneration == focusGeneration,
                  self.frontmostPIDProvider() == ownerPID,
                  let focusedWindowID,
                  focusedWindowID != windowID,
                  let focusedWindow = self.excludingRetired(self.windowService.listWindows())
                    .first(where: {
                        $0.windowID == focusedWindowID &&
                            $0.ownerPID == ownerPID &&
                            !self.excludedBundleIDs.contains($0.ownerBundleID)
                    })
            else { return }

            self.trackAndRegister(windowID: focusedWindow.windowID, pid: focusedWindow.ownerPID)
            self.onWindowActivated?(focusedWindow.windowID)
        }
    }

    static func isSystemAttentionAXWindow(
        role: String,
        subrole: String,
        isModal: Bool
    ) -> Bool {
        isModal || role == kAXSheetRole as String ||
            subrole == kAXDialogSubrole as String ||
            subrole == kAXSystemDialogSubrole as String
    }

    private static func windowCreationMetadata(
        for element: AXUIElement
    ) -> AXWindowCreationMetadata? {
        let candidate: AXUIElement
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRef
        ) == .success,
           let role = roleRef as? String,
           role == kAXWindowRole as String || role == kAXSheetRole as String {
            candidate = element
        } else {
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXFocusedWindowAttribute as CFString,
                &focusedRef
            ) == .success,
                  let focused = focusedRef,
                  CFGetTypeID(focused) == AXUIElementGetTypeID()
            else { return nil }
            candidate = unsafeDowncast(focused, to: AXUIElement.self)
        }

        func stringAttribute(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, name as CFString, &value) == .success
            else { return nil }
            return value as? String
        }
        func boolAttribute(_ name: String) -> Bool {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, name as CFString, &value) == .success
            else { return false }
            return value as? Bool ?? false
        }
        var ownerPID: pid_t = 0
        var windowID: CGWindowID = 0
        guard let role = stringAttribute(kAXRoleAttribute),
              let subrole = stringAttribute(kAXSubroleAttribute),
              AXUIElementGetPid(candidate, &ownerPID) == .success,
              _AXUIElementGetWindow(candidate, &windowID) == .success,
              ownerPID > 0,
              windowID > 0
        else { return nil }
        return AXWindowCreationMetadata(
            windowID: windowID,
            ownerPID: ownerPID,
            role: role,
            subrole: subrole,
            isModal: boolAttribute(kAXModalAttribute)
        )
    }

    static func isPotentialStandardAXWindow(
        role: String,
        subrole: String,
        isModal: Bool
    ) -> Bool {
        role == kAXWindowRole as String &&
            !isModal &&
            (subrole == kAXStandardWindowSubrole as String ||
                subrole == kAXDialogSubrole as String)
    }

    static func isPendingStandardAXWindowClassification(
        role: String,
        subrole: String,
        isModal: Bool
    ) -> Bool {
        role == kAXWindowRole as String &&
            !isModal &&
            subrole == kAXUnknownSubrole as String
    }

    fileprivate func handleWindowCreated(element: AXUIElement, notification: String) {
        beginWindowCreationProbe(element: element, fixedMetadata: nil, notification: notification)
    }

    /// Test entry point for the part after AX has supplied the new window identity.
    func handleWindowCreated(_ metadata: AXWindowCreationMetadata) {
        beginWindowCreationProbe(
            element: nil,
            fixedMetadata: metadata,
            notification: kAXWindowCreatedNotification
        )
    }

    private func beginWindowCreationProbe(
        element: AXUIElement?,
        fixedMetadata: AXWindowCreationMetadata?,
        notification: String
    ) {
        let probeID = UUID()
        pendingWindowCreations[probeID] = PendingWindowCreation(
            element: element,
            fixedMetadata: fixedMetadata,
            startedAt: DispatchTime.now().uptimeNanoseconds,
            identity: nil,
            systemAttentionRequested: false
        )
        var details = [
            "notification": notification,
            "probeID": probeID.uuidString,
        ]
        if let fixedMetadata {
            details["ownerPID"] = "\(fixedMetadata.ownerPID)"
            details["windowID"] = "\(fixedMetadata.windowID)"
        }
        diag.report("window_creation_notification_received", details: details)
        attemptWindowCreationDetection(probeID: probeID, attempt: 1)
    }

    private func attemptWindowCreationDetection(probeID: UUID, attempt: Int) {
        guard var pending = pendingWindowCreations[probeID] else { return }
        let metadata = pending.fixedMetadata ?? pending.element.flatMap(Self.windowCreationMetadata(for:))
        guard let metadata else {
            retryWindowCreationDetection(
                probeID: probeID,
                attempt: attempt,
                reason: "ax_identity_unresolved",
                metadata: nil
            )
            return
        }

        let identity = WindowOwnerIdentity(
            windowID: metadata.windowID,
            ownerPID: metadata.ownerPID
        )
        pending.identity = identity
        pendingWindowCreations[probeID] = pending
        creationNotificationsSeen.insert(identity)

        if Self.isSystemAttentionAXWindow(
            role: metadata.role,
            subrole: metadata.subrole,
            isModal: metadata.isModal
        ) {
            if !pending.systemAttentionRequested {
                reportWindowCreationAttempt(
                    metadata: metadata,
                    probeID: probeID,
                    attempt: attempt,
                    result: "system_attention"
                )
                pending.systemAttentionRequested = true
                pendingWindowCreations[probeID] = pending
                onSystemAttentionRequested?(metadata.windowID, metadata.ownerPID)
            }
            // A non-modal AXDialog is also a trackable window. Dia reports DevTools this way
            // during creation, then exposes it as a standard window. Keep probing instead of
            // treating the first subrole snapshot as a final exclusion verdict.
            guard Self.isPotentialStandardAXWindow(
                role: metadata.role,
                subrole: metadata.subrole,
                isModal: metadata.isModal
            ) else {
                pendingWindowCreations.removeValue(forKey: probeID)
                return
            }
        }

        // AXUnknown is the absence of a classification, not evidence that the new object is a
        // standard window. Dia emits transient, untitled internal surfaces this way, and Core
        // Graphics briefly gives them every plausible-window signal. Keep re-reading the AX
        // element so a real window can graduate to AXStandardWindow or AXDialog, but do not
        // publish an object whose classification never settles during the bounded probe.
        if Self.isPendingStandardAXWindowClassification(
            role: metadata.role,
            subrole: metadata.subrole,
            isModal: metadata.isModal
        ) {
            retryWindowCreationDetection(
                probeID: probeID,
                attempt: attempt,
                reason: "ax_classification_pending",
                metadata: metadata
            )
            return
        }

        guard Self.isPotentialStandardAXWindow(
            role: metadata.role,
            subrole: metadata.subrole,
            isModal: metadata.isModal
        ) else {
            reportWindowCreationAttempt(
                metadata: metadata,
                probeID: probeID,
                attempt: attempt,
                result: "auxiliary_ignored"
            )
            pendingWindowCreations.removeValue(forKey: probeID)
            return
        }

        if windowOwnerPIDs[metadata.windowID] == metadata.ownerPID {
            reportWindowCreationAttempt(
                metadata: metadata,
                probeID: probeID,
                attempt: attempt,
                result: "already_detected"
            )
            pendingWindowCreations.removeValue(forKey: probeID)
            return
        }

        guard let info = windowService.listWindows().first(where: {
            $0.windowID == metadata.windowID && $0.ownerPID == metadata.ownerPID
        }) else {
            retryWindowCreationDetection(
                probeID: probeID,
                attempt: attempt,
                reason: "window_not_listed",
                metadata: metadata
            )
            return
        }
        // Debut admits its own Settings and tutorial windows explicitly. Sending those windows
        // through this generic path as well races the tutorial's replace-and-prepare sequence.
        guard info.ownerBundleID != "com.thomplth.Debut" else {
            reportWindowCreationAttempt(
                metadata: metadata,
                probeID: probeID,
                attempt: attempt,
                result: "self_managed_ignored"
            )
            pendingWindowCreations.removeValue(forKey: probeID)
            return
        }
        guard !excludedBundleIDs.contains(info.ownerBundleID) else {
            reportWindowCreationAttempt(
                metadata: metadata,
                probeID: probeID,
                attempt: attempt,
                result: "excluded_ignored"
            )
            pendingWindowCreations.removeValue(forKey: probeID)
            return
        }

        let locations = spaceSwitcher?.desktopLocations(forWindows: [metadata.windowID]) ?? [:]
        if spaceSwitcher != nil, locations[metadata.windowID] == nil {
            retryWindowCreationDetection(
                probeID: probeID,
                attempt: attempt,
                reason: "desktop_unresolved",
                metadata: metadata
            )
            return
        }

        // A destroy notification retires the old window lifetime even when Core Graphics keeps
        // its surface. Dia can later reuse that ID in the same process for a new DevTools window.
        // Only this explicit creation notification, after the new window resolves through both
        // discovery layers, is strong enough to start a new lifetime and clear the tombstone.
        if let retired = retiredWindowOwners[metadata.windowID],
           retired.ownerPID == metadata.ownerPID {
            retiredWindowOwners.removeValue(forKey: metadata.windowID)
            diag.report("window_retirement_cleared", details: [
                "bundleID": info.ownerBundleID,
                "ownerPID": "\(metadata.ownerPID)",
                "reason": "creation_event",
                "retiredBundleID": retired.ownerBundleID,
                "windowID": "\(metadata.windowID)",
                "windowTitle": info.title,
            ])
        }

        trackAndRegister(windowID: metadata.windowID, pid: metadata.ownerPID)
        creationDetectionFailures.removeValue(forKey: identity)
        reportWindowCreationAttempt(
            metadata: metadata,
            probeID: probeID,
            attempt: attempt,
            result: "detected",
            extra: ["armed": "\(armedWindowIDs.contains(metadata.windowID))"]
        )
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - pending.startedAt
        diag.report("window_creation_detected", details: [
            "attempts": "\(attempt)",
            "bundleID": info.ownerBundleID,
            "elapsedMilliseconds": String(
                format: "%.3f",
                Double(elapsedNanoseconds) / 1_000_000
            ),
            "ownerPID": "\(metadata.ownerPID)",
            "windowID": "\(metadata.windowID)",
            "windowTitle": info.title,
        ])
        pendingWindowCreations.removeValue(forKey: probeID)
        onWindowCreated?(RuntimeWindowSnapshot(
            liveWindows: [info],
            allWindowIDs: nil,
            unarmedWindowIDs: unarmedWindowIDs,
            desktopIndexes: locations.mapValues(\.index),
            desktopLocations: locations,
            skyLightWindowIDs: spaceSwitcher == nil ? nil : Set(locations.keys)
        ))

        guard frontmostPIDProvider() == metadata.ownerPID else { return }
        focusProbeScheduler(metadata.ownerPID) { [weak self] focusedWindowID in
            guard let self,
                  self.frontmostPIDProvider() == metadata.ownerPID,
                  focusedWindowID == metadata.windowID
            else { return }
            self.onWindowActivated?(metadata.windowID)
        }
    }

    private func retryWindowCreationDetection(
        probeID: UUID,
        attempt: Int,
        reason: String,
        metadata: AXWindowCreationMetadata?
    ) {
        if let metadata {
            reportWindowCreationAttempt(
                metadata: metadata,
                probeID: probeID,
                attempt: attempt,
                result: reason
            )
        } else {
            diag.report("window_creation_detection_attempted", details: [
                "attempt": "\(attempt)",
                "probeID": probeID.uuidString,
                "result": reason,
                "windowID": "unresolved",
            ])
        }

        guard attempt <= Self.windowCreationRetryDelays.count else {
            if let identity = pendingWindowCreations[probeID]?.identity {
                creationDetectionFailures[identity] = (reason, attempt)
            }
            diag.report("window_creation_detection_failed", details: [
                "attempts": "\(attempt)",
                "ownerPID": metadata.map { "\($0.ownerPID)" } ?? "unresolved",
                "probeID": probeID.uuidString,
                "reason": reason,
                "windowID": metadata.map { "\($0.windowID)" } ?? "unresolved",
            ])
            pendingWindowCreations.removeValue(forKey: probeID)
            return
        }

        let delay = Self.windowCreationRetryDelays[attempt - 1]
        let work: @Sendable () -> Void = { [weak self] in
            self?.attemptWindowCreationDetection(probeID: probeID, attempt: attempt + 1)
        }
        if let windowCreationRetryScheduler {
            windowCreationRetryScheduler(delay, work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func reportWindowCreationAttempt(
        metadata: AXWindowCreationMetadata,
        probeID: UUID,
        attempt: Int,
        result: String,
        extra: [String: String] = [:]
    ) {
        var details: [String: String] = [
            "attempt": "\(attempt)",
            "isModal": "\(metadata.isModal)",
            "ownerPID": "\(metadata.ownerPID)",
            "probeID": probeID.uuidString,
            "result": result,
            "role": metadata.role,
            "subrole": metadata.subrole,
            "windowID": "\(metadata.windowID)",
        ]
        details.merge(extra) { _, new in new }
        diag.report("window_creation_detection_attempted", details: details)
    }

    private func trackedWindowID(for element: AXUIElement) -> CGWindowID? {
        trackedWindowElements.first { CFEqual(element, $0.value) }?.key
    }

    fileprivate func handleWindowTitleChanged(element: AXUIElement) {
        guard let windowID = trackedWindowID(for: element) else { return }

        // Read new title
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return }
        onWindowTitleChanged?(windowID, title)
    }

    /// A window's size only ever reaches the model through discovery, and resizing a window
    /// runs none of it — the card kept the shape the window had at the last app switch.
    func handleWindowResized(element: AXUIElement) {
        // The notification hands over the window itself, so ask it which window it is rather
        // than looking it up. A stored element is only ever recorded when `kAXWindows` could
        // see the window, which depends on the desktop showing at the time it was armed.
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(element, &windowID) != .success {
            guard let tracked = trackedWindowID(for: element) else { return }
            windowID = tracked
        }
        guard let size = windowSizeReader?(element) ?? Self.axSize(of: element) else { return }
        onWindowResized?(windowID, size)
    }

    private static func axSize(of element: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let value = sizeRef, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - AXObserver for focused window changes

    /// An app that is still starting up refuses this registration — measured at -25204 for
    /// nine of nine freshly launched apps, with the AX server not answering for the first
    /// 0.8-2.9s while Debut sees the activation ~0.2s in. There is no notification for an AX
    /// server coming up, so recovery is a bounded retry rather than an event: it stops on the
    /// first success, on the next activation, and after the last delay below.
    private static let focusObserverRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2]

    func installFocusObserver(for pid: pid_t, bundleID: String) {
        // The exclusion check lives here rather than at the call sites: only one of the two had
        // it, so relaunching while an excluded app was frontmost pointed the observer at it for
        // the whole session, and every focus change inside that app reached the activation path.
        // Leave an observer already installed elsewhere alone — the user has not left that app.
        guard bundleID != "com.thomplth.Debut", !excludedBundleIDs.contains(bundleID) else { return }

        // Skip if already observing this app, or already retrying for it — the launch pass
        // asks again 0.5s after the activation did, and a second chain would only reset the
        // backoff the first one is already working through.
        if observedPID == pid || pendingFocusObserverPID == pid { return }
        removeFocusObserver()

        pendingFocusObserverPID = pid
        focusObserverAttempt = 0
        attemptFocusObserverInstall()
    }

    private func attemptFocusObserverInstall() {
        guard let pid = pendingFocusObserverPID else { return }

        let result = registerFocusObserver(for: pid)
        guard result != .success else {
            if focusObserverAttempt > 0 {
                diag.report("focus_observer_registered", details: [
                    "pid": "\(pid)",
                    "attempts": "\(focusObserverAttempt + 1)",
                ])
            }
            pendingFocusObserverPID = nil
            observedPID = pid
            return
        }

        guard focusObserverAttempt < Self.focusObserverRetryDelays.count else {
            diag.report("focus_observer_registration_failed", details: [
                "pid": "\(pid)",
                "error": "\(result.rawValue)",
                "attempts": "\(focusObserverAttempt + 1)",
            ])
            pendingFocusObserverPID = nil
            return
        }

        let delay = Self.focusObserverRetryDelays[focusObserverAttempt]
        focusObserverAttempt += 1
        let retry: @Sendable () -> Void = { [weak self] in self?.attemptFocusObserverInstall() }
        if let focusObserverRetryScheduler {
            focusObserverRetryScheduler(delay, retry)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
        }
    }

    private func registerFocusObserver(for pid: pid_t) -> AXError {
        if let focusObserverRegistrationOverride {
            return focusObserverRegistrationOverride(pid)
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var observer: AXObserver?
        let created = AXObserverCreate(pid, focusChangedCallback, &observer)
        guard created == .success, let observer else { return created }

        let axApp = AXUIElementCreateApplication(pid)
        let added = AXObserverAddNotification(
            observer,
            axApp,
            kAXFocusedWindowChangedNotification as CFString,
            selfPtr
        )
        guard added == .success else { return added }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.focusObserver = observer
        return .success
    }

    private func removeFocusObserver() {
        if let observer = focusObserver, let pid = observedPID {
            let axApp = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        focusObserver = nil
        observedPID = nil
        pendingFocusObserverPID = nil
    }

    fileprivate func handleFocusChanged() {
        guard let pid = observedPID else { return }
        focusChangeProbeGeneration += 1
        let generation = focusChangeProbeGeneration
        let activationGeneration = activationProbeGeneration
        focusProbeScheduler(pid) { [weak self] windowID in
            guard let self,
                  self.observedPID == pid,
                  self.focusChangeProbeGeneration == generation,
                  self.activationProbeGeneration == activationGeneration,
                  let windowID
            else { return }
            self.trackAndRegister(windowID: windowID, pid: pid)
            self.onWindowActivated?(windowID)
        }
    }

    // MARK: - NSWorkspace notifications

    /// Launch Services leaves hosted foreground processes such as CrossOver's Wine children
    /// bundleless. The window service resolves those children to their signed host identity;
    /// use the same answer for launch and activation notifications so a window created after
    /// startup reaches discovery instead of waiting for an unrelated reconciliation event.
    private func appInfo(for application: NSRunningApplication) -> AppInfo? {
        guard application.activationPolicy == .regular else { return nil }
        let pid = application.processIdentifier
        if let bundleID = application.bundleIdentifier {
            return AppInfo(
                bundleID: bundleID,
                name: application.localizedName ?? bundleID,
                pid: pid,
                isHidden: application.isHidden
            )
        }
        return windowService.listRunningApps().first { $0.pid == pid }
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let appInfo = appInfo(for: app),
              !excludedBundleIDs.contains(appInfo.bundleID)
        else { return }

        handleAppLaunch(appInfo)
    }

    func handleAppLaunch(_ app: AppInfo) {
        installWindowCreationObserver(for: app.pid, bundleID: app.bundleID)
        AppIconCache.shared.warm(
            bundleIDs: [app.bundleID],
            sizes: AppIconCache.overlayIconSizes,
            badgeSizes: AppIconCache.overlayBadgeIconSizes
        )

        if launchDiscoveryDelay == 0 {
            discoverLaunchedWindows(for: app)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + launchDiscoveryDelay) { [weak self] in
            self?.discoverLaunchedWindows(for: app)
        }
    }

    private func desktopIndexes(for windows: [WindowInfo]) -> [CGWindowID: Int] {
        desktopLocations(for: windows).mapValues(\.index)
    }

    /// One `windowLocations()` call covering every desktop, filtered down to the windows
    /// asked about — not one `SLSCopySpacesForWindows` call per window. `listWindows()`
    /// already calls `windowLocations()` to discover windows outside the active Space, so
    /// this reuses that same per-desktop enumeration for placement instead of re-asking
    /// per window.
    private func desktopLocations(for windows: [WindowInfo]) -> [CGWindowID: DesktopLocation] {
        guard let spaceSwitcher else { return [:] }
        let liveIDs = Set(windows.map(\.windowID))
        return spaceSwitcher.windowLocations().filter { liveIDs.contains($0.key) }
    }

    /// Every window SkyLight places, unfiltered — which `windowLocations().keys` was not, since
    /// that map drops a window found on more than one desktop. Nil without a space switcher,
    /// since an enumeration that was never made must not read as a screen with nothing on it.
    private func skyLightWindowIDs() -> Set<CGWindowID>? {
        spaceSwitcher.map { $0.placedWindowIDs() }
    }

    private func discoverLaunchedWindows(for app: AppInfo) {
        let pid = app.pid
        let windows = excludingRetired(windowService.listWindows())
            .filter { $0.ownerPID == pid }
        // Matching by window ID alone would trust stale bookkeeping from a process whose
        // exit was missed, so a reused ID for a different PID must still be (re-)tracked.
        for info in windows where windowOwnerPIDs[info.windowID] != pid {
            trackAndRegister(windowID: info.windowID, pid: pid)
        }

        // Publish the complete app window set as one reconciliation unit so
        // dormant dynamic-title assignments can use one-to-one matching.
        onWindowsDiscovered?(windows)

        guard frontmostPIDProvider() == pid else { return }
        launchProbeGeneration += 1
        let generation = launchProbeGeneration
        focusProbeScheduler(pid) { [weak self] probedWindowID in
            guard let self,
                  self.launchProbeGeneration == generation,
                  self.frontmostPIDProvider() == pid
            else { return }
            let focusedWindowID = probedWindowID.flatMap { candidate in
                windows.contains(where: { $0.windowID == candidate }) ? candidate : nil
            } ?? windows.first?.windowID
            guard let focusedWindowID else { return }
            self.trackAndRegister(windowID: focusedWindowID, pid: pid)
            self.onWindowActivated?(focusedWindowID)
        }
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let appInfo = appInfo(for: app)
        else { return }

        handleAppActivation(appInfo)

        // Move the focus observer to this app
        installFocusObserver(for: appInfo.pid, bundleID: appInfo.bundleID)
    }

    /// Re-reads which desktop every window is on.
    ///
    /// Activation was the only thing that asked, so a window the user dragged to another
    /// desktop kept its old space until they clicked it — the move was invisible in Debut
    /// until then. Deliberately carries no focused window and registers no AX observers:
    /// nothing was activated, and the only question being asked is where things are now.
    public func refreshDesktopAssignments() {
        let liveWindows = excludingRetired(windowService.listWindows()).filter {
            !excludedBundleIDs.contains($0.ownerBundleID)
        }
        reportWindowsDetectedByLaterScan(liveWindows, trigger: "desktop_changed")
        for window in liveWindows where windowOwnerPIDs[window.windowID] != window.ownerPID {
            trackAndRegister(windowID: window.windowID, pid: window.ownerPID)
        }
        onDesktopsChanged?(RuntimeWindowSnapshot(
            liveWindows: liveWindows,
            allWindowIDs: windowService.listAllWindowIDs(),
            unarmedWindowIDs: unarmedWindowIDs,
            desktopIndexes: desktopIndexes(for: liveWindows),
            desktopLocations: desktopLocations(for: liveWindows),
            axContradictedWindowIDs: windowService.listAXContradictedWindowIDs(),
            skyLightWindowIDs: skyLightWindowIDs()
        ))
    }

    /// Production desktop-change handling performs its Core Graphics, AX, and SkyLight snapshot
    /// away from the main queue. The generation check drops an older answer when two display or
    /// desktop events arrive while WindowServer is already under pressure.
    public func refreshDesktopAssignmentsInBackground() {
        desktopRefreshGeneration += 1
        let generation = desktopRefreshGeneration
        let excludedBundleIDs = excludedBundleIDs
        let retiredWindowOwners = retiredWindowOwners
        let unarmedWindowIDs = unarmedWindowIDs
        let windowService = windowService
        let spaceSwitcher = spaceSwitcher

        ExternalCallScheduler.shared.schedule(on: .windowServer) { [weak self] in
            let liveWindows = windowService.listWindows().filter { window in
                !excludedBundleIDs.contains(window.ownerBundleID) &&
                    retiredWindowOwners[window.windowID]?.ownerPID != window.ownerPID
            }
            let liveIDs = Set(liveWindows.map(\.windowID))
            let locations = spaceSwitcher?.windowLocations().filter {
                liveIDs.contains($0.key)
            } ?? [:]
            let snapshot = RuntimeWindowSnapshot(
                liveWindows: liveWindows,
                allWindowIDs: windowService.listAllWindowIDs(),
                unarmedWindowIDs: unarmedWindowIDs,
                desktopIndexes: locations.mapValues(\.index),
                desktopLocations: locations,
                axContradictedWindowIDs: windowService.listAXContradictedWindowIDs(),
                skyLightWindowIDs: spaceSwitcher.map { $0.placedWindowIDs() }
            )
            DispatchQueue.main.async(qos: .userInitiated, flags: .enforceQoS) {
                guard let self, self.desktopRefreshGeneration == generation else { return }
                self.reportWindowsDetectedByLaterScan(liveWindows, trigger: "desktop_changed")
                for window in liveWindows where
                    self.windowOwnerPIDs[window.windowID] != window.ownerPID {
                    self.trackAndRegister(windowID: window.windowID, pid: window.ownerPID)
                }
                self.onDesktopsChanged?(snapshot)
            }
        }
    }

    func handleAppActivation(_ app: AppInfo) {
        activationProbeGeneration += 1
        activatedPID = app.pid
        let generation = activationProbeGeneration
        let probeStartedAt = DispatchTime.now().uptimeNanoseconds

        // A switcher is never the app the user switched to. Debut's activation policy used to
        // keep it out of this notification; as a regular app it arrives like anything else, and
        // answering would name Debut the frontmost app every time its own window took focus.
        guard app.bundleID != "com.thomplth.Debut" else {
            activatedPID = nil
            return
        }
        diag.report("app_activation_observed", details: [
            "bundleID": app.bundleID,
            "ownerPID": "\(app.pid)",
            "source": FrontmostAppObservationSource.workspaceActivation.rawValue,
        ])
        onFrontmostAppChanged?(app.bundleID, .workspaceActivation)

        let pid = app.pid
        let shouldTrackActivation = !excludedBundleIDs.contains(app.bundleID)
        guard shouldTrackActivation else {
            finishAppActivation(
                app,
                sampledFocusedWindowID: nil,
                generation: generation,
                probeStartedAt: probeStartedAt
            )
            return
        }
        installWindowCreationObserver(for: app.pid, bundleID: app.bundleID)
        let focusGeneration = focusChangeProbeGeneration
        focusProbeScheduler(pid) { [weak self] sampledFocusedWindowID in
            self?.finishAppActivation(
                app,
                sampledFocusedWindowID: sampledFocusedWindowID,
                generation: generation,
                focusGeneration: focusGeneration,
                probeStartedAt: probeStartedAt
            )
        }
    }

    private func finishAppActivation(
        _ app: AppInfo,
        sampledFocusedWindowID: CGWindowID?,
        generation: Int,
        focusGeneration: Int? = nil,
        probeStartedAt: UInt64
    ) {
        guard activationProbeGeneration == generation, activatedPID == app.pid else { return }
        let pid = app.pid
        let shouldTrackActivation = !excludedBundleIDs.contains(app.bundleID)
        let runningApps = windowService.listRunningApps()
        var runningPIDs = Set(runningApps.map(\.pid))
        // The activation notification is authoritative even if Launch Services has not
        // inserted the newly activated process into runningApplications yet.
        runningPIDs.insert(pid)
        pruneTracking(runningPIDs: runningPIDs)
        let liveWindows = excludingRetired(windowService.listWindows()).filter {
            !excludedBundleIDs.contains($0.ownerBundleID)
        }
        reportWindowsDetectedByLaterScan(liveWindows, trigger: "app_activation")
        // The full snapshot drives reconciliation, but only the activated app needs
        // a retry when its earlier registration failed. A full scan can also find a window
        // from another app whose creation event was missed; arm only those newly found windows
        // rather than doing cross-process AX work for every window on every switch.
        for window in liveWindows where
            window.ownerPID == pid || windowOwnerPIDs[window.windowID] != window.ownerPID {
            trackAndRegister(windowID: window.windowID, pid: window.ownerPID)
        }
        // AX focus can be nil while an app launches, or can briefly retain the ID of a
        // document window the app just replaced. Trust the early sample only when the
        // activated process still enumerates that window. Re-read once after enumeration
        // before falling back to CGWindowList's front-to-back order.
        let activatedWindows = liveWindows.filter { $0.ownerPID == pid }
        let activatedWindowIDs = Set(activatedWindows.map(\.windowID))
        let focusedWindowID: CGWindowID?
        if let sampledFocusedWindowID,
           activatedWindowIDs.contains(sampledFocusedWindowID) {
            focusedWindowID = sampledFocusedWindowID
        } else if shouldTrackActivation {
            focusedWindowID = activatedWindows.first?.windowID
        } else {
            focusedWindowID = nil
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - probeStartedAt
        diag.report("app_activation_focus_probed", details: [
            "bundleID": app.bundleID,
            "elapsedMilliseconds": String(format: "%.3f", Double(elapsedNanoseconds) / 1_000_000),
            "ownerPID": "\(pid)",
            "resolvedWindowID": focusedWindowID.map(String.init) ?? "none",
            "sampledWindowID": sampledFocusedWindowID.map(String.init) ?? "none",
            "source": FrontmostAppObservationSource.workspaceActivation.rawValue,
        ])
        if let focusedWindowID {
            trackAndRegister(windowID: focusedWindowID, pid: pid)
        }
        onAppActivated?(RuntimeWindowSnapshot(
            liveWindows: liveWindows,
            allWindowIDs: windowService.listAllWindowIDs(),
            focusedWindowID: focusedWindowID,
            unarmedWindowIDs: unarmedWindowIDs,
            desktopIndexes: desktopIndexes(for: liveWindows),
            desktopLocations: desktopLocations(for: liveWindows),
            skyLightWindowIDs: skyLightWindowIDs()
        ))
        if let focusedWindowID,
           focusGeneration == nil || focusChangeProbeGeneration == focusGeneration {
            onWindowActivated?(focusedWindowID)
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        handleProcessExit(pid: app.processIdentifier)
    }

    /// Central cleanup for both kernel PID-exit events and NSWorkspace's backup signal.
    /// Multiple lifecycle sources may report the same exit, so this must remain idempotent.
    func handleProcessExit(pid: pid_t) {
        guard pid > 0, handledExitedProcessIDs.insert(pid).inserted else { return }

        monitoredProcessIDs.remove(pid)
        processExitMonitor.stopMonitoring(pid: pid)

        // Clean up focus observer if we were observing this app, or still trying to
        if pid == observedPID || pid == pendingFocusObserverPID {
            removeFocusObserver()
        }

        // Clean up per-window lifecycle observer for this app
        removeAppObserver(for: pid)

        pendingWindowCreations = pendingWindowCreations.filter { $0.value.identity?.ownerPID != pid }
        creationNotificationsSeen = creationNotificationsSeen.filter { $0.ownerPID != pid }
        creationDetectionFailures = creationDetectionFailures.filter { $0.key.ownerPID != pid }

        onAppTerminated?(pid)
    }

    /// A full scan is a safety net, not the normal creation path. A window that first appears
    /// here was not delivered by launch, creation, or focus tracking soon enough. Report the
    /// available observer state before arming it so the diagnostic preserves that failure.
    private func reportWindowsDetectedByLaterScan(
        _ windows: [WindowInfo],
        trigger: String
    ) {
        for window in windows where windowOwnerPIDs[window.windowID] != window.ownerPID {
            let identity = WindowOwnerIdentity(
                windowID: window.windowID,
                ownerPID: window.ownerPID
            )
            let failure = creationDetectionFailures[identity]
            diag.report("window_detection_late", details: [
                "bundleID": window.ownerBundleID,
                "creationAttempts": failure.map { "\($0.attempts)" } ?? "0",
                "creationFailureReason": failure?.reason ?? "none",
                "creationNotificationSeen": "\(creationNotificationsSeen.contains(identity))",
                "focusObserverPresent": "\(observedPID == window.ownerPID)",
                "lifecycleObserverPresent": "\(windowCreationObservedPIDs.contains(window.ownerPID))",
                "ownerPID": "\(window.ownerPID)",
                "trigger": trigger,
                "windowID": "\(window.windowID)",
                "windowTitle": window.title,
            ])
        }
    }

    // MARK: - Helpers

    public func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        Self.boundedFocusedWindowID(for: pid)
    }

    private static func boundedFocusedWindowID(for pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Float(focusProbeTimeout))
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else {
            return nil
        }
        guard let windowRef else { return nil }
        let window = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, Float(focusProbeTimeout))
        var cgWindowID: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &cgWindowID) == .success else {
            return nil
        }
        return cgWindowID
    }

}

// AXObserver C callback — per-window lifecycle (destroyed, title changed, resized)
private func windowLifecycleCallback(
    observer: AXObserver,
    element: AXUIElement,
    notificationName: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let service = Unmanaged<WindowDiscoveryService>.fromOpaque(refcon).takeUnretainedValue()
    let name = notificationName as String
    if name == kAXUIElementDestroyedNotification {
        service.handleWindowDestroyed(element: element)
    } else if name == kAXTitleChangedNotification {
        service.handleWindowTitleChanged(element: element)
    } else if name == kAXWindowResizedNotification {
        service.handleWindowResized(element: element)
    } else if name == kAXWindowCreatedNotification || name == kAXSheetCreatedNotification {
        service.handleWindowCreated(element: element, notification: name)
    }
}

// AXObserver C callback — bridges to WindowDiscoveryService.handleFocusChanged()
private func focusChangedCallback(
    observer: AXObserver,
    element: AXUIElement,
    notificationName: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let service = Unmanaged<WindowDiscoveryService>.fromOpaque(refcon).takeUnretainedValue()
    service.handleFocusChanged()
}
