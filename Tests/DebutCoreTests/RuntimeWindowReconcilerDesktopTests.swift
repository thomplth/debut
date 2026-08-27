import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

/// Spaces are desktops, so macOS — not Debut's own bookkeeping — decides which space a
/// window belongs to. These cover the cases where the two disagree.
@Suite("RuntimeWindowReconciler desktop truth")
struct RuntimeWindowReconcilerDesktopTests {
    private func liveWindow(
        _ windowID: CGWindowID,
        bundleID: String = "com.a",
        ownerName: String = "A",
        ownerPID: pid_t = 10,
        title: String = "Window"
    ) -> WindowInfo {
        WindowInfo(
            windowID: windowID,
            ownerBundleID: bundleID,
            ownerName: ownerName,
            ownerPID: ownerPID,
            title: title,
            bounds: .zero,
            isOnScreen: true
        )
    }

    private func threeSpaces() -> SpaceManager {
        var manager = SpaceManager()
        manager.createSpace(position: .below)
        manager.createSpace(position: .below)
        return manager
    }

    // Launching an app while standing on desktop 3 puts its window on desktop 3. Adding it
    // to the active space is the same answer only by coincidence; asking macOS is the answer.
    @Test("A newly discovered window joins the space matching its desktop")
    func newWindowJoinsItsDesktop() {
        var manager = threeSpaces()
        manager.activateSpace(id: manager.spaces[0].id)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7)],
                allWindowIDs: [7],
                desktopIndexes: [7: 2]
            ),
            spaceManager: &manager
        )

        #expect(result.addedCount == 1)
        #expect(manager.spaceContainingWindow(windowID: 7) == manager.spaces[2].id)
    }

    // The whole point of the Spaces architecture: the user drags a window to another desktop
    // with Mission Control, and Debut has to follow rather than fight.
    @Test("A window dragged to another desktop is reassigned to that space")
    func draggedWindowFollowsItsDesktop() {
        var manager = threeSpaces()
        manager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Window", ownerPID: 10),
            toSpaceID: manager.spaces[0].id
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7)],
                allWindowIDs: [7],
                desktopIndexes: [7: 1]
            ),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 7) == manager.spaces[1].id)
        #expect(result.reassignedCount == 1)
        #expect(result.events.contains {
            $0.windowID == 7 && $0.reason == .desktopChanged && $0.toSpace == 1
        })
    }

    @Test("Reassigning across desktops preserves the window's identity")
    func reassignmentPreservesWindowIdentity() {
        var manager = threeSpaces()
        manager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Draft", ownerPID: 42),
            toSpaceID: manager.spaces[0].id
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7, ownerPID: 42, title: "Draft")],
                allWindowIDs: [7],
                desktopIndexes: [7: 2]
            ),
            spaceManager: &manager
        )

        let moved = manager.spaces[2].windows.first { $0.windowID == 7 }
        #expect(moved?.windowTitle == "Draft")
        #expect(moved?.ownerPID == 42)
        #expect(manager.spaces[0].windows.isEmpty)
    }

    // Windows assigned to every Space, and windows on a fullscreen Space, have no single
    // desktop. `SpaceService.desktopIndex(forWindow:)` returns nil for them, and a nil must
    // never be read as "desktop 0" — that would sweep Finder onto the first space.
    @Test("A window with no reported desktop keeps its existing space")
    func unreportedDesktopLeavesAssignmentAlone() {
        var manager = threeSpaces()
        manager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Window", ownerPID: 10),
            toSpaceID: manager.spaces[1].id
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7)],
                allWindowIDs: [7],
                desktopIndexes: [:]
            ),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 7) == manager.spaces[1].id)
        #expect(!result.didMutate)
    }

    // Desktop enumeration and the space list are reconciled separately, so a snapshot can
    // name a desktop the space list has not grown to yet. Dropping the window would lose it.
    @Test("A desktop index with no matching space leaves the assignment alone")
    func outOfRangeDesktopLeavesAssignmentAlone() {
        var manager = threeSpaces()
        manager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Window", ownerPID: 10),
            toSpaceID: manager.spaces[1].id
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7)],
                allWindowIDs: [7],
                desktopIndexes: [7: 9]
            ),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 7) == manager.spaces[1].id)
    }

    @Test("A window already on its reported desktop is not reassigned")
    func matchingDesktopIsNoOp() {
        var manager = threeSpaces()
        manager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Window", ownerPID: 10),
            toSpaceID: manager.spaces[1].id
        )
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7)],
                allWindowIDs: [7],
                desktopIndexes: [7: 1]
            ),
            spaceManager: &manager
        )

        #expect(!result.didMutate)
    }

    // A desktop answer is a fact, not the guess `strandedSpaceIDs` exists to hedge. Leaving
    // the window provisional would let a later bundle-only match drag it off its real desktop.
    @Test("A desktop-placed window outranks the stranded-space guess")
    func desktopOutranksStrandedSpace() {
        var manager = threeSpaces()
        // Space 0 holds an assignment whose window ID has vanished, which normally claims
        // the replacement for space 0.
        manager.addWindow(
            SpaceWindow(windowID: 99, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Old", ownerPID: 10),
            toSpaceID: manager.spaces[0].id
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7, title: "Fresh")],
                allWindowIDs: [7],
                desktopIndexes: [7: 2]
            ),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 7) == manager.spaces[2].id)
    }

    @Test("The same desktop index on another display maps to another stack")
    func displayQualifiedDesktopLocation() {
        let topology = SpaceTopology(separateSpaces: true, stacks: [
            SpaceStackDescriptor(
                id: "a", displayID: 1, displayName: "A", frame: .zero,
                desktopIDs: [10, 11], currentDesktopID: 10
            ),
            SpaceStackDescriptor(
                id: "b", displayID: 2, displayName: "B", frame: .zero,
                desktopIDs: [20, 21], currentDesktopID: 20
            ),
        ])
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: topology)
        manager.addWindow(
            SpaceWindow(
                windowID: 7,
                ownerBundleID: "com.a",
                ownerName: "A",
                windowTitle: "Window",
                ownerPID: 10
            ),
            toSpaceID: manager.spaceID(stackID: "a", at: 1)!
        )
        var reconciler = RuntimeWindowReconciler()

        _ = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(7)],
                allWindowIDs: [7],
                desktopLocations: [
                    7: DesktopLocation(stackID: "b", desktopID: 21, index: 1),
                ]
            ),
            spaceManager: &manager
        )

        #expect(manager.spaceContainingWindow(windowID: 7) == manager.spaceID(stackID: "b", at: 1))
    }

    // App windows are discovered one desktop at a time after a relaunch. A bundle-only
    // recovery cannot wait for every Ghostty window to appear: the desktop answer already
    // identifies which dormant assignment this replacement belongs to.
    @Test("A partial relaunch restores a dynamic-title window by its reported desktop")
    func partialRelaunchRestoresByDesktop() {
        var manager = threeSpaces()
        manager.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "com.mitchellh.ghostty",
                ownerName: "Ghostty",
                windowTitle: "old title",
                ownerPID: 10
            ),
            toSpaceID: manager.spaces[0].id
        )
        manager.addWindow(
            SpaceWindow(
                windowID: 102,
                ownerBundleID: "com.mitchellh.ghostty",
                ownerName: "Ghostty",
                windowTitle: "another old title",
                ownerPID: 10
            ),
            toSpaceID: manager.spaces[1].id
        )
        _ = manager.makeWindowsDormant(forOwnerPID: 10)
        var reconciler = RuntimeWindowReconciler()

        let result = reconciler.reconcile(
            RuntimeWindowSnapshot(
                liveWindows: [liveWindow(
                    201,
                    bundleID: "com.mitchellh.ghostty",
                    ownerName: "Ghostty",
                    ownerPID: 20,
                    title: "new title"
                )],
                allWindowIDs: [201],
                desktopIndexes: [201: 1]
            ),
            spaceManager: &manager
        )

        #expect(result.addedCount == 0)
        #expect(result.reassignedCount == 1)
        #expect(manager.dormantWindowAssignments.count == 1)
        #expect(manager.spaceContainingWindow(windowID: 201) == manager.spaces[1].id)
    }
}
