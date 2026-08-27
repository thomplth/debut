import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Multi-display Spaces")
struct MultiDisplaySpaceTests {
    private let topology = SpaceTopology(
        separateSpaces: true,
        stacks: [
            SpaceStackDescriptor(
                id: "display-a",
                displayID: 1,
                displayName: "Built-in Display",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                desktopIDs: [3, 4916],
                currentDesktopID: 4916
            ),
            SpaceStackDescriptor(
                id: "display-b",
                displayID: 5,
                displayName: "Studio Display",
                frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                desktopIDs: [5338, 5370, 5400],
                currentDesktopID: 5338
            ),
        ]
    )

    @Test("Separate Spaces creates one independently active space stack per display")
    func separateStacks() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: topology)

        #expect(manager.spaceStacks.count == 2)
        #expect(manager.selectedSpaceStackID == "display-a")
        #expect(manager.spaces.count == 2)
        #expect(manager.activeSpaceID == manager.spaces[1].id)

        manager.selectSpaceStack(id: "display-b")
        #expect(manager.spaces.count == 3)
        #expect(manager.activeSpaceID == manager.spaces[0].id)
    }

    @Test("Cycling wraps through display stacks and preserves each active space")
    func cyclesStacks() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: topology)
        let activeOnA = manager.activeSpaceID

        manager.selectNextSpaceStack()
        let spaceOnB = manager.spaces[2].id
        manager.activateSpace(id: spaceOnB)
        #expect(manager.selectedSpaceStackID == "display-b")

        manager.selectNextSpaceStack()
        #expect(manager.selectedSpaceStackID == "display-a")
        #expect(manager.activeSpaceID == activeOnA)

        manager.selectNextSpaceStack()
        #expect(manager.activeSpaceID == spaceOnB)
    }

    @Test("Shared Spaces exposes one stack for the whole display wall")
    func sharedStack() {
        let shared = SpaceTopology(
            separateSpaces: false,
            stacks: [
                SpaceStackDescriptor(
                    id: SpaceTopology.sharedStackID,
                    displayID: nil,
                    displayName: "All Displays",
                    frame: .zero,
                    desktopIDs: [10, 11, 12],
                    currentDesktopID: 11
                ),
            ]
        )
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: shared)

        #expect(manager.spaceStacks.count == 1)
        #expect(manager.selectedSpaceStackID == SpaceTopology.sharedStackID)
        #expect(manager.spaces.count == 3)
        #expect(manager.activeSpaceID == manager.spaces[1].id)
    }

    @Test("Desktop locations include display stack identity")
    func desktopLocations() {
        #expect(topology.location(ofSpace: 5370) == DesktopLocation(
            stackID: "display-b",
            desktopID: 5370,
            index: 1
        ))
        #expect(topology.location(ofSpace: 4916)?.stackID == "display-a")
        #expect(topology.location(ofSpace: 9999) == nil)
    }

    @Test("Enabling separate Spaces preserves the existing shared stack on the first display")
    func sharedToSeparateMigration() {
        var manager = SpaceManager()
        manager.createSpace(position: .below)
        manager.addWindow(
            SpaceWindow(windowID: 70, ownerBundleID: "com.example", ownerName: "Example", windowTitle: "Example"),
            toSpaceID: manager.spaces[1].id
        )

        manager.reconcileSpaceStacks(with: topology)

        #expect(manager.spaceStacks.count == 2)
        #expect(manager.spaceStacks[0].id == "display-a")
        #expect(manager.spaceStacks[0].spaces[1].windowIDs == [70])
    }

    @Test("Disabling separate Spaces merges display stacks into the shared stack")
    func separateToSharedMigration() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: topology)
        manager.addWindow(
            SpaceWindow(windowID: 70, ownerBundleID: "com.a", ownerName: "A", windowTitle: "A"),
            toSpaceID: manager.spaceID(stackID: "display-a", at: 1)!
        )
        manager.addWindow(
            SpaceWindow(windowID: 80, ownerBundleID: "com.b", ownerName: "B", windowTitle: "B"),
            toSpaceID: manager.spaceID(stackID: "display-b", at: 1)!
        )
        let shared = SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: SpaceTopology.sharedStackID,
                displayID: nil,
                displayName: "All Displays",
                frame: .zero,
                desktopIDs: [10, 11, 12],
                currentDesktopID: 10
            ),
        ])

        manager.reconcileSpaceStacks(with: shared)

        #expect(manager.spaceStacks.count == 1)
        #expect(Set(manager.spaces[1].windowIDs) == [70, 80])
    }
}
