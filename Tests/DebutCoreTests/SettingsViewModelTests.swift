import Testing
import Foundation
@testable import DebutCore

@Suite("SettingsViewModel")
struct SettingsViewModelTests {

    @Test("Default settings values")
    func defaults() {
        let vm = SettingsViewModel()
        #expect(vm.settings.launchAtLogin == true)
        #expect(vm.settings.glassStyle == .clear)
        #expect(vm.settings.stageCornerRadius == 40)
        #expect(vm.settings.inactiveStageScale == 0.7)
        #expect(vm.settings.stageScale == 1.0)
        // Must stay on the hold-delay slider's 25ms step grid, or the first drag moves it.
        #expect(vm.settings.overlayPresentationDelay == 0.075)
        #expect(vm.settings.quickSwitchExcludedBundleIDs.isEmpty)
        #expect(vm.settings.commandHintVisibility == .automatic)
        #expect(vm.settings.commandUsageCounts.isEmpty)
    }

    @Test("Update settings")
    func updateSettings() {
        var vm = SettingsViewModel()
        vm.settings.launchAtLogin = true
        vm.settings.quickSwitchExcludedBundleIDs.append("com.tinyspeck.slackmacgap")
        #expect(vm.settings.launchAtLogin == true)
        #expect(vm.settings.isQuickSwitchExcluded(bundleID: "com.tinyspeck.slackmacgap"))
    }

    @Test("Sections list")
    func sections() {
        let vm = SettingsViewModel()
        #expect(vm.sections == [
            .appearance,
            .excludedApps,
            .app,
            .privacy,
            .keyboardShortcuts,
            .troubleshooting,
            .about,
        ])
    }

    @Test("Privacy payload preview is exact JSON and documents excluded data")
    func privacyPayloadPreview() throws {
        let vm = SettingsViewModel()
        let preview = try vm.telemetryPayloadPreview()
        let data = try #require(preview.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(vm.telemetryExcludedData.contains("window titles"))
        #expect(!preview.contains("bundleID"))
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
