import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics

public final class AccessibilityWindowService: WindowService, @unchecked Sendable {
    public init() {}

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

    public func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Window listing

    public func listWindows() -> [WindowInfo] {
        let realWindowIDs = axWindowIDs()

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

        var seen = Set<CGWindowID>()
        return infoList.compactMap { dict in
            guard let windowID = dict[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID] as? pid_t,
                  let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat],
                  let bundleID = pidToBundleID[ownerPID]
            else { return nil }

            guard realWindowIDs.contains(windowID) else { return nil }
            guard seen.insert(windowID).inserted else { return nil }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

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

    private func axWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        for app in runningApps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
            guard result == .success, let axWindows = windowsRef as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                var cgWindowID: CGWindowID = 0
                if _AXUIElementGetWindow(axWindow, &cgWindowID) == .success {
                    ids.insert(cgWindowID)
                }
            }
        }
        return ids
    }

    // MARK: - Window capture

    public func captureWindowImage(windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, .boundsIgnoreFraming)
    }

    // MARK: - Window raise

    public func raiseWindow(windowID: CGWindowID) -> Bool {
        guard let axWindow = axWindowElement(for: windowID) else { return false }
        return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
    }

    // MARK: - AX-CG bridge

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
