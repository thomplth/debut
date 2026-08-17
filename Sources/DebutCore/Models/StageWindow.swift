import Foundation
import CoreGraphics

public struct StageWindow: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var windowID: CGWindowID
    public let ownerBundleID: String
    public let ownerName: String
    public var windowTitle: String
    public var ownerPID: pid_t?

    public init(windowID: CGWindowID, ownerBundleID: String, ownerName: String, windowTitle: String, ownerPID: pid_t? = nil) {
        self.id = UUID()
        self.windowID = windowID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.ownerPID = ownerPID
    }

    public static func == (lhs: StageWindow, rhs: StageWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }
}
