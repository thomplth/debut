import Foundation

public struct StageApp: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let bundleID: String
    public var name: String
    public var isShared: Bool
    public var pid: pid_t?

    public init(bundleID: String, name: String, isShared: Bool = false, pid: pid_t? = nil) {
        self.id = UUID()
        self.bundleID = bundleID
        self.name = name
        self.isShared = isShared
        self.pid = pid
    }

    public static func == (lhs: StageApp, rhs: StageApp) -> Bool {
        lhs.bundleID == rhs.bundleID
    }
}
