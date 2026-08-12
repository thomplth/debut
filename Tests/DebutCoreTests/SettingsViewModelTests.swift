import Testing
import Foundation
@testable import DebutCore

@Suite("SettingsViewModel")
struct SettingsViewModelTests {

    @Test("Default settings values")
    func defaults() {
        let vm = SettingsViewModel()
        #expect(vm.settings.launchAtLogin == false)
        #expect(vm.settings.showInMenuBar == true)
        #expect(vm.settings.confirmStageDeletion == true)
        #expect(vm.settings.overlayPresentationDelay == 0.08)
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
            .keyboardShortcuts,
            .troubleshooting,
            .about,
        ])
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
}
