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

    /// Appearance options only preview cards draw; icon cards have no badge, take no window's
    /// shape, and keep the icon's own corner.
    static let previewOnlyAppearance: [SettingsOption] = [
        .badgePlacement,
        .badgeGrowth,
        .adaptiveCardSizing,
        .previewCornerRadius,
    ]
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
    /// Without it the switchers draw icons, so the Appearance page edits the icon mode.
    public var screenRecordingGranted = true

    /// What the switchers are drawing with the current settings and permission.
    public var overlayCardStyle: OverlayCardStyle {
        OverlayCardStyle(previewsAvailable: settings.features.windowPreviews && screenRecordingGranted)
    }

    /// The Appearance page's values: those of the mode the switchers are drawing. Previews and
    /// icons are stored apart, so editing one never moves the other (KHA-1099).
    public var appearance: SwitcherAppearance {
        get { settings.appearance(for: overlayCardStyle) }
        set { settings.setAppearance(newValue, for: overlayCardStyle) }
    }

    /// Icon position, icon growth, window-shaped cards and the preview corner mean nothing to
    /// icon cards, so the page shows them only while previews are drawn.
    public var showsPreviewOnlyAppearance: Bool { overlayCardStyle == .previews }

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
            // Appearance restores only the mode it shows; hidden preview-only values are kept.
            if !showsPreviewOnlyAppearance, SettingsOption.previewOnlyAppearance.contains(option) { continue }
            restore(option, from: defaults)
        }
    }

    private mutating func restore(_ option: SettingsOption, from defaults: AppSettings) {
        let modeDefaults = defaults.appearance(for: overlayCardStyle)
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
        case .glassStyle: appearance.glassStyle = modeDefaults.glassStyle
        case .glassRimStrength: appearance.glassRimStrength = modeDefaults.glassRimStrength
        case .glassEdgeRefraction: appearance.glassEdgeRefraction = modeDefaults.glassEdgeRefraction
        case .selectionHighlightStrength: appearance.selectionHighlightStrength = modeDefaults.selectionHighlightStrength
        case .glassTint:
            appearance.followsSystemGlassTint = modeDefaults.followsSystemGlassTint
            appearance.glassTintAmount = modeDefaults.glassTintAmount
        case .titleHaloStrength: appearance.titleHaloStrength = modeDefaults.titleHaloStrength
        case .titleHaloSize: appearance.titleHaloSize = modeDefaults.titleHaloSize
        case .badgeGrowth: settings.badgeGrowth = defaults.badgeGrowth
        case .badgePlacement: settings.badgePlacement = defaults.badgePlacement
        case .stageCornerRadius: appearance.stageCornerRadius = modeDefaults.stageCornerRadius
        case .stageScale: appearance.stageScale = modeDefaults.stageScale
        case .adaptiveCardSizing: settings.adaptiveCardSizing = defaults.adaptiveCardSizing
        case .inactiveStageScale: appearance.inactiveStageScale = modeDefaults.inactiveStageScale
        case .previewRefreshPolicy: settings.previewRefreshPolicy = defaults.previewRefreshPolicy
        case .previewCacheTTL: settings.previewCacheTTL = defaults.previewCacheTTL
        case .selectorOutset: appearance.selectorOutset = modeDefaults.selectorOutset
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
