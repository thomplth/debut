import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
    case appearance = "Appearance"
    case excludedApps = "Excluded Apps"
    case app = "App"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case troubleshooting = "Troubleshooting"
    case about = "About"
}

public struct SettingsViewModel: Sendable {
    public var settings: AppSettings
    public var stageManager: StageManager
    public let sections: [SettingsSection] = SettingsSection.allCases
    public var onSettingsChanged: (@Sendable (AppSettings) -> Void)?
    public var onResetWindowCache: (@Sendable () -> Void)?
    public var onExportDiagnosticData: (@Sendable () -> Void)?

    public init(settings: AppSettings = AppSettings(), stageManager: StageManager = StageManager()) {
        self.settings = settings
        self.stageManager = stageManager
    }

    public func resetWindowCache() {
        onResetWindowCache?()
    }

    public func exportDiagnosticData() {
        onExportDiagnosticData?()
    }
}
