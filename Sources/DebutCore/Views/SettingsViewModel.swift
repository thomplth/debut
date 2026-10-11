import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
    case general = "General"
    case desktops = "Desktops"
    case switcher = "Switcher"
    case appearance = "Appearance"
    case shortcuts = "Shortcuts"
    case support = "Support"
    case about = "About"

    var options: [SettingsOption] {
        switch self {
        case .general:
            [.launchAtLogin, .showInDock, .ignoredApps, .crashReports]
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
                .optionTab,
                .windowPreviews,
                .mainDisplayOnly,
                .previewRefreshPolicy,
                .previewCacheTTL,
                .overlayPresentationDelay,
                .heldCycleMinimumInterval,
            ]
        case .appearance:
            [
                .glassStyle,
                .glassRimStrength,
                .glassEdgeRefraction,
                .glassTint,
                .titleHaloStrength,
                .titleHaloSize,
                .stageCornerRadius,
                .stageScale,
                .badgePlacement,
                .badgeGrowth,
                .adaptiveCardSizing,
                .inactiveStageScale,
                .selectionHighlightStrength,
                .selectorOutset,
                .previewCornerRadius,
            ]
        case .shortcuts:
            [
                .keyBindings,
                .quickSwitchModifiers,
                .quickSwitchSameApplicationModifiers,
            ]
        case .support, .about:
            []
        }
    }
}

/// A complete inventory of user-configurable values and their settings destination.
enum SettingsOption: String, CaseIterable, Sendable {
    case launchAtLogin
    case showInDock
    case ignoredApps
    case crashReports
    case fasterDesktopSwitching
    case numberShortcuts
    case controlArrows
    case trackpadSwipes
    case spaceSwitchDuration
    case desktopSwitchIndicator
    case workspaceIsolation
    case optionTab
    case windowPreviews
    case mainDisplayOnly
    case glassStyle
    case glassRimStrength
    case glassEdgeRefraction
    case selectionHighlightStrength
    case glassTint
    case titleHaloStrength
    case titleHaloSize
    case badgeGrowth
    case badgePlacement
    case stageCornerRadius
    case stageScale
    case adaptiveCardSizing
    case inactiveStageScale
    case previewRefreshPolicy
    case previewCacheTTL
    case selectorOutset
    case previewCornerRadius
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
    /// Hides the crash report preference in builds that have nowhere to send reports.
    public var crashReportingAvailable = false
    /// Without it the switchers draw icons, so the size slider edits the icon size.
    public var screenRecordingGranted = true

    /// What the switchers are drawing with the current settings and permission.
    public var overlayCardStyle: OverlayCardStyle {
        OverlayCardStyle(previewsAvailable: settings.features.windowPreviews && screenRecordingGranted)
    }

    /// The one corner slider: the preview plate's corner, or the icon plate's while icons show.
    public var overlayCornerRadius: Double {
        get { settings.stageCornerRadius(for: overlayCardStyle) }
        set {
            switch overlayCardStyle {
            case .previews: settings.stageCornerRadius = newValue
            case .icons: settings.iconStageCornerRadius = newValue
            }
        }
    }

    /// The one size slider: the preview size, or the icon size while icons are drawn.
    public var overlaySize: Double {
        get { settings.overlayScale(for: overlayCardStyle) }
        set {
            switch overlayCardStyle {
            case .previews: settings.stageScale = newValue
            case .icons: settings.iconScale = newValue
            }
        }
    }

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
        restoreDefaults(for: .shortcuts)
    }

    /// Resets only the settings that `section` shows; every other page keeps its choices.
    public mutating func restoreDefaults(for section: SettingsSection) {
        let defaults = AppSettings()
        for option in section.options {
            restore(option, from: defaults)
        }
    }

    private mutating func restore(_ option: SettingsOption, from defaults: AppSettings) {
        switch option {
        case .launchAtLogin: settings.launchAtLogin = defaults.launchAtLogin
        case .showInDock: settings.showsDockIcon = defaults.showsDockIcon
        case .ignoredApps: settings.excludedBundleIDs = defaults.excludedBundleIDs
        case .crashReports: settings.sendsCrashReportsAutomatically = defaults.sendsCrashReportsAutomatically
        case .fasterDesktopSwitching: settings.features.fasterDesktopSwitching = defaults.features.fasterDesktopSwitching
        case .numberShortcuts: settings.features.numberShortcuts = defaults.features.numberShortcuts
        case .controlArrows: settings.features.controlArrows = defaults.features.controlArrows
        case .trackpadSwipes: settings.features.trackpadSwipes = defaults.features.trackpadSwipes
        case .spaceSwitchDuration: settings.spaceSwitchDuration = defaults.spaceSwitchDuration
        case .desktopSwitchIndicator: settings.showsDesktopSwitchIndicator = defaults.showsDesktopSwitchIndicator
        case .workspaceIsolation: settings.features.workspaceIsolation = defaults.features.workspaceIsolation
        case .optionTab: settings.features.optionTab = defaults.features.optionTab
        case .windowPreviews: settings.features.windowPreviews = defaults.features.windowPreviews
        case .mainDisplayOnly: settings.overlayOnMainDisplayOnly = defaults.overlayOnMainDisplayOnly
        case .glassStyle: settings.glassStyle = defaults.glassStyle
        case .glassRimStrength: settings.glassRimStrength = defaults.glassRimStrength
        case .glassEdgeRefraction: settings.glassEdgeRefraction = defaults.glassEdgeRefraction
        case .selectionHighlightStrength: settings.selectionHighlightStrength = defaults.selectionHighlightStrength
        case .glassTint:
            settings.followsSystemGlassTint = defaults.followsSystemGlassTint
            settings.glassTintAmount = defaults.glassTintAmount
        case .titleHaloStrength: settings.titleHaloStrength = defaults.titleHaloStrength
        case .titleHaloSize: settings.titleHaloSize = defaults.titleHaloSize
        case .badgeGrowth: settings.badgeGrowth = defaults.badgeGrowth
        case .badgePlacement: settings.badgePlacement = defaults.badgePlacement
        case .stageCornerRadius:
            // One slider edits both corners, so both return to their defaults.
            settings.stageCornerRadius = defaults.stageCornerRadius
            settings.iconStageCornerRadius = defaults.iconStageCornerRadius
        case .stageScale:
            // One slider edits both sizes, so both return to their defaults.
            settings.stageScale = defaults.stageScale
            settings.iconScale = defaults.iconScale
        case .adaptiveCardSizing: settings.adaptiveCardSizing = defaults.adaptiveCardSizing
        case .inactiveStageScale: settings.inactiveStageScale = defaults.inactiveStageScale
        case .previewRefreshPolicy: settings.previewRefreshPolicy = defaults.previewRefreshPolicy
        case .previewCacheTTL: settings.previewCacheTTL = defaults.previewCacheTTL
        case .selectorOutset: settings.selectorOutset = defaults.selectorOutset
        case .previewCornerRadius: settings.previewCornerRadius = defaults.previewCornerRadius
        case .keyBindings: settings.keyBindings = defaults.keyBindings
        case .quickSwitchModifiers: settings.quickSwitchModifiers = defaults.quickSwitchModifiers
        case .quickSwitchSameApplicationModifiers:
            settings.quickSwitchSameApplicationModifiers = defaults.quickSwitchSameApplicationModifiers
        case .overlayPresentationDelay: settings.overlayPresentationDelay = defaults.overlayPresentationDelay
        case .heldCycleMinimumInterval: settings.heldCycleMinimumInterval = defaults.heldCycleMinimumInterval
        }
    }

    public mutating func restoreDefaultSettings() {
        settings = AppSettings()
    }

}
