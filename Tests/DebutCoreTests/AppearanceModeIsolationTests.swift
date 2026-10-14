import Foundation
import Testing
@testable import DebutCore

/// The Appearance page edits the switcher that is being drawn: previews, or icons when previews
/// are off or Screen Recording is missing. Each keeps its own values and defaults (KHA-1099).
@Suite("Appearance mode isolation")
struct AppearanceModeIsolationTests {
    private func settingsViewModel(_ cardStyle: OverlayCardStyle) -> SettingsViewModel {
        var vm = SettingsViewModel()
        vm.screenRecordingGranted = cardStyle == .previews
        return vm
    }

    /// Every value both modes draw, set away from both modes' defaults.
    private static let edited = SwitcherAppearance(
        glassStyle: .regular,
        glassRimStrength: 0.4,
        glassEdgeRefraction: 1.6,
        followsSystemGlassTint: false,
        glassTintAmount: 0.35,
        selectionHighlightStrength: 1.4,
        titleHaloStrength: 0.25,
        titleHaloSize: 2,
        stageCornerRadius: 12,
        stageScale: 2.5,
        inactiveStageScale: 0.5,
        selectorOutset: 3
    )

    @Test("Each mode has its own defaults")
    func eachModeHasItsOwnDefaults() {
        let settings = AppSettings()
        #expect(settings.previewAppearance == .previewDefaults)
        #expect(settings.iconAppearance == .iconDefaults)
        #expect(settings.appearance(for: .previews) == .previewDefaults)
        #expect(settings.appearance(for: .icons) == .iconDefaults)
        #expect(SwitcherAppearance.previewDefaults.stageScale == AppSettings.defaultStageScale)
        #expect(SwitcherAppearance.iconDefaults.stageScale == AppSettings.defaultIconScale)
        #expect(SwitcherAppearance.iconDefaults.stageCornerRadius == AppSettings.defaultIconStageCornerRadius)
        for mode in [SwitcherAppearance.previewDefaults, .iconDefaults] {
            #expect(mode != Self.edited)
        }
    }

    @Test("Editing one mode leaves the other's values alone", arguments: [OverlayCardStyle.previews, .icons])
    func editingOneModeLeavesTheOtherAlone(edited mode: OverlayCardStyle) {
        let other: OverlayCardStyle = mode == .previews ? .icons : .previews
        var vm = settingsViewModel(mode)
        let untouched = vm.settings.appearance(for: other)

        vm.appearance = Self.edited

        #expect(vm.settings.appearance(for: mode) == Self.edited)
        #expect(vm.settings.appearance(for: other) == untouched)
    }

    @Test("The Settings page edits whichever mode the switcher draws")
    func settingsPageFollowsTheDrawnMode() {
        var vm = settingsViewModel(.previews)
        vm.appearance.glassStyle = .clear
        vm.screenRecordingGranted = false
        #expect(vm.appearance == .iconDefaults)
        vm.appearance.glassStyle = .regular
        vm.screenRecordingGranted = true
        #expect(vm.appearance.glassStyle == .clear)
        vm.settings.features.windowPreviews = false
        #expect(vm.appearance.glassStyle == .regular)
    }

    @Test("Restoring Appearance defaults resets only the mode shown", arguments: [OverlayCardStyle.previews, .icons])
    func restoreResetsOnlyTheModeShown(shown mode: OverlayCardStyle) {
        var vm = settingsViewModel(mode)
        vm.settings.previewAppearance = Self.edited
        vm.settings.iconAppearance = Self.edited
        vm.settings.badgePlacement = .corner
        vm.settings.badgeGrowth = 1
        vm.settings.adaptiveCardSizing = false
        vm.settings.previewCornerRadius = 20

        vm.restoreDefaults(for: .appearance)

        let defaults = AppSettings()
        let other: OverlayCardStyle = mode == .previews ? .icons : .previews
        #expect(vm.settings.appearance(for: mode) == defaults.appearance(for: mode))
        #expect(vm.settings.appearance(for: other) == Self.edited)
        // Preview-only values are not shown in icon mode, so its restore keeps them.
        let previewOnlyRestored = mode == .previews
        #expect((vm.settings.badgePlacement == defaults.badgePlacement) == previewOnlyRestored)
        #expect((vm.settings.badgeGrowth == defaults.badgeGrowth) == previewOnlyRestored)
        #expect((vm.settings.adaptiveCardSizing == defaults.adaptiveCardSizing) == previewOnlyRestored)
        #expect((vm.settings.previewCornerRadius == defaults.previewCornerRadius) == previewOnlyRestored)
    }

    @Test("Preview-only controls show only while previews are drawn")
    func previewOnlyControlsHideInIconMode() {
        #expect(SettingsOption.previewOnlyAppearance == [
            .badgePlacement, .badgeGrowth, .adaptiveCardSizing, .previewCornerRadius,
        ])
        #expect(settingsViewModel(.previews).showsPreviewOnlyAppearance)
        #expect(!settingsViewModel(.icons).showsPreviewOnlyAppearance)
    }

    @Test("Both modes round-trip through storage apart")
    func bothModesRoundTrip() throws {
        var settings = AppSettings()
        settings.iconAppearance = Self.edited
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.previewAppearance == .previewDefaults)
        #expect(decoded.iconAppearance == Self.edited)
    }

    /// Before KHA-1099 both modes drew one set of values, apart from size and stage corner. Each
    /// mode keeps what it drew then, so an upgrade changes nothing on screen.
    @Test("Settings saved before the split keep what each mode drew")
    func legacySettingsKeepWhatEachModeDrew() throws {
        let legacy: [String: Any] = [
            "launchAtLogin": true,
            "excludedBundleIDs": [String](),
            "glassStyle": "Regular",
            "glassRimStrength": 0.4,
            "glassEdgeRefraction": 1.6,
            "followsSystemGlassTint": false,
            "glassTintAmount": 0.35,
            "selectionHighlightStrength": 1.4,
            "titleHaloStrength": 0.25,
            "titleHaloSize": 2,
            "stageCornerRadius": 12,
            "iconStageCornerRadius": 30,
            "stageScale": 2.5,
            "iconScale": 9,
            "inactiveStageScale": 0.5,
            "selectorOutset": 3,
        ]
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )

        #expect(decoded.previewAppearance == Self.edited)
        var icons = Self.edited
        icons.stageCornerRadius = 30
        icons.stageScale = AppSettings.maximumStageScale
        #expect(decoded.iconAppearance == icons)
    }

    @Test("Legacy settings without icon values give icons their own defaults")
    func legacySettingsWithoutIconValues() throws {
        let legacy: [String: Any] = [
            "launchAtLogin": true,
            "excludedBundleIDs": [String](),
            "glassStyle": "Native",
            "stageCornerRadius": 47.5,
            "inactiveStageScale": 0.7,
        ]
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.previewAppearance == .previewDefaults)
        #expect(decoded.iconAppearance == .iconDefaults)
    }

    @Test("The switchers draw the mode's own values")
    @MainActor
    func overlaysDrawTheirModesValues() {
        var settings = AppSettings()
        settings.iconAppearance = Self.edited

        var stage = StageOverlayViewModel(
            spaceManager: SpaceManager(), activeSpaceIndex: 0, selectedWindowIndex: 0, appearance: settings
        )
        #expect(stage.switcherAppearance == .previewDefaults)
        stage.cardStyle = .icons
        #expect(stage.switcherAppearance == Self.edited)

        var altTab = AltTabOverlayViewModel(entries: [], selectedIndex: 0, appearance: settings)
        #expect(altTab.switcherAppearance == .previewDefaults)
        altTab.cardStyle = .icons
        #expect(altTab.switcherAppearance == Self.edited)
    }
}
