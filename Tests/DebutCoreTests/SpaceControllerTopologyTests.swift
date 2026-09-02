import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

final class MockSpaceSwitcher: SpaceSwitching, @unchecked Sendable {
    var desktops: Int
    var current: Int
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

    /// The desktops in display order, each named by a stable key. `nil` numbers them 0..<n,
    /// which is what a test that only cares about the count wants; assigning a permutation is
    /// how a Mission Control reorder is expressed, since that leaves the count untouched.
    var desktopKeys: [Int]?

    init(desktops: Int = 3, current: Int = 0) {
        self.desktops = desktops
        self.current = current
    }

    private var keys: [Int] { desktopKeys ?? Array(0..<desktops) }

    func spaceTopology() -> SpaceTopology {
        let keys = self.keys
        let desktopIDs = keys.map { CGSSpaceID($0 + 100) }
        return SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: SpaceTopology.sharedStackID,
                displayID: nil,
                displayName: "All Displays",
                frame: .zero,
                desktopIDs: desktopIDs,
                desktopUUIDs: keys.map { "DESKTOP-\($0)" },
                currentDesktopID: desktopIDs.indices.contains(current) ? desktopIDs[current] : nil,
                currentDesktopUUID: keys.indices.contains(current) ? "DESKTOP-\(keys[current])" : nil
            ),
        ])
    }

    func desktopCount() -> Int { keys.count }
    /// Nil off the end, mirroring the real service: a fullscreen Space is not a user
    /// desktop, so macOS reports no index while one is showing.
    func currentDesktopIndex() -> Int? { keys.indices.contains(current) ? current : nil }
    func desktopIndex(forWindow windowID: CGWindowID) -> Int? { windowDesktops[windowID] }

    /// Built from `windowDesktops` rather than tracked separately, so a test that plants a
    /// window's desktop one way sees it consistently through both the per-window and the
    /// bulk lookup — a caller migrating from one to the other should see no behavior change.
    func windowLocations() -> [CGWindowID: DesktopLocation] {
        guard let stack = spaceTopology().stacks.first else { return [:] }
        return windowDesktops.reduce(into: [:]) { result, entry in
            result[entry.key] = stack.location(at: entry.value)
        }
    }

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

private final class SpaceMutationDelegate: SpaceControllerDelegate {
    private(set) var mutationCount = 0

    func spaceControllerDidOpenOverlay(_ controller: SpaceController) {}
    func spaceControllerDidCloseOverlay(_ controller: SpaceController) {}
    func spaceControllerDidUpdateSelection(_ controller: SpaceController) {}
    func spaceControllerDidSwitchSpace(_ controller: SpaceController) {}
    func spaceControllerDidMutateState(_ controller: SpaceController) { mutationCount += 1 }
}

@Suite("SpaceController on real Spaces")
struct SpaceControllerSpaceTests {

    private func makeController(spaces: MockSpaceSwitcher)
        -> (SpaceController, MockWindowService) {
        let (controller, windowService, _) = makeKeyedController(spaces: spaces)
        return (controller, windowService)
    }

    private func makeKeyedController(spaces: MockSpaceSwitcher)
        -> (SpaceController, MockWindowService, MockKeyboardService) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        controller.spaceSwitcher = spaces
        return (controller, windowService, keyboardService)
    }

    @Test("Switching space switches to the matching desktop")
    func switchesDesktop() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        // createSpace activates what it creates, so return to the first space before
        // switching — otherwise this would ask to switch to the space already showing.
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        let target = controller.spaceManager.spaces[2].id
        controller.switchToSpace(id: target)

        #expect(spaces.switchRequests == [2])
        #expect(controller.spaceManager.activeSpaceID == target)
    }

    // Under the surface architecture every window in the target space had to be AX-raised
    // above the wallpaper overlay, one at a time, and that staggered raise is exactly the
    // "desktop flashes with the windows" the Spaces migration exists to remove. macOS shows
    // the desktop's windows itself, so raising them is not merely unnecessary — doing it
    // would reintroduce the flash.
    @Test("Switching space does not raise the target space's windows one by one")
    func doesNotRaiseEveryWindow() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService) = makeController(spaces: spaces)
        let spaceA = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let spaceB = controller.spaceManager.spaces[1].id

        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceA)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: spaceB)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"),
            toSpaceID: spaceB)
        controller.spaceManager.activateSpace(id: spaceA)

        controller.switchToSpace(id: spaceB)

        #expect(!windowService.raisedWindowIDs.contains(303))
    }

    @Test("Switching to the space already showing requests no desktop change")
    func noRedundantSwitch() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)

        controller.switchToSpace(id: controller.spaceManager.spaces[0].id)

        #expect(spaces.switchRequests.isEmpty)
    }

    // Spaces are desktops, and only the user can make a desktop (SLSSpaceCreate is
    // SIP-gated). A space with no desktop behind it would be a switch target that silently
    // does nothing, so the space list is clamped to what macOS actually has.
    @Test("Space count is clamped to the number of real desktops")
    func clampsToDesktops() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)

        controller.reconcileSpacesWithDesktops()

        #expect(controller.spaceManager.spaces.count == 2)
    }

    // Nothing stops the user switching desktop with Mission Control or Control+Arrow. When
    // they do, Debut's idea of the active space is simply wrong until it is resynced, and a
    // wrong active space shows the wrong stage as selected and catches newly discovered
    // windows that have nowhere else to go.
    @Test("The active space follows a desktop the user switched to themselves")
    func activeSpaceFollowsUserSwitch() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        spaces.current = 2
        controller.syncActiveSpaceWithCurrentDesktop()

        #expect(controller.spaceManager.activeSpaceID == controller.spaceManager.spaces[2].id)
    }

    // The sync reacts to a switch that already happened. Switching again would fight the
    // user, and on a manual switch would bounce them back and forth.
    @Test("Syncing the active space requests no desktop change")
    func syncRequestsNoSwitch() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 2)
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        controller.syncActiveSpaceWithCurrentDesktop()

        #expect(spaces.switchRequests.isEmpty)
    }

    // A fullscreen Space is not a user desktop, so `currentDesktopIndex()` reports nothing
    // while one is showing. Guessing a space there would move the user's active space every
    // time they watched a video fullscreen.
    @Test("A desktop with no matching space leaves the active space alone")
    func unknownDesktopLeavesActiveSpace() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        let expected = controller.spaceManager.activeSpaceID

        spaces.current = -1
        controller.syncActiveSpaceWithCurrentDesktop()

        #expect(controller.spaceManager.activeSpaceID == expected)
    }

    // Observed as a live feedback loop: a stale assignment made Debut switch spaces on
    // focus, switching spaces now switches desktop, the desktop change resynced the active
    // space, and the next focus event switched straight back. A window cannot take focus on
    // a desktop that is not showing, so the assignment is what is wrong, never the desktop.
    @Test("Activating a window recorded on another space never switches desktop")
    func activationDoesNotSwitchDesktop() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 2)
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[2].id)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W"),
            toSpaceID: controller.spaceManager.spaces[0].id)
        spaces.windowDesktops = [7: 2]

        controller.recordWindowActivation(windowID: 7)

        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 7)
            == controller.spaceManager.spaces[2].id)
    }

    // Observed live: a Finder window sits on every desktop, so macOS reports no single one,
    // and reading that silence as "the desktop showing" dragged its stage onto whichever
    // space was last visited. Reassignment is destructive, so it needs a positive answer;
    // silence is not one, and leaving the assignment lets a later real answer correct it.
    @Test("An activated window with no reported desktop keeps its space")
    func activationWithoutDesktopKeepsAssignment() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 1)
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[1].id)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W"),
            toSpaceID: controller.spaceManager.spaces[0].id)

        controller.recordWindowActivation(windowID: 7)

        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 7)
            == controller.spaceManager.spaces[0].id)
    }

    // A window Debut has never seen has no assignment to protect, so the showing desktop is
    // the only answer available and is very likely right.
    @Test("An unassigned window with no reported desktop joins the showing space")
    func activationOfUnknownWindowJoinsActiveSpace() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 1)
        let (controller, windowService) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[1].id)
        windowService.windowList = [
            WindowInfo(windowID: 7, ownerBundleID: "com.a", ownerName: "A", ownerPID: 42,
                       title: "W", bounds: .zero, isOnScreen: true)
        ]

        controller.recordWindowActivation(windowID: 7)

        #expect(controller.spaceManager.spaceContainingWindow(windowID: 7)
            == controller.spaceManager.spaces[1].id)
    }

    @Test("Activating a window already on the showing space only updates its order")
    func activationOnActiveSpaceUpdatesOrder() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        let spaceID = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W"),
            toSpaceID: spaceID)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 8, ownerBundleID: "com.b", ownerName: "B", windowTitle: "X"),
            toSpaceID: spaceID)
        spaces.windowDesktops = [7: 0, 8: 0]

        controller.recordWindowActivation(windowID: 7)

        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.spaceManager.spaces[0].windows.first?.windowID == 7)
    }

    // The state block is the only way E2E observes a running session, and it reported the
    // overlay's selection cursor under the name `activeSpaceIndex`. The two used to be the
    // same thing; a desktop the user switches to themselves moves the active space without
    // touching the cursor, so the block claimed space 1 while the app was on space 3.
    @Test("The diagnostic state reports the active space and the cursor separately")
    func diagnosticStateSeparatesActiveFromSelected() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)
        controller.selectedSpaceIndex = 0

        spaces.current = 2
        controller.syncActiveSpaceWithCurrentDesktop()

        #expect(controller.diagnosticState["activeSpaceIndex"] == "2")
        #expect(controller.diagnosticState["selectedSpaceIndex"] == "0")
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
        controller.spaceManager.createSpace(position: .below)
        let spaceB = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 55, ownerBundleID: "com.b", ownerName: "B", windowTitle: "W"),
            toSpaceID: spaceB)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        controller.switchToSpace(id: spaceB)
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
        controller.spaceManager.createSpace(position: .below)
        let showingSpace = controller.spaceManager.spaces[0].id
        let settlingSpace = controller.spaceManager.spaces[1].id
        controller.spaceManager.activateSpace(id: settlingSpace)

        controller.switchToSpace(id: showingSpace)

        #expect(spaces.switchRequests == [0])
        #expect(controller.spaceManager.activeSpaceID == showingSpace)
    }

    @Test("A desktop change advances the switcher before space reconciliation")
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
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        let target = controller.spaceManager.spaces[2]
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 55, ownerBundleID: "com.c", ownerName: "C", windowTitle: "W"),
            toSpaceID: target.id
        )
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        controller.switchToSpace(id: target.id)
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

    /// A 1 -> 4 switch is three real Dock gestures. macOS restores a focused window on each
    /// desktop as it appears, but spaces 2 and 3 were only crossed — the user never chose
    /// either window, so neither may jump ahead in the global Option-Tab order.
    @Test("Intermediate switch focus does not change MRU")
    func intermediateSwitchFocusDoesNotChangeMRU() throws {
        let spaces = MockSpaceSwitcher(desktops: 4, current: 0)
        spaces.switchChangesDesktop = false
        let (controller, _) = makeController(spaces: spaces)
        for _ in 1..<4 { controller.spaceManager.createSpace(position: .below) }
        let ids = [11, 22, 33, 44] as [CGWindowID]
        let oldDates = ids.enumerated().map { index, _ in
            Date(timeIntervalSinceReferenceDate: TimeInterval(40 - index * 10))
        }
        for index in ids.indices {
            controller.spaceManager.addWindow(
                SpaceWindow(
                    windowID: ids[index],
                    ownerBundleID: "com.app.\(ids[index])",
                    ownerName: "App \(ids[index])",
                    windowTitle: "Window \(ids[index])",
                    lastActivatedAt: oldDates[index]
                ),
                toSpaceID: controller.spaceManager.spaces[index].id
            )
            spaces.windowDesktops[ids[index]] = index
        }
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        controller.switchToSpace(id: controller.spaceManager.spaces[3].id)
        spaces.switchingStackIDs = [SpaceTopology.sharedStackID]

        spaces.current = 1
        controller.recordWindowActivation(windowID: 22)
        controller.desktopDidChange()

        spaces.current = 2
        controller.recordWindowActivation(windowID: 33)
        controller.desktopDidChange()

        spaces.current = 3
        controller.recordWindowActivation(windowID: 44)
        spaces.switchingStackIDs = []
        controller.desktopDidChange()

        let second = try #require(
            controller.spaceManager.allSpaces[1].windows.first { $0.windowID == 22 }
        )
        let third = try #require(
            controller.spaceManager.allSpaces[2].windows.first { $0.windowID == 33 }
        )
        #expect(second.lastActivatedAt == oldDates[1])
        #expect(third.lastActivatedAt == oldDates[2])
        #expect(controller.spaceManager.globalWindowOrder().map(\.window.windowID)
            == [44, 11, 22, 33])
    }

    /// Plain Control+number deliberately leaves the final choice to macOS. If its focus event
    /// arrives before the last desktop notification, suppressing every in-flight event would
    /// also suppress the one activation that should count.
    @Test("A final passive focus deferred during switching becomes MRU")
    func finalPassiveFocusBecomesMRU() throws {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        spaces.switchChangesDesktop = false
        let (controller, _) = makeController(spaces: spaces)
        for _ in 1..<3 { controller.spaceManager.createSpace(position: .below) }
        let oldDate = Date(timeIntervalSinceReferenceDate: 10)
        for index in 0..<3 {
            let windowID = CGWindowID((index + 1) * 10)
            controller.spaceManager.addWindow(
                SpaceWindow(
                    windowID: windowID,
                    ownerBundleID: "com.app.\(windowID)",
                    ownerName: "App \(windowID)",
                    windowTitle: "Window \(windowID)",
                    lastActivatedAt: oldDate
                ),
                toSpaceID: controller.spaceManager.spaces[index].id
            )
            spaces.windowDesktops[windowID] = index
        }
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        controller.switchToSpace(
            id: controller.spaceManager.spaces[2].id,
            focusesWindow: false
        )
        spaces.switchingStackIDs = [SpaceTopology.sharedStackID]

        spaces.current = 1
        controller.recordWindowActivation(windowID: 20)
        controller.desktopDidChange()

        spaces.current = 2
        controller.recordWindowActivation(windowID: 30)
        spaces.switchingStackIDs = []
        controller.desktopDidChange()

        let intermediate = try #require(
            controller.spaceManager.allSpaces[1].windows.first { $0.windowID == 20 }
        )
        let final = try #require(
            controller.spaceManager.allSpaces[2].windows.first { $0.windowID == 30 }
        )
        #expect(intermediate.lastActivatedAt == oldDate)
        #expect(final.lastActivatedAt.map { $0 > oldDate } == true)
        #expect(controller.spaceManager.globalWindowOrder().first?.window.windowID == 30)
    }

    /// The final desktop notification can arrive before its restored focus callback. The last
    /// held candidate still belongs to the desktop just crossed and must be discarded rather
    /// than treated as the destination's MRU window.
    @Test("A held focus from a departed intermediate desktop does not change MRU")
    func departedIntermediateFocusDoesNotChangeMRU() throws {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        spaces.switchChangesDesktop = false
        let (controller, _) = makeController(spaces: spaces)
        for _ in 1..<3 { controller.spaceManager.createSpace(position: .below) }
        let oldDate = Date(timeIntervalSinceReferenceDate: 10)
        controller.spaceManager.addWindow(
            SpaceWindow(
                windowID: 22,
                ownerBundleID: "com.b",
                ownerName: "B",
                windowTitle: "B",
                lastActivatedAt: oldDate
            ),
            toSpaceID: controller.spaceManager.spaces[1].id
        )
        spaces.windowDesktops = [22: 1]
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        controller.switchToSpace(
            id: controller.spaceManager.spaces[2].id,
            focusesWindow: false
        )
        spaces.switchingStackIDs = [SpaceTopology.sharedStackID]
        spaces.current = 1
        controller.recordWindowActivation(windowID: 22)

        spaces.current = 2
        spaces.switchingStackIDs = []
        controller.desktopDidChange()

        let departed = try #require(
            controller.spaceManager.allSpaces[1].windows.first { $0.windowID == 22 }
        )
        #expect(departed.lastActivatedAt == oldDate)
    }

    /// An unexpected landing stops the coordinator instead of fighting the user. The focus on
    /// that desktop is therefore the real result, not an intermediate side effect to discard.
    @Test("An unexpected landing keeps its focused window as MRU")
    func unexpectedLandingKeepsFocusedWindow() throws {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        spaces.switchChangesDesktop = false
        let (controller, _) = makeController(spaces: spaces)
        for _ in 1..<3 { controller.spaceManager.createSpace(position: .below) }
        let oldDate = Date(timeIntervalSinceReferenceDate: 10)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 22, ownerBundleID: "com.b", ownerName: "B", windowTitle: "B",
                        lastActivatedAt: oldDate),
            toSpaceID: controller.spaceManager.spaces[1].id
        )
        spaces.windowDesktops = [22: 1]

        controller.switchToSpace(
            id: controller.spaceManager.spaces[2].id,
            focusesWindow: false
        )
        spaces.switchingStackIDs = [SpaceTopology.sharedStackID]
        spaces.current = 1
        controller.recordWindowActivation(windowID: 22)

        // Models the coordinator stopping after an unexpected or user-overtaken landing.
        spaces.switchingStackIDs = []
        controller.desktopDidChange()

        let landed = try #require(
            controller.spaceManager.allSpaces[1].windows.first { $0.windowID == 22 }
        )
        #expect(landed.lastActivatedAt.map { $0 > oldDate } == true)
    }

    /// A stage or Option-Tab commit names the desired target. macOS may restore another window
    /// on the final desktop first, but Debut's explicit focus runs after deferred passive focus
    /// and must be the MRU head when the switch completes.
    @Test("Explicit target focus wins over passive final focus")
    func explicitTargetWinsOverPassiveFinalFocus() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.switchChangesDesktop = false
        let (controller, _) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        let target = controller.spaceManager.spaces[1]
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 21, ownerBundleID: "com.passive", ownerName: "Passive",
                        windowTitle: "Passive"),
            toSpaceID: target.id
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 22, ownerBundleID: "com.explicit", ownerName: "Explicit",
                        windowTitle: "Explicit"),
            toSpaceID: target.id
        )
        spaces.windowDesktops = [21: 1, 22: 1]
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        controller.switchToSpace(id: target.id, raiseWindowID: 22)
        spaces.switchingStackIDs = [SpaceTopology.sharedStackID]
        spaces.current = 1
        controller.recordWindowActivation(windowID: 21)

        spaces.switchingStackIDs = []
        controller.desktopDidChange()

        #expect(controller.spaceManager.spaces[1].windows.map(\.windowID) == [22, 21])
    }

    // The settling path is where the race lives: Debut's deferred focus lands within a few
    // milliseconds of macOS restoring the destination's remembered app. Plain quick switch
    // must queue nothing, so the desktop settles on whatever macOS chose.
    @Test("Quick switch queues no focus for the settled desktop")
    func quickSwitchQueuesNoFocus() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService, keyboardService) = makeKeyedController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        let spaceB = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 55, ownerBundleID: "com.b", ownerName: "B", windowTitle: "W"),
            toSpaceID: spaceB)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        keyboardService.simulateEvent(.switchToSpace(2))
        controller.desktopDidChange()

        #expect(spaces.switchRequests == [1])
        #expect(controller.spaceManager.activeSpaceID == spaceB)
        #expect(windowService.raisedWindowIDs.isEmpty)
        #expect(windowService.activatedBundleID == nil)
    }

    // Skipping the focus is not enough on its own. A focus queued by an earlier switch that is
    // still settling survives, and firing it later would activate an app the plain switch was
    // supposed to leave to macOS. `applyPendingSpaceFocus` only drops a queue whose space is
    // not the one that settled, so a re-switch to that same space slips straight through it.
    @Test("Quick switch clears a focus queued by an earlier switch")
    func quickSwitchClearsPendingFocus() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService, keyboardService) = makeKeyedController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        let spaceA = controller.spaceManager.spaces[0].id
        let spaceB = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 11, ownerBundleID: "com.a", ownerName: "A", windowTitle: "WA"),
            toSpaceID: spaceA)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 22, ownerBundleID: "com.a", ownerName: "A", windowTitle: "WB"),
            toSpaceID: spaceB)
        controller.spaceManager.activateSpace(id: spaceA)

        // Control+Option+2 still focuses, so this queues window 22 while the desktop settles.
        keyboardService.simulateEvent(.switchToSpaceKeepingCurrentApplication(2))
        #expect(windowService.raisedWindowIDs.isEmpty)

        // A plain Control+2 on the space already being switched to must discard that queue.
        keyboardService.simulateEvent(.switchToSpace(2))
        controller.desktopDidChange()

        #expect(controller.spaceManager.activeSpaceID == spaceB)
        #expect(windowService.raisedWindowIDs.isEmpty)
        #expect(windowService.activatedBundleID == nil)
    }

    // Nothing has to settle when the desktop is already right, and waiting for a change that
    // will never come would leave the window unfocused forever.
    @Test("A switch that changes no desktop focuses straight away")
    func sameDesktopSwitchFocusesImmediately() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, windowService) = makeController(spaces: spaces)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 55, ownerBundleID: "com.a", ownerName: "A", windowTitle: "W"),
            toSpaceID: controller.spaceManager.spaces[0].id)

        controller.switchToSpace(id: controller.spaceManager.spaces[0].id)

        #expect(windowService.raisedWindowIDs.contains(55))
    }

    // A switch the user overtakes — hitting Control+3 while Control+2 is still settling —
    // must not drag focus back to the space they left behind.
    @Test("Focus is dropped when the desktop settles somewhere else")
    func pendingFocusDroppedOnDifferentDesktop() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, windowService) = makeController(spaces: spaces)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 55, ownerBundleID: "com.b", ownerName: "B", windowTitle: "W"),
            toSpaceID: controller.spaceManager.spaces[1].id)
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[0].id)

        controller.switchToSpace(id: controller.spaceManager.spaces[1].id)
        spaces.current = 2
        controller.desktopDidChange()

        #expect(!windowService.raisedWindowIDs.contains(55))
    }

    // A space assignment that does not relocate the window is only a label: the window would
    // stay visible on the desktop it started on, in every space.
    @Test("Assigning a window to another space moves it to that desktop")
    func dragMovesWindowToDesktop() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let spaceA = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: spaceA)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceA)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(windowID: 101, fromSpaceIndex: 0, toSpaceIndex: 1,
                                            toWindowIndex: 0))

        #expect(spaces.moveRequests.isEmpty)
        keyboardService.simulateEvent(.cmdRelease)
        #expect(spaces.moveRequests.map(\.windowID) == [101])
        #expect(spaces.moveRequests.map(\.desktop) == [1])
    }

    // The overlay reconciles on every open, so a reconcile now lands in the middle of a session
    // holding an uncommitted move. Aligning spaces to the desktop order must carry the previewed
    // move with them: rebuilding the array from macOS and losing the preview would show the user
    // one thing and commit another.
    @Test("A reconcile during an uncommitted move preserves the preview")
    @MainActor
    func reconcileDuringPendingMoveKeepsPreview() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.completesMovesImmediately = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        controller.reconcileSpacesWithDesktops()
        let spaceA = controller.spaceManager.spaces[0].id
        let spaceB = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceA
        )
        controller.spaceManager.activateSpace(id: spaceA)

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.moveWindowDown)
        // The overlay shows the move straight away while the live model waits for the commit,
        // so the two deliberately disagree here. E2E reads the overlay's copy.
        #expect(controller.overlaySpaceManager.spaces.map(\.windows.count) == [0, 1])
        #expect(controller.spaceManager.spaces.map(\.windows.count) == [1, 0])

        controller.reconcileSpacesWithDesktops()

        #expect(controller.overlaySpaceManager.spaces.map(\.windows.count) == [0, 1])
        #expect(controller.spaceManager.spaces.map(\.windows.count) == [1, 0])

        keyboardService.simulateEvent(.cmdRelease)

        #expect(spaces.moveRequests.map(\.windowID) == [101])
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 101) == spaceB)
    }

    @Test("Arrow-key moves reach the window server only when the session commits")
    @MainActor
    func keyboardMoveWaitsForCommit() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.completesMovesImmediately = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let spaceA = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: spaceA)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceA
        )

        keyboardService.simulateEvent(.cmdTabHold)
        keyboardService.simulateEvent(.moveWindowDown)

        #expect(spaces.moveRequests.isEmpty)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 101) == spaceA)

        keyboardService.simulateEvent(.cmdRelease)

        #expect(spaces.moveRequests.map(\.windowID) == [101])
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.isSpaceManagerVisible)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 101)
                == controller.spaceManager.spaces[1].id)

        spaces.completePendingMoves()

        #expect(spaces.switchRequests == [1])
        #expect(!controller.isSpaceManagerVisible)
    }

    @Test("Space focus waits for every committed window move")
    @MainActor
    func spaceFocusWaitsForEveryWindowMove() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.completesMovesImmediately = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let spaceA = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: spaceA)
        for windowID in [CGWindowID(101), 202] {
            controller.spaceManager.addWindow(
                SpaceWindow(
                    windowID: windowID,
                    ownerBundleID: "com.\(windowID)",
                    ownerName: "App",
                    windowTitle: "Window"
                ),
                toSpaceID: spaceA
            )
        }

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(
            windowID: 101,
            fromSpaceIndex: 0,
            toSpaceIndex: 1,
            toWindowIndex: 0
        ))
        #expect(controller.moveWindowByDrag(
            windowID: 202,
            fromSpaceIndex: 0,
            toSpaceIndex: 1,
            toWindowIndex: 1
        ))
        controller.jumpToSpace(index: 1)

        keyboardService.simulateEvent(.cmdRelease)
        #expect(spaces.moveRequests.map(\.windowID) == [101, 202])
        #expect(spaces.switchRequests.isEmpty)

        spaces.completeNextMove()
        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.isSpaceManagerVisible)

        spaces.completeNextMove()
        #expect(spaces.switchRequests == [1])
        #expect(!controller.isSpaceManagerVisible)
    }

    @Test("Reordering within a space does not move the window between desktops")
    func withinSpaceDoesNotMove() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let spaceA = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceA)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: spaceA)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(windowID: 202, fromSpaceIndex: 0, toSpaceIndex: 0,
                                            toWindowIndex: 0))
        keyboardService.simulateEvent(.cmdRelease)

        #expect(spaces.moveRequests.isEmpty)
    }

    // The transport is a private-API bridge that fails by doing nothing. If it ever goes
    // inert, a move that still updated the model would leave the stage on one space and the
    // window on another desktop, persisted, with nothing to correct it.
    @Test("A cross-space move is refused outright when the transport is unavailable")
    func refusesMoveWithoutTransport() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.canMoveWindows = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let spaceA = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        controller.spaceManager.activateSpace(id: spaceA)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceA)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(!controller.moveWindowByDrag(windowID: 101, fromSpaceIndex: 0, toSpaceIndex: 1,
                                             toWindowIndex: 0))
        #expect(spaces.moveRequests.isEmpty)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 101) == spaceA)
    }

    // Reordering inside one space never touches a desktop, so it must survive the gate.
    @Test("Reordering within a space still works when the transport is unavailable")
    func reordersWithoutTransport() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        spaces.canMoveWindows = false
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        let spaceA = controller.spaceManager.spaces[0].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"),
            toSpaceID: spaceA)
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"),
            toSpaceID: spaceA)

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByDrag(windowID: 202, fromSpaceIndex: 0, toSpaceIndex: 0,
                                            toWindowIndex: 0))
        #expect(controller.spaceManager.spaces[0].windows.first?.windowID == 101)
        keyboardService.simulateEvent(.cmdRelease)
        #expect(controller.spaceManager.spaces[0].windows.first?.windowID == 202)
    }

    @Test("Missing desktops are added as spaces")
    func growsToDesktops() {
        let spaces = MockSpaceSwitcher(desktops: 4, current: 0)
        let (controller, _) = makeController(spaces: spaces)

        controller.reconcileSpacesWithDesktops()

        #expect(controller.spaceManager.spaces.count == 4)
    }

    // Reconciling only at launch means a desktop added from Mission Control is invisible for
    // the rest of the session: the space list stops equalling the desktop list, and every
    // window on the new desktop reports an index past the end of the space array. Debut cannot
    // ask to be relaunched, so the notification that already tells it the Space changed has to
    // recheck the shape of the desktop list too.
    @Test("A desktop added while Debut runs becomes a space")
    func desktopChangeGrowsTheSpaceList() {
        let spaces = MockSpaceSwitcher(desktops: 2, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.reconcileSpacesWithDesktops()

        spaces.desktops = 4
        controller.desktopDidChange()

        #expect(controller.spaceManager.spaces.count == 4)
    }

    @Test("A desktop removed while Debut runs stops being a space")
    func desktopChangeShrinksTheSpaceList() {
        let spaces = MockSpaceSwitcher(desktops: 4, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.reconcileSpacesWithDesktops()

        spaces.desktops = 2
        controller.desktopDidChange()

        #expect(controller.spaceManager.spaces.count == 2)
    }

    // Removing an inactive desktop in Mission Control does not necessarily change the active
    // Space, so AppKit may give Debut no active-space notification to react to. The overlay is
    // the first place the stale space becomes visible and must recheck macOS before presenting.
    @Test("Opening the overlay detects an inactive desktop removed in Mission Control")
    func overlayOpenShrinksTheSpaceList() {
        let spaces = MockSpaceSwitcher(desktops: 5, current: 0)
        let (controller, _, keyboardService) = makeKeyedController(spaces: spaces)
        controller.reconcileSpacesWithDesktops()
        #expect(controller.spaceManager.spaces.count == 5)
        let delegate = SpaceMutationDelegate()
        controller.delegate = delegate

        spaces.desktops = 4
        keyboardService.simulateEvent(.cmdOptionTabHold)

        #expect(controller.spaceManager.spaces.count == 4)
        #expect(controller.overlaySpaceManager.spaces.count == 4)
        #expect(delegate.mutationCount == 1)
    }

    // Dragging desktops around in Mission Control changes their order but not their number, so
    // a reconcile that compares counts sees nothing and stays silent. Nothing then persists the
    // new order or redraws the overlay, and the stale order outlives the session.
    @Test("Reordering desktops permutes the spaces and reports the mutation")
    func reorderPermutesSpacesAndReports() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.reconcileSpacesWithDesktops()
        let before = controller.spaceManager.spaces.map(\.id)
        let delegate = SpaceMutationDelegate()
        controller.delegate = delegate

        spaces.desktopKeys = [0, 2, 1]
        controller.reconcileSpacesWithDesktops()

        #expect(controller.spaceManager.spaces.map(\.id) == [before[0], before[2], before[1]])
        #expect(delegate.mutationCount == 1)
    }

    // The overlay reconciles on every open, so a reconcile that changed nothing must stay quiet;
    // reporting anyway would persist and redraw on each Cmd+Tab.
    @Test("A reconcile that changes nothing reports no mutation")
    func unchangedReconcileIsSilent() {
        let spaces = MockSpaceSwitcher(desktops: 3, current: 0)
        let (controller, _) = makeController(spaces: spaces)
        controller.reconcileSpacesWithDesktops()
        let delegate = SpaceMutationDelegate()
        controller.delegate = delegate

        controller.reconcileSpacesWithDesktops()

        #expect(delegate.mutationCount == 0)
    }

    // A window server that answers "no desktops" is answered with silence: the space list is
    // left alone, which is right, but the caller cannot tell that apart from a host that
    // genuinely has one desktop. E2E caught Debut launching with one space against three real
    // desktops and there was nothing in the log to say which step had declined.
    @Test("A reconcile that cannot see any desktop reports that it refused")
    func refusalIsObservable() {
        var manager = SpaceManager()
        manager.createSpace(position: .below)

        let outcome = SpaceController.reconcileSpaces(&manager, desktopCount: 0)

        #expect(outcome.refused)
        #expect(outcome.spacesBefore == 2)
        #expect(outcome.spacesAfter == 2)
        #expect(manager.spaces.count == 2)
    }

    @Test("A reconcile reports the desktop count it acted on")
    func reconciliationReportsWhatItSaw() {
        var manager = SpaceManager()

        let outcome = SpaceController.reconcileSpaces(&manager, desktopCount: 3)

        #expect(!outcome.refused)
        #expect(outcome.desktopCount == 3)
        #expect(outcome.spacesBefore == 1)
        #expect(outcome.spacesAfter == 3)
    }
}
