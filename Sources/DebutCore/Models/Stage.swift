import Foundation

public struct Stage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public private(set) var apps: [StageApp]

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.apps = []
    }

    public var appBundleIDs: Set<String> {
        Set(apps.map(\.bundleID))
    }

    public mutating func addApp(_ app: StageApp) {
        guard !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        apps.append(app)
    }

    public mutating func removeApp(bundleID: String) {
        apps.removeAll { $0.bundleID == bundleID }
    }

    public mutating func markShared(bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        apps[index].isShared = true
    }

    public mutating func bringAppToFront(bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        let app = apps.remove(at: index)
        apps.insert(app, at: 0)
    }

    public static func == (lhs: Stage, rhs: Stage) -> Bool {
        lhs.id == rhs.id
    }
}
