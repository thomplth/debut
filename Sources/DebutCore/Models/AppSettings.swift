import Foundation

public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    case clear = "Clear"
    case regular = "Regular"
}

public enum CommandHintVisibility: String, Codable, Sendable, CaseIterable {
    case automatic = "Automatic"
    case never = "Never"
    case always = "Always"
}

public struct AppSettings: Codable, Sendable, Equatable {
    public static let defaultOverlayPresentationDelay: TimeInterval = 0.08

    public var launchAtLogin: Bool
    public var showInMenuBar: Bool
    public var newStagePlacement: StageInsertPosition
    public var confirmStageDeletion: Bool
    public var animationsEnabled: Bool
    public var excludedBundleIDs: [String]
    public var shareAnonymousTelemetry: Bool

    // Appearance
    public var glassStyle: GlassStyle
    public var plateCornerRadius: Double
    public var selectionOpacity: Double
    public var selectionBorderWidth: Double
    public var selectionBorderOpacity: Double
    public var inactivePlateScale: Double

    // Keyboard
    public var overlayPresentationDelay: TimeInterval
    public var keyBindings: KeyBindings
    public var quickSwitchExcludedBundleIDs: [String]

    // Command hints
    public var commandHintVisibility: CommandHintVisibility
    public var commandUsageCounts: [KeyAction: Int]

    public init() {
        self.launchAtLogin = false
        self.showInMenuBar = true
        self.newStagePlacement = .below
        self.confirmStageDeletion = true
        self.animationsEnabled = true
        self.excludedBundleIDs = []
        self.shareAnonymousTelemetry = true

        self.glassStyle = .clear
        self.plateCornerRadius = 22
        self.selectionOpacity = 0.15
        self.selectionBorderWidth = 1.5
        self.selectionBorderOpacity = 0.2
        self.inactivePlateScale = 0.8

        self.overlayPresentationDelay = Self.defaultOverlayPresentationDelay
        self.keyBindings = KeyBindings()
        self.quickSwitchExcludedBundleIDs = []
        self.commandHintVisibility = .automatic
        self.commandUsageCounts = [:]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        showInMenuBar = try container.decode(Bool.self, forKey: .showInMenuBar)
        newStagePlacement = try container.decode(StageInsertPosition.self, forKey: .newStagePlacement)
        confirmStageDeletion = try container.decode(Bool.self, forKey: .confirmStageDeletion)
        animationsEnabled = try container.decode(Bool.self, forKey: .animationsEnabled)
        excludedBundleIDs = try container.decode([String].self, forKey: .excludedBundleIDs)
        shareAnonymousTelemetry = try container.decodeIfPresent(
            Bool.self,
            forKey: .shareAnonymousTelemetry
        ) ?? true
        glassStyle = try container.decode(GlassStyle.self, forKey: .glassStyle)
        plateCornerRadius = try container.decode(Double.self, forKey: .plateCornerRadius)
        selectionOpacity = try container.decode(Double.self, forKey: .selectionOpacity)
        selectionBorderWidth = try container.decode(Double.self, forKey: .selectionBorderWidth)
        selectionBorderOpacity = try container.decode(Double.self, forKey: .selectionBorderOpacity)
        inactivePlateScale = try container.decode(Double.self, forKey: .inactivePlateScale)
        overlayPresentationDelay = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .overlayPresentationDelay
        ) ?? Self.defaultOverlayPresentationDelay
        keyBindings = try container.decodeIfPresent(KeyBindings.self, forKey: .keyBindings) ?? KeyBindings()
        quickSwitchExcludedBundleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .quickSwitchExcludedBundleIDs
        ) ?? []
        commandHintVisibility = try container.decodeIfPresent(
            CommandHintVisibility.self,
            forKey: .commandHintVisibility
        ) ?? .automatic
        commandUsageCounts = try container.decodeIfPresent(
            DecodedKeyActionDictionary<Int>.self,
            forKey: .commandUsageCounts
        )?.values ?? [:]
    }

    public func isExcluded(bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    public func isQuickSwitchExcluded(bundleID: String) -> Bool {
        quickSwitchExcludedBundleIDs.contains(bundleID)
    }

    public func shouldShowCommandHint(for action: KeyAction) -> Bool {
        switch commandHintVisibility {
        case .automatic:
            (commandUsageCounts[action] ?? 0) <= 3
        case .never:
            false
        case .always:
            true
        }
    }

    /// Records only the four uses needed by automatic mode. Returns whether state changed.
    @discardableResult
    public mutating func recordCommandUsage(_ action: KeyAction) -> Bool {
        let currentCount = commandUsageCounts[action] ?? 0
        guard currentCount < 4 else { return false }
        commandUsageCounts[action] = currentCount + 1
        return true
    }

    public mutating func resetCommandHintUsage() {
        commandUsageCounts.removeAll()
    }
}
