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
        #expect(vm.settings.glassStyle == .native)
        #expect(vm.settings.glassRimStrength == 1)
        #expect(vm.settings.glassEdgeRefraction == 1)
        #expect(vm.settings.followsSystemGlassTint)
        #expect(vm.settings.glassTintAmount == 0)
        #expect(vm.settings.stageCornerRadius == 57.5)
        #expect(vm.settings.inactiveStageScale == 0.7)
        #expect(vm.settings.stageScale == 1.45)
        #expect(vm.settings.previewCardSpacing == 14)
        #expect(vm.settings.overlayOnMainDisplayOnly)
        #expect(vm.settings.windowSelectionStyle == .filled)
        #expect(vm.settings.selectorOutset == 9)
        #expect(vm.settings.selectorCornerRadius == 16)
        #expect(vm.settings.selectionHighlightStrength == 1)
        #expect(vm.settings.badgeGrowth == 0.8)
        #expect(vm.settings.titleHaloStrength == 1)
        #expect(vm.settings.titleHaloSize == 1)
        #expect(vm.settings.magnifyScale == 1.06)
        #expect(vm.settings.magnifyShadowStrength == 1)
        #expect(vm.settings.showsDesktopSwitchIndicator)
        // Must stay on the hold-delay slider's 25ms step grid, or the first drag moves it.
        #expect(vm.settings.overlayPresentationDelay == 0.1)
        #expect(vm.settings.spaceSwitchDuration == 0)
        #expect(vm.settings.excludedBundleIDs.isEmpty)
        #expect(vm.settings.quickSwitchSameApplicationModifiers == ShortcutModifiers(
            control: true,
            option: true
        ))
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
        vm.settings.stageScale = 1.25

        vm.restoreDefaultShortcuts()

        #expect(vm.settings.keyBindings == KeyBindings())
        #expect(vm.settings.quickSwitchModifiers == .control)
        #expect(vm.settings.quickSwitchSameApplicationModifiers == ShortcutModifiers(
            control: true,
            option: true
        ))
        #expect(vm.settings.stageScale == 1.25)
    }

    @Test("Restore all settings resets every preference to its default")
    func restoreDefaultSettings() {
        var vm = SettingsViewModel()
        vm.settings.features.windowPreviews = false
        vm.settings.launchAtLogin = false
        vm.settings.showsDockIcon = false
        vm.settings.excludedBundleIDs = ["com.example.app"]
        vm.settings.glassStyle = .regular
        vm.settings.stageScale = 2.25
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
            .selectionHighlightStrength,
            .glassTint,
            .titleHaloStrength,
            .titleHaloSize,
            .stageCornerRadius,
            .stageScale,
            .badgeGrowth,
            .previewCardSpacing,
            .adaptiveCardSizing,
            .inactiveStageScale,
            .windowSelectionStyle,
            .selectorOutset,
            .selectorCornerRadius,
            .magnifyScale,
            .magnifyShadowStrength,
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

    @Test("Preview card spacing persists and settings without it use the default gap")
    func previewCardSpacingPersistence() throws {
        var settings = AppSettings()
        settings.previewCardSpacing = 24
        let saved = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: saved).previewCardSpacing == 24)

        var object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object.removeValue(forKey: "previewCardSpacing")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AppSettings.self, from: oldData).previewCardSpacing == AppSettings.defaultPreviewCardSpacing)
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
