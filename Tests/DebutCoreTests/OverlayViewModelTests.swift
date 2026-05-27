import Testing
import Foundation
@testable import DebutCore

@Suite("OverlayViewModel")
struct OverlayViewModelTests {

    private func makeViewModel() -> OverlayViewModel {
        var sm = StageManager()
        sm.addWindow(StageWindow(windowID: 1, appBundleID: "com.a", appName: "AppA", isShared: false), toStageID: sm.stages[0].id)
        sm.addWindow(StageWindow(windowID: 2, appBundleID: "com.b", appName: "AppB", isShared: false), toStageID: sm.stages[0].id)
        sm.createStage(name: "Coding", position: .below)
        sm.addWindow(StageWindow(windowID: 3, appBundleID: "com.c", appName: "AppC", isShared: false), toStageID: sm.stages[1].id)
        sm.addWindow(StageWindow(windowID: 4, appBundleID: "com.d", appName: "AppD", isShared: false), toStageID: sm.stages[1].id)
        sm.addWindow(StageWindow(windowID: 5, appBundleID: "com.e", appName: "AppE", isShared: false), toStageID: sm.stages[1].id)
        sm.activateStage(id: sm.stages[0].id)

        return OverlayViewModel(stageManager: sm, activeStageIndex: 0, selectedAppIndex: 0)
    }

    @Test("Plate data reflects stages")
    func plateData() {
        let vm = makeViewModel()
        let plates = vm.plates
        #expect(plates.count == 2)
        #expect(plates[0].name == "Stage 1")
        #expect(plates[0].apps.count == 2)
        #expect(plates[1].name == "Coding")
        #expect(plates[1].apps.count == 3)
    }

    @Test("Active plate index")
    func activePlateIndex() {
        let vm = makeViewModel()
        #expect(vm.activeStageIndex == 0)
    }

    @Test("Selected app in active plate")
    func selectedApp() {
        let vm = makeViewModel()
        #expect(vm.selectedAppIndex == 0)
        #expect(vm.selectedApp?.bundleID == "com.a")
    }

    @Test("App data includes bundle ID and name")
    func appData() {
        let vm = makeViewModel()
        let app = vm.plates[0].apps[1]
        #expect(app.bundleID == "com.b")
        #expect(app.name == "AppB")
        #expect(app.windowID == 2)
    }

    @Test("isActive flag on plates")
    func isActiveFlag() {
        let vm = makeViewModel()
        #expect(vm.plates[0].isActive)
        #expect(!vm.plates[1].isActive)
    }

    @Test("Selection state for app icons")
    func selectionState() {
        let vm = makeViewModel()
        #expect(vm.isSelected(stageIndex: 0, appIndex: 0))
        #expect(!vm.isSelected(stageIndex: 0, appIndex: 1))
        #expect(!vm.isSelected(stageIndex: 1, appIndex: 0))
    }

    @Test("Update selection")
    func updateSelection() {
        var vm = makeViewModel()
        vm.activeStageIndex = 1
        vm.selectedAppIndex = 2
        #expect(vm.isSelected(stageIndex: 1, appIndex: 2))
        #expect(vm.selectedApp?.bundleID == "com.e")
    }
}
