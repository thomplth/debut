import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

/// Creating and removing a macOS desktop is only honest where the Dock adopts the result.
/// macOS 26's window server accepts the same request and builds a desktop the Dock never hears
/// about, which neither the return value nor the desktop list can distinguish (KHA-1087).
@Suite("Desktop management")
struct DesktopManagementTests {

    @Test("Only macOS 27 manages desktops; 26 would build a desktop the Dock never adopts")
    func compatibilityIsMacOS27Only() {
        #expect(!DesktopManagementCompatibility.supports(operatingSystemMajor: 26))
        #expect(DesktopManagementCompatibility.supports(operatingSystemMajor: 27))
        // Unmeasured releases stay off until someone verifies the Dock still adopts the desktop.
        #expect(!DesktopManagementCompatibility.supports(operatingSystemMajor: 28))
    }

    private func topology(
        _ stacks: [(id: String, desktops: [CGSSpaceID], current: CGSSpaceID?)]
    ) -> SpaceTopology {
        SpaceTopology(separateSpaces: stacks.count > 1, stacks: stacks.map { stack in
            SpaceStackDescriptor(
                id: stack.id, displayID: nil, displayName: stack.id, frame: .zero,
                desktopIDs: stack.desktops, currentDesktopID: stack.current
            )
        })
    }

    @Test("A created desktop is found on the stack it was requested for")
    func createdDesktopIsLocated() {
        let after = topology([("main", [3, 4, 4901], 3)])
        #expect(DesktopManagementPlan.createdLocation(of: 4901, onStack: "main", in: after)
            == DesktopLocation(stackID: "main", desktopID: 4901, index: 2))
    }

    @Test("A desktop that lands on another display is not reported as created")
    func createdDesktopOnWrongStackIsRejected() {
        let after = topology([("left", [3, 4], 3), ("right", [5, 4901], 5)])
        #expect(DesktopManagementPlan.createdLocation(of: 4901, onStack: "left", in: after) == nil)
    }

    @Test("A desktop the Dock has not listed yet is not reported as created")
    func unlistedDesktopIsNotCreated() {
        let after = topology([("main", [3, 4], 3)])
        #expect(DesktopManagementPlan.createdLocation(of: 4901, onStack: "main", in: after) == nil)
    }

    @Test("Removal refuses the last desktop, the showing desktop and an unknown one")
    func removalRefusals() {
        let shared = topology([("main", [3, 4, 5], 4)])
        #expect(DesktopManagementPlan.removalRefusal(
            for: DesktopLocation(stackID: "main", desktopID: 4, index: 1), in: shared
        ) == .showingDesktop)
        #expect(DesktopManagementPlan.removalRefusal(
            for: DesktopLocation(stackID: "main", desktopID: 5, index: 2), in: shared
        ) == nil)
        #expect(DesktopManagementPlan.removalRefusal(
            for: DesktopLocation(stackID: "main", desktopID: 9, index: 2), in: shared
        ) == .unknownDesktop)

        let single = topology([("main", [3], nil)])
        #expect(DesktopManagementPlan.removalRefusal(
            for: DesktopLocation(stackID: "main", desktopID: 3, index: 0), in: single
        ) == .lastDesktop)
    }

    @Test("A new desktop moves to the top, after its anchor, or nowhere when already in place")
    func placementIndex() {
        // 9 is the new desktop, appended last; 20 is a fullscreen Space after desktop 3.
        let stack = SpaceStackDescriptor(
            id: "main", displayID: nil, displayName: "main", frame: .zero,
            desktopIDs: [3, 4, 9], orderedSpaceIDs: [3, 20, 4, 9], currentDesktopID: 3
        )
        #expect(DesktopManagementPlan.orderedIndex(placing: 9, at: .start, in: stack) == 0)
        // Straight after its anchor, ahead of the fullscreen Space that follows it.
        #expect(DesktopManagementPlan.orderedIndex(placing: 9, at: .after(3), in: stack) == 1)
        #expect(DesktopManagementPlan.orderedIndex(placing: 9, at: .after(4), in: stack) == nil)
        #expect(DesktopManagementPlan.orderedIndex(placing: 9, at: .end, in: stack) == nil)
        #expect(DesktopManagementPlan.orderedIndex(placing: 9, at: .after(77), in: stack) == nil)
    }

    @Test("A conformer that cannot manage desktops refuses without side effects")
    func defaultConformerIsInert() {
        let switcher = MockSpaceSwitcher(desktops: 2, current: 0)
        #expect(!switcher.canManageDesktops)
        nonisolated(unsafe) var created: DesktopLocation?? = .none
        switcher.createDesktop(onStack: SpaceTopology.sharedStackID) { created = .some($0) }
        #expect(created == .some(nil))
        #expect(switcher.desktopCount() == 2)
    }
}

/// A switcher that can add and remove desktops the way macOS 27 does: a new desktop is
/// appended and then moved into place, and a removed desktop's windows land on the desktop
/// showing.
private final class ManagingSpaceSwitcher: SpaceSwitching, @unchecked Sendable {
    var keys: [Int]
    var current: Int
    var windowDesktops: [CGWindowID: Int] = [:]
    private var nextKey: Int

    init(desktops: Int, current: Int) {
        keys = Array(0..<desktops)
        nextKey = desktops
        self.current = current
    }

    func spaceTopology() -> SpaceTopology {
        let ids = keys.map { CGSSpaceID($0 + 100) }
        return SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: SpaceTopology.sharedStackID, displayID: nil, displayName: "All Displays",
                frame: .zero, desktopIDs: ids, desktopUUIDs: keys.map { "DESKTOP-\($0)" },
                currentDesktopID: ids[current], currentDesktopUUID: "DESKTOP-\(keys[current])"
            ),
        ])
    }

    func desktopCount() -> Int { keys.count }
    func currentDesktopIndex() -> Int? { current }
    func desktopIndex(forWindow windowID: CGWindowID) -> Int? { windowDesktops[windowID] }
    func switchToDesktop(index: Int) -> Bool { current = index; return true }
    var canMoveWindows: Bool { true }
    func moveWindow(windowID: CGWindowID, toDesktop: Int, completion: (@Sendable (Bool) -> Void)?) {
        windowDesktops[windowID] = toDesktop
        completion?(true)
    }

    var canManageDesktops: Bool { true }

    func createDesktop(onStack stackID: String, placement: DesktopPlacement,
                       completion: @escaping @Sendable (DesktopLocation?) -> Void) {
        let showingKey = keys[current]
        keys.append(nextKey)
        nextKey += 1
        let stack = spaceTopology().stacks[0]
        let created = stack.desktopIDs.last!
        if let target = DesktopManagementPlan.orderedIndex(placing: created, at: placement, in: stack) {
            let key = keys.removeLast()
            keys.insert(key, at: target)
            for (windowID, desktop) in windowDesktops where desktop >= target {
                windowDesktops[windowID] = desktop + 1
            }
        }
        current = keys.firstIndex(of: showingKey)!
        let index = keys.firstIndex(of: nextKey - 1)!
        completion(spaceTopology().stacks[0].location(at: index))
    }

    func moveDesktop(_ location: DesktopLocation, placement: DesktopPlacement,
                     completion: @escaping @Sendable (DesktopLocation?) -> Void) {
        let stack = spaceTopology().stacks[0]
        guard let target = DesktopManagementPlan.orderedIndex(
            placing: location.desktopID, at: placement, in: stack
        ) else { return completion(stack.location(at: location.index)) }
        let showingKey = keys[current]
        let key = keys.remove(at: location.index)
        keys.insert(key, at: target)
        var moved: [CGWindowID: Int] = [:]
        for (windowID, desktop) in windowDesktops {
            var order = Array(0..<keys.count)
            let from = order.remove(at: location.index)
            order.insert(from, at: target)
            moved[windowID] = order.firstIndex(of: desktop)!
        }
        windowDesktops = moved
        current = keys.firstIndex(of: showingKey)!
        completion(spaceTopology().stacks[0].location(at: target))
    }

    func removeDesktop(_ location: DesktopLocation,
                       completion: @escaping @Sendable (Bool) -> Void) {
        guard DesktopManagementPlan.removalRefusal(for: location, in: spaceTopology()) == nil
        else { completion(false); return }
        let showingKey = keys[current]
        keys.remove(at: location.index)
        current = keys.firstIndex(of: showingKey)!
        for (windowID, desktop) in windowDesktops {
            if desktop == location.index { windowDesktops[windowID] = current }
            else if desktop > location.index { windowDesktops[windowID] = desktop - 1 }
        }
        completion(true)
    }
}

@Suite("SpaceController desktop management")
@MainActor
struct SpaceControllerDesktopManagementTests {

    private func makeController(_ switcher: any SpaceSwitching) -> SpaceController {
        let controller = SpaceController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .unfocused }
        )
        controller.spaceSwitcher = switcher
        controller.reconcileSpacesWithDesktops()
        return controller
    }

    @Test("Adding a desktop appends a space joined to it")
    func addingAppendsSpace() {
        let switcher = ManagingSpaceSwitcher(desktops: 2, current: 0)
        let controller = makeController(switcher)
        #expect(controller.canManageDesktops)

        nonisolated(unsafe) var added: UUID?
        controller.addDesktop { added = $0 }

        #expect(controller.spaceManager.spaces.count == 3)
        #expect(added == controller.spaceManager.spaces[2].id)
        #expect(controller.spaceManager.spaces[2].desktopUUID == "DESKTOP-2")
    }

    @Test("Removing a desktop files its windows under the showing space, as macOS does")
    func removingRefilesWindowsOnShowingSpace() {
        let switcher = ManagingSpaceSwitcher(desktops: 3, current: 0)
        let controller = makeController(switcher)
        let showingID = controller.spaceManager.spaces[0].id
        let doomedID = controller.spaceManager.spaces[2].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 41, ownerBundleID: "com.apple.TextEdit", ownerName: "TextEdit",
                        windowTitle: "Notes", ownerPID: 400),
            toSpaceID: doomedID
        )
        switcher.windowDesktops[41] = 2

        nonisolated(unsafe) var removed: Bool?
        controller.removeDesktop(spaceID: doomedID) { removed = $0 }

        #expect(removed == true)
        #expect(controller.spaceManager.spaces.count == 2)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 41) == showingID)
    }

    @Test("A quit app's windows saved on a removed desktop follow to the showing space")
    func removingKeepsDormantAssignments() {
        let switcher = ManagingSpaceSwitcher(desktops: 3, current: 0)
        let controller = makeController(switcher)
        let showingID = controller.spaceManager.spaces[0].id
        let doomedID = controller.spaceManager.spaces[1].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 52, ownerBundleID: "com.apple.Notes", ownerName: "Notes",
                        windowTitle: "List", ownerPID: 500),
            toSpaceID: doomedID
        )
        _ = controller.spaceManager.makeWindowDormant(windowID: 52)

        controller.removeDesktop(spaceID: doomedID)

        #expect(controller.spaceManager.dormantWindowAssignments.map(\.spaceID) == [showingID])
    }

    @Test("Removing the showing desktop is refused and changes nothing")
    func removingShowingDesktopIsRefused() {
        let switcher = ManagingSpaceSwitcher(desktops: 2, current: 1)
        let controller = makeController(switcher)
        let showingID = controller.spaceManager.spaces[1].id

        nonisolated(unsafe) var removed: Bool?
        controller.removeDesktop(spaceID: showingID) { removed = $0 }

        #expect(removed == false)
        #expect(switcher.keys.count == 2)
        #expect(controller.spaceManager.spaces.count == 2)
    }

    @Test("A switcher that cannot manage desktops leaves the model alone")
    func inertSwitcherChangesNothing() {
        let controller = makeController(MockSpaceSwitcher(desktops: 2, current: 0))
        #expect(!controller.canManageDesktops)

        nonisolated(unsafe) var added: UUID?? = .none
        controller.addDesktop { added = .some($0) }

        #expect(added == .some(nil))
        #expect(controller.spaceManager.spaces.count == 2)
    }
}

/// Adding and removing desktops from the overlay is staged like every other overlay edit:
/// macOS gains or loses a desktop only when the session commits, and Escape leaves nothing.
@Suite("Overlay desktop staging")
@MainActor
struct OverlayDesktopStagingTests {

    private func make(desktops: Int, current: Int)
        -> (SpaceController, ManagingSpaceSwitcher, MockKeyboardService) {
        let switcher = ManagingSpaceSwitcher(desktops: desktops, current: current)
        let keyboard = MockKeyboardService()
        let controller = SpaceController(
            windowService: MockWindowService(),
            keyboardService: keyboard,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        controller.spaceSwitcher = switcher
        controller.reconcileSpacesWithDesktops()
        return (controller, switcher, keyboard)
    }

    private func place(_ windowID: CGWindowID, onSpace index: Int,
                       _ controller: SpaceController, _ switcher: ManagingSpaceSwitcher) {
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: windowID, ownerBundleID: "com.example.\(windowID)",
                        ownerName: "App \(windowID)", windowTitle: "Window \(windowID)",
                        ownerPID: pid_t(windowID)),
            toSpaceID: controller.spaceManager.spaces[index].id
        )
        switcher.windowDesktops[windowID] = index
    }

    private func newDesktopDrop(_ windowID: CGWindowID, from index: Int,
                                _ controller: SpaceController) -> PointerWindowDropRequest {
        let preview = controller.overlaySpaceManager
        let source = preview.spaces[index]
        return PointerWindowDropRequest(
            windowID: windowID,
            modelID: source.windows.first { $0.windowID == windowID }!.id,
            fromSpaceID: source.id,
            toSpaceID: UUID(),
            logicalIndex: 0,
            placement: .start,
            fingerprint: StageStructureFingerprint(spaces: preview.spaces),
            newDesktopPosition: .bottom
        )
    }

    @Test("⌘N shows a new desktop after the selected one at once, created only on release")
    func addIsStagedUntilRelease() {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 0)
        let firstID = controller.spaceManager.spaces[0].id
        let secondID = controller.spaceManager.spaces[1].id

        keyboard.simulateEvent(.cmdTabHold)
        controller.jumpToSpace(index: 0)
        keyboard.simulateEvent(.addDesktop)

        #expect(controller.overlaySpaceManager.spaces.count == 4)
        #expect(controller.overlaySpaceManager.spaces[0].id == firstID)
        #expect(controller.overlaySpaceManager.spaces[2].id == secondID)
        #expect(controller.selectedSpaceIndex == 1)
        #expect(switcher.keys.count == 3)
        #expect(controller.spaceManager.spaces.count == 3)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys == [0, 3, 1, 2])
        #expect(controller.spaceManager.spaces.count == 4)
        #expect(controller.spaceManager.spaces[0].id == firstID)
        #expect(controller.spaceManager.spaces[1].desktopUUID == "DESKTOP-3")
        #expect(controller.spaceManager.spaces[2].id == secondID)
        // The new desktop was selected, so the commit switches to it.
        #expect(switcher.current == 1)
    }

    @Test("The + above the first plate and below the last put the desktop at that end, keeping the selection")
    func addAtEitherEnd() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 1)

        keyboard.simulateEvent(.cmdTabHold)
        controller.jumpToSpace(index: 0)
        let selectedID = controller.overlaySpaceManager.spaces[0].id
        let top = controller.stageNewDesktop(at: .top)
        let bottom = controller.stageNewDesktop(at: .bottom)

        let preview = controller.overlaySpaceManager.spaces.map(\.id)
        #expect(preview.count == 4)
        #expect(preview.first == top)
        #expect(preview.last == bottom)
        #expect(preview[safe: controller.selectedSpaceIndex] == selectedID)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys == [2, 0, 1, 3])
        #expect(controller.spaceManager.spaces.map(\.desktopUUID)
            == ["DESKTOP-2", "DESKTOP-0", "DESKTOP-1", "DESKTOP-3"])
        #expect(switcher.current == 1)
    }

    @Test("A desktop added after another staged desktop lands after it once both exist")
    func addAfterStagedDesktop() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 0)

        keyboard.simulateEvent(.cmdTabHold)
        controller.jumpToSpace(index: 0)
        keyboard.simulateEvent(.addDesktop)
        keyboard.simulateEvent(.addDesktop)
        #expect(controller.selectedSpaceIndex == 2)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys == [0, 2, 3, 1])
    }

    @Test("Taking back a staged desktop hands its place to one staged after it")
    func unstagedPredecessorHandsOverItsPlace() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 0)

        keyboard.simulateEvent(.cmdTabHold)
        controller.jumpToSpace(index: 0)
        keyboard.simulateEvent(.addDesktop)
        keyboard.simulateEvent(.addDesktop)
        #expect(controller.stageDesktopRemoval(spaceIndex: 1, into: 0))
        #expect(controller.overlaySpaceManager.spaces.count == 3)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys == [0, 2, 1])
    }

    @Test("Escape leaves no desktop behind")
    func escapeDiscardsStagedDesktop() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 0)

        keyboard.simulateEvent(.cmdTabHold)
        keyboard.simulateEvent(.addDesktop)
        keyboard.simulateEvent(.escape)
        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys.count == 2)
        #expect(controller.spaceManager.spaces.count == 2)
        #expect(controller.overlaySpaceManager.spaces.count == 2)
    }

    @Test("A window dropped on the top + gets a new first desktop")
    func dropIntoNewTopDesktop() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 0)
        place(41, onSpace: 1, controller, switcher)

        keyboard.simulateEvent(.cmdTabHold)
        let bottom = newDesktopDrop(41, from: 1, controller)
        let request = PointerWindowDropRequest(
            windowID: bottom.windowID, modelID: bottom.modelID, fromSpaceID: bottom.fromSpaceID,
            toSpaceID: bottom.toSpaceID, logicalIndex: 0, placement: .start,
            fingerprint: bottom.fingerprint, newDesktopPosition: .top
        )
        #expect(controller.moveWindowByPointerDrop(request) == .accepted)
        #expect(controller.overlaySpaceManager.spaces[0].id == request.toSpaceID)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys == [2, 0, 1])
        #expect(switcher.windowDesktops[41] == 0)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 41)
            == controller.spaceManager.spaces[0].id)
    }

    @Test("A window dropped on a + adds its desktop and leaves the selection where it was",
          arguments: [NewDesktopPosition.top, .bottom])
    func dropIntoNewDesktopKeepsSelection(position: NewDesktopPosition) {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 0)
        place(41, onSpace: 2, controller, switcher)

        keyboard.simulateEvent(.cmdTabHold)
        controller.jumpToSpace(index: 1)
        let selectedID = controller.overlaySpaceManager.spaces[1].id
        let drop = newDesktopDrop(41, from: 2, controller)
        let request = PointerWindowDropRequest(
            windowID: drop.windowID, modelID: drop.modelID, fromSpaceID: drop.fromSpaceID,
            toSpaceID: drop.toSpaceID, logicalIndex: 0, placement: .start,
            fingerprint: drop.fingerprint, newDesktopPosition: position
        )
        #expect(controller.moveWindowByPointerDrop(request) == .accepted)

        #expect(controller.overlaySpaceManager.spaces[safe: controller.selectedSpaceIndex]?.id
            == selectedID)
    }

    @Test("A window dropped on the new-desktop target moves there after the desktop is created")
    func dropIntoNewDesktop() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 0)
        place(41, onSpace: 0, controller, switcher)

        keyboard.simulateEvent(.cmdTabHold)
        let request = newDesktopDrop(41, from: 0, controller)
        #expect(controller.moveWindowByPointerDrop(request) == .accepted)

        let preview = controller.overlaySpaceManager
        #expect(preview.spaces.count == 3)
        #expect(preview.spaces[2].id == request.toSpaceID)
        #expect(preview.spaceContainingWindow(windowID: 41) == request.toSpaceID)
        #expect(switcher.keys.count == 2)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys.count == 3)
        #expect(switcher.windowDesktops[41] == 2)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 41)
            == controller.spaceManager.spaces[2].id)
    }

    @Test("A refused drop does not leave an empty staged desktop")
    func refusedDropUnstagesDesktop() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 0)
        place(41, onSpace: 0, controller, switcher)

        keyboard.simulateEvent(.cmdTabHold)
        let stale = newDesktopDrop(41, from: 0, controller)
        let request = PointerWindowDropRequest(
            windowID: stale.windowID, modelID: UUID(), fromSpaceID: stale.fromSpaceID,
            toSpaceID: stale.toSpaceID, logicalIndex: 0, placement: .start,
            fingerprint: stale.fingerprint, newDesktopPosition: .bottom
        )

        #expect(controller.moveWindowByPointerDrop(request) == .rejected("window identity changed"))
        #expect(controller.overlaySpaceManager.spaces.count == 2)
    }

    @Test("⌘⌫ removes the selected desktop and its windows join the desktop showing")
    func removeSelectedDesktop() {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 0)
        place(41, onSpace: 2, controller, switcher)
        let showingID = controller.spaceManager.spaces[0].id

        keyboard.simulateEvent(.cmdTabHold)
        keyboard.simulateEvent(.jumpToSpace(3))
        keyboard.simulateEvent(.removeDesktop)

        #expect(controller.overlaySpaceManager.spaces.count == 2)
        #expect(controller.overlaySpaceManager.spaceContainingWindow(windowID: 41) == showingID)
        #expect(controller.selectedSpaceIndex == 0)
        #expect(switcher.keys.count == 3)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys.count == 2)
        #expect(controller.spaceManager.spaces.count == 2)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 41) == showingID)
        #expect(switcher.windowDesktops[41] == 0)
    }

    @Test("⌘⌫ on the desktop showing merges it into its neighbour and removes it after the switch")
    func removeShowingDesktop() {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 1)
        place(41, onSpace: 1, controller, switcher)
        let showingID = controller.spaceManager.spaces[1].id
        let neighbourID = controller.spaceManager.spaces[0].id

        keyboard.simulateEvent(.cmdTabHold)
        controller.jumpToSpace(index: 1)
        keyboard.simulateEvent(.removeDesktop)

        let preview = controller.overlaySpaceManager
        #expect(preview.spaces.count == 2)
        #expect(preview.spaceContainingWindow(windowID: 41) == neighbourID)
        #expect(preview.activeSpaceID == neighbourID)
        #expect(controller.selectedSpaceIndex == 0)

        keyboard.simulateEvent(.cmdRelease)

        // The commit switched to the selection; the desktop it left goes once that lands.
        #expect(switcher.current == 0)
        #expect(switcher.windowDesktops[41] == 0)
        #expect(switcher.keys.count == 3)
        controller.desktopDidChange()

        #expect(switcher.keys == [0, 2])
        #expect(!controller.spaceManager.spaces.contains { $0.id == showingID })
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 41) == neighbourID)
    }

    @Test("A desktop showing on its own merges into the one after it")
    func removeFirstShowingDesktopMergesDown() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 0)
        place(41, onSpace: 0, controller, switcher)
        let nextID = controller.spaceManager.spaces[1].id

        keyboard.simulateEvent(.cmdTabHold)
        controller.jumpToSpace(index: 0)
        keyboard.simulateEvent(.removeDesktop)

        #expect(controller.overlaySpaceManager.spaces.map(\.id) == [nextID])
        #expect(controller.overlaySpaceManager.spaceContainingWindow(windowID: 41) == nextID)
        #expect(!controller.stageDesktopRemoval(spaceIndex: 0))

        keyboard.simulateEvent(.cmdRelease)
        controller.desktopDidChange()

        #expect(switcher.keys == [1])
        #expect(switcher.windowDesktops[41] == 0)
    }

    @Test("A held plate dropped on another merges even when it is the desktop showing")
    func mergeShowingDesktopByDrag() {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 0)
        place(41, onSpace: 0, controller, switcher)
        let destinationID = controller.spaceManager.spaces[2].id

        keyboard.simulateEvent(.cmdTabHold)
        #expect(controller.stageDesktopRemoval(spaceIndex: 0, into: 2))
        keyboard.simulateEvent(.cmdRelease)
        controller.desktopDidChange()

        #expect(switcher.keys == [1, 2])
        #expect(switcher.windowDesktops[41] == 1)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 41) == destinationID)
    }

    @Test("A plate dropped into a gap merges its windows there, in order")
    func plateDropMergesIntoGap() {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 0)
        place(41, onSpace: 0, controller, switcher)
        place(42, onSpace: 0, controller, switcher)
        place(51, onSpace: 2, controller, switcher)
        place(52, onSpace: 2, controller, switcher)
        let destinationID = controller.spaceManager.spaces[0].id
        let sourceID = controller.spaceManager.spaces[2].id

        keyboard.simulateEvent(.cmdTabHold)
        let order = controller.overlaySpaceManager.windowIDs(inSpaceID: destinationID)!
        let request = PlateDropRequest(
            spaceID: sourceID,
            action: .merge(into: destinationID, placement: .between(predecessor: order[0],
                                                                    successor: order[1])),
            fingerprint: StageStructureFingerprint(spaces: controller.overlaySpaceManager.spaces)
        )
        #expect(controller.stagePlateDrop(request) == .accepted)
        let merged = controller.overlaySpaceManager.windowIDs(inSpaceID: destinationID)!
        let held = controller.spaceManager.windowIDs(inSpaceID: sourceID)!
        #expect(merged == [order[0]] + held + [order[1]])

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys == [0, 1])
        // The commit then focuses the selection, which fronts it as any commit does.
        #expect(Set(controller.spaceManager.windowIDs(inSpaceID: destinationID) ?? []) == Set(merged))
        #expect(switcher.windowDesktops[51] == 0)
    }

    @Test("A plate dropped between plates moves its desktop there on release")
    func plateDropReorders() {
        let (controller, switcher, keyboard) = make(desktops: 4, current: 0)
        place(41, onSpace: 3, controller, switcher)
        let ids = controller.spaceManager.spaces.map(\.id)

        keyboard.simulateEvent(.cmdTabHold)
        controller.jumpToSpace(index: 3)
        let request = PlateDropRequest(
            spaceID: ids[3], action: .reorder(after: ids[0]),
            fingerprint: StageStructureFingerprint(spaces: controller.overlaySpaceManager.spaces)
        )
        #expect(controller.stagePlateDrop(request) == .accepted)
        #expect(controller.overlaySpaceManager.spaces.map(\.id) == [ids[0], ids[3], ids[1], ids[2]])
        #expect(controller.selectedSpaceIndex == 1)
        #expect(switcher.keys == [0, 1, 2, 3])

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys == [0, 3, 1, 2])
        #expect(controller.spaceManager.spaces.map(\.id) == [ids[0], ids[3], ids[1], ids[2]])
        #expect(switcher.windowDesktops[41] == 1)
        #expect(switcher.current == 1)
    }

    @Test("A plate dropped back where it was changes nothing")
    func plateDropInPlaceIsNoChange() {
        let (controller, _, keyboard) = make(desktops: 3, current: 0)
        let ids = controller.spaceManager.spaces.map(\.id)
        keyboard.simulateEvent(.cmdTabHold)
        let request = PlateDropRequest(
            spaceID: ids[1], action: .reorder(after: ids[0]),
            fingerprint: StageStructureFingerprint(spaces: controller.overlaySpaceManager.spaces)
        )
        #expect(controller.stagePlateDrop(request) == .noChange)
    }

    @Test("Adds and reorders replay on release in the order they were staged")
    func addsAndReordersReplayInOrder() {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 0)
        let ids = controller.spaceManager.spaces.map(\.id)

        keyboard.simulateEvent(.cmdTabHold)
        // Move the last desktop to the top, then add one after what is now the first.
        #expect(controller.stagePlateDrop(PlateDropRequest(
            spaceID: ids[2], action: .reorder(after: nil),
            fingerprint: StageStructureFingerprint(spaces: controller.overlaySpaceManager.spaces)
        )) == .accepted)
        controller.jumpToSpace(index: 0)
        keyboard.simulateEvent(.addDesktop)
        let preview = controller.overlaySpaceManager.spaces.map(\.id)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys == [2, 3, 0, 1])
        #expect(controller.spaceManager.spaces.map(\.desktopUUID)
            == ["DESKTOP-2", "DESKTOP-3", "DESKTOP-0", "DESKTOP-1"])
        #expect(controller.spaceManager.spaces[0].id == preview[0])
    }

    @Test("Dropping a desktop onto another merges its windows there, then removes it")
    func mergeIntoChosenDesktop() {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 0)
        place(41, onSpace: 2, controller, switcher)
        let destinationID = controller.spaceManager.spaces[1].id

        keyboard.simulateEvent(.cmdTabHold)
        #expect(controller.stageDesktopRemoval(spaceIndex: 2, into: 1))
        #expect(controller.overlaySpaceManager.spaceContainingWindow(windowID: 41) == destinationID)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys.count == 2)
        #expect(switcher.windowDesktops[41] == 1)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 41) == destinationID)
    }

    @Test("Removing a desktop added in the same session takes it back; its windows return")
    func removingStagedDesktopUnstagesIt() {
        let (controller, switcher, keyboard) = make(desktops: 2, current: 0)
        place(41, onSpace: 1, controller, switcher)
        let originID = controller.spaceManager.spaces[1].id

        keyboard.simulateEvent(.cmdTabHold)
        #expect(controller.moveWindowByPointerDrop(newDesktopDrop(41, from: 1, controller))
            == .accepted)
        #expect(controller.stageDesktopRemoval(spaceIndex: 2))

        #expect(controller.overlaySpaceManager.spaces.count == 2)
        #expect(controller.overlaySpaceManager.spaceContainingWindow(windowID: 41) == originID)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys.count == 2)
        #expect(switcher.windowDesktops[41] == 1)
    }

    @Test("A window moved off a removed desktop keeps the later move")
    func moveAfterRemovalStartsFromTheMerge() {
        let (controller, switcher, keyboard) = make(desktops: 3, current: 0)
        place(41, onSpace: 2, controller, switcher)
        let targetID = controller.spaceManager.spaces[1].id

        keyboard.simulateEvent(.cmdTabHold)
        keyboard.simulateEvent(.jumpToSpace(3))
        keyboard.simulateEvent(.removeDesktop)
        // 41 now shows on the first desktop; moving it down puts it on the second.
        controller.selectedWindowIndex = 0
        keyboard.simulateEvent(.moveWindowDown)
        #expect(controller.overlaySpaceManager.spaceContainingWindow(windowID: 41) == targetID)

        keyboard.simulateEvent(.cmdRelease)

        #expect(switcher.keys.count == 2)
        #expect(switcher.windowDesktops[41] == 1)
        #expect(controller.spaceManager.spaceContainingWindow(windowID: 41) == targetID)
    }

    @Test("Without desktop management the commands change nothing")
    func inertWithoutDesktopManagement() {
        let switcher = MockSpaceSwitcher(desktops: 2, current: 0)
        let keyboard = MockKeyboardService()
        let controller = SpaceController(
            windowService: MockWindowService(),
            keyboardService: keyboard,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        controller.spaceSwitcher = switcher
        controller.reconcileSpacesWithDesktops()

        keyboard.simulateEvent(.cmdTabHold)
        keyboard.simulateEvent(.addDesktop)
        #expect(!controller.canStageDesktopChanges)
        #expect(controller.overlaySpaceManager.spaces.count == 2)
        keyboard.simulateEvent(.jumpToSpace(2))
        keyboard.simulateEvent(.removeDesktop)
        #expect(controller.overlaySpaceManager.spaces.count == 2)
    }
}
