import Foundation

public final class MockWindowService: WindowService, @unchecked Sendable {
    public var windows: [WindowInfo] = []
    public var hiddenWindowIDs: Set<Int> = []
    public var focusedWindowID: Int?
    public var closedWindowIDs: Set<Int> = []
    public var accessibilityEnabled: Bool = true
    public var closeWillFail: Set<Int> = []

    public init() {}

    public func listWindows() -> [WindowInfo] {
        windows.filter { !closedWindowIDs.contains($0.windowID) }
    }

    public func hideWindow(windowID: Int) -> Bool {
        hiddenWindowIDs.insert(windowID)
        return true
    }

    public func showWindow(windowID: Int) -> Bool {
        hiddenWindowIDs.remove(windowID)
        return true
    }

    public func focusWindow(windowID: Int) -> Bool {
        focusedWindowID = windowID
        hiddenWindowIDs.remove(windowID)
        return true
    }

    public func closeWindow(windowID: Int) -> Bool {
        if closeWillFail.contains(windowID) { return false }
        closedWindowIDs.insert(windowID)
        return true
    }

    public func getWindowFrame(windowID: Int) -> CGRect? {
        windows.first(where: { $0.windowID == windowID })?.frame
    }

    public func isAccessibilityEnabled() -> Bool {
        accessibilityEnabled
    }
}
