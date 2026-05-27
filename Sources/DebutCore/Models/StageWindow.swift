import Foundation

public struct StageWindow: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let windowID: Int
    public let appBundleID: String
    public let appName: String
    public var isShared: Bool

    public init(windowID: Int, appBundleID: String, appName: String, isShared: Bool) {
        self.id = UUID()
        self.windowID = windowID
        self.appBundleID = appBundleID
        self.appName = appName
        self.isShared = isShared
    }

    public static func == (lhs: StageWindow, rhs: StageWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }
}
