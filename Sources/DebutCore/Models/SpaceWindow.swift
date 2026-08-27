import Foundation
import CoreGraphics

public struct SpaceWindow: Codable, Identifiable, Equatable, Sendable {
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

    public static func == (lhs: SpaceWindow, rhs: SpaceWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }

    public var displayTitle: String {
        Self.displayTitle(windowTitle: windowTitle, ownerName: ownerName)
    }

    /// The label anything presenting this window puts on it. `windowTitle` is empty whenever
    /// macOS withholds `kCGWindowName`, which it does for every window until Debut holds Screen
    /// Recording permission — so the fallback is routine, not an edge case. Every consumer
    /// resolves the label here, so a card and a diagnostic describing that card cannot disagree
    /// about what it is called.
    public static func displayTitle(windowTitle: String, ownerName: String) -> String {
        windowTitle.isEmpty ? ownerName : windowTitle
    }
}
