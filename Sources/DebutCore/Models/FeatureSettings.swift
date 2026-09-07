import Foundation

/// Shared by setup, Settings and the event tap. New interception stays opt-in on upgrade.
public struct FeatureSettings: Codable, Equatable, Sendable {
    public var windowPreviews = true
    public var workspaceIsolation = true
    public var numberShortcuts = true
    public var controlArrows = false
    public var trackpadSwipes = false
    public init() {}
}
