import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics

/// Result of trying to arm a window's lifecycle notifications. An assignment
/// may only be trusted to be removable while its destroy notification is armed.
public enum WindowArmingOutcome: Equatable, Sendable {
    case armed
    case observerUnavailable
    case elementUnavailable
    case notificationRejected(Int32)
}

public final class WindowDiscoveryService: NSObject, @unchecked Sendable {
    private let diag: DiagnosticReporter
    private let windowService: any WindowService
    public var onWindowsDiscovered: (([WindowInfo]) -> Void)?
    public var onWindowClosed: ((CGWindowID) -> Void)?
    public var onWindowActivated: ((CGWindowID) -> Void)?
    public var onWindowTitleChanged: ((CGWindowID, String) -> Void)?
    public var onFrontmostAppChanged: ((String?) -> Void)?
    public var onAppActivated: ((RuntimeWindowSnapshot) -> Void)?
    public var onAppTerminated: ((pid_t) -> Void)?
    public var excludedBundleIDs: Set<String> = []

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

    // AXObserver for tracking focused window changes within the frontmost app
    private var focusObserver: AXObserver?
    private var observedPID: pid_t?

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

    public func discoverRunningWindows() -> [StageWindow] {
        windowService.listWindows().filter { !excludedBundleIDs.contains($0.ownerBundleID) }.map { info in
            StageWindow(
                windowID: info.windowID,
                ownerBundleID: info.ownerBundleID,
                ownerName: info.ownerName,
                windowTitle: info.title,
                ownerPID: info.ownerPID
            )
        }
    }

    public func populateDefaultStage(_ stageManager: inout StageManager) {
        let windows = discoverRunningWindows()
        let stageID = stageManager.stages[0].id

        for window in windows {
            stageManager.addWindow(window, toStageID: stageID)
            trackAndRegister(windowID: window.windowID, pid: window.ownerPID ?? 0)
        }

        DiagnosticReporter.shared.report("windows_discovered", details: [
            "count": "\(windows.count)",
        ])
    }

    /// Reconcile persisted stage windows against live windows.
    /// CGWindowIDs and PIDs are ephemeral — match by (bundleID, title).
    /// Assignments from stopped processes become dormant rather than being deleted.
    /// Unmatched live windows go to the first stage.
    public func reconcileWindows(_ stageManager: inout StageManager) {
        let discoveryID = PerformanceRecorder.shared.begin(.windowDiscovery)
        let liveWindows = windowService.listWindows().filter {
            !excludedBundleIDs.contains($0.ownerBundleID)
        }
        let untrackableWindowIDs = windowService.listUntrackableWindowIDs()
        let runningApps = windowService.listRunningApps()
        _ = PerformanceRecorder.shared.end(discoveryID)

        // Explicit AX classification identifies modal, floating, and other
        // auxiliary UI — but it is a snapshot, not a verdict. An app still
        // warming up can describe a user-manageable window this way, and deleting
        // the assignment would make that momentary misreport permanent. Park the
        // placement instead; a later snapshot reclaims it.
        let classificationID = PerformanceRecorder.shared.begin(
            .windowClassification,
            workload: .init(windows: liveWindows.count)
        )
        var untrackableDormantCount = 0
        for stage in stageManager.stages {
            for windowID in stage.windowIDs where untrackableWindowIDs.contains(windowID) {
                guard let assignment = stageManager.makeWindowDormant(windowID: windowID) else { continue }
                untrackableDormantCount += 1
                diag.report("window_made_dormant", details: [
                    "windowID": "\(windowID)",
                    "bundleID": assignment.window.ownerBundleID,
                    "windowTitle": assignment.window.windowTitle,
                    "fromStage": "\(stageManager.stages.firstIndex(where: { $0.id == assignment.stageID }) ?? -1)",
                    "reason": "untrackable",
                ])
            }
        }
        _ = PerformanceRecorder.shared.end(classificationID)

        // An empty snapshot while regular apps are running usually means AX window
        // enumeration failed. Treating it as authoritative would erase every saved
        // stage assignment, so leave persisted state intact for runtime PID cleanup.
        let persistedWindowCount = stageManager.liveWindowCount
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
        let stoppedPIDs: Set<pid_t> = Set(stageManager.stages.flatMap(\.windows).compactMap { window -> pid_t? in
            guard let ownerPID = window.ownerPID,
                  !runningPIDs.contains(ownerPID),
                  !runningBundleIDs.contains(window.ownerBundleID)
            else { return nil }
            return ownerPID
        })
        for ownerPID in stoppedPIDs {
            _ = stageManager.makeWindowsDormant(forOwnerPID: ownerPID)
        }

        let firstStageID = stageManager.stages[0].id
        var reconciler = RuntimeWindowReconciler()
        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: liveWindows,
                allWindowIDs: windowService.listAllWindowIDs()
            ),
            stageManager: &stageManager,
            newWindowStageID: firstStageID
        )
        for info in liveWindows {
            trackAndRegister(windowID: info.windowID, pid: info.ownerPID)
        }

        diag.report("windows_reconciled", details: [
            "liveCount": "\(liveWindows.count)",
            "added": "\(result.addedCount)",
            "reassigned": "\(result.reassignedCount)",
            "dormant": "\(stageManager.dormantWindowAssignments.count)",
            "untrackable": "\(untrackableDormantCount)",
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
        if let front,
           front.bundleIdentifier != "com.thomplth.DebutSpace" {
            installFocusObserver(for: front.processIdentifier)
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
        handledExitedProcessIDs.removeAll()
    }

    // MARK: - Per-window lifecycle tracking

    /// Registers process-exit monitoring and arms window lifecycle notifications.
    /// PID monitoring must not depend on per-window AX success.
    private func trackAndRegister(windowID: CGWindowID, pid: pid_t) {
        registerProcessExitMonitoring(for: pid)
        trackWindow(windowID: windowID, pid: pid)
    }

    /// Public entry point for external callers (e.g., StageController adding new windows)
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
        if armedWindowIDs.contains(windowID) { return }

        windowOwnerPIDs[windowID] = pid
        let element = windowElementOverride?(windowID, pid) ?? axWindowElement(for: windowID, pid: pid)
        let outcome = armingOverride?(windowID, pid)
            ?? armWindow(windowID: windowID, pid: pid, element: element)
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

    private func armWindow(
        windowID: CGWindowID,
        pid: pid_t,
        element axElement: AXUIElement?
    ) -> WindowArmingOutcome {
        guard let observer = getOrCreateObserver(for: pid) else { return .observerUnavailable }
        guard let axElement else { return .elementUnavailable }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let destroyed = AXObserverAddNotification(
            observer, axElement, kAXUIElementDestroyedNotification as CFString, selfPtr
        )
        // A retry after a partial failure reports the notification as already
        // registered, which is success.
        guard destroyed == .success || destroyed == .notificationAlreadyRegistered else {
            return .notificationRejected(destroyed.rawValue)
        }
        // A stale title is cosmetic, so it never gates tracking.
        _ = AXObserverAddNotification(
            observer, axElement, kAXTitleChangedNotification as CFString, selfPtr
        )
        return .armed
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
        case .elementUnavailable: step = "element_lookup"
        case .notificationRejected(let error):
            step = "add_destroy_notification"
            axError = "\(error)"
        }
        DiagnosticReporter.shared.report("tracking_failed", details: [
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

    // MARK: - AXObserver for focused window changes

    private func installFocusObserver(for pid: pid_t) {
        // Skip if already observing this app
        if observedPID == pid { return }
        removeFocusObserver()

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var observer: AXObserver?
        let result = AXObserverCreate(pid, focusChangedCallback, &observer)
        guard result == .success, let observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.focusObserver = observer
        self.observedPID = pid
    }

    private func removeFocusObserver() {
        if let observer = focusObserver, let pid = observedPID {
            let axApp = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        focusObserver = nil
        observedPID = nil
    }

    fileprivate func handleFocusChanged() {
        guard let pid = observedPID,
              let windowID = focusedWindowID(for: pid)
        else { return }
        trackAndRegister(windowID: windowID, pid: pid)
        onWindowActivated?(windowID)
    }

    // MARK: - NSWorkspace notifications

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              !excludedBundleIDs.contains(bundleID),
              app.activationPolicy == .regular
        else { return }

        handleAppLaunch(AppInfo(
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            pid: app.processIdentifier,
            isHidden: app.isHidden
        ))
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

    private func discoverLaunchedWindows(for app: AppInfo) {
        let pid = app.pid
        let windows = windowService.listWindows().filter { $0.ownerPID == pid }
        for info in windows where !knownWindowIDs.contains(info.windowID) {
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
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        handleAppActivation(AppInfo(
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            pid: pid,
            isHidden: app.isHidden
        ))

        guard bundleID != "com.thomplth.DebutSpace",
              !excludedBundleIDs.contains(bundleID),
              app.activationPolicy == .regular
        else { return }

        // Move the focus observer to this app
        installFocusObserver(for: pid)
    }

    func handleAppActivation(_ app: AppInfo) {
        onFrontmostAppChanged?(app.bundleID)

        let pid = app.pid
        let shouldTrackActivation = app.bundleID != "com.thomplth.DebutSpace"
            && !excludedBundleIDs.contains(app.bundleID)
        let sampledFocusedWindowID: CGWindowID?

        // Sample focus before performing any enumeration so transient activation
        // windows are not introduced by reconciliation latency.
        if shouldTrackActivation {
            sampledFocusedWindowID = focusedWindowProvider?(pid) ?? self.focusedWindowID(for: pid)
        } else {
            sampledFocusedWindowID = nil
        }
        if let focusedWindowID = sampledFocusedWindowID {
            trackAndRegister(windowID: focusedWindowID, pid: pid)
        }

        let runningApps = windowService.listRunningApps()
        var runningPIDs = Set(runningApps.map(\.pid))
        // The activation notification is authoritative even if Launch Services has not
        // inserted the newly activated process into runningApplications yet.
        runningPIDs.insert(pid)
        pruneTracking(runningPIDs: runningPIDs)
        let liveWindows = windowService.listWindows().filter {
            !excludedBundleIDs.contains($0.ownerBundleID)
        }
        // The full snapshot drives reconciliation, but only the activated app needs
        // fresh AX lifecycle registration here. Other apps are registered when they
        // activate, avoiding cross-process AX work for every window on every switch.
        for window in liveWindows where window.ownerPID == pid {
            trackAndRegister(windowID: window.windowID, pid: window.ownerPID)
        }
        // Newly launched apps can report no AX-focused window during the activation
        // notification. CGWindowList is front-to-back, so use the activated process's
        // first enumerated window until the delayed AX confirmation arrives.
        let focusedWindowID = sampledFocusedWindowID
            ?? (shouldTrackActivation
                ? liveWindows.first(where: { $0.ownerPID == pid })?.windowID
                : nil)
        onAppActivated?(RuntimeWindowSnapshot(
            liveWindows: liveWindows,
            allWindowIDs: windowService.listAllWindowIDs(),
            focusedWindowID: focusedWindowID,
            unarmedWindowIDs: unarmedWindowIDs
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

        // Clean up focus observer if we were observing this app
        if pid == observedPID {
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

// AXObserver C callback — per-window lifecycle (destroyed, title changed)
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
