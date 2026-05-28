import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics

public final class WindowDiscoveryService: NSObject, @unchecked Sendable {
    private let windowService: any WindowService
    public var onWindowDiscovered: ((StageWindow) -> Void)?
    public var onWindowClosed: ((CGWindowID) -> Void)?
    public var onWindowActivated: ((CGWindowID) -> Void)?
    public var onAppTerminated: ((String) -> Void)?
    public var excludedBundleIDs: Set<String> = []

    private var knownWindowIDs: Set<CGWindowID> = []

    // AXObserver for tracking focused window changes within the frontmost app
    private var focusObserver: AXObserver?
    private var observedPID: pid_t?

    public init(windowService: any WindowService) {
        self.windowService = windowService
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
            knownWindowIDs.insert(window.windowID)
        }

        DiagnosticReporter.shared.report("windows_discovered", details: [
            "count": "\(windows.count)",
        ])
    }

    /// Reconcile persisted stage windows against live windows.
    /// CGWindowIDs and PIDs are ephemeral — match by (bundleID, title).
    /// Unmatched persisted windows are removed. Unmatched live windows go to active stage.
    public func reconcileWindows(_ stageManager: inout StageManager) {
        let liveWindows = windowService.listWindows()

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
                    knownWindowIDs.insert(match.windowID)
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
                knownWindowIDs.insert(match.windowID)
            } else {
                trulyStale.append((stageID, windowID))
            }
        }

        for (stageID, windowID) in trulyStale {
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
            knownWindowIDs.insert(info.windowID)
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

        // Install focus observer on the current frontmost app
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != "com.thomplth.Debut" {
            installFocusObserver(for: front.processIdentifier)
        }
    }

    public func stopObserving() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeFocusObserver()
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
                self.knownWindowIDs.insert(info.windowID)
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
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != "com.thomplth.Debut",
              !excludedBundleIDs.contains(bundleID),
              app.activationPolicy == .regular
        else { return }

        let pid = app.processIdentifier

        // Update MRU for the activated app's focused window
        if let windowID = focusedWindowID(for: pid) {
            onWindowActivated?(windowID)
        }

        // Move the focus observer to this app
        installFocusObserver(for: pid)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier
        else { return }

        // If we were observing this app, clean up
        if app.processIdentifier == observedPID {
            removeFocusObserver()
        }

        onAppTerminated?(bundleID)
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
