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
/// appended, and a removed desktop's windows land on the desktop showing.
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

    func createDesktop(onStack stackID: String,
                       completion: @escaping @Sendable (DesktopLocation?) -> Void) {
        keys.append(nextKey)
        nextKey += 1
        completion(spaceTopology().stacks[0].location(at: keys.count - 1))
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
