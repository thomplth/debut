import Foundation
import CoreGraphics

public struct Stage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public private(set) var windows: [StageWindow]

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.windows = []
    }

    public var windowIDs: Set<CGWindowID> {
        Set(windows.map(\.windowID))
    }

    public mutating func addWindow(_ window: StageWindow) {
        guard !windows.contains(where: { $0.windowID == window.windowID }) else { return }
        windows.append(window)
    }

    public mutating func removeWindow(windowID: CGWindowID) {
        windows.removeAll { $0.windowID == windowID }
    }

    public mutating func removeAllWindows(forBundleID bundleID: String) {
        windows.removeAll { $0.ownerBundleID == bundleID }
    }

    public mutating func markShared(windowID: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.windowID == windowID }) else { return }
        windows[index].isShared = true
    }

    public mutating func updateWindow(at index: Int, windowID: CGWindowID, ownerPID: pid_t?) {
        guard windows.indices.contains(index) else { return }
        windows[index].windowID = windowID
        windows[index].ownerPID = ownerPID
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
