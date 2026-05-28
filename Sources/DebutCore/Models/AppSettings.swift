import Foundation

public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    case clear = "Clear"
    case regular = "Regular"
}

public struct AppSettings: Codable, Sendable {
    public var launchAtLogin: Bool
    public var showInMenuBar: Bool
    public var defaultStageName: String
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

    public init() {
        self.launchAtLogin = false
        self.showInMenuBar = true
        self.defaultStageName = "Stage"
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
    }

    public func isExcluded(bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }
}
