import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
    case templates = "Templates"
    case app = "App"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case about = "About"
}

public struct SettingsViewModel: Sendable {
    public var settings: AppSettings
    public var stageManager: StageManager
    public let sections: [SettingsSection] = SettingsSection.allCases

    public init(settings: AppSettings = AppSettings(), stageManager: StageManager = StageManager()) {
        self.settings = settings
        self.stageManager = stageManager
    }
}
