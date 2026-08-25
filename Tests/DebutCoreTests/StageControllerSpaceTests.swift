import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

final class MockSpaceSwitcher: SpaceSwitching, @unchecked Sendable {
    var desktops: Int
    var current: Int
    var separateSpaces: Bool
    private(set) var switchRequests: [Int] = []
    private(set) var moveRequests: [(windowID: CGWindowID, desktop: Int)] = []
    var windowDesktops: [CGWindowID: Int] = [:]
    var moveSucceeds = true
    var switchChangesDesktop = true
    var canMoveWindows = true
    var completesMovesImmediately = true
    var switchingStackIDs: Set<String> = []
    private(set) var spaceDidChangeCount = 0
    private var pendingMoveCompletions: [(@Sendable () -> Void)] = []

    init(desktops: Int = 3, current: Int = 0, separateSpaces: Bool = false) {
        self.desktops = desktops
        self.current = current
        self.separateSpaces = separateSpaces
    }

    func spaceTopology() -> SpaceTopology {
        let desktopIDs = (0..<desktops).map { CGSSpaceID($0 + 100) }
        let stackID = separateSpaces ? "display-a" : SpaceTopology.sharedStackID
        return SpaceTopology(separateSpaces: separateSpaces, stacks: [
            SpaceStackDescriptor(
                id: stackID,
                displayID: separateSpaces ? 1 : nil,
                displayName: separateSpaces ? "Built-in Display" : "All Displays",
                frame: .zero,
                desktopIDs: desktopIDs,
                currentDesktopID: desktopIDs.indices.contains(current) ? desktopIDs[current] : nil
            ),
        ])
    }

    func desktopCount() -> Int { desktops }
    /// Nil off the end, mirroring the real service: a fullscreen Space is not a user
    /// desktop, so macOS reports no index while one is showing.
    func currentDesktopIndex() -> Int? { (0..<desktops).contains(current) ? current : nil }
    func desktopIndex(forWindow windowID: CGWindowID) -> Int? { windowDesktops[windowID] }

    func isSwitchInFlight(stackID: String) -> Bool {
        switchingStackIDs.contains(stackID)
    }

    func spaceDidChange() {
        spaceDidChangeCount += 1
    }

    func switchToDesktop(index: Int) -> Bool {
        switchRequests.append(index)
        guard (0..<desktops).contains(index) else { return false }
        if switchChangesDesktop { current = index }
        return true
    }

    func moveWindow(windowID: CGWindowID, toDesktop: Int,
                    completion: (@Sendable (Bool) -> Void)?) {
        moveRequests.append((windowID, toDesktop))
        let finish: @Sendable () -> Void = { [self] in
            if moveSucceeds { windowDesktops[windowID] = toDesktop }
            completion?(moveSucceeds)
        }
        if completesMovesImmediately {
            finish()
        } else {
            pendingMoveCompletions.append(finish)
        }
    }

    func completePendingMoves() {
        let completions = pendingMoveCompletions
        pendingMoveCompletions.removeAll()
        completions.forEach { $0() }
    }

    func completeNextMove() {
        guard !pendingMoveCompletions.isEmpty else { return }
        pendingMoveCompletions.removeFirst()()
    }
}

private final class SpaceMutationDelegate: StageControllerDelegate {
    private(set) var mutationCount = 0

    func stageControllerDidOpenOverlay(_ controller: StageController) {}
    func stageControllerDidCloseOverlay(_ controller: StageController) {}
    func stageControllerDidUpdateSelection(_ controller: StageController) {}
    func stageControllerDidSwitchStage(_ controller: StageController) {}
    func stageControllerDidMutateState(_ controller: StageController) { mutationCount += 1 }
}

@Suite("StageController on real Spaces")
struct StageControllerSpaceTests {

    private func makeController(spaces: MockSpaceSwitcher)
        -> (StageController, MockWindowService) {
        let (controller, windowService, _) = makeKeyedController(spaces: spaces)
        return (controller, windowService)
    }

    private func makeKeyedController(spaces: MockSpaceSwitcher)
        -> (StageController, MockWindowService, MockKeyboardService) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        controller.spaceSwitcher = spaces
        return (controller, windowService, keyboardService)
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

    @Test("A switch request does not activate its stage before macOS confirms the desktop")
    func switchWaitsToActivateStage() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        let source = controller.stageManager.stages[0].id
        let target = controller.stageManager.stages[1].id
        controller.stageManager.activateStage(id: source)

        controller.switchToStage(id: target)

        #expect(controller.stageManager.activeStageID == source)
        controller.desktopDidChange()
        #expect(controller.stageManager.activeStageID == target)
    }

    @Test("A shortcut retries when Dock did not land the previous switch request")
    func droppedSwitchCanBeRetried() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.switchChangesDesktop = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        let source = controller.stageManager.stages[0].id
        controller.stageManager.activateStage(id: source)

        keyboardService.simulateEvent(.switchToStage(2))
        keyboardService.simulateEvent(.switchToStage(2))

        #expect(spaces.switchRequests == [1, 1])
        #expect(controller.stageManager.activeStageID == source)
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

    @Test("A target that is still showing retargets an in-flight switch")
    func showingTargetRetargetsInFlightSwitch() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.switchChangesDesktop = false
        spaces.switchingStackIDs = [SpaceTopology.sharedStackID]
        let (controller, _) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        let showingStage = controller.stageManager.stages[0].id
        let settlingStage = controller.stageManager.stages[1].id
        controller.stageManager.activateStage(id: settlingStage)

        controller.switchToStage(id: showingStage)

        #expect(spaces.switchRequests == [0])
        #expect(controller.stageManager.activeStageID == settlingStage)
    }

    @Test("A desktop change advances the switcher before stage reconciliation")
    func desktopChangeAdvancesSwitcher() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _) = makeController(spaces: spaces)

        controller.desktopDidChange()

        #expect(spaces.spaceDidChangeCount == 1)
    }

    @Test("Focus survives an intermediate confirmed hop")
    func focusSurvivesIntermediateHop() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        spaces.switchChangesDesktop = false
        let (controller, windowService) = makeController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        controller.stageManager.createStage(position: .below)
        let target = controller.stageManager.stages[2]
        controller.stageManager.addWindow(
            StageWindow(windowID: 55, ownerBundleID: "com.c", ownerName: "C", windowTitle: "W"),
            toStageID: target.id
        )
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        controller.switchToStage(id: target.id)
        spaces.switchingStackIDs = [SpaceTopology.sharedStackID]
        spaces.current = 1
        controller.desktopDidChange()

        #expect(!windowService.raisedWindowIDs.contains(55))

        spaces.switchingStackIDs = []
        spaces.current = 2
        controller.desktopDidChange()

        #expect(windowService.raisedWindowIDs.contains(55))
        #expect(windowService.activatedBundleID == "com.c")
    }

    // The settling path is where the race lives: Debut's deferred focus lands within a few
    // milliseconds of macOS restoring the destination's remembered app. Plain quick switch
    // must queue nothing, so the desktop settles on whatever macOS chose.
    @Test("Quick switch queues no focus for the settled desktop")
    func quickSwitchQueuesNoFocus() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService, keyboardService) = makeKeyedController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        let stageB = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 55, ownerBundleID: "com.b", ownerName: "B", windowTitle: "W"),
            toStageID: stageB)
        controller.stageManager.activateStage(id: controller.stageManager.stages[0].id)

        keyboardService.simulateEvent(.switchToStage(2))
        controller.desktopDidChange()

        #expect(spaces.switchRequests == [1])
        #expect(controller.stageManager.activeStageID == stageB)
        #expect(windowService.raisedWindowIDs.isEmpty)
        #expect(windowService.activatedBundleID == nil)
    }

    // Skipping the focus is not enough on its own. A focus queued by an earlier switch that is
    // still settling survives, and firing it later would activate an app the plain switch was
    // supposed to leave to macOS. `applyPendingStageFocus` only drops a queue whose stage is
    // not the one that settled, so a re-switch to that same stage slips straight through it.
    @Test("Quick switch clears a focus queued by an earlier switch")
    func quickSwitchClearsPendingFocus() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService, keyboardService) = makeKeyedController(spaces: spaces)
        controller.stageManager.createStage(position: .below)
        let stageA = controller.stageManager.stages[0].id
        let stageB = controller.stageManager.stages[1].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 11, ownerBundleID: "com.a", ownerName: "A", windowTitle: "WA"),
            toStageID: stageA)
        controller.stageManager.addWindow(
            StageWindow(windowID: 22, ownerBundleID: "com.a", ownerName: "A", windowTitle: "WB"),
            toStageID: stageB)
        controller.stageManager.activateStage(id: stageA)

        // Control+Option+2 still focuses, so this queues window 22 while the desktop settles.
        keyboardService.simulateEvent(.switchToStageKeepingCurrentApplication(2))
        #expect(windowService.raisedWindowIDs.isEmpty)

        // A plain Control+2 on the stage already being switched to must discard that queue.
        keyboardService.simulateEvent(.switchToStage(2))
        controller.desktopDidChange()

        #expect(controller.stageManager.activeStageID == stageB)
        #expect(windowService.raisedWindowIDs.isEmpty)
        #expect(windowService.activatedBundleID == nil)
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

    // A stage assignment that does not relocate the window is only a label: the window would
    // stay visible on the desktop it started on, in every stage.
    @Test("Assigning a window to another stage moves it to that desktop")
    func dragMovesWindowToDesktop() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let stageA = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: stageA)
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: stageA)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(windowID: 101, fromStageIndex: 0, toStageIndex: 1,
                                            toWindowIndex: 0))

        #expect(spaces.moveRequests.isEmpty)
        keyboardService.simulateEvent(.cmdRelease)
        #expect(spaces.moveRequests.map(\.windowID) == [101])
        #expect(spaces.moveRequests.map(\.desktop) == [1])
    }

    @Test("Arrow-key moves reach the window server only when the session commits")
    @MainActor
    func keyboardMoveWaitsForCommit() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.completesMovesImmediately = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let stageA = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: stageA)
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: stageA
        )

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.moveWindowDown)

        #expect(spaces.moveRequests.isEmpty)
        #expect(controller.stageManager.stageContainingWindow(windowID: 101) == stageA)

        keyboardService.simulateEvent(.cmdRelease)

        #expect(spaces.moveRequests.map(\.windowID) == [101])
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.isStageManagerVisible)
        #expect(controller.stageManager.stageContainingWindow(windowID: 101)
                == controller.stageManager.stages[1].id)

        spaces.completePendingMoves()

        #expect(spaces.switchRequests == [1])
        #expect(!controller.isStageManagerVisible)
    }

    @Test("Stage focus waits for every committed window move")
    @MainActor
    func stageFocusWaitsForEveryWindowMove() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.completesMovesImmediately = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let stageA = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: stageA)
        for windowID in [CGWindowID(101), 202] {
            controller.stageManager.addWindow(
                StageWindow(
                    windowID: windowID,
                    ownerBundleID: "com.\(windowID)",
                    ownerName: "App",
                    windowTitle: "Window"
                ),
                toStageID: stageA
            )
        }

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(
            windowID: 101,
            fromStageIndex: 0,
            toStageIndex: 1,
            toWindowIndex: 0
        ))
        #expect(controller.moveWindowByDrag(
            windowID: 202,
            fromStageIndex: 0,
            toStageIndex: 1,
            toWindowIndex: 1
        ))
        controller.jumpToStage(index: 1)

        keyboardService.simulateEvent(.cmdRelease)
        #expect(spaces.moveRequests.map(\.windowID) == [101, 202])
        #expect(spaces.switchRequests.isEmpty)

        spaces.completeNextMove()
        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.isStageManagerVisible)

        spaces.completeNextMove()
        #expect(spaces.switchRequests == [1])
        #expect(!controller.isStageManagerVisible)
    }

    @Test("Reordering within a stage does not move the window between desktops")
    func withinStageDoesNotMove() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let stageA = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: stageA)
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toStageID: stageA)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(windowID: 202, fromStageIndex: 0, toStageIndex: 0,
                                            toWindowIndex: 0))
        keyboardService.simulateEvent(.cmdRelease)

        #expect(spaces.moveRequests.isEmpty)
    }

    // The transport is a private-API bridge that fails by doing nothing. If it ever goes
    // inert, a move that still updated the model would leave the plate on one stage and the
    // window on another desktop, persisted, with nothing to correct it.
    @Test("A cross-stage move is refused outright when the transport is unavailable")
    func refusesMoveWithoutTransport() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.canMoveWindows = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let stageA = controller.stageManager.stages[0].id
        controller.stageManager.createStage(position: .below)
        controller.stageManager.activateStage(id: stageA)
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: stageA)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(!controller.moveWindowByDrag(windowID: 101, fromStageIndex: 0, toStageIndex: 1,
                                             toWindowIndex: 0))
        #expect(spaces.moveRequests.isEmpty)
        #expect(controller.stageManager.stageContainingWindow(windowID: 101) == stageA)
    }

    // Reordering inside one stage never touches a desktop, so it must survive the gate.
    @Test("Reordering within a stage still works when the transport is unavailable")
    func reordersWithoutTransport() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.canMoveWindows = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let stageA = controller.stageManager.stages[0].id
        controller.stageManager.addWindow(
            StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toStageID: stageA)
        controller.stageManager.addWindow(
            StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toStageID: stageA)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(windowID: 202, fromStageIndex: 0, toStageIndex: 0,
                                            toWindowIndex: 0))
        #expect(controller.stageManager.stages[0].windows.first?.windowID == 101)
        keyboardService.simulateEvent(.cmdRelease)
        #expect(controller.stageManager.stages[0].windows.first?.windowID == 202)
    }

    @Test("Missing desktops are added as stages")
    func growsToDesktops() {
        let spaces = MockSpaceSwitcher(desktops: 4, current: 0)
        let (controller, _) = makeController(spaces: spaces)

        controller.reconcileStagesWithDesktops()

        #expect(controller.stageManager.stages.count == 4)
    }

    // Reconciling only at launch means a desktop added from Mission Control is invisible for
    // the rest of the session: the stage list stops equalling the desktop list, and every
    // window on the new desktop reports an index past the end of the stage array. Debut cannot
    // ask to be relaunched, so the notification that already tells it the Space changed has to
    // recheck the shape of the desktop list too.
    @Test("A desktop added while Debut runs becomes a stage")
    func desktopChangeGrowsTheStageList() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.reconcileStagesWithDesktops()

        spaces.desktops = 4
        controller.desktopDidChange()

        #expect(controller.stageManager.stages.count == 4)
    }

    @Test("A desktop removed while Debut runs stops being a stage")
    func desktopChangeShrinksTheStageList() {
        let spaces = MockSpaceSwitcher(desktops: 4, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.reconcileStagesWithDesktops()

        spaces.desktops = 2
        controller.desktopDidChange()

        #expect(controller.stageManager.stages.count == 2)
    }

    // Removing an inactive desktop in Mission Control does not necessarily change the active
    // Space, so AppKit may give Debut no active-space notification to react to. The overlay is
    // the first place the stale stage becomes visible and must recheck macOS before presenting.
    @Test("Opening the overlay detects an inactive desktop removed in Mission Control")
    func overlayOpenShrinksTheStageList() {
        let spaces = MockSpaceSwitcher(desktops: 5, current: 0)
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        controller.reconcileStagesWithDesktops()
        #expect(controller.stageManager.stages.count == 5)
        let delegate = SpaceMutationDelegate()
        controller.delegate = delegate

        spaces.desktops = 4
        keyboardService.simulateEvent(.cmdOptionTabHold)

        #expect(controller.stageManager.stages.count == 4)
        #expect(controller.overlayStageManager.stages.count == 4)
        #expect(delegate.mutationCount == 1)
    }

    // A window server that answers "no desktops" is answered with silence: the stage list is
    // left alone, which is right, but the caller cannot tell that apart from a host that
    // genuinely has one desktop. E2E caught Debut launching with one stage against three real
    // desktops and there was nothing in the log to say which step had declined.
    @Test("A reconcile that cannot see any desktop reports that it refused")
    func refusalIsObservable() {
        var manager = StageManager()
        manager.createStage(position: .below)

        let outcome = StageController.reconcileStages(&manager, desktopCount: 0)

        #expect(outcome.refused)
        #expect(outcome.stagesBefore == 2)
        #expect(outcome.stagesAfter == 2)
        #expect(manager.stages.count == 2)
    }

    @Test("A reconcile reports the desktop count it acted on")
    func reconciliationReportsWhatItSaw() {
        var manager = StageManager()

        let outcome = StageController.reconcileStages(&manager, desktopCount: 3)

        #expect(!outcome.refused)
        #expect(outcome.desktopCount == 3)
        #expect(outcome.stagesBefore == 1)
        #expect(outcome.stagesAfter == 3)
    }
}
