import Foundation

public struct Stage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public private(set) var windows: [StageWindow]

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.windows = []
    }

    public var appBundleIDs: Set<String> {
        Set(windows.map(\.appBundleID))
    }

    public mutating func addWindow(_ window: StageWindow) {
        guard !windows.contains(where: { $0.windowID == window.windowID }) else { return }
        windows.append(window)
    }

    public mutating func removeWindow(byID windowID: Int) {
        windows.removeAll { $0.windowID == windowID }
    }

    public static func == (lhs: Stage, rhs: Stage) -> Bool {
        lhs.id == rhs.id
    }
}
