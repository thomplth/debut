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
        #expect(vm.settings.defaultStageName == "Stage")
        #expect(vm.settings.confirmStageDeletion == true)
        #expect(vm.settings.animationsEnabled == true)
    }

    @Test("Update settings")
    func updateSettings() {
        var vm = SettingsViewModel()
        vm.settings.launchAtLogin = true
        vm.settings.defaultStageName = "Workspace"
        #expect(vm.settings.launchAtLogin == true)
        #expect(vm.settings.defaultStageName == "Workspace")
    }

    @Test("Template list from StageManager")
    func templateList() {
        var vm = SettingsViewModel()
        vm.stageManager.createStage(name: "Coding", position: .below)
        vm.stageManager.addWindow(
            StageWindow(windowID: 1, appBundleID: "com.vscode", appName: "VS Code", isShared: false),
            toStageID: vm.stageManager.stages[1].id
        )
        vm.stageManager.saveStageAsTemplate(stageID: vm.stageManager.stages[1].id, templateName: "Dev Setup")

        #expect(vm.stageManager.templates.count == 1)
        #expect(vm.stageManager.templates[0].name == "Dev Setup")
        #expect(vm.stageManager.templates[0].appBundleIDs == ["com.vscode"])
    }

    @Test("Delete template")
    func deleteTemplate() {
        var vm = SettingsViewModel()
        vm.stageManager.saveStageAsTemplate(stageID: vm.stageManager.stages[0].id, templateName: "Empty")
        let id = vm.stageManager.templates[0].id
        vm.stageManager.deleteTemplate(id: id)
        #expect(vm.stageManager.templates.isEmpty)
    }

    @Test("Sections list")
    func sections() {
        let vm = SettingsViewModel()
        #expect(vm.sections == [.templates, .app, .keyboardShortcuts, .about])
    }
}
