import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics

public final class WindowDiscoveryService: NSObject, @unchecked Sendable {
    private let windowService: any WindowService
    public var onWindowDiscovered: ((StageWindow) -> Void)?
    public var onWindowClosed: ((CGWindowID) -> Void)?
    public var onWindowActivated: ((CGWindowID) -> Void)?
    public var onWindowTitleChanged: ((CGWindowID, String) -> Void)?
    public var onFrontmostAppChanged: ((String?) -> Void)?
    public var onAppActivated: ((RuntimeWindowSnapshot) -> Void)?
    public var onAppTerminated: ((pid_t) -> Void)?
    public var excludedBundleIDs: Set<String> = []

    private let focusedWindowProvider: (@Sendable (pid_t) -> CGWindowID?)?

    private var knownWindowIDs: Set<CGWindowID> = []

    // AXObserver for tracking focused window changes within the frontmost app
    private var focusObserver: AXObserver?
    private var observedPID: pid_t?

    // Per-app AXObservers for window lifecycle (destroyed, title changed)
    private struct AppObserverState {
        let observer: AXObserver
        var trackedWindows: [CGWindowID: AXUIElement]
    }
    private var perAppObservers: [pid_t: AppObserverState] = [:]

    public init(
        windowService: any WindowService,
        focusedWindowProvider: (@Sendable (pid_t) -> CGWindowID?)? = nil
    ) {
        self.windowService = windowService
        self.focusedWindowProvider = focusedWindowProvider
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
    /// Unmatched windows from running apps are preserved for runtime confirmation.
    /// Unmatched live windows go to the first stage.
    public func reconcileWindows(_ stageManager: inout StageManager) {
        let liveWindows = windowService.listWindows()
        let runningApps = windowService.listRunningApps()

        // An empty snapshot while regular apps are running usually means AX window
        // enumeration failed. Treating it as authoritative would erase every saved
        // stage assignment, so leave persisted state intact for runtime PID cleanup.
        let persistedWindowCount = stageManager.stages.reduce(0) { $0 + $1.windows.count }
        if liveWindows.isEmpty,
           persistedWindowCount > 0,
           !runningApps.isEmpty {
            DiagnosticReporter.shared.report("windows_reconcile_skipped", details: [
                "persistedCount": "\(persistedWindowCount)",
                "reason": "empty_snapshot_with_running_apps",
            ])
            return
        }

        // Build lookup: (bundleID, title) -> [WindowInfo]
        var liveByKey: [String: [WindowInfo]] = [:]
        for info in liveWindows {
            let key = "\(info.ownerBundleID)|\(info.title)"
            liveByKey[key, default: []].append(info)
        }

        var matchedLiveIDs = Set<CGWindowID>()
        var staleEntries: [(stageID: UUID, windowID: CGWindowID)] = []

        for stageIndex in stageManager.stages.indices {
            for windowIndex in stageManager.stages[stageIndex].windows.indices {
                let window = stageManager.stages[stageIndex].windows[windowIndex]
                // Skip excluded apps — treat as stale
                if excludedBundleIDs.contains(window.ownerBundleID) {
                    staleEntries.append((stageManager.stages[stageIndex].id, window.windowID))
                    continue
                }

                let key = "\(window.ownerBundleID)|\(window.windowTitle)"

                if var candidates = liveByKey[key], !candidates.isEmpty {
                    let match = candidates.removeFirst()
                    liveByKey[key] = candidates.isEmpty ? nil : candidates
                    stageManager.updateWindowIDs(stageIndex: stageIndex, windowIndex: windowIndex, windowID: match.windowID, ownerPID: match.ownerPID)
                    matchedLiveIDs.insert(match.windowID)
                    trackAndRegister(windowID: match.windowID, pid: match.ownerPID)
                } else {
                    staleEntries.append((stageManager.stages[stageIndex].id, window.windowID))
                }
            }
        }

        // Second pass: for stale entries, try matching by bundleID alone (handles title changes)
        var remainingLiveByBundle: [String: [WindowInfo]] = [:]
        for info in liveWindows where !matchedLiveIDs.contains(info.windowID) && !excludedBundleIDs.contains(info.ownerBundleID) {
            remainingLiveByBundle[info.ownerBundleID, default: []].append(info)
        }

        var trulyStale: [(stageID: UUID, windowID: CGWindowID)] = []
        for (stageID, windowID) in staleEntries {
            // Find the persisted window's bundleID
            guard let stageIdx = stageManager.stages.firstIndex(where: { $0.id == stageID }),
                  let winIdx = stageManager.stages[stageIdx].windows.firstIndex(where: { $0.windowID == windowID })
            else {
                trulyStale.append((stageID, windowID))
                continue
            }
            let bundleID = stageManager.stages[stageIdx].windows[winIdx].ownerBundleID

            if var candidates = remainingLiveByBundle[bundleID], !candidates.isEmpty {
                let match = candidates.removeFirst()
                remainingLiveByBundle[bundleID] = candidates.isEmpty ? nil : candidates
                stageManager.updateWindowIDs(stageIndex: stageIdx, windowIndex: winIdx, windowID: match.windowID, ownerPID: match.ownerPID, windowTitle: match.title)
                matchedLiveIDs.insert(match.windowID)
                trackAndRegister(windowID: match.windowID, pid: match.ownerPID)
            } else {
                trulyStale.append((stageID, windowID))
            }
        }

        let runningPIDs = Set(runningApps.map(\.pid))
        let runningBundleIDs = Set(runningApps.map(\.bundleID))
        for (stageID, windowID) in trulyStale {
            guard let stage = stageManager.stages.first(where: { $0.id == stageID }),
                  let window = stage.windows.first(where: { $0.windowID == windowID })
            else { continue }

            // A non-empty AX result can still omit arbitrary windows. Preserve an
            // unmatched assignment while its process (or a relaunched instance of
            // the same app) is running. Runtime CG-ID sweeps confirm real closures.
            if window.ownerPID.map(runningPIDs.contains) == true ||
                runningBundleIDs.contains(window.ownerBundleID) {
                continue
            }
            stageManager.removeWindow(windowID: windowID, fromStageID: stageID)
        }

        // Add unmatched live windows to the first stage (not the last-active stage)
        let firstStageID = stageManager.stages[0].id
        for info in liveWindows where !matchedLiveIDs.contains(info.windowID) && !excludedBundleIDs.contains(info.ownerBundleID) {
            let window = StageWindow(
                windowID: info.windowID,
                ownerBundleID: info.ownerBundleID,
                ownerName: info.ownerName,
                windowTitle: info.title,
                ownerPID: info.ownerPID
            )
            stageManager.addWindow(window, toStageID: firstStageID)
            trackAndRegister(windowID: info.windowID, pid: info.ownerPID)
        }

        DiagnosticReporter.shared.report("windows_reconciled", details: [
            "liveCount": "\(liveWindows.count)",
            "matched": "\(matchedLiveIDs.count)",
            "stale": "\(staleEntries.count)",
        ])
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
           front.bundleIdentifier != "com.thomplth.Debut" {
            installFocusObserver(for: front.processIdentifier)
        }
    }

    public func stopObserving() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeFocusObserver()
        for pid in perAppObservers.keys {
            removeAppObserver(for: pid)
        }
    }

    // MARK: - Per-window lifecycle tracking

    /// Combined insert into knownWindowIDs + register AX notifications
    private func trackAndRegister(windowID: CGWindowID, pid: pid_t) {
        knownWindowIDs.insert(windowID)
        trackWindow(windowID: windowID, pid: pid)
    }

    /// Public entry point for external callers (e.g., StageController adding new windows)
    public func registerTracking(windowID: CGWindowID, pid: pid_t) {
        trackAndRegister(windowID: windowID, pid: pid)
    }

    private func trackWindow(windowID: CGWindowID, pid: pid_t) {
        // Already tracking this window
        if perAppObservers[pid]?.trackedWindows[windowID] != nil { return }
        guard let observer = getOrCreateObserver(for: pid),
              let axElement = axWindowElement(for: windowID, pid: pid)
        else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // Register destroy + title notifications on this specific window element
        AXObserverAddNotification(observer, axElement, kAXUIElementDestroyedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, axElement, kAXTitleChangedNotification as CFString, selfPtr)
        perAppObservers[pid]?.trackedWindows[windowID] = axElement
    }

    private func getOrCreateObserver(for pid: pid_t) -> AXObserver? {
        if let existing = perAppObservers[pid] {
            return existing.observer
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, windowLifecycleCallback, &observer) == .success,
              let observer else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        perAppObservers[pid] = AppObserverState(observer: observer, trackedWindows: [:])
        return observer
    }

    private func removeAppObserver(for pid: pid_t) {
        guard let state = perAppObservers.removeValue(forKey: pid) else { return }
        knownWindowIDs.subtract(state.trackedWindows.keys)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(state.observer), .defaultMode)
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

    fileprivate func handleWindowDestroyed(element: AXUIElement) {
        for (pid, var state) in perAppObservers {
            for (windowID, trackedElement) in state.trackedWindows {
                if CFEqual(element, trackedElement) {
                    state.trackedWindows.removeValue(forKey: windowID)
                    perAppObservers[pid] = state
                    knownWindowIDs.remove(windowID)
                    onWindowClosed?(windowID)
                    return
                }
            }
        }
    }

    fileprivate func handleWindowTitleChanged(element: AXUIElement) {
        // Find the windowID for this element
        var windowID: CGWindowID?
        for (_, state) in perAppObservers {
            for (wID, trackedElement) in state.trackedWindows {
                if CFEqual(element, trackedElement) {
                    windowID = wID
                    break
                }
            }
            if windowID != nil { break }
        }
        guard let windowID else { return }

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

        let pid = app.processIdentifier
        let name = app.localizedName ?? bundleID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let windows = self.windowService.listWindows().filter { $0.ownerPID == pid }
            for info in windows where !self.knownWindowIDs.contains(info.windowID) {
                self.trackAndRegister(windowID: info.windowID, pid: pid)
                let stageWindow = StageWindow(
                    windowID: info.windowID,
                    ownerBundleID: bundleID,
                    ownerName: name,
                    windowTitle: info.title,
                    ownerPID: pid
                )
                self.onWindowDiscovered?(stageWindow)
            }
        }
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        let activationStarted = DispatchTime.now().uptimeNanoseconds
        defer {
            let durationMicroseconds = (
                DispatchTime.now().uptimeNanoseconds - activationStarted
            ) / 1_000
            DiagnosticReporter.shared.reportAsync("app_activation_latency", details: [
                "bundleID": bundleID,
                "durationUs": "\(durationMicroseconds)",
            ])
        }
        handleAppActivation(AppInfo(
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            pid: pid,
            isHidden: app.isHidden
        ))

        guard bundleID != "com.thomplth.Debut",
              !excludedBundleIDs.contains(bundleID),
              app.activationPolicy == .regular
        else { return }

        // Move the focus observer to this app
        installFocusObserver(for: pid)
    }

    func handleAppActivation(_ app: AppInfo) {
        onFrontmostAppChanged?(app.bundleID)

        let pid = app.pid

        // Sample focus before performing any enumeration so transient activation
        // windows are not introduced by reconciliation latency.
        if app.bundleID != "com.thomplth.Debut",
           !excludedBundleIDs.contains(app.bundleID),
           let windowID = focusedWindowProvider?(pid) ?? focusedWindowID(for: pid) {
            trackAndRegister(windowID: windowID, pid: pid)
            onWindowActivated?(windowID)
        }

        var runningPIDs = Set(windowService.listRunningApps().map(\.pid))
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
        onAppActivated?(RuntimeWindowSnapshot(
            runningPIDs: runningPIDs,
            liveWindows: liveWindows,
            allWindowIDs: windowService.listAllWindowIDs()
        ))
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        let pid = app.processIdentifier

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
        var cgWindowID: CGWindowID = 0
        guard _AXUIElementGetWindow(windowRef as! AXUIElement, &cgWindowID) == .success else {
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
