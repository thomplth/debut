import Foundation
import CoreGraphics

public struct Stage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public private(set) var windows: [StageWindow]

    public init() {
        self.id = UUID()
        self.windows = []
    }

    public var windowIDs: Set<CGWindowID> {
        Set(windows.map(\.windowID))
    }

    public mutating func addWindow(_ window: StageWindow) {
        guard !windows.contains(where: { $0.windowID == window.windowID }) else { return }
        windows.append(window)
    }

    public mutating func insertWindow(_ window: StageWindow, at index: Int) {
        guard !windows.contains(where: { $0.windowID == window.windowID }) else { return }
        windows.insert(window, at: min(max(index, 0), windows.count))
    }

    public mutating func removeWindow(windowID: CGWindowID) {
        windows.removeAll { $0.windowID == windowID }
    }

    public mutating func removeAllWindows(forBundleID bundleID: String) {
        windows.removeAll { $0.ownerBundleID == bundleID }
    }

    @discardableResult
    public mutating func removeAllWindows(forOwnerPID ownerPID: pid_t) -> Int {
        let previousCount = windows.count
        windows.removeAll { $0.ownerPID == ownerPID }
        return previousCount - windows.count
    }

    public mutating func updateWindow(at index: Int, windowID: CGWindowID, ownerPID: pid_t?, windowTitle: String? = nil) {
        guard windows.indices.contains(index) else { return }
        windows[index].windowID = windowID
        windows[index].ownerPID = ownerPID
        if let windowTitle { windows[index].windowTitle = windowTitle }
    }

    public mutating func updateWindowTitle(at index: Int, title: String) {
        guard windows.indices.contains(index) else { return }
        windows[index].windowTitle = title
    }

    public mutating func bringWindowToFront(windowID: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.windowID == windowID }) else { return }
        let window = windows.remove(at: index)
        windows.insert(window, at: 0)
    }

    public static func == (lhs: Stage, rhs: Stage) -> Bool {
        lhs.id == rhs.id
    }
}
