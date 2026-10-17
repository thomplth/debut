import Testing
import Foundation
@testable import DebutCore

@Suite("SettingsViewModel")
struct SettingsViewModelTests {

    @Test("Default settings values")
    func defaults() {
        let vm = SettingsViewModel()
        #expect(vm.settings.launchAtLogin == true)
        #expect(vm.settings.features.fasterDesktopSwitching)
        #expect(vm.settings.features.controlArrows)
        #expect(vm.settings.features.trackpadSwipes)
        #expect(vm.settings.previewAppearance.glassStyle == .native)
        #expect(vm.settings.previewAppearance.glassRimStrength == 1)
        #expect(vm.settings.previewAppearance.glassEdgeRefraction == 1)
        #expect(vm.settings.previewAppearance.followsSystemGlassTint)
        #expect(vm.settings.previewAppearance.glassTintAmount == 0)
        #expect(vm.settings.previewAppearance.stageCornerRadius == 40)
        #expect(vm.settings.iconAppearance.stageCornerRadius == AppSettings.defaultIconStageCornerRadius)
        #expect(vm.settings.previewAppearance.inactiveStageScale == 0.7)
        #expect(vm.settings.previewAppearance.stageScale == 1.5)
        #expect(vm.settings.previewCardSpacing == 14)
        #expect(vm.settings.overlayOnMainDisplayOnly)
        #expect(vm.settings.previewAppearance.selectorOutset == 8)
        #expect(vm.settings.iconAppearance.selectorOutset == 9)
        #expect(vm.settings.previewCornerRadius == 6)
        #expect(vm.settings.previewAppearance.selectionHighlightStrength == 1)
        #expect(vm.settings.badgePlacement == .titleRow)
        #expect(vm.settings.badgeGrowth == 0.5)
        #expect(vm.settings.previewAppearance.titleHaloStrength == 1)
        #expect(vm.settings.previewAppearance.titleHaloSize == 0.5)
        #expect(vm.settings.showsDesktopSwitchIndicator)
        // Must stay on the hold-delay slider's step grid, or the first drag moves it.
        #expect(vm.settings.overlayPresentationDelay == 0.1)
        let steps = vm.settings.overlayPresentationDelay / AppSettings.overlayPresentationDelayStep
        #expect(abs(steps - steps.rounded()) < 0.0001)
        #expect(vm.settings.spaceSwitchDuration == 0)
        #expect(vm.settings.excludedBundleIDs.isEmpty)
        #expect(vm.settings.quickSwitchSameApplicationModifiers == ShortcutModifiers(
            control: true,
            option: true
        ))
    }

    @Test("The hold-delay slider adjusts in 5ms steps")
    func holdDelaySliderStepsByFiveMilliseconds() {
        #expect(AppSettings.overlayPresentationDelayStep == 0.005)
    }

    @Test("Update settings")
    func updateSettings() {
        var vm = SettingsViewModel()
        vm.settings.launchAtLogin = true
        vm.settings.quickSwitchModifiers = ShortcutModifiers(control: true, shift: true)
        #expect(vm.settings.launchAtLogin == true)
        #expect(vm.settings.quickSwitchModifiers == ShortcutModifiers(control: true, shift: true))
    }

    @Test("Restore default shortcuts resets only shortcut preferences")
    func restoreDefaultShortcuts() {
        var vm = SettingsViewModel()
        vm.settings.keyBindings.bindings[.nextWindow] = KeyCombo(
            keyCode: 42,
            option: true
        )
        vm.settings.quickSwitchModifiers = ShortcutModifiers(command: true)
        vm.settings.quickSwitchSameApplicationModifiers = ShortcutModifiers(shift: true)
        vm.settings.previewAppearance.stageScale = 1.25

        vm.restoreDefaultShortcuts()

        #expect(vm.settings.keyBindings == KeyBindings())
        #expect(vm.settings.quickSwitchModifiers == .control)
        #expect(vm.settings.quickSwitchSameApplicationModifiers == ShortcutModifiers(
            control: true,
            option: true
        ))
        #expect(vm.settings.previewAppearance.stageScale == 1.25)
    }

    @Test("Restore all settings resets every preference to its default")
    func restoreDefaultSettings() {
        var vm = SettingsViewModel()
        vm.settings.features.windowPreviews = false
        vm.settings.launchAtLogin = false
        vm.settings.showsDockIcon = false
        vm.settings.excludedBundleIDs = ["com.example.app"]
        vm.settings.previewAppearance.glassStyle = .regular
        vm.settings.previewAppearance.stageScale = 2.25
        vm.settings.quickSwitchModifiers = ShortcutModifiers(command: true)
        vm.settings.previewCacheTTL = 5

        vm.restoreDefaultSettings()

        #expect(vm.settings == AppSettings())
    }

    @Test("Sections list")
    func sections() {
        let vm = SettingsViewModel()
        #expect(vm.sections == [
            .general,
            .desktops,
            .switcher,
            .appearance,
            .shortcuts,
            .support,
            .about,
        ])
    }

    @Test("About destinations use the requested profiles")
    func aboutDestinations() {
        #expect(AboutLinks.github.absoluteString == "https://github.com/thomplth/debut")
        #expect(AboutLinks.twitter.absoluteString == "https://twitter.com/thomplth")
    }

    @Test("Appearance owns visual options while Switcher owns behavior")
    func appearanceOptions() {
        #expect(SettingsSection.switcher.options == [
            .workspaceIsolation,
            .optionTab,
            .windowPreviews,
            .mainDisplayOnly,
            .previewRefreshPolicy,
            .previewCacheTTL,
            .overlayPresentationDelay,
            .heldCycleMinimumInterval,
        ])
        #expect(SettingsSection.appearance.options == [
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
        ])
    }

    @Test("Every configurable option appears in exactly one section")
    func sectionOptionsAreCompleteAndUnique() {
        let groupedOptions = SettingsSection.allCases.flatMap(\.options)

        #expect(groupedOptions.count == SettingsOption.allCases.count)
        #expect(Set(groupedOptions) == Set(SettingsOption.allCases))
    }

    @Test("Settings no longer persist the removed sharing preference")
    func settingsExcludeRemovedSharingPreference() throws {
        let data = try JSONEncoder().encode(AppSettings())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["shareAnonymousTelemetry"] == nil)
    }

    @Test("Settings written by sharing-enabled builds remain decodable")
    func legacySharingPreferenceIsIgnored() throws {
        let current = AppSettings()
        let encoded = try JSONEncoder().encode(current)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["shareAnonymousTelemetry"] = true
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)

        #expect(decoded == current)
        let normalized = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        #expect(normalized["shareAnonymousTelemetry"] == nil)
    }

    /// Restoring a page's defaults resets that page's settings and nothing else (KHA-1064).
    @Test("Restoring a page's defaults leaves the other pages alone", arguments: SettingsSection.allCases)
    func restoreDefaultsForOnePage(section: SettingsSection) {
        var changed = AppSettings()
        changed.launchAtLogin = false
        changed.excludedBundleIDs = ["com.example.app"]
        changed.features.numberShortcuts = false
        changed.spaceSwitchDuration = 0.2
        changed.features.optionTab = false
        changed.previewCacheTTL = 5
        changed.previewAppearance.glassStyle = .regular
        changed.previewAppearance.stageCornerRadius = 20
        changed.iconAppearance.stageCornerRadius = 30
        changed.previewAppearance.stageScale = 2
        changed.iconAppearance.stageScale = 1.5
        changed.badgePlacement = .corner
        changed.previewCornerRadius = 12
        changed.quickSwitchModifiers = ShortcutModifiers(command: true)

        var vm = SettingsViewModel(settings: changed)
        vm.restoreDefaults(for: section)

        let defaults = AppSettings()
        let isGeneral = section == .general, isDesktops = section == .desktops
        let isSwitcher = section == .switcher, isAppearance = section == .appearance
        #expect((vm.settings.launchAtLogin == defaults.launchAtLogin) == isGeneral)
        #expect((vm.settings.excludedBundleIDs == defaults.excludedBundleIDs) == isGeneral)
        #expect((vm.settings.features.numberShortcuts == defaults.features.numberShortcuts) == isDesktops)
        #expect((vm.settings.spaceSwitchDuration == defaults.spaceSwitchDuration) == isDesktops)
        #expect((vm.settings.features.optionTab == defaults.features.optionTab) == isSwitcher)
        #expect((vm.settings.previewCacheTTL == defaults.previewCacheTTL) == isSwitcher)
        for appearanceValueIsDefault in [
            vm.settings.previewAppearance.glassStyle == defaults.previewAppearance.glassStyle,
            vm.settings.previewAppearance.stageCornerRadius == defaults.previewAppearance.stageCornerRadius,
            vm.settings.previewAppearance.stageScale == defaults.previewAppearance.stageScale,
            vm.settings.badgePlacement == defaults.badgePlacement,
            vm.settings.previewCornerRadius == defaults.previewCornerRadius,
        ] {
            #expect(appearanceValueIsDefault == isAppearance)
        }
        // Previews are drawn, so Appearance restores only the preview mode (KHA-1099).
        #expect(vm.settings.iconAppearance == changed.iconAppearance)
        #expect((vm.settings.quickSwitchModifiers == defaults.quickSwitchModifiers) == (section == .shortcuts))
    }

    @Test("One corner slider edits whichever plate the switcher is drawing")
    func cornerSliderFollowsTheCardStyle() {
        var vm = SettingsViewModel()
        vm.screenRecordingGranted = true
        #expect(vm.appearance.stageCornerRadius == 40)
        vm.appearance.stageCornerRadius = 30
        #expect(vm.settings.previewAppearance.stageCornerRadius == 30)
        #expect(vm.settings.iconAppearance.stageCornerRadius == AppSettings.defaultIconStageCornerRadius)

        vm.screenRecordingGranted = false
        #expect(vm.appearance.stageCornerRadius == AppSettings.defaultIconStageCornerRadius)
        vm.appearance.stageCornerRadius = 50
        #expect(vm.settings.iconAppearance.stageCornerRadius == 50)
        #expect(vm.settings.previewAppearance.stageCornerRadius == 30)
        #expect(vm.settings.appearance(for: .icons).stageCornerRadius == 50)
        #expect(vm.settings.appearance(for: .previews).stageCornerRadius == 30)
    }

    @Test("Troubleshooting actions are forwarded to the app")
    func troubleshootingActions() {
        final class Calls: @unchecked Sendable {
            var reset = 0
            var export = 0
        }
        let calls = Calls()
        var vm = SettingsViewModel()
        vm.onResetWindowCache = { calls.reset += 1 }
        vm.onExportDiagnosticData = { calls.export += 1 }

        vm.resetWindowCache()
        vm.exportDiagnosticData()

        #expect(calls.reset == 1)
        #expect(calls.export == 1)
    }

    @Test("Update checks are forwarded to the app")
    func updateChecks() {
        final class Calls: @unchecked Sendable { var checks = 0 }
        let calls = Calls()
        var vm = SettingsViewModel()
        vm.onCheckForUpdates = { calls.checks += 1 }

        vm.checkForUpdates()

        #expect(calls.checks == 1)
    }
}
