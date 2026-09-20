import Foundation

/// Shared by setup, Settings and the event tap.
public struct FeatureSettings: Codable, Equatable, Sendable {
    public var windowPreviews = true
    public var workspaceIsolation = true
    public var numberShortcuts = true
    public var controlArrows = true
    public var trackpadSwipes = true
    public init() {}
}
