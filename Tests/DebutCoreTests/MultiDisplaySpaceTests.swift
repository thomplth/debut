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

    @Test("Separate Spaces creates one independently active stage stack per display")
    func separateStacks() {
        var manager = StageManager()
        manager.reconcileStageStacks(with: topology)

        #expect(manager.stageStacks.count == 2)
        #expect(manager.selectedStageStackID == "display-a")
        #expect(manager.stages.count == 2)
        #expect(manager.activeStageID == manager.stages[1].id)

        manager.selectStageStack(id: "display-b")
        #expect(manager.stages.count == 3)
        #expect(manager.activeStageID == manager.stages[0].id)
    }

    @Test("Cycling wraps through display stacks and preserves each active stage")
    func cyclesStacks() {
        var manager = StageManager()
        manager.reconcileStageStacks(with: topology)
        let activeOnA = manager.activeStageID

        manager.selectNextStageStack()
        let stageOnB = manager.stages[2].id
        manager.activateStage(id: stageOnB)
        #expect(manager.selectedStageStackID == "display-b")

        manager.selectNextStageStack()
        #expect(manager.selectedStageStackID == "display-a")
        #expect(manager.activeStageID == activeOnA)

        manager.selectNextStageStack()
        #expect(manager.activeStageID == stageOnB)
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
        var manager = StageManager()
        manager.reconcileStageStacks(with: shared)

        #expect(manager.stageStacks.count == 1)
        #expect(manager.selectedStageStackID == SpaceTopology.sharedStackID)
        #expect(manager.stages.count == 3)
        #expect(manager.activeStageID == manager.stages[1].id)
    }

    @Test("A shared Space switch is not scoped to one display")
    func sharedSwitchHasNoDisplayLocation() {
        let stack = SpaceStackDescriptor(
            id: SpaceTopology.sharedStackID,
            displayID: 5,
            displayName: "All Displays",
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            desktopIDs: [10, 11],
            currentDesktopID: 10
        )

        let location = SpaceService.gestureLocation(
            for: stack,
            separateSpaces: false,
            displayBounds: { _ in CGRect(x: 0, y: 0, width: 2560, height: 1440) }
        )

        #expect(location == nil)
    }

    @Test("A separate Space switch is scoped to its display")
    func separateSwitchUsesDisplayLocation() {
        let stack = topology.stacks[1]

        let location = SpaceService.gestureLocation(
            for: stack,
            separateSpaces: true,
            displayBounds: { _ in CGRect(x: 1512, y: 0, width: 2560, height: 1440) }
        )

        #expect(location == CGPoint(x: 2792, y: 720))
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
        var manager = StageManager()
        manager.createStage(position: .below)
        manager.addWindow(
            StageWindow(windowID: 70, ownerBundleID: "com.example", ownerName: "Example", windowTitle: "Example"),
            toStageID: manager.stages[1].id
        )

        manager.reconcileStageStacks(with: topology)

        #expect(manager.stageStacks.count == 2)
        #expect(manager.stageStacks[0].id == "display-a")
        #expect(manager.stageStacks[0].stages[1].windowIDs == [70])
    }

    @Test("Disabling separate Spaces merges display stacks into the shared stack")
    func separateToSharedMigration() {
        var manager = StageManager()
        manager.reconcileStageStacks(with: topology)
        manager.addWindow(
            StageWindow(windowID: 70, ownerBundleID: "com.a", ownerName: "A", windowTitle: "A"),
            toStageID: manager.stageID(stackID: "display-a", at: 1)!
        )
        manager.addWindow(
            StageWindow(windowID: 80, ownerBundleID: "com.b", ownerName: "B", windowTitle: "B"),
            toStageID: manager.stageID(stackID: "display-b", at: 1)!
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

        manager.reconcileStageStacks(with: shared)

        #expect(manager.stageStacks.count == 1)
        #expect(Set(manager.stages[1].windowIDs) == [70, 80])
    }
}
