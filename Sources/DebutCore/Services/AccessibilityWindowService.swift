import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics
import ScreenCaptureKit
import Security

private struct SendableCaptureWindow: @unchecked Sendable {
    let window: SCWindow
}

private struct ResolvedRunningApplication {
    let application: NSRunningApplication
    let bundleID: String
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

    private let ownWindowLock = NSLock()
    private var consentedOwnWindowIDs: Set<CGWindowID> = []

    /// Admits or withdraws one of Debut's own windows. As a regular application Debut is
    /// enumerated like any other app, so without consent the overlay — which joins every Space —
    /// would be managed as a window and render inside itself.
    public func setOwnWindowConsent(_ consented: Bool, windowID: CGWindowID) {
        ownWindowLock.withLock {
            if consented {
                consentedOwnWindowIDs.insert(windowID)
            } else {
                consentedOwnWindowIDs.remove(windowID)
            }
        }
    }

    static func admitsWindow(
        windowID: CGWindowID,
        ownerPID: pid_t,
        currentPID: pid_t,
        consentedOwnWindowIDs: Set<CGWindowID>
    ) -> Bool {
        ownerPID != currentPID || consentedOwnWindowIDs.contains(windowID)
    }

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
        resolvedRunningApplications().map { resolved in
            let app = resolved.application
            return AppInfo(
                bundleID: resolved.bundleID,
                name: app.localizedName ?? resolved.bundleID,
                pid: app.processIdentifier,
                isHidden: app.isHidden
            )
        }
    }

    public func frontWindow(windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        FrontProcessManagement.front(windowID: windowID, ownerPID: ownerPID)
    }

    public func frontmostApplicationPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func activateApp(bundleID: String) -> Bool {
        guard let app = findApp(bundleID: bundleID) else { return false }
        return app.activate()
    }

    public func activateApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
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

        let runningApps = resolvedRunningApplications()
        let pidToBundleID: [pid_t: String] = Dictionary(
            runningApps.map { ($0.application.processIdentifier, $0.bundleID) },
            uniquingKeysWith: { first, _ in first }
        )
        let pidToName: [pid_t: String] = Dictionary(
            runningApps.map {
                ($0.application.processIdentifier, $0.application.localizedName ?? $0.bundleID)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let regularPIDs = Set(runningApps.map(\.application.processIdentifier))

        // `kAXWindows` only reports windows on the active Space. This is what lets a window on
        // another desktop resolve to exactly one desktop even though AX has never seen it.
        let windowDesktops = (spaceSwitcher?.windowLocations() ?? [:]).mapValues(\.index)
        let showingDesktop = spaceSwitcher?.currentDesktopIndex()
        let corroboratedPIDs = Self.appPIDsWhoseAXAnswerCoversShowingDesktop(
            axWindowIDsByPID: classification.axWindowIDsByPID,
            focusedWindowID: classification.focusedWindowID,
            focusedWindowPID: classification.focusedWindowPID,
            windowDesktops: windowDesktops,
            showingDesktop: showingDesktop
        )
        let axNamedWindowIDs = Self.confirmedAXWindowIDs(
            listedByPID: classification.axWindowIDsByPID,
            focusedWindowID: classification.focusedWindowID
        )

        // AX naming a window is the only thing that can overturn a contradiction, so drop
        // those entries first. A momentary misreport then costs one snapshot, not the window.
        contradictionLock.withLock {
            contradictions.clear(windowIDs: axNamedWindowIDs)
            contradictions.retainOnly(owners: regularPIDs)
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let consentedOwnWindowIDs = ownWindowLock.withLock { self.consentedOwnWindowIDs }
        let parentedWindowIDs = spaceSwitcher?.parentedWindowIDs(
            among: infoList.compactMap { $0[kCGWindowNumber] as? CGWindowID }
        ) ?? []

        var seen = Set<CGWindowID>()
        return infoList.compactMap { dict in
            guard let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID] as? pid_t,
                  let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat],
                  let bundleID = pidToBundleID[ownerPID]
            else { return nil }

            guard Self.admitsWindow(
                windowID: windowID,
                ownerPID: ownerPID,
                currentPID: currentPID,
                consentedOwnWindowIDs: consentedOwnWindowIDs
            ) else { return nil }

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
                    hasResolvedDesktop: windowDesktop != nil,
                    hasParentWindow: parentedWindowIDs.contains(windowID)
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
    ///
    /// Parentage is the only one of these a dismissed sheet or popup fails. Such a surface keeps
    /// its layer, size and desktop for as long as its app runs, so every other signal agrees it
    /// is a window and it is admitted as a duplicate card beside the window it was raised over.
    static func isPlausibleUntrackedWindow(
        layer: Int?,
        isRegularApp: Bool,
        bounds: CGRect,
        hasResolvedDesktop: Bool,
        hasParentWindow: Bool = false
    ) -> Bool {
        layer == 0
            && isRegularApp
            && hasResolvedDesktop
            && !hasParentWindow
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

    /// Apps whose Accessibility answer demonstrably describes the desktop now showing, because
    /// either `kAXWindows` or the direct `kAXFocusedWindow` answer names a window there.
    ///
    /// Debut samples on the space-change notification, when the window server has already
    /// switched and AX has not. Without the desktop check, the transition into a desktop reads
    /// AX's account of the desktop being left as silence about the one arriving. Dia adds the
    /// inverse wrinkle: its list can omit the focused browser window even while the direct
    /// focused-window attribute names it, so ignoring that answer admits its transient surfaces.
    static func appPIDsWhoseAXAnswerCoversShowingDesktop(
        axWindowIDsByPID: [pid_t: Set<CGWindowID>],
        focusedWindowID: CGWindowID? = nil,
        focusedWindowPID: pid_t? = nil,
        windowDesktops: [CGWindowID: Int],
        showingDesktop: Int?
    ) -> Set<pid_t> {
        guard let showingDesktop else { return [] }
        var confirmedWindowIDsByPID = axWindowIDsByPID
        if let focusedWindowID, let focusedWindowPID {
            confirmedWindowIDsByPID[focusedWindowPID, default: []].insert(focusedWindowID)
        }
        return Set(confirmedWindowIDsByPID.compactMap { pid, windowIDs in
            windowIDs.contains { windowDesktops[$0] == showingDesktop } ? pid : nil
        })
    }

    /// `kAXWindows` is allowed to return a partial presentation snapshot, but
    /// `kAXFocusedWindow` is a direct positive statement about one window. Dia has been
    /// observed omitting its focused browser window from the former while returning it from
    /// the latter, so both answers must clear or prevent an AX contradiction.
    static func confirmedAXWindowIDs(
        listedByPID: [pid_t: Set<CGWindowID>],
        focusedWindowID: CGWindowID?
    ) -> Set<CGWindowID> {
        var confirmed = listedByPID.values.reduce(into: Set<CGWindowID>()) {
            $0.formUnion($1)
        }
        if let focusedWindowID {
            confirmed.insert(focusedWindowID)
        }
        return confirmed
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
            focusedWindowID: classification.focusedWindowID,
            focusedWindowPID: classification.focusedWindowPID,
            windowDesktops: windowDesktops,
            showingDesktop: showingDesktop
        )
        let axNamedWindowIDs = Self.confirmedAXWindowIDs(
            listedByPID: classification.axWindowIDsByPID,
            focusedWindowID: classification.focusedWindowID
        )
        contradictionLock.withLock {
            contradictions.clear(windowIDs: axNamedWindowIDs)
        }

        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[CFString: Any]]
        else { return [] }

        let pidToBundleID: [pid_t: String] = Dictionary(
            resolvedRunningApplications().map {
                ($0.application.processIdentifier, $0.bundleID)
            },
            uniquingKeysWith: { first, _ in first }
        )

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

    /// Assigned windows the window server attaches to another window.
    ///
    /// A dismissed sheet or popup keeps a layer-0 surface on a resolved desktop for as long as
    /// its app runs, so the Core Graphics and Accessibility channels both miss it: nothing about
    /// it degrades, and AX can only contradict it while its own desktop is showing. Parentage is
    /// a positive statement readable from any desktop, which is what closes that gap.
    public func listParentedWindowIDs() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[CFString: Any]]
        else { return [] }
        return spaceSwitcher?.parentedWindowIDs(
            among: infoList.compactMap { $0[kCGWindowNumber] as? CGWindowID }
        ) ?? []
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

    /// A bundleless foreground process may still be code owned by a running host app. Wine
    /// child executables launched by CrossOver are the measured case: Launch Services reports
    /// no bundle ID, while their signature identifier is
    /// `com.codeweavers.CrossOver.wineloader`. Require a whole identifier component and pick
    /// the longest running match so a broad vendor prefix cannot steal a more specific host.
    static func hostBundleID(
        forSigningIdentifier signingIdentifier: String?,
        among runningBundleIDs: some Sequence<String>
    ) -> String? {
        guard let signingIdentifier, !signingIdentifier.isEmpty else { return nil }
        return runningBundleIDs
            .filter {
                signingIdentifier == $0 || signingIdentifier.hasPrefix($0 + ".")
            }
            .max { $0.count < $1.count }
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
        axWindowIDsByPID: [pid_t: Set<CGWindowID>],
        focusedWindowID: CGWindowID?,
        focusedWindowPID: pid_t?
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
        let focusedWindowID: CGWindowID?
        let focusedWindowPID: pid_t?
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            focusedWindowID = self.focusedWindowID(for: frontmost.processIdentifier)
            focusedWindowPID = focusedWindowID == nil ? nil : frontmost.processIdentifier
        } else {
            focusedWindowID = nil
            focusedWindowPID = nil
        }
        return (
            trackable,
            untrackable,
            axWindowIDsByPID,
            focusedWindowID,
            focusedWindowPID
        )
    }

    private func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef
        else { return nil }

        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow((focusedRef as! AXUIElement), &windowID) == .success,
              windowID != 0
        else { return nil }
        return windowID
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

    /// Regular Launch Services applications with stable ownership. An ordinary app supplies
    /// its bundle ID directly. A bundleless hosted child is admitted only when its signed code
    /// identifier is namespaced beneath another regular app that is running right now.
    private func resolvedRunningApplications() -> [ResolvedRunningApplication] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        let directBundleIDs = Set(applications.compactMap(\.bundleIdentifier))
        return applications.compactMap { application in
            let bundleID = application.bundleIdentifier ?? Self.hostBundleID(
                forSigningIdentifier: Self.signingIdentifier(of: application),
                among: directBundleIDs
            )
            guard let bundleID else { return nil }
            return ResolvedRunningApplication(application: application, bundleID: bundleID)
        }
    }

    private static func signingIdentifier(of application: NSRunningApplication) -> String? {
        guard let executableURL = application.executableURL else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [CFString: Any]
        else { return nil }
        return dictionary[kSecCodeInfoIdentifier] as? String
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
