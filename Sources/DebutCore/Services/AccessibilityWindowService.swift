import AppKit
import ApplicationServices
import AXPrivate
import CoreGraphics
import ScreenCaptureKit

private struct SendableCaptureWindow: @unchecked Sendable {
    let window: SCWindow
}

public final class AccessibilityWindowService: WindowService, @unchecked Sendable {
    private let windowCaptureEnabled: Bool

    /// Supplies the AX element for a window without cross-process lookup. `WindowDiscoveryService`
    /// already holds one per armed window, so wiring this turns a raise from a walk of every
    /// running app's window list into a dictionary read.
    public var windowElementResolver: ((CGWindowID) -> AXUIElement?)?

    /// Replaces the running-app scan in tests. Production leaves this nil.
    var elementScanOverride: ((CGWindowID) -> AXUIElement?)?

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

    public func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Window listing

    public func listWindows() -> [WindowInfo] {
        let trackableWindowIDs = classifyAXWindowIDs().trackable

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

            guard trackableWindowIDs.contains(windowID) else { return nil }
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

    private func classifyAXWindowIDs() -> (trackable: Set<CGWindowID>, untrackable: Set<CGWindowID>) {
        var trackable = Set<CGWindowID>()
        var untrackable = Set<CGWindowID>()
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

                let isModal = boolAttribute(kAXModalAttribute, of: axWindow) ?? false
                if Self.isTrackableAXWindow(role: role, subrole: subrole, isModal: isModal) {
                    trackable.insert(cgWindowID)
                } else {
                    untrackable.insert(cgWindowID)
                }
            }
        }
        return (trackable, untrackable)
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
