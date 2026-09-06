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

/// One window a destroy notification proved gone, named together with the process that owned
/// it. The bundle ID is only there to survive being written to disk: on reload it is what
/// distinguishes the original owner from whatever process inherited its PID.
struct RetiredWindowRecord: Codable, Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerBundleID: String
}

public final class WindowDiscoveryService: NSObject, @unchecked Sendable {
    private let diag: DiagnosticReporter
    private let windowService: any WindowService
    public var onWindowsDiscovered: (([WindowInfo]) -> Void)?
    public var onWindowClosed: ((CGWindowID) -> Void)?
    public var onWindowActivated: ((CGWindowID) -> Void)?
    public var onWindowTitleChanged: ((CGWindowID, String) -> Void)?
    public var onWindowResized: ((CGWindowID, CGSize) -> Void)?
    public var onFrontmostAppChanged: ((String?) -> Void)?
    public var onAppActivated: ((RuntimeWindowSnapshot) -> Void)?
    public var onDesktopsChanged: ((RuntimeWindowSnapshot) -> Void)?
    public var onAppTerminated: ((pid_t) -> Void)?
    public var excludedBundleIDs: Set<String> = []
    /// Spaces are desktops, so every snapshot carries the desktop macOS reports for each
    /// window. Without it the reconciler falls back to guessing from the active space.
    public var spaceSwitcher: (any SpaceSwitching)?

    private let focusedWindowProvider: (@Sendable (pid_t) -> CGWindowID?)?
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
    private var retiredWindowOwners: [CGWindowID: RetiredWindowRecord] = [:]

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

    /// Replaces retry scheduling in tests so a refused registration can be re-driven
    /// without waiting on wall time. Production leaves this nil.
    var focusObserverRetryScheduler: ((TimeInterval, @escaping () -> Void) -> Void)?

    // AXObserver for tracking focused window changes within the frontmost app
    private var focusObserver: AXObserver?
    private var observedPID: pid_t?

    /// The app a refused registration is still retrying for, and how many retries it has spent.
    private var pendingFocusObserverPID: pid_t?
    private var focusObserverAttempt = 0

    // Per-app AXObservers for window lifecycle (destroyed, title changed)
    private var perAppObservers: [pid_t: AXObserver] = [:]

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
        frontmostPIDProvider: (@Sendable () -> pid_t?)? = nil,
        launchDiscoveryDelay: TimeInterval = 0.5,
        processExitMonitor: any ProcessExitMonitoring,
        diagnosticReporter: DiagnosticReporter = .shared
    ) {
        self.diag = diagnosticReporter
        self.windowService = windowService
        self.focusedWindowProvider = focusedWindowProvider
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
        let parentedWindowIDs = windowService.listParentedWindowIDs()
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
        let refusedWindowIDs = untrackableWindowIDs
            .union(disqualifiedWindowIDs)
            .union(axContradictedWindowIDs)
            .union(parentedWindowIDs)

        var parkedDormantCount = 0
        for space in spaceManager.allSpaces {
            for windowID in space.windowIDs {
                let reason: String
                if untrackableWindowIDs.contains(windowID) {
                    reason = "untrackable"
                } else if disqualifiedWindowIDs.contains(windowID) {
                    reason = "disqualified"
                } else if axContradictedWindowIDs.contains(windowID) {
                    reason = "ax_contradicted"
                } else if parentedWindowIDs.contains(windowID) {
                    reason = "parented"
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
        onFrontmostAppChanged?(front?.bundleIdentifier)

        // Install focus observer on the current frontmost app
        if let front, let info = appInfo(for: front) {
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
        return .armed
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
        if let owner = windowOwnerPIDs[windowID] {
            retiredWindowOwners[windowID] = RetiredWindowRecord(
                windowID: windowID,
                ownerPID: owner,
                ownerBundleID: windowService.listRunningApps()
                    .first { $0.pid == owner }?.bundleID ?? ""
            )
        }
        trackedWindowElements.removeValue(forKey: windowID)
        knownWindowIDs.remove(windowID)
        armedWindowIDs.remove(windowID)
        unarmedWindowIDs.remove(windowID)
        windowOwnerPIDs.removeValue(forKey: windowID)
        onWindowClosed?(windowID)
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
        guard let pid = observedPID,
              let windowID = focusedWindowID(for: pid)
        else { return }
        trackAndRegister(windowID: windowID, pid: pid)
        onWindowActivated?(windowID)
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
        AppIconCache.shared.warm(bundleIDs: [app.bundleID], sizes: AppIconCache.overlayIconSizes)

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

    /// Every window SkyLight places, unfiltered. Nil without a space switcher, since an
    /// enumeration that was never made must not read as a screen with nothing on it.
    private func skyLightWindowIDs() -> Set<CGWindowID>? {
        spaceSwitcher.map { Set($0.windowLocations().keys) }
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
        let focusedWindowID = focusedWindowProvider?(pid)
            ?? focusedWindowID(for: pid)
            ?? windows.first?.windowID
        if let focusedWindowID,
           windows.contains(where: { $0.windowID == focusedWindowID }) {
            trackAndRegister(windowID: focusedWindowID, pid: pid)
            onWindowActivated?(focusedWindowID)
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

    func handleAppActivation(_ app: AppInfo) {
        // A switcher is never the app the user switched to. Debut's activation policy used to
        // keep it out of this notification; as a regular app it arrives like anything else, and
        // answering would name Debut the frontmost app every time its own window took focus.
        guard app.bundleID != "com.thomplth.Debut" else { return }
        onFrontmostAppChanged?(app.bundleID)

        let pid = app.pid
        let shouldTrackActivation = !excludedBundleIDs.contains(app.bundleID)
        let sampledFocusedWindowID: CGWindowID?

        // Sample focus before performing any enumeration so transient activation
        // windows are not introduced by reconciliation latency.
        if shouldTrackActivation {
            sampledFocusedWindowID = focusedWindowProvider?(pid) ?? self.focusedWindowID(for: pid)
        } else {
            sampledFocusedWindowID = nil
        }
        let runningApps = windowService.listRunningApps()
        var runningPIDs = Set(runningApps.map(\.pid))
        // The activation notification is authoritative even if Launch Services has not
        // inserted the newly activated process into runningApplications yet.
        runningPIDs.insert(pid)
        pruneTracking(runningPIDs: runningPIDs)
        let liveWindows = excludingRetired(windowService.listWindows()).filter {
            !excludedBundleIDs.contains($0.ownerBundleID)
        }
        // The full snapshot drives reconciliation, but only the activated app needs
        // fresh AX lifecycle registration here. Other apps are registered when they
        // activate, avoiding cross-process AX work for every window on every switch.
        for window in liveWindows where window.ownerPID == pid {
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
            let refreshedFocusedWindowID = focusedWindowProvider?(pid)
                ?? self.focusedWindowID(for: pid)
            focusedWindowID = refreshedFocusedWindowID.flatMap {
                activatedWindowIDs.contains($0) ? $0 : nil
            } ?? activatedWindows.first?.windowID
        } else {
            focusedWindowID = nil
        }
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
        if let focusedWindowID {
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

        onAppTerminated?(pid)
    }

    // MARK: - Helpers

    public func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else {
            return nil
        }
        guard let windowRef else { return nil }
        let window = windowRef as! AXUIElement
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
