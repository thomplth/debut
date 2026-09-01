import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Global window order")
struct GlobalWindowOrderTests {
    private let topology = SpaceTopology(
        separateSpaces: true,
        stacks: [
            SpaceStackDescriptor(
                id: "display-a",
                displayID: 1,
                displayName: "Built-in Display",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                desktopIDs: [3, 4916],
                currentDesktopID: 3
            ),
            SpaceStackDescriptor(
                id: "display-b",
                displayID: 5,
                displayName: "Studio Display",
                frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                desktopIDs: [5338, 5370],
                currentDesktopID: 5338
            ),
        ]
    )

    private func window(_ id: CGWindowID, _ bundle: String = "com.a") -> SpaceWindow {
        SpaceWindow(
            windowID: id,
            ownerBundleID: bundle,
            ownerName: bundle,
            windowTitle: "W\(id)"
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + offset)
    }

    @Test("Activation stamps the window it fronts")
    func stampOnFront() {
        var space = Space()
        space.addWindow(window(101))
        space.addWindow(window(202))
        #expect(space.windows.allSatisfy { $0.lastActivatedAt == nil })

        space.bringWindowToFront(windowID: 202, activatedAt: date(5))

        #expect(space.windows[0].windowID == 202)
        #expect(space.windows[0].lastActivatedAt == date(5))
        #expect(space.windows[1].lastActivatedAt == nil)
    }

    /// The stamp is written by the same mutation that rotates the array, so the global order
    /// restricted to one space can never disagree with that space's own MRU order.
    @Test("Global order agrees with per-space order within a space")
    func agreesWithPerSpaceOrder() {
        var manager = SpaceManager()
        let spaceID = manager.spaces[0].id
        for id in [101, 202, 303] as [CGWindowID] {
            manager.addWindow(window(id), toSpaceID: spaceID)
        }

        manager.bringWindowToFront(windowID: 303, inSpaceID: spaceID, activatedAt: date(1))
        manager.bringWindowToFront(windowID: 101, inSpaceID: spaceID, activatedAt: date(2))

        let global = manager.globalWindowOrder().map(\.window.windowID)
        #expect(global == manager.spaces[0].windows.map(\.windowID))
        #expect(global == [101, 303, 202])
    }

    @Test("Global order interleaves spaces across every display stack")
    func spansDisplayStacks() {
        var manager = SpaceManager()
        manager.reconcileSpaceStacks(with: topology)

        let displayA = manager.spaceStacks[0].spaces[0].id
        let displayB = manager.spaceStacks[1].spaces[1].id
        manager.addWindow(window(101), toSpaceID: displayA)
        manager.addWindow(window(202), toSpaceID: displayB)
        manager.addWindow(window(303), toSpaceID: displayA)

        manager.bringWindowToFront(windowID: 101, inSpaceID: displayA, activatedAt: date(1))
        manager.bringWindowToFront(windowID: 202, inSpaceID: displayB, activatedAt: date(2))
        manager.bringWindowToFront(windowID: 303, inSpaceID: displayA, activatedAt: date(3))

        let entries = manager.globalWindowOrder()
        #expect(entries.map(\.window.windowID) == [303, 202, 101])
        #expect(entries.map(\.spaceID) == [displayA, displayB, displayA])
    }

    /// Windows discovered at startup have never been activated. They must still appear — they
    /// are exactly the windows the user has not reached for yet — but behind everything that
    /// has a stamp, in a stable order rather than an arbitrary one.
    @Test("Never-activated windows sort last in space order")
    func neverActivatedSortLast() {
        var manager = SpaceManager()
        let first = manager.spaces[0].id
        manager.createSpace(position: .below)
        let second = manager.activeSpaceID

        manager.addWindow(window(101), toSpaceID: first)
        manager.addWindow(window(202), toSpaceID: first)
        manager.addWindow(window(303), toSpaceID: second)
        manager.bringWindowToFront(windowID: 303, inSpaceID: second, activatedAt: date(1))

        #expect(manager.globalWindowOrder().map(\.window.windowID) == [303, 101, 202])
    }

    @Test("Global order excludes dormant assignments")
    func excludesDormant() {
        var manager = SpaceManager()
        let spaceID = manager.spaces[0].id
        manager.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "com.a",
                ownerName: "A",
                windowTitle: "Live",
                ownerPID: 42
            ),
            toSpaceID: spaceID
        )
        manager.addWindow(
            SpaceWindow(
                windowID: 202,
                ownerBundleID: "com.b",
                ownerName: "B",
                windowTitle: "Quits",
                ownerPID: 99
            ),
            toSpaceID: spaceID
        )
        _ = manager.makeWindowsDormant(forOwnerPID: 99)

        #expect(manager.globalWindowOrder().map(\.window.windowID) == [101])
    }

    @Test("lastActivatedAt survives a state round trip")
    func codableRoundTrip() throws {
        var manager = SpaceManager()
        let spaceID = manager.spaces[0].id
        manager.addWindow(window(101), toSpaceID: spaceID)
        manager.bringWindowToFront(windowID: 101, inSpaceID: spaceID, activatedAt: date(7))

        let data = try JSONEncoder().encode(manager)
        let restored = try JSONDecoder().decode(SpaceManager.self, from: data)

        #expect(restored.spaces[0].windows[0].lastActivatedAt == date(7))
    }

    /// State written before this field existed decodes with no stamp rather than failing.
    @Test("A state file without the field still decodes")
    func decodesLegacyState() throws {
        var manager = SpaceManager()
        let spaceID = manager.spaces[0].id
        manager.addWindow(window(101), toSpaceID: spaceID)

        let data = try JSONEncoder().encode(manager)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var stacks = try #require(object["spaceStacks"] as? [[String: Any]])
        var spaces = try #require(stacks[0]["spaces"] as? [[String: Any]])
        var windows = try #require(spaces[0]["windows"] as? [[String: Any]])
        windows[0].removeValue(forKey: "lastActivatedAt")
        spaces[0]["windows"] = windows
        stacks[0]["spaces"] = spaces
        object["spaceStacks"] = stacks

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(SpaceManager.self, from: stripped)

        #expect(restored.spaces[0].windows[0].lastActivatedAt == nil)
    }
}
