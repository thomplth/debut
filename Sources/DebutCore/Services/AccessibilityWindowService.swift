import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics
import ScreenCaptureKit

private struct SendableCaptureWindow: @unchecked Sendable {
    let window: SCWindow
}

/// One window Accessibility contradicted, named together with the process that owned it. The
/// bundle ID is only there to survive being written to disk: on reload it is what distinguishes
/// the original owner from whatever process inherited its PID.
struct AXContradictionRecord: Codable, Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerBundleID: String
}

/// Remembers which windows Accessibility has positively contradicted, keyed to the process
/// that owned them at the time.
///
/// The verdict has to outlive the moment that produced it: AX can only contradict a window
/// while its own desktop is showing, so a judgement scoped to that instant is re-admitted by
/// the Core Graphics heuristic as soon as the user switches desktops. The window server
/// recycles IDs, so the owner is half the key — the same ID under a different process is a
/// different window and must not inherit this verdict.
///
/// `clear` is what stops a lasting refusal from becoming a permanent loss: the entry is
/// dropped as soon as AX does name the window, so a misreport heals itself.
struct AXContradictionRegistry {
    private var owners: [CGWindowID: AXContradictionRecord] = [:]

    var windowIDs: Set<CGWindowID> { Set(owners.keys) }

    var records: [AXContradictionRecord] { Array(owners.values) }

    init() {}

    /// Restores verdicts written by an earlier run of Debut. A window ID and a PID both mean
    /// nothing on their own across a relaunch — macOS reissues them from low numbers — so a
    /// record is only honoured while the PID it names is still running the app it named.
    init(records: [AXContradictionRecord], runningBundleIDsByPID: [pid_t: String]) {
        owners = Dictionary(
            uniqueKeysWithValues: records
                .filter { runningBundleIDsByPID[$0.ownerPID] == $0.ownerBundleID }
                .map { ($0.windowID, $0) }
        )
    }

    mutating func record(windowID: CGWindowID, owner: pid_t, bundleID: String) {
        owners[windowID] = AXContradictionRecord(
            windowID: windowID, ownerPID: owner, ownerBundleID: bundleID
        )
    }

    mutating func clear(windowIDs: some Sequence<CGWindowID>) {
        for windowID in windowIDs { owners.removeValue(forKey: windowID) }
    }

    /// Drops verdicts belonging to processes that are gone, so the table cannot grow without
    /// bound across a long session of app restarts.
    mutating func retainOnly(owners liveOwners: Set<pid_t>) {
        owners = owners.filter { liveOwners.contains($0.value.ownerPID) }
    }

    func refuses(windowID: CGWindowID, owner: pid_t) -> Bool {
        owners[windowID]?.ownerPID == owner
    }
}

public final class AccessibilityWindowService: WindowService, @unchecked Sendable {
    private let windowCaptureEnabled: Bool

    /// Supplies the AX element for a window without cross-process lookup. `WindowDiscoveryService`
    /// already holds one per armed window, so wiring this turns a raise from a walk of every
    /// running app's window list into a dictionary read.
    public var windowElementResolver: ((CGWindowID) -> AXUIElement?)?

    /// Replaces the running-app scan in tests. Production leaves this nil.
    var elementScanOverride: ((CGWindowID) -> AXUIElement?)?

    /// Where a window's desktop comes from. `kAXWindows` only reports windows on the active
    /// Space, so an AX-unknown window on another desktop still needs a way to resolve to
    /// exactly one desktop before the CG heuristic in `listWindows()` will trust it.
    public var spaceSwitcher: (any SpaceSwitching)?

    private let contradictionLock = NSLock()
    private var contradictions = AXContradictionRegistry()

    /// The verdicts worth carrying to the next launch, and the ones a previous launch left.
    /// Without this the dormant assignment for a ghost outlives the reason it was parked, and
    /// the startup reconcile restores the ghost before AX ever gets a chance to object again.
    var contradictionRecords: [AXContradictionRecord] {
        contradictionLock.withLock { contradictions.records }
    }

    func restoreContradictions(
        _ records: [AXContradictionRecord],
        runningBundleIDsByPID: [pid_t: String]
    ) {
        contradictionLock.withLock {
            contradictions = AXContradictionRegistry(
                records: records, runningBundleIDsByPID: runningBundleIDsByPID
            )
        }
    }

    public init(
        windowCaptureEnabled: Bool = ProcessInfo.processInfo.environment["DEBUT_DISABLE_WINDOW_PREVIEWS"] != "1"
    ) {
        self.windowCaptureEnabled = windowCaptureEnabled
    }

    // MARK: - App-level

    public func listRunningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular
            else { return nil }
            return AppInfo(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                pid: app.processIdentifier,
                isHidden: app.isHidden
            )
        }
    }

    public func activateApp(bundleID: String) -> Bool {
        guard let app = findApp(bundleID: bundleID) else { return false }
        return app.activate()
    }

    /// `terminate` sends the standard quit request, so an app with unsaved work still gets to
    /// put up its own save prompt.
    public func terminateApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.terminate()
    }

    public func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Window listing

    /// A window narrower or shorter than this is not a plausible standard window. Matches the
    /// 40px margin macOS always keeps visible via AX position clamping.
    private static let minimumPlausibleWindowDimension: CGFloat = 40

    public func listWindows() -> [WindowInfo] {
        let classification = classifyAXWindowIDs()

        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        let pidToBundleID: [pid_t: String] = Dictionary(
            runningApps.map { ($0.processIdentifier, $0.bundleIdentifier!) },
            uniquingKeysWith: { first, _ in first }
        )
        let pidToName: [pid_t: String] = Dictionary(
            runningApps.map { ($0.processIdentifier, $0.localizedName ?? $0.bundleIdentifier!) },
            uniquingKeysWith: { first, _ in first }
        )
        let regularPIDs = Set(runningApps.map(\.processIdentifier))

        // `kAXWindows` only reports windows on the active Space. This is what lets a window on
        // another desktop resolve to exactly one desktop even though AX has never seen it.
        let windowDesktops = (spaceSwitcher?.windowLocations() ?? [:]).mapValues(\.index)
        let showingDesktop = spaceSwitcher?.currentDesktopIndex()
        let corroboratedPIDs = Self.appPIDsWhoseAXAnswerCoversShowingDesktop(
            axWindowIDsByPID: classification.axWindowIDsByPID,
            windowDesktops: windowDesktops,
            showingDesktop: showingDesktop
        )
        let axNamedWindowIDs = classification.axWindowIDsByPID.values.reduce(into: Set<CGWindowID>()) {
            $0.formUnion($1)
        }

        // AX naming a window is the only thing that can overturn a contradiction, so drop
        // those entries first. A momentary misreport then costs one snapshot, not the window.
        contradictionLock.withLock {
            contradictions.clear(windowIDs: axNamedWindowIDs)
            contradictions.retainOnly(owners: regularPIDs)
        }

        var seen = Set<CGWindowID>()
        return infoList.compactMap { dict in
            guard let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID] as? pid_t,
                  let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat],
                  let bundleID = pidToBundleID[ownerPID]
            else { return nil }

            // A positive AX verdict is a reason to exclude; the absence of one is not — an app
            // still warming up, or a window on a Space that isn't showing, reports neither.
            guard !classification.untrackable.contains(windowID) else { return nil }
            guard seen.insert(windowID).inserted else { return nil }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if !classification.trackable.contains(windowID) {
                let windowDesktop = windowDesktops[windowID]
                guard Self.isPlausibleUntrackedWindow(
                    layer: dict[kCGWindowLayer] as? Int,
                    isRegularApp: regularPIDs.contains(ownerPID),
                    bounds: bounds,
                    hasResolvedDesktop: windowDesktop != nil
                ) else { return nil }
                if Self.accessibilityContradictsWindow(
                    isNamedByAX: axNamedWindowIDs.contains(windowID),
                    windowDesktop: windowDesktop,
                    showingDesktop: showingDesktop,
                    appAXAnswerCoversShowingDesktop: corroboratedPIDs.contains(ownerPID)
                ) {
                    contradictionLock.withLock {
                        contradictions.record(
                            windowID: windowID, owner: ownerPID, bundleID: bundleID
                        )
                    }
                    return nil
                }
                // The verdict was reached on a desktop that may no longer be showing, so
                // without this the heuristic re-admits the window as soon as the user
                // switches away from it.
                let remembered = contradictionLock.withLock {
                    contradictions.refuses(windowID: windowID, owner: ownerPID)
                }
                if remembered { return nil }
            }

            let title = dict[kCGWindowName] as? String ?? ""
            let isOnScreen = dict[kCGWindowIsOnscreen] as? Bool ?? true
            let ownerName = pidToName[ownerPID] ?? bundleID

            return WindowInfo(
                windowID: windowID,
                ownerBundleID: bundleID,
                ownerName: ownerName,
                ownerPID: ownerPID,
                title: title,
                bounds: bounds,
                isOnScreen: isOnScreen
            )
        }
    }

    /// Whether a window AX has not classified either way still looks like a standard window,
    /// judged purely from Core Graphics signals: on the normal window layer, owned by a regular
    /// (non-background) app, large enough to plausibly be user-facing, and resolvable to
    /// exactly one desktop rather than absent from the window server's Space bookkeeping.
    static func isPlausibleUntrackedWindow(
        layer: Int?,
        isRegularApp: Bool,
        bounds: CGRect,
        hasResolvedDesktop: Bool
    ) -> Bool {
        layer == 0
            && isRegularApp
            && hasResolvedDesktop
            && bounds.width >= minimumPlausibleWindowDimension
            && bounds.height >= minimumPlausibleWindowDimension
    }

    /// Whether Accessibility's silence about a window is a verdict rather than a blind spot.
    ///
    /// `kAXWindows` cannot see other desktops, which is why silence normally proves nothing and
    /// the Core Graphics heuristic exists at all. But when the window's own desktop is the one
    /// showing, and AX is demonstrably answering for its app, silence becomes a positive claim:
    /// AX enumerated that process and did not list this window. Measured across four desktops,
    /// 22 of 23 CG-plausible windows were named by AX on their own desktop; the one that was
    /// not is Chrome's dismissed omnibox popup.
    ///
    /// `appAXAnswerCoversShowingDesktop` is load-bearing rather than defensive. An app AX
    /// returns nothing for looks identical to an app with no real windows, and an app whose
    /// answer still describes the desktop being left looks identical to one that saw this
    /// desktop and declined — either would refuse real windows wholesale.
    static func accessibilityContradictsWindow(
        isNamedByAX: Bool = false,
        windowDesktop: Int?,
        showingDesktop: Int?,
        appAXAnswerCoversShowingDesktop: Bool
    ) -> Bool {
        guard !isNamedByAX,
              appAXAnswerCoversShowingDesktop,
              let windowDesktop,
              let showingDesktop
        else { return false }
        return windowDesktop == showingDesktop
    }

    /// Apps whose `kAXWindows` answer demonstrably describes the desktop now showing, because
    /// at least one window it named is on that desktop.
    ///
    /// Debut samples on the space-change notification, when the window server has already
    /// switched and AX has not. Without this the transition into a desktop reads AX's account
    /// of the desktop being left as silence about the one arriving.
    static func appPIDsWhoseAXAnswerCoversShowingDesktop(
        axWindowIDsByPID: [pid_t: Set<CGWindowID>],
        windowDesktops: [CGWindowID: Int],
        showingDesktop: Int?
    ) -> Set<pid_t> {
        guard let showingDesktop else { return [] }
        return Set(axWindowIDsByPID.compactMap { pid, windowIDs in
            windowIDs.contains { windowDesktops[$0] == showingDesktop } ? pid : nil
        })
    }

    /// Core Graphics signals that positively contradict a window being user-manageable.
    /// Deliberately not the inverse of `isPlausibleUntrackedWindow`: admission may refuse a
    /// window on ambiguous evidence, but eviction may not act on it. A window macOS places on
    /// no single desktop is unadmittable and yet perfectly real — that is what an all-Spaces
    /// or fullscreen window looks like — so only layer and size, which cannot be true of a
    /// window the user can manage, are grounds for parking one that is already assigned.
    static func isDisqualifiedWindow(layer: Int?, bounds: CGRect) -> Bool {
        guard let layer else { return false }
        return layer != 0
            || bounds.width < minimumPlausibleWindowDimension
            || bounds.height < minimumPlausibleWindowDimension
    }

    /// Assigned windows Accessibility now contradicts. Only windows on the desktop currently
    /// showing can appear here, so this necessarily says nothing about the rest.
    public func listAXContradictedWindowIDs() -> Set<CGWindowID> {
        guard let showingDesktop = spaceSwitcher?.currentDesktopIndex() else { return [] }
        let classification = classifyAXWindowIDs()
        let windowDesktops = (spaceSwitcher?.windowLocations() ?? [:]).mapValues(\.index)
        let corroboratedPIDs = Self.appPIDsWhoseAXAnswerCoversShowingDesktop(
            axWindowIDsByPID: classification.axWindowIDsByPID,
            windowDesktops: windowDesktops,
            showingDesktop: showingDesktop
        )
        let axNamedWindowIDs = classification.axWindowIDsByPID.values.reduce(into: Set<CGWindowID>()) {
            $0.formUnion($1)
        }
        contradictionLock.withLock {
            contradictions.clear(windowIDs: axNamedWindowIDs)
        }

        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[CFString: Any]]
        else { return [] }

        let pidToBundleID: [pid_t: String] = NSWorkspace.shared.runningApplications
            .reduce(into: [:]) { table, app in table[app.processIdentifier] = app.bundleIdentifier }

        var contradicted = Set<CGWindowID>()
        for dict in infoList {
            guard let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID] as? pid_t,
                  let bundleID = pidToBundleID[ownerPID],
                  !classification.trackable.contains(windowID),
                  Self.accessibilityContradictsWindow(
                      isNamedByAX: axNamedWindowIDs.contains(windowID),
                      windowDesktop: windowDesktops[windowID],
                      showingDesktop: showingDesktop,
                      appAXAnswerCoversShowingDesktop: corroboratedPIDs.contains(ownerPID)
                  )
            else { continue }
            contradicted.insert(windowID)
            contradictionLock.withLock {
                contradictions.record(windowID: windowID, owner: ownerPID, bundleID: bundleID)
            }
        }
        // Assignments made on another desktop have to be reclaimed too, and the evidence that
        // condemned them is only visible from the desktop that produced it.
        return contradicted.union(contradictionLock.withLock { contradictions.windowIDs })
    }

    /// Assigned windows Core Graphics now contradicts. Absence from this set is not a claim
    /// that a window is fine, only that nothing disproves it.
    public func listDisqualifiedWindowIDs() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[CFString: Any]]
        else { return [] }

        var disqualified = Set<CGWindowID>()
        for dict in infoList {
            guard let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat]
            else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            if Self.isDisqualifiedWindow(layer: dict[kCGWindowLayer] as? Int, bounds: bounds) {
                disqualified.insert(windowID)
            }
        }
        return disqualified
    }

    /// Returns window IDs that AX explicitly identifies as modal or auxiliary UI
    /// rather than user-manageable standard or non-modal dialog windows. This is
    /// separate from an omitted AX result, which may only mean that an app returned
    /// a partial snapshot.
    public func listUntrackableWindowIDs() -> Set<CGWindowID> {
        classifyAXWindowIDs().untrackable
    }

    /// Returns the unfiltered Core Graphics window IDs. Unlike the AX-filtered
    /// metadata list, this is suitable for confirming that a saved ID no longer
    /// exists. Nil means the system snapshot failed and must not drive removal.
    public func listAllWindowIDs() -> Set<CGWindowID>? {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }
        return Set(infoList.compactMap { $0[kCGWindowNumber] as? CGWindowID })
    }

    static func isTrackableAXWindow(role: String, subrole: String, isModal: Bool) -> Bool {
        role == kAXWindowRole as String &&
            (subrole == kAXStandardWindowSubrole as String ||
                subrole == kAXDialogSubrole as String) &&
            !isModal
    }

    /// Whether Accessibility positively identifies auxiliary UI. `AXUnknown` is not such an
    /// identification: several apps use it for real borderless viewer windows, so those must
    /// fall through to the same Core Graphics and SkyLight checks as an AX-unnamed window.
    static func isPositivelyUntrackableAXWindow(
        role: String,
        subrole: String,
        isModal: Bool
    ) -> Bool {
        guard role == kAXWindowRole as String else { return true }
        guard !isModal else { return true }
        guard subrole != kAXUnknownSubrole as String else { return false }
        return !isTrackableAXWindow(role: role, subrole: subrole, isModal: isModal)
    }

    private func classifyAXWindowIDs() -> (
        trackable: Set<CGWindowID>,
        untrackable: Set<CGWindowID>,
        axWindowIDsByPID: [pid_t: Set<CGWindowID>]
    ) {
        var trackable = Set<CGWindowID>()
        var untrackable = Set<CGWindowID>()
        var axWindowIDsByPID: [pid_t: Set<CGWindowID>] = [:]
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        for app in runningApps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
            guard result == .success, let axWindows = windowsRef as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                guard let role = stringAttribute(kAXRoleAttribute, of: axWindow),
                      let subrole = stringAttribute(kAXSubroleAttribute, of: axWindow)
                else { continue }

                var cgWindowID: CGWindowID = 0
                guard _AXUIElementGetWindow(axWindow, &cgWindowID) == .success,
                      cgWindowID != 0
                else { continue }

                axWindowIDsByPID[app.processIdentifier, default: []].insert(cgWindowID)
                let isModal = boolAttribute(kAXModalAttribute, of: axWindow) ?? false
                if Self.isTrackableAXWindow(role: role, subrole: subrole, isModal: isModal) {
                    trackable.insert(cgWindowID)
                } else if Self.isPositivelyUntrackableAXWindow(
                    role: role,
                    subrole: subrole,
                    isModal: isModal
                ) {
                    untrackable.insert(cgWindowID)
                }
            }
        }
        return (trackable, untrackable, axWindowIDsByPID)
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    // MARK: - Window capture

    public func captureWindowImages(
        windowIDs: [CGWindowID],
        onEnumerated: @escaping @Sendable ([CGWindowID]) -> Void,
        onCapture: @escaping @Sendable (WindowImageCapture) -> Void
    ) async {
        guard windowCaptureEnabled, !windowIDs.isEmpty else { return }

        let content: SCShareableContent
        do {
            content = try await ShareableContent.shared.value().content
        } catch {
            DiagnosticReporter.shared.report("window_preview_enumeration_failed", details: [
                "error": "\(error)",
                "requestedCount": "\(windowIDs.count)",
            ])
            return
        }

        let requestedWindowIDs = Set(windowIDs)
        let windows = content.windows
            .filter { requestedWindowIDs.contains($0.windowID) }
            .map(SendableCaptureWindow.init)
        onEnumerated(windows.map(\.window.windowID))
        // Durable: this is the boundary between the shared enumeration wait and
        // the captures, and a stall on either side is only diagnosable from a
        // log that survived the session it happened in.
        DiagnosticReporter.shared.report("window_preview_capture_started", details: [
            "matchedCount": "\(windows.count)",
            "requestedCount": "\(windowIDs.count)",
            "shareableCount": "\(content.windows.count)",
        ])

        await withTaskGroup(of: WindowImageCapture?.self) { group in
            for captureWindow in windows {
                group.addTask { [captureWindow] in
                    let window = captureWindow.window
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let configuration = SCStreamConfiguration()
                    let pixelSize = PreviewCaptureSize.pixelSize(
                        contentSize: filter.contentRect.size,
                        pointPixelScale: CGFloat(filter.pointPixelScale)
                    )
                    configuration.width = pixelSize.width
                    configuration.height = pixelSize.height
                    configuration.showsCursor = false
                    configuration.captureResolution = .best

                    do {
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: filter,
                            configuration: configuration
                        )
                        return WindowImageCapture(windowID: window.windowID, image: image)
                    } catch {
                        DiagnosticReporter.shared.report("window_preview_capture_failed", details: [
                            "error": "\(error)",
                            "windowID": "\(window.windowID)",
                        ])
                        return nil
                    }
                }
            }

            for await capture in group {
                if let capture { onCapture(capture) }
            }
        }
    }

    // MARK: - Window raise

    public func raiseWindow(windowID: CGWindowID) -> Bool {
        guard let axWindow = resolveWindowElement(for: windowID) else { return false }
        return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
    }

    /// Presses the window's native close button without terminating its owning app. Apps may not
    /// expose a close button (or may reject the press), so the result is reported to the caller
    /// rather than changing Debut's assignment until lifecycle reconciliation confirms the close.
    public func closeWindow(windowID: CGWindowID) -> Bool {
        guard let axWindow = resolveWindowElement(for: windowID) else { return false }
        var closeButtonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axWindow,
            kAXCloseButtonAttribute as CFString,
            &closeButtonRef
        ) == .success, let closeButtonRef else { return false }
        let closeButton = closeButtonRef as! AXUIElement
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    // MARK: - AX-CG bridge

    /// Windows discovered outside the tracking paths have no cached element, so the scan stays
    /// as the fallback rather than the default.
    private func resolveWindowElement(for windowID: CGWindowID) -> AXUIElement? {
        if let resolved = windowElementResolver?(windowID) { return resolved }
        if let scanOverride = elementScanOverride { return scanOverride(windowID) }
        return axWindowElement(for: windowID)
    }

    private func axWindowElement(for targetWindowID: CGWindowID) -> AXUIElement? {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        for app in runningApps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
            guard result == .success, let axWindows = windowsRef as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                var cgWindowID: CGWindowID = 0
                let err = _AXUIElementGetWindow(axWindow, &cgWindowID)
                if err == .success && cgWindowID == targetWindowID {
                    return axWindow
                }
            }
        }
        return nil
    }

    private func findApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
}
