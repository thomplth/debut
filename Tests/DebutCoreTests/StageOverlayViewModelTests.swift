import Testing
import Foundation
@testable import DebutCore

@Suite("StageOverlayViewModel")
struct OverlayViewModelTests {

    private func multiDisplayManager() -> SpaceManager {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: SpaceTopology(separateSpaces: true, stacks: [
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

    private func makeViewModel() -> StageOverlayViewModel {
        var sm = SpaceManager()
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "AppA", windowTitle: "Window A"), toSpaceID: sm.spaces[0].id)
        sm.addWindow(SpaceWindow(windowID: 102, ownerBundleID: "com.b", ownerName: "AppB", windowTitle: "Window B"), toSpaceID: sm.spaces[0].id)
        sm.createSpace(position: .below)
        sm.addWindow(SpaceWindow(windowID: 201, ownerBundleID: "com.c", ownerName: "AppC", windowTitle: "Window C"), toSpaceID: sm.spaces[1].id)
        sm.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.d", ownerName: "AppD", windowTitle: "Window D"), toSpaceID: sm.spaces[1].id)
        sm.addWindow(SpaceWindow(windowID: 203, ownerBundleID: "com.e", ownerName: "AppE", windowTitle: "Window E"), toSpaceID: sm.spaces[1].id)
        sm.activateSpace(id: sm.spaces[0].id)

        return StageOverlayViewModel(spaceManager: sm, activeSpaceIndex: 0, selectedWindowIndex: 0)
    }

    // macOS withholds `kCGWindowName` without Screen Recording permission, so an empty title is
    // routine rather than exceptional. The card label and whatever a diagnostic reports about a
    // card have to resolve it the same way, or an observer looking for a card by name searches
    // for a string the card never showed.
    @Test("An empty window title resolves to the owner name for every consumer of the label")
    func emptyTitleFallsBackToOwnerName() {
        var sm = SpaceManager()
        sm.addWindow(
            SpaceWindow(windowID: 301, ownerBundleID: "com.apple.TextEdit", ownerName: "TextEdit", windowTitle: ""),
            toSpaceID: sm.spaces[0].id
        )
        sm.addWindow(
            SpaceWindow(windowID: 302, ownerBundleID: "com.apple.TextEdit", ownerName: "TextEdit", windowTitle: "two.txt"),
            toSpaceID: sm.spaces[0].id
        )
        let vm = StageOverlayViewModel(spaceManager: sm, activeSpaceIndex: 0, selectedWindowIndex: 0)

        #expect(sm.spaces[0].windows.map(\.displayTitle) == ["TextEdit", "two.txt"])
        #expect(vm.stages[0].windows.map(\.displayTitle) == ["TextEdit", "two.txt"])
        #expect(vm.selectedWindow?.displayTitle == "TextEdit")
    }

    @Test("Stage data reflects spaces")
    func stageData() {
        let vm = makeViewModel()
        #expect(vm.stages.count == 2)
        #expect(vm.stages[0].windows.count == 2)
        #expect(vm.stages[1].windows.count == 3)
    }

    @Test("Stage data has no presentation title")
    func stageDataHasNoTitle() {
        let stage = StageData(id: UUID(), windows: [], isActive: false, index: 0)
        #expect(stage.index == 0)
    }

    @Test("Each space wraps independently against the same available width")
    func perSpaceStageLayouts() {
        let metrics = StageMetrics.standard
        // 1200pt leaves room for five cards once both margins and both paddings are taken out.
        let layouts = StageConstants.stageLayouts(
            forWindowCounts: [1, 5, 8],
            screenWidth: 1_200,
            metrics: metrics
        )

        #expect(layouts.map(\.rowSizes) == [[1], [5], [4, 4]])
        #expect(layouts[0].stageSize.width == metrics.minStageWidth)
        #expect(layouts[2].stageSize.height
            == metrics.cardHeight * 2 + metrics.rowSpacing
                + metrics.topPadding + metrics.bottomPadding)
        #expect(layouts.allSatisfy {
            $0.stageSize.width <= StageConstants.availableStageWidth(screenWidth: 1_200)
        })
    }

    @Test("A window card is drawn where the overlay-external hit test expects it")
    func windowCardCenterMatchesGrid() {
        let metrics = StageMetrics.standard
        let container = CGSize(width: 1_200, height: 800)
        let stride = metrics.cardWidth + metrics.windowSpacing
        let opticalOffset = (metrics.topPadding - metrics.bottomPadding) / 2

        let first = StageConstants.windowCardCenter(
            spaceIndex: 0, windowIndex: 0, windowCounts: [3],
            activeSpaceIndex: 0, inactiveScale: 0.8, containerSize: container
        )
        let last = StageConstants.windowCardCenter(
            spaceIndex: 0, windowIndex: 2, windowCounts: [3],
            activeSpaceIndex: 0, inactiveScale: 0.8, containerSize: container
        )

        #expect(first == CGPoint(x: 600 - stride, y: 400 + opticalOffset))
        #expect(last == CGPoint(x: 600 + stride, y: 400 + opticalOffset))
        #expect(StageConstants.windowCardCenter(
            spaceIndex: 0, windowIndex: 3, windowCounts: [3],
            activeSpaceIndex: 0, inactiveScale: 0.8, containerSize: container
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
        #expect(vm.stages[0].isActive)
        #expect(!vm.stages[1].isActive)
    }

    @Test("Selection state")
    func selection() {
        let vm = makeViewModel()
        #expect(vm.isSelected(spaceIndex: 0, windowIndex: 0))
        #expect(!vm.isSelected(spaceIndex: 0, windowIndex: 1))
    }

    @Test("Update selection")
    func updateSelection() {
        var vm = makeViewModel()
        vm.activeSpaceIndex = 1
        vm.selectedWindowIndex = 2
        #expect(vm.selectedWindow?.ownerBundleID == "com.e")
    }

    @Test("Display stack shortcut uses a half-width gap between Command and Return")
    func displayStackShortcutSpacing() {
        let vm = StageOverlayViewModel(
            spaceManager: multiDisplayManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        )

        #expect(vm.displayStackShortcut == "Return")
        #expect(vm.displayStackShortcutSpacing == 3.5)
    }

    @Test("Display stack shortcut retires through the standard command hint policy")
    func displayStackShortcutRetires() {
        var settings = AppSettings()
        settings.commandUsageCounts[.nextDisplayStack] = AppSettings.commandHintRetirementUses
        let vm = StageOverlayViewModel(
            spaceManager: multiDisplayManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0,
            appearance: settings
        )

        #expect(vm.displayStackShortcut.isEmpty)
    }

    @Test("Display stack indicator starts below the screen safe area")
    func displayStackIndicatorSafeArea() {
        let vm = StageOverlayViewModel(
            spaceManager: multiDisplayManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0,
            displayTopContentInset: 38
        )

        #expect(vm.displayStackIndicatorTopPadding == 56)
    }

    @Test("The VM preview can show a display indicator with one connected stack")
    func vmDisplayIndicatorPreview() {
        let normal = StageOverlayViewModel(
            spaceManager: SpaceManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        )
        #expect(normal.displayStackCount == 1)
        #expect(!normal.shouldShowDisplayStackIndicator)

        let vm = StageOverlayViewModel(
            spaceManager: SpaceManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0,
            forceDisplayStackIndicator: true
        )

        #expect(vm.displayStackCount == 2)
        #expect(vm.shouldShowDisplayStackIndicator)
    }
}
