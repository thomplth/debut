import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
    case features = "Features"
    case excludedApps = "Excluded Apps"
    case app = "App"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case advanced = "Advanced"
    case troubleshooting = "Troubleshooting"
    case about = "About"
}

public struct SettingsViewModel: Sendable {
    public var settings: AppSettings
    public var spaceManager: SpaceManager
    public let sections: [SettingsSection] = SettingsSection.allCases
    public var onSettingsChanged: (@Sendable (AppSettings) -> Void)?
    public var onResetWindowCache: (@Sendable () -> Void)?
    public var onExportDiagnosticData: (@Sendable () -> Void)?
    public var onCheckForUpdates: (@Sendable () -> Void)?

    public init(settings: AppSettings = AppSettings(), spaceManager: SpaceManager = SpaceManager()) {
        self.settings = settings
        self.spaceManager = spaceManager
    }

    public func resetWindowCache() {
        onResetWindowCache?()
    }

    public func exportDiagnosticData() {
        onExportDiagnosticData?()
    }

    public func checkForUpdates() {
        onCheckForUpdates?()
    }

    public mutating func restoreDefaultShortcuts() {
        settings.keyBindings.restoreDefaults()
        settings.quickSwitchModifiers = .control
        settings.quickSwitchSameApplicationModifiers = ShortcutModifiers(
            control: true,
            option: true
        )
    }

}
