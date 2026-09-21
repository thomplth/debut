import Foundation

/// Shared by setup, Settings and the event tap.
public struct FeatureSettings: Codable, Equatable, Sendable {
    public var windowPreviews = true
    public var workspaceIsolation = true
    public var optionTab = true
    public var fasterDesktopSwitching = true
    public var numberShortcuts = true
    public var controlArrows = true
    public var trackpadSwipes = true
    public init() {}

    public var effectiveNumberShortcuts: Bool {
        fasterDesktopSwitching && numberShortcuts
    }

    public var effectiveControlArrows: Bool {
        fasterDesktopSwitching && controlArrows
    }

    public var effectiveTrackpadSwipes: Bool {
        fasterDesktopSwitching && trackpadSwipes
    }

    public mutating func setFasterDesktopSwitching(_ enabled: Bool) {
        fasterDesktopSwitching = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case windowPreviews
        case workspaceIsolation
        case optionTab
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
        optionTab = try container.decodeIfPresent(Bool.self, forKey: .optionTab) ?? true
        fasterDesktopSwitching = try container.decodeIfPresent(
            Bool.self,
            forKey: .fasterDesktopSwitching
        ) ?? true
        numberShortcuts = try container.decodeIfPresent(Bool.self, forKey: .numberShortcuts) ?? true
        controlArrows = try container.decodeIfPresent(Bool.self, forKey: .controlArrows) ?? true
        trackpadSwipes = try container.decodeIfPresent(Bool.self, forKey: .trackpadSwipes) ?? true
    }
}
