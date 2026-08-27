import Testing
import Foundation
@testable import DebutCore

@Suite("OverlayViewModel")
struct OverlayViewModelTests {

    private func multiDisplayManager() -> StageManager {
        var manager = StageManager()
        manager.reconcileStageStacks(with: SpaceTopology(separateSpaces: true, stacks: [
            SpaceStackDescriptor(
                id: "display-a", displayID: 1, displayName: "Built-in Display", frame: .zero,
                desktopIDs: [10], currentDesktopID: 10
            ),
            SpaceStackDescriptor(
                id: "display-b", displayID: 2, displayName: "Studio Display", frame: .zero,
                desktopIDs: [20], currentDesktopID: 20
            ),
        ]))
        return manager
    }

    private func makeViewModel() -> OverlayViewModel {
        var sm = StageManager()
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "AppA", windowTitle: "Window A"), toStageID: sm.stages[0].id)
        sm.addWindow(StageWindow(windowID: 102, ownerBundleID: "com.b", ownerName: "AppB", windowTitle: "Window B"), toStageID: sm.stages[0].id)
        sm.createStage(position: .below)
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
        #expect(vm.plates[0].windows.count == 2)
        #expect(vm.plates[1].windows.count == 3)
    }

    @Test("Plate data has no presentation title")
    func plateDataHasNoTitle() {
        let plate = PlateData(id: UUID(), windows: [], isActive: false, index: 0)
        #expect(plate.index == 0)
    }

    @Test("Each stage wraps independently against the same available width")
    func perStagePlateLayouts() {
        let metrics = PlateMetrics.standard
        // 1200pt leaves room for five cards once both margins and both paddings are taken out.
        let layouts = PlateConstants.plateLayouts(
            forWindowCounts: [1, 5, 8],
            screenWidth: 1_200,
            metrics: metrics
        )

        #expect(layouts.map(\.rowSizes) == [[1], [5], [4, 4]])
        #expect(layouts[0].plateSize.width == metrics.minPlateWidth)
        #expect(layouts[2].plateSize.height
            == metrics.cardHeight * 2 + metrics.rowSpacing
                + metrics.topPadding + metrics.bottomPadding)
        #expect(layouts.allSatisfy {
            $0.plateSize.width <= PlateConstants.availablePlateWidth(screenWidth: 1_200)
        })
    }

    @Test("A window card is drawn where the overlay-external hit test expects it")
    func windowCardCenterMatchesGrid() {
        let metrics = PlateMetrics.standard
        let container = CGSize(width: 1_200, height: 800)
        let stride = metrics.cardWidth + metrics.windowSpacing

        let first = PlateConstants.windowCardCenter(
            stageIndex: 0, windowIndex: 0, windowCounts: [3],
            activeStageIndex: 0, inactiveScale: 0.8, containerSize: container
        )
        let last = PlateConstants.windowCardCenter(
            stageIndex: 0, windowIndex: 2, windowCounts: [3],
            activeStageIndex: 0, inactiveScale: 0.8, containerSize: container
        )

        #expect(first == CGPoint(x: 600 - stride, y: 400))
        #expect(last == CGPoint(x: 600 + stride, y: 400))
        #expect(PlateConstants.windowCardCenter(
            stageIndex: 0, windowIndex: 3, windowCounts: [3],
            activeStageIndex: 0, inactiveScale: 0.8, containerSize: container
        ) == nil)
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

    @Test("Display stack shortcut uses a half-width gap between Command and Return")
    func displayStackShortcutSpacing() {
        let vm = OverlayViewModel(
            stageManager: multiDisplayManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0
        )

        #expect(vm.displayStackShortcut == "Return")
        #expect(vm.displayStackShortcutSpacing == 3.5)
    }

    @Test("Display stack shortcut retires through the standard command hint policy")
    func displayStackShortcutRetires() {
        var settings = AppSettings()
        settings.commandUsageCounts[.nextDisplayStack] = AppSettings.commandHintRetirementUses
        let vm = OverlayViewModel(
            stageManager: multiDisplayManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0,
            appearance: settings
        )

        #expect(vm.displayStackShortcut.isEmpty)
    }

    @Test("Display stack indicator starts below the screen safe area")
    func displayStackIndicatorSafeArea() {
        let vm = OverlayViewModel(
            stageManager: multiDisplayManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0,
            displayTopContentInset: 38
        )

        #expect(vm.displayStackIndicatorTopPadding == 56)
    }

    @Test("The VM preview can show a display indicator with one connected stack")
    func vmDisplayIndicatorPreview() {
        let normal = OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0
        )
        #expect(normal.displayStackCount == 1)
        #expect(!normal.shouldShowDisplayStackIndicator)

        let vm = OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0,
            forceDisplayStackIndicator: true
        )

        #expect(vm.displayStackCount == 2)
        #expect(vm.shouldShowDisplayStackIndicator)
    }
}
