import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

/// Reordering desktops in Mission Control changes the order of the macOS desktop list without
/// changing its length. Reconciliation that compares only counts cannot see that, so these
/// tests pin the identity join that makes the reorder observable.
@Suite("Desktop reordering")
struct DesktopReorderTests {
    private static let alpha = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let bravo = "BBBBBBBB-0000-0000-0000-000000000002"
    private static let charlie = "CCCCCCCC-0000-0000-0000-000000000003"

    private func topology(
        desktopIDs: [CGSSpaceID],
        desktopUUIDs: [String],
        currentDesktopID: CGSSpaceID?,
        currentDesktopUUID: String?
    ) -> SpaceTopology {
        SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: SpaceTopology.sharedStackID,
                displayID: nil,
                displayName: "All Displays",
                frame: .zero,
                desktopIDs: desktopIDs,
                desktopUUIDs: desktopUUIDs,
                currentDesktopID: currentDesktopID,
                currentDesktopUUID: currentDesktopUUID
            ),
        ])
    }

    private func threeDesktops(
        currentIndex: Int = 0
    ) -> SpaceTopology {
        let ids: [CGSSpaceID] = [3, 4, 5]
        let uuids = [Self.alpha, Self.bravo, Self.charlie]
        return topology(
            desktopIDs: ids,
            desktopUUIDs: uuids,
            currentDesktopID: ids[currentIndex],
            currentDesktopUUID: uuids[currentIndex]
        )
    }

    /// The same three desktops with the middle two swapped, which is what Mission Control
    /// produces when the user drags desktop 2 past desktop 3.
    private func middleTwoSwapped(currentIndex: Int = 0) -> SpaceTopology {
        let ids: [CGSSpaceID] = [3, 5, 4]
        let uuids = [Self.alpha, Self.charlie, Self.bravo]
        return topology(
            desktopIDs: ids,
            desktopUUIDs: uuids,
            currentDesktopID: ids[currentIndex],
            currentDesktopUUID: uuids[currentIndex]
        )
    }

    private func window(_ id: CGWindowID, _ bundleID: String) -> SpaceWindow {
        SpaceWindow(
            windowID: id,
            ownerBundleID: bundleID,
            ownerName: bundleID,
            windowTitle: "w\(id)"
        )
    }

    @Test("A reorder permutes the spaces so each one keeps the desktop it was joined to")
    func reorderPermutesSpaces() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: threeDesktops())
        let original = manager.spaces.map(\.id)
        #expect(manager.spaces.count == 3)

        manager.reconcileSpaceStacks(with: middleTwoSwapped())

        #expect(manager.spaces.count == 3)
        #expect(manager.spaces.map(\.id) == [original[0], original[2], original[1]])
        #expect(manager.spaces.map(\.desktopUUID) == [Self.alpha, Self.charlie, Self.bravo])
    }

    @Test("Windows travel with their desktop rather than collapsing into one space")
    func reorderKeepsWindowsWithTheirDesktop() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: threeDesktops())
        let spaces = manager.spaces.map(\.id)
        manager.addWindow(window(101, "com.first"), toSpaceID: spaces[0])
        manager.addWindow(window(202, "com.second"), toSpaceID: spaces[1])
        manager.addWindow(window(303, "com.third"), toSpaceID: spaces[2])

        manager.reconcileSpaceStacks(with: middleTwoSwapped())

        #expect(manager.spaces.map { $0.windows.map(\.windowID) } == [[101], [303], [202]])
        #expect(manager.liveWindowCount == 3)
    }

    @Test("Dormant assignments survive a reorder")
    func reorderKeepsDormantAssignments() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: threeDesktops())
        let spaces = manager.spaces.map(\.id)
        var quitting = window(202, "com.second")
        quitting.ownerPID = 4242
        manager.addWindow(quitting, toSpaceID: spaces[1])
        #expect(manager.makeWindowsDormant(forOwnerPID: 4242) == 1)
        #expect(manager.dormantWindowAssignments.count == 1)

        manager.reconcileSpaceStacks(with: middleTwoSwapped())

        #expect(manager.dormantWindowAssignments.count == 1)
        // The assignment still names the space that now sits last, because that space is
        // still the one joined to desktop bravo.
        #expect(manager.dormantWindowAssignments[0].spaceID == manager.spaces[2].id)
    }

    @Test("The active space follows its desktop across a reorder")
    func reorderKeepsActiveSpace() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: threeDesktops(currentIndex: 1))
        let active = manager.activeSpaceID
        #expect(active == manager.spaces[1].id)

        manager.reconcileSpaceStacks(with: middleTwoSwapped(currentIndex: 2))

        #expect(manager.activeSpaceID == active)
        #expect(manager.activeSpaceID == manager.spaces[2].id)
    }

    @Test("Spaces with no recorded desktop adopt the identity at their position")
    func legacySpacesAdoptPositionally() {
        var manager = SpaceManager()
        // A topology carrying no identities is what every pre-upgrade state.json reconciled
        // against, so this is the shape the stored spaces start in.
        manager.reconcileSpaceStacks(with: topology(
            desktopIDs: [3, 4, 5],
            desktopUUIDs: [],
            currentDesktopID: 3,
            currentDesktopUUID: nil
        ))
        let original = manager.spaces.map(\.id)
        #expect(manager.spaces.allSatisfy { $0.desktopUUID == nil })

        manager.reconcileSpaceStacks(with: threeDesktops())

        #expect(manager.spaces.map(\.id) == original)
        #expect(manager.spaces.map(\.desktopUUID) == [Self.alpha, Self.bravo, Self.charlie])
    }

    @Test("A desktop that disappears spills its windows and drops its dormant assignments")
    func removedDesktopStillSpills() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: threeDesktops())
        let spaces = manager.spaces.map(\.id)
        manager.addWindow(window(101, "com.first"), toSpaceID: spaces[0])
        manager.addWindow(window(303, "com.third"), toSpaceID: spaces[2])
        var quitting = window(404, "com.third")
        quitting.ownerPID = 909
        manager.addWindow(quitting, toSpaceID: spaces[2])
        #expect(manager.makeWindowsDormant(forOwnerPID: 909) == 1)

        manager.reconcileSpaceStacks(with: topology(
            desktopIDs: [3, 4],
            desktopUUIDs: [Self.alpha, Self.bravo],
            currentDesktopID: 3,
            currentDesktopUUID: Self.alpha
        ))

        #expect(manager.spaces.count == 2)
        #expect(manager.spaces.map(\.desktopUUID) == [Self.alpha, Self.bravo])
        #expect(manager.spaces[1].windows.map(\.windowID) == [303])
        #expect(manager.dormantWindowAssignments.isEmpty)
    }

    @Test("A new desktop arrives as its own empty space instead of reusing a departed one")
    func replacedDesktopDoesNotInheritTheOldSpace() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: threeDesktops())
        let spaces = manager.spaces.map(\.id)
        manager.addWindow(window(303, "com.third"), toSpaceID: spaces[2])

        // Desktop charlie is deleted and a brand new desktop is created in the same pass.
        let delta = "DDDDDDDD-0000-0000-0000-000000000004"
        manager.reconcileSpaceStacks(with: topology(
            desktopIDs: [3, 4, 6],
            desktopUUIDs: [Self.alpha, Self.bravo, delta],
            currentDesktopID: 3,
            currentDesktopUUID: Self.alpha
        ))

        #expect(manager.spaces.count == 3)
        #expect(manager.spaces.map(\.desktopUUID) == [Self.alpha, Self.bravo, delta])
        // The record for the departed desktop is not re-labelled onto the new one, which is
        // what would silently hand one desktop's windows to another.
        #expect(manager.spaces[2].id != spaces[2])
        // Charlie's window spills rather than vanishing. Which space it spills into is a
        // placeholder either way: macOS moved the window somewhere real when the desktop went
        // away, and the next `refreshDesktopAssignments` is what settles where.
        #expect(manager.liveWindowCount == 1)
    }

    @Test("State written before the desktop join existed still decodes")
    func stateWithoutDesktopIdentityDecodes() throws {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: threeDesktops())
        let data = try JSONEncoder().encode(manager)

        // Strip every desktopUUID back out, which is exactly the shape an installed build
        // wrote before this field existed.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stacks = try #require(object["spaceStacks"] as? [[String: Any]])
        stacks = stacks.map { stack in
            var stack = stack
            stack["spaces"] = (stack["spaces"] as? [[String: Any]] ?? []).map { space in
                var space = space
                space.removeValue(forKey: "desktopUUID")
                return space
            }
            return stack
        }
        object["spaceStacks"] = stacks
        let legacy = try JSONSerialization.data(withJSONObject: object)

        var decoded = try JSONDecoder().decode(SpaceManager.self, from: legacy)
        #expect(decoded.spaces.count == 3)
        #expect(decoded.spaces.allSatisfy { $0.desktopUUID == nil })

        decoded.reconcileSpaceStacks(with: threeDesktops())
        #expect(decoded.spaces.map(\.desktopUUID) == [Self.alpha, Self.bravo, Self.charlie])
    }

    @Test("Reconciling an unchanged topology twice changes nothing")
    func reconcileIsIdempotent() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: threeDesktops(currentIndex: 1))
        let spaces = manager.spaces.map(\.id)
        let active = manager.activeSpaceID

        manager.reconcileSpaceStacks(with: threeDesktops(currentIndex: 1))

        #expect(manager.spaces.map(\.id) == spaces)
        #expect(manager.activeSpaceID == active)
    }
}
