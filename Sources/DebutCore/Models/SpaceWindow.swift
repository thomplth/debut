import Foundation
import CoreGraphics

/// A live window paired with the space holding it, for consumers that flatten every space into
/// one list and so cannot use a space-relative index to say which window they mean.
public struct GlobalWindowEntry: Equatable, Sendable {
    public let spaceID: UUID
    public let window: SpaceWindow

    public init(spaceID: UUID, window: SpaceWindow) {
        self.spaceID = spaceID
        self.window = window
    }
}

public struct SpaceWindow: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var windowID: CGWindowID
    public let ownerBundleID: String
    public let ownerName: String
    public var windowTitle: String
    public var ownerPID: pid_t?

    /// When this window was last brought to the front of its space, or `nil` if it never has
    /// been. Written only by `Space.bringWindowToFront`, which is also what rotates the space's
    /// array — so an ordering derived from this field across spaces cannot disagree with any
    /// one space's own MRU order.
    public var lastActivatedAt: Date?

    public init(windowID: CGWindowID, ownerBundleID: String, ownerName: String, windowTitle: String, ownerPID: pid_t? = nil, lastActivatedAt: Date? = nil) {
        self.id = UUID()
        self.windowID = windowID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.ownerPID = ownerPID
        self.lastActivatedAt = lastActivatedAt
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
