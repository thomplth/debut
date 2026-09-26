import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

/// KHA-782: launch used to fall back to stage 1 whenever the focused window could not be
/// resolved — Debut or Finder frontmost, AX focus unavailable, or the window excluded — even
/// though topology had already named the desktop macOS is showing.
@Suite("Launch desktop")
struct LaunchDesktopTests {
    private static let uuids = [
        "AAAAAAAA-0000-0000-0000-000000000001",
        "BBBBBBBB-0000-0000-0000-000000000002",
        "CCCCCCCC-0000-0000-0000-000000000003",
    ]

    private func manager(currentIndex: Int) -> SpaceManager {
        let ids: [CGSSpaceID] = [3, 4, 5]
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: SpaceTopology.sharedStackID,
                displayID: nil,
                displayName: "All Displays",
                frame: .zero,
                desktopIDs: ids,
                desktopUUIDs: Self.uuids,
                currentDesktopID: ids[currentIndex],
                currentDesktopUUID: Self.uuids[currentIndex]
            ),
        ]))
        return manager
    }

    @Test("Without a focused window, launch keeps the desktop macOS is showing")
    func unresolvedFocusKeepsTopologyDesktop() {
        var manager = manager(currentIndex: 2)
        #expect(manager.activeSpaceID == manager.spaces[2].id)

        manager.activateLaunchSpace(focusedWindowID: nil)

        #expect(manager.activeSpaceID == manager.spaces[2].id)
    }

    @Test("A focused window on an unmanaged desktop does not reset launch to stage 1")
    func unassignedFocusKeepsTopologyDesktop() {
        var manager = manager(currentIndex: 1)

        manager.activateLaunchSpace(focusedWindowID: 99)

        #expect(manager.activeSpaceID == manager.spaces[1].id)
    }

    @Test("A resolved focused window selects the desktop that owns it")
    func resolvedFocusSelectsOwningDesktop() {
        var manager = manager(currentIndex: 2)
        manager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"),
            toSpaceID: manager.spaces[0].id
        )

        manager.activateLaunchSpace(focusedWindowID: 7)

        #expect(manager.activeSpaceID == manager.spaces[0].id)
    }
}
