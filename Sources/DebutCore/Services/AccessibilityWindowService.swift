import AppKit
import ApplicationServices
import AXPrivate

public final class AccessibilityWindowService: WindowService, @unchecked Sendable {
    public init() {}

    public func listWindows() -> [WindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [WindowInfo] = []
        for entry in windowList {
            guard let windowID = entry[kCGWindowNumber as String] as? Int,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            let app = NSRunningApplication(processIdentifier: ownerPID)
            let bundleID = app?.bundleIdentifier ?? ""
            let appName = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = entry[kCGWindowName as String] as? String ?? ""

            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )

            guard !bundleID.isEmpty else { continue }

            let info = WindowInfo(
                windowID: windowID,
                appBundleID: bundleID,
                appName: appName,
                title: title,
                frame: frame,
                isMinimized: false,
                ownerPID: ownerPID
            )
            result.append(info)
        }
        return result
    }

    public func hideWindow(windowID: Int) -> Bool {
        guard let (app, element) = findAXWindow(windowID: windowID) else { return false }
        _ = app
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    public func showWindow(windowID: Int) -> Bool {
        guard let (app, element) = findAXWindow(windowID: windowID) else { return false }
        let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if result == .success {
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        return result == .success
    }

    public func focusWindow(windowID: Int) -> Bool {
        guard let (app, element) = findAXWindow(windowID: windowID) else { return false }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let focused = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return raised == .success || focused == .success
    }

    public func closeWindow(windowID: Int) -> Bool {
        guard let (_, element) = findAXWindow(windowID: windowID) else { return false }

        var closeButtonRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButtonRef)
        guard err == .success, let closeButton = closeButtonRef else { return false }

        let button = closeButton as! AXUIElement
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    public func getWindowFrame(windowID: Int) -> CGRect? {
        guard let (_, element) = findAXWindow(windowID: windowID) else { return nil }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    public func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Private

    private func findAXWindow(windowID: Int) -> (app: AXUIElement, window: AXUIElement)? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        guard let entry = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowID }),
              let pid = entry[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else { return nil }

        for axWindow in axWindows {
            var cgWindowID: CGWindowID = 0
            _AXUIElementGetWindow(axWindow, &cgWindowID)
            if Int(cgWindowID) == windowID {
                return (appElement, axWindow)
            }
        }

        return nil
    }
}
