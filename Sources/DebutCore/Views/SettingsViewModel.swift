import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
    case general = "General"
    case desktops = "Desktops"
    case switcher = "Switcher"
    case appearance = "Appearance"
    case shortcuts = "Shortcuts"
    case support = "Support"

    var options: [SettingsOption] {
        switch self {
        case .general:
            [.launchAtLogin, .showInDock, .ignoredApps]
        case .desktops:
            [
                .fasterDesktopSwitching,
                .numberShortcuts,
                .controlArrows,
                .trackpadSwipes,
                .spaceSwitchDuration,
                .desktopSwitchIndicator,
            ]
        case .switcher:
            [
                .workspaceIsolation,
                .windowPreviews,
                .mainDisplayOnly,
                .previewRefreshPolicy,
                .previewCacheTTL,
            ]
        case .appearance:
            [
                .glassStyle,
                .stageCornerRadius,
                .stageScale,
                .adaptiveCardSizing,
                .inactiveStageScale,
                .windowSelectionStyle,
                .selectorOutset,
                .selectorCornerRadius,
                .magnifyScale,
                .magnifyShadowStrength,
            ]
        case .shortcuts:
            [
                .keyBindings,
                .quickSwitchModifiers,
                .quickSwitchSameApplicationModifiers,
                .overlayPresentationDelay,
                .heldCycleMinimumInterval,
            ]
        case .support:
            []
        }
    }
}

/// A complete inventory of user-configurable values and their settings destination.
enum SettingsOption: String, CaseIterable, Sendable {
    case launchAtLogin
    case showInDock
    case ignoredApps
    case fasterDesktopSwitching
    case numberShortcuts
    case controlArrows
    case trackpadSwipes
    case spaceSwitchDuration
    case desktopSwitchIndicator
    case workspaceIsolation
    case windowPreviews
    case mainDisplayOnly
    case glassStyle
    case stageCornerRadius
    case stageScale
    case adaptiveCardSizing
    case inactiveStageScale
    case previewRefreshPolicy
    case previewCacheTTL
    case windowSelectionStyle
    case selectorOutset
    case selectorCornerRadius
    case magnifyScale
    case magnifyShadowStrength
    case keyBindings
    case quickSwitchModifiers
    case quickSwitchSameApplicationModifiers
    case overlayPresentationDelay
    case heldCycleMinimumInterval
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
