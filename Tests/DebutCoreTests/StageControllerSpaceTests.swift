import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

final class MockSpaceSwitcher: SpaceSwitching, @unchecked Sendable {
    var desktops: Int
    var current: Int
    private(set) var switchRequests: [Int] = []
    var windowDesktops: [CGWindowID: Int] = [:]

    init(desktops: Int = 3, current: Int = 0) {
        self.desktops = desktops
        self.current = current
    }

    func desktopCount() -> Int { desktops }
    /// Nil off the end, mirroring the real service: a fullscreen Space is not a user
    /// desktop, so macOS reports no index while one is showing.
    func currentDesktopIndex() -> Int? { (0..<desktops).contains(current) ? current : nil }
    func desktopIndex(forWindow windowID: CGWindowID) -> Int? { windowDesktops[windowID] }

    func switchToDesktop(index: Int) -> Bool {
        switchRequests.append(index)
        guard (0..<desktops).contains(index) else { return false }
        current = index
        return true
    }
}

@Suite("StageController on real Spaces")
struct StageControllerSpaceTests {

    private func makeController(spaces: MockSpaceSwitcher)
        -> (StageController, MockWindowService) {
        let windowService = MockWindowService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .unfocused }
        )
        controller.spaceSwitcher = spaces
        return (controller, windowService)
    }

    @Test("Switching stage switches to the matching desktop")
    func switchesDesktop() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        // createStage activates what it creates, so return to the first stage before
        // switching — otherwise this would ask to switch to the stage already showing.
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        controller.switchToStage(id: controller.stageManager.stages[2].id)

        #expect(spaces.switchRequests == [2])
    }

    // Under the surface architecture every window in the target stage had to be AX-raised
    // above the wallpaper overlay, one at a time, and that staggered raise is exactly the
    // "desktop flashes with the windows" the Spaces migration exists to remove. macOS shows
    // the desktop's windows itself, so raising them is not merely unnecessary — doing it
    // would reintroduce the flash.
    @Test("Switching stage does not raise the target stage's windows one by one")
    func doesNotRaiseEveryWindow() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService) = makeController(spaces: spaces)
        let stageA = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        let stageB = controller.stageManager.stages[1].id

        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: stageA)
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toStageID: stageB)
        controller.stageManager.addWindow(
            StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"),
            toStageID: stageB)
        controller.stageManager.activateStage(id: stageA)

        controller.switchToStage(id: stageB)

        #expect(!windowService.raisedWindowIDs.contains(303))
    }

    @Test("Switching to the stage already showing requests no desktop change")
    func noRedundantSwitch() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)

        controller.switchToStage(id: controller.stageManager.stages[0].id)

        #expect(spaces.switchRequests.isEmpty)
    }

    // Stages are desktops, and only the user can make a desktop (SLSSpaceCreate is
    // SIP-gated). A stage with no desktop behind it would be a switch target that silently
    // does nothing, so the stage list is clamped to what macOS actually has.
    @Test("Stage count is clamped to the number of real desktops")
    func clampsToDesktops() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)

        controller.reconcileStagesWithDesktops()

        #expect(controller.stageManager.stages.count == 2)
    }

    // Nothing stops the user switching desktop with Mission Control or Control+Arrow. When
    // they do, Debut's idea of the active stage is simply wrong until it is resynced, and a
    // wrong active stage shows the wrong plate as selected and catches newly discovered
    // windows that have nowhere else to go.
    @Test("The active stage follows a desktop the user switched to themselves")
    func activeStageFollowsUserSwitch() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        spaces.current = 2
        controller.syncActiveStageWithCurrentDesktop()

        #expect(controller.stageManager.activeStageID == controller.stageManager.stages[2].id)
    }

    // The sync reacts to a switch that already happened. Switching again would fight the
    // user, and on a manual switch would bounce them back and forth.
    @Test("Syncing the active stage requests no desktop change")
    func syncRequestsNoSwitch() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 2)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        controller.syncActiveStageWithCurrentDesktop()

        #expect(spaces.switchRequests.isEmpty)
    }

    // A fullscreen Space is not a user desktop, so `currentDesktopIndex()` reports nothing
    // while one is showing. Guessing a stage there would move the user's active stage every
    // time they watched a video fullscreen.
    @Test("A desktop with no matching stage leaves the active stage alone")
    func unknownDesktopLeavesActiveStage() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        let expected = controller.stageManager.activeStageID

        spaces.current = -1
        controller.syncActiveStageWithCurrentDesktop()

        #expect(controller.stageManager.activeStageID == expected)
    }

    // Observed as a live feedback loop: a stale assignment made Debut switch stages on
    // focus, switching stages now switches desktop, the desktop change resynced the active
    // stage, and the next focus event switched straight back. A window cannot take focus on
    // a desktop that is not showing, so the assignment is what is wrong, never the desktop.
    @Test("Activating a window recorded on another stage never switches desktop")
    func activationDoesNotSwitchDesktop() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 2)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[2].id)
        controller.stageManager.addWindow(
            StageWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W"),
            toStageID: controller.stageManager.stages[0].id)
        spaces.windowDesktops = [7: 2]

        controller.recordWindowActivation(windowID: 7)

        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.stageManager.stageContainingWindow(windowID: 7)
            == controller.stageManager.stages[2].id)
    }

    // Observed live: a Finder window sits on every desktop, so macOS reports no single one,
    // and reading that silence as "the desktop showing" dragged its plate onto whichever
    // stage was last visited. Reassignment is destructive, so it needs a positive answer;
    // silence is not one, and leaving the assignment lets a later real answer correct it.
    @Test("An activated window with no reported desktop keeps its stage")
    func activationWithoutDesktopKeepsAssignment() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 1)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[1].id)
        controller.stageManager.addWindow(
            StageWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W"),
            toStageID: controller.stageManager.stages[0].id)

        controller.recordWindowActivation(windowID: 7)

        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.stageManager.stageContainingWindow(windowID: 7)
            == controller.stageManager.stages[0].id)
    }

    // A window Debut has never seen has no assignment to protect, so the showing desktop is
    // the only answer available and is very likely right.
    @Test("An unassigned window with no reported desktop joins the showing stage")
    func activationOfUnknownWindowJoinsActiveStage() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 1)
        let (controller, windowService) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[1].id)
        windowService.windowList = [
            WindowInfo(windowID: 7, ownerBundleID: "com.a", ownerName: "A", ownerPID: 42,
                       title: "W", bounds: .zero, isOnScreen: true)
        ]

        controller.recordWindowActivation(windowID: 7)

        #expect(controller.stageManager.stageContainingWindow(windowID: 7)
            == controller.stageManager.stages[1].id)
    }

    @Test("Activating a window already on the showing stage only updates its order")
    func activationOnActiveStageUpdatesOrder() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        let stageID = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W"),
            toStageID: stageID)
        controller.stageManager.addWindow(
            StageWindow(windowID: 8, ownerBundleID: "com.b", ownerName: "B", windowTitle: "X"),
            toStageID: stageID)
        spaces.windowDesktops = [7: 0, 8: 0]

        controller.recordWindowActivation(windowID: 7)

        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.stageManager.stages[0].windows.first?.windowID == 7)
    }

    // The state block is the only way E2E observes a running session, and it reported the
    // overlay's selection cursor under the name `activeStageIndex`. The two used to be the
    // same thing; a desktop the user switches to themselves moves the active stage without
    // touching the cursor, so the block claimed stage 1 while the app was on stage 3.
    @Test("The diagnostic state reports the active stage and the cursor separately")
    func diagnosticStateSeparatesActiveFromSelected() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)
        controller.selectedStageIndex = 0

        spaces.current = 2
        controller.syncActiveStageWithCurrentDesktop()

        #expect(controller.diagnosticState["activeStageIndex"] == "2")
        #expect(controller.diagnosticState["selectedStageIndex"] == "0")
    }

    // The Dock consumes the forged swipe asynchronously, so a switch that focused its target
    // straight away was focusing it on the desktop it was leaving. macOS then restored its
    // own idea of focus as the Space settled and overwrote the choice: measured on a desktop
    // holding one Calculator window, the switch landed on Finder every time but the first,
    // and activating Calculator by hand a second later worked.
    @Test("Focus waits for the desktop to actually change")
    func focusWaitsForDesktopChange() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        let stageB = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 55, ownerBundleID: "com.b", ownerName: "B", windowTitle: "W"),
            toStageID: stageB)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        controller.switchToStage(id: stageB)
        #expect(!windowService.raisedWindowIDs.contains(55))

        controller.desktopDidChange()
        #expect(windowService.raisedWindowIDs.contains(55))
        #expect(windowService.activatedBundleID == "com.b")
    }

    // Nothing has to settle when the desktop is already right, and waiting for a change that
    // will never come would leave the window unfocused forever.
    @Test("A switch that changes no desktop focuses straight away")
    func sameDesktopSwitchFocusesImmediately() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService) = makeController(spaces: spaces)
        controller.stageManager.addWindow(
            StageWindow(windowID: 55, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W"),
            toStageID: controller.stageManager.stages[0].id)

        controller.switchToStage(id: controller.stageManager.stages[0].id)

        #expect(windowService.raisedWindowIDs.contains(55))
    }

    // A switch the user overtakes — hitting Control+3 while Control+2 is still settling —
    // must not drag focus back to the stage they left behind.
    @Test("Focus is dropped when the desktop settles somewhere else")
    func pendingFocusDroppedOnDifferentDesktop() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, windowService) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.addWindow(
            StageWindow(windowID: 55, ownerBundleID: "com.b", ownerName: "B", windowTitle: "W"),
            toStageID: controller.stageManager.stages[1].id)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        controller.switchToStage(id: controller.stageManager.stages[1].id)
        spaces.current = 2
        controller.desktopDidChange()

        #expect(!windowService.raisedWindowIDs.contains(55))
    }

    @Test("Missing desktops are added as stages")
    func growsToDesktops() {
        let spaces = MockSpaceSwitcher(desktops: 4, current: 0)
        let (controller, _) = makeController(spaces: spaces)

        controller.reconcileStagesWithDesktops()

        #expect(controller.stageManager.stages.count == 4)
    }
}
