import Foundation

/// Shared by setup, Settings and the event tap.
public struct FeatureSettings: Codable, Equatable, Sendable {
    public var windowPreviews = true
    public var workspaceIsolation = true
    public var fasterDesktopSwitching = true {
        didSet {
            if !fasterDesktopSwitching { disableDesktopOverrides() }
        }
    }
    public var numberShortcuts = true
    public var controlArrows = true
    public var trackpadSwipes = true
    public init() {}

    public mutating func setFasterDesktopSwitching(_ enabled: Bool) {
        fasterDesktopSwitching = enabled
    }

    public mutating func normalizeDesktopOverrides() {
        if !fasterDesktopSwitching { disableDesktopOverrides() }
    }

    private mutating func disableDesktopOverrides() {
        numberShortcuts = false
        controlArrows = false
        trackpadSwipes = false
    }

    private enum CodingKeys: String, CodingKey {
        case windowPreviews
        case workspaceIsolation
        case fasterDesktopSwitching
        case numberShortcuts
        case controlArrows
        case trackpadSwipes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowPreviews = try container.decodeIfPresent(Bool.self, forKey: .windowPreviews) ?? true
        workspaceIsolation = try container.decodeIfPresent(
            Bool.self,
            forKey: .workspaceIsolation
        ) ?? true
        fasterDesktopSwitching = try container.decodeIfPresent(
            Bool.self,
            forKey: .fasterDesktopSwitching
        ) ?? true
        numberShortcuts = try container.decodeIfPresent(Bool.self, forKey: .numberShortcuts) ?? true
        controlArrows = try container.decodeIfPresent(Bool.self, forKey: .controlArrows) ?? true
        trackpadSwipes = try container.decodeIfPresent(Bool.self, forKey: .trackpadSwipes) ?? true
        normalizeDesktopOverrides()
    }
}
