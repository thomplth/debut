import Testing
import Foundation
@testable import DebutCore

@Suite("OverlayViewModel")
struct OverlayViewModelTests {

    private func makeViewModel() -> OverlayViewModel {
        var sm = StageManager()
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "AppA", windowTitle: "Window A"), toStageID: sm.stages[0].id)
        sm.addWindow(StageWindow(windowID: 102, ownerBundleID: "com.b", ownerName: "AppB", windowTitle: "Window B"), toStageID: sm.stages[0].id)
        sm.createStage(name: "Coding", position: .below)
        sm.addWindow(StageWindow(windowID: 201, ownerBundleID: "com.c", ownerName: "AppC", windowTitle: "Window C"), toStageID: sm.stages[1].id)
        sm.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.d", ownerName: "AppD", windowTitle: "Window D"), toStageID: sm.stages[1].id)
        sm.addWindow(StageWindow(windowID: 203, ownerBundleID: "com.e", ownerName: "AppE", windowTitle: "Window E"), toStageID: sm.stages[1].id)
        sm.activateStage(id: sm.stages[0].id)

        return OverlayViewModel(stageManager: sm, activeStageIndex: 0, selectedWindowIndex: 0)
    }

    @Test("Plate data reflects stages")
    func plateData() {
        let vm = makeViewModel()
        #expect(vm.plates.count == 2)
        #expect(vm.plates[0].name == "Stage 1")
        #expect(vm.plates[0].windows.count == 2)
        #expect(vm.plates[1].name == "Coding")
        #expect(vm.plates[1].windows.count == 3)
    }

    @Test("Selected window")
    func selectedWindow() {
        let vm = makeViewModel()
        #expect(vm.selectedWindow?.ownerBundleID == "com.a")
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
        #expect(vm.isSelected(stageIndex: 0, windowIndex: 0))
        #expect(!vm.isSelected(stageIndex: 0, windowIndex: 1))
    }

    @Test("Update selection")
    func updateSelection() {
        var vm = makeViewModel()
        vm.activeStageIndex = 1
        vm.selectedWindowIndex = 2
        #expect(vm.selectedWindow?.ownerBundleID == "com.e")
    }
}
