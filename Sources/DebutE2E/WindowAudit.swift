import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics
import DebutCore
import Foundation

/// Read-only comparison of the three window sources Debut relies on: Accessibility's
/// per-app `kAXWindows`, Core Graphics' window list, and SkyLight's per-desktop
/// enumeration. Discovery admits a window from CG when AX has no opinion, so the
/// disagreements between these three are what decide whether a window is tracked,
/// classified as auxiliary, or resurrected after it was destroyed.
enum WindowAudit {
    private struct AXFacts {
        let role: String
        let subrole: String
        let modal: Bool
    }

    static func run(samples: Int, interval: TimeInterval, bundleFilter: String?) {
        let spaceService = SpaceService()
        for sample in 0..<max(1, samples) {
            emit(sample: sample, spaceService: spaceService, bundleFilter: bundleFilter)
            if sample + 1 < samples { Thread.sleep(forTimeInterval: interval) }
        }
    }

    private static func emit(sample: Int, spaceService: SpaceService, bundleFilter: String?) {
        let axFacts = accessibilityFacts()
        let cgWindows = coreGraphicsWindows()
        let locations = spaceService.windowLocations()
        let activeDesktop = spaceService.currentDesktopIndex().map(String.init) ?? "-"

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        let pidToBundle = Dictionary(
            apps.map { ($0.processIdentifier, $0.bundleIdentifier!) },
            uniquingKeysWith: { first, _ in first }
        )
        let regularPIDs = Set(apps.map(\.processIdentifier))

        let allIDs = Set(cgWindows.keys)
            .union(axFacts.keys)
            .union(locations.keys)

        print("SAMPLE \(sample) at=\(Date().timeIntervalSince1970) activeDesktop=\(activeDesktop) " +
              "cg=\(cgWindows.count) ax=\(axFacts.count) sls=\(locations.count) " +
              "axTrusted=\(AXIsProcessTrusted())")
        for line in accessibilityPerApp() { print("AXAPP \(line)") }

        for id in allIDs.sorted() {
            let cg = cgWindows[id]
            let pid = cg?.pid
            let bundle = pid.flatMap { pidToBundle[$0] } ?? "-"
            if let bundleFilter, !bundle.localizedCaseInsensitiveContains(bundleFilter) { continue }
            // A window absent from CG has no owner to attribute, so unfiltered runs still
            // show it; a filtered run cannot, which is why the filter is opt-in.
            let ax = axFacts[id]
            let location = locations[id]
            let inCG = cg != nil ? 1 : 0
            let inAX = ax != nil ? 1 : 0
            let inSLS = location != nil ? 1 : 0
            let trackable = ax.map {
                AccessibilityWindowServiceProbe.isTrackable(
                    role: $0.role, subrole: $0.subrole, isModal: $0.modal
                ) ? 1 : 0
            }.map(String.init) ?? "-"
            let plausible: String
            if let cg {
                plausible = AccessibilityWindowServiceProbe.isPlausibleUntracked(
                    layer: cg.layer,
                    isRegularApp: regularPIDs.contains(cg.pid),
                    bounds: cg.bounds,
                    hasResolvedDesktop: location != nil
                ) ? "1" : "0"
            } else {
                plausible = "-"
            }
            // `admitted` is exactly what `listWindows()` would return for this window.
            let admitted: String
            if let cg, pidToBundle[cg.pid] != nil {
                if let ax, !AccessibilityWindowServiceProbe.isTrackable(
                    role: ax.role, subrole: ax.subrole, isModal: ax.modal
                ) {
                    admitted = "0"          // AX says auxiliary
                } else if ax != nil {
                    admitted = "1"          // AX says standard
                } else {
                    admitted = plausible    // no AX opinion: CG heuristic decides
                }
            } else {
                admitted = "0"
            }

            print("WIN id=\(id) pid=\(pid.map(String.init) ?? "-") bundle=\(bundle) " +
                  "cg=\(inCG) ax=\(inAX) sls=\(inSLS) desk=\(location?.index.description ?? "-") " +
                  "layer=\(cg?.layer.description ?? "-") " +
                  "size=\(Int(cg?.bounds.width ?? 0))x\(Int(cg?.bounds.height ?? 0)) " +
                  "role=\(ax?.role ?? "-") subrole=\(ax?.subrole ?? "-") " +
                  "modal=\(ax.map { $0.modal ? 1 : 0 }.map(String.init) ?? "-") " +
                  "trackable=\(trackable) plausible=\(plausible) admitted=\(admitted) " +
                  "title=\(quoted(cg?.title ?? ""))")
        }
        print("ENDSAMPLE \(sample)")
        fflush(stdout)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "'").prefix(60) + "\""
    }

    // MARK: - Sources

    private struct CGFacts {
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
        let title: String
    }

    private static func coreGraphicsWindows() -> [CGWindowID: CGFacts] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]]
        else { return [:] }
        var result: [CGWindowID: CGFacts] = [:]
        for dict in list {
            guard let id = dict[kCGWindowNumber] as? CGWindowID,
                  let pid = dict[kCGWindowOwnerPID] as? pid_t,
                  let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat]
            else { continue }
            result[id] = CGFacts(
                pid: pid,
                layer: dict[kCGWindowLayer] as? Int ?? -1,
                bounds: CGRect(
                    x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
                ),
                title: dict[kCGWindowName] as? String ?? ""
            )
        }
        return result
    }

    /// Per-app `kAXWindows` outcome, so an empty AX picture can be told apart from a denied one.
    private static func accessibilityPerApp() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(
                    axApp, kAXWindowsAttribute as CFString, &windowsRef
                )
                let count = (windowsRef as? [AXUIElement])?.count ?? -1
                return "bundle=\(app.bundleIdentifier ?? "-") pid=\(app.processIdentifier) " +
                       "axError=\(error.rawValue) axWindows=\(count)"
            }
    }

    private static func accessibilityFacts() -> [CGWindowID: AXFacts] {
        var result: [CGWindowID: AXFacts] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &windowsRef
            ) == .success, let axWindows = windowsRef as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(axWindow, &id) == .success, id != 0 else { continue }
                result[id] = AXFacts(
                    role: string(kAXRoleAttribute, axWindow) ?? "?",
                    subrole: string(kAXSubroleAttribute, axWindow) ?? "?",
                    modal: bool(kAXModalAttribute, axWindow) ?? false
                )
            }
        }
        return result
    }

    private static func string(_ attribute: String, _ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func bool(_ attribute: String, _ element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }
}

/// Mirrors the two decision rules in `AccessibilityWindowService` so the audit reports what
/// discovery would actually do. Kept here rather than exported from DebutCore, since these
/// are internal policy and the audit is a diagnostic, not a caller.
enum AccessibilityWindowServiceProbe {
    static func isTrackable(role: String, subrole: String, isModal: Bool) -> Bool {
        role == kAXWindowRole as String &&
            (subrole == kAXStandardWindowSubrole as String ||
                subrole == kAXDialogSubrole as String) &&
            !isModal
    }

    static func isPlausibleUntracked(
        layer: Int, isRegularApp: Bool, bounds: CGRect, hasResolvedDesktop: Bool
    ) -> Bool {
        layer == 0 && isRegularApp && hasResolvedDesktop
            && bounds.width >= 40 && bounds.height >= 40
    }
}
