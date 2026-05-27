import Testing
import Foundation
@testable import DebutCore

@Suite("OverlayViewModel")
struct OverlayViewModelTests {

    private func makeViewModel() -> OverlayViewModel {
        var sm = StageManager()
        sm.addApp(StageApp(bundleID: "com.a", name: "AppA"), toStageID: sm.stages[0].id)
        sm.addApp(StageApp(bundleID: "com.b", name: "AppB"), toStageID: sm.stages[0].id)
        sm.createStage(name: "Coding", position: .below)
        sm.addApp(StageApp(bundleID: "com.c", name: "AppC"), toStageID: sm.stages[1].id)
        sm.addApp(StageApp(bundleID: "com.d", name: "AppD"), toStageID: sm.stages[1].id)
        sm.addApp(StageApp(bundleID: "com.e", name: "AppE"), toStageID: sm.stages[1].id)
        sm.activateStage(id: sm.stages[0].id)

        return OverlayViewModel(stageManager: sm, activeStageIndex: 0, selectedAppIndex: 0)
    }

    @Test("Plate data reflects stages")
    func plateData() {
        let vm = makeViewModel()
        #expect(vm.plates.count == 2)
        #expect(vm.plates[0].name == "Stage 1")
        #expect(vm.plates[0].apps.count == 2)
        #expect(vm.plates[1].name == "Coding")
        #expect(vm.plates[1].apps.count == 3)
    }

    @Test("Selected app")
    func selectedApp() {
        let vm = makeViewModel()
        #expect(vm.selectedApp?.bundleID == "com.a")
    }

    @Test("isActive flag")
    func isActive() {
        let vm = makeViewModel()
        #expect(vm.plates[0].isActive)
        #expect(!vm.plates[1].isActive)
    }

    @Test("Selection state")
    func selection() {
        let vm = makeViewModel()
        #expect(vm.isSelected(stageIndex: 0, appIndex: 0))
        #expect(!vm.isSelected(stageIndex: 0, appIndex: 1))
    }

    @Test("Update selection")
    func updateSelection() {
        var vm = makeViewModel()
        vm.activeStageIndex = 1
        vm.selectedAppIndex = 2
        #expect(vm.selectedApp?.bundleID == "com.e")
    }
}
