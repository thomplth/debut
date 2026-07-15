import Foundation

public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    case clear = "Clear"
    case regular = "Regular"
}

public struct AppSettings: Codable, Sendable {
    public var launchAtLogin: Bool
    public var showInMenuBar: Bool
    public var newStagePlacement: StageInsertPosition
    public var confirmStageDeletion: Bool
    public var animationsEnabled: Bool
    public var excludedBundleIDs: [String]

    // Appearance
    public var glassStyle: GlassStyle
    public var plateCornerRadius: Double
    public var selectionOpacity: Double
    public var selectionBorderWidth: Double
    public var selectionBorderOpacity: Double
    public var inactivePlateScale: Double

    // Keyboard
    public var keyBindings: KeyBindings

    public init() {
        self.launchAtLogin = false
        self.showInMenuBar = true
        self.newStagePlacement = .below
        self.confirmStageDeletion = true
        self.animationsEnabled = true
        self.excludedBundleIDs = []

        self.glassStyle = .clear
        self.plateCornerRadius = 22
        self.selectionOpacity = 0.15
        self.selectionBorderWidth = 1.5
        self.selectionBorderOpacity = 0.2
        self.inactivePlateScale = 0.8

        self.keyBindings = KeyBindings()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        showInMenuBar = try container.decode(Bool.self, forKey: .showInMenuBar)
        newStagePlacement = try container.decode(StageInsertPosition.self, forKey: .newStagePlacement)
        confirmStageDeletion = try container.decode(Bool.self, forKey: .confirmStageDeletion)
        animationsEnabled = try container.decode(Bool.self, forKey: .animationsEnabled)
        excludedBundleIDs = try container.decode([String].self, forKey: .excludedBundleIDs)
        glassStyle = try container.decode(GlassStyle.self, forKey: .glassStyle)
        plateCornerRadius = try container.decode(Double.self, forKey: .plateCornerRadius)
        selectionOpacity = try container.decode(Double.self, forKey: .selectionOpacity)
        selectionBorderWidth = try container.decode(Double.self, forKey: .selectionBorderWidth)
        selectionBorderOpacity = try container.decode(Double.self, forKey: .selectionBorderOpacity)
        inactivePlateScale = try container.decode(Double.self, forKey: .inactivePlateScale)
        keyBindings = try container.decodeIfPresent(KeyBindings.self, forKey: .keyBindings) ?? KeyBindings()
    }

    public func isExcluded(bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }
}
