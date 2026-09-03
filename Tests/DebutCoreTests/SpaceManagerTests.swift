import Testing
import Foundation
@testable import DebutCore

@Suite("SpaceManager")
struct SpaceManagerTests {

    @Test("Starts with one default space")
    func defaultState() {
        let sm = SpaceManager()
        #expect(sm.spaces.count == 1)
        #expect(sm.activeSpaceID == sm.spaces[0].id)
        #expect(sm.liveWindowCount == 0)
    }

    @Test("Live window count spans every space and excludes dormant assignments")
    func liveWindowCount() {
        var sm = SpaceManager()
        let firstSpaceID = sm.activeSpaceID
        sm.createSpace(position: .below)
        let secondSpaceID = sm.activeSpaceID
        sm.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One"),
            toSpaceID: firstSpaceID
        )
        sm.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Two", ownerPID: 20),
            toSpaceID: secondSpaceID
        )

        #expect(sm.liveWindowCount == 2)
        _ = sm.makeWindowsDormant(forOwnerPID: 20)
        #expect(sm.liveWindowCount == 1)
    }

    @Test("Owner bundle identifiers are deduplicated and include dormant assignments")
    func allWindowOwnerBundleIDs() {
        var sm = SpaceManager()
        let firstSpaceID = sm.activeSpaceID
        sm.createSpace(position: .below)
        let secondSpaceID = sm.activeSpaceID
        sm.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One"),
            toSpaceID: firstSpaceID
        )
        sm.addWindow(
            SpaceWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Two"),
            toSpaceID: secondSpaceID
        )
        sm.addWindow(
            SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Three", ownerPID: 20),
            toSpaceID: secondSpaceID
        )

        #expect(Set(sm.allWindowOwnerBundleIDs) == ["com.a", "com.b"])

        // A dormant app still gets a stage once it relaunches, so its icon is worth warming.
        _ = sm.makeWindowsDormant(forOwnerPID: 20)
        #expect(Set(sm.allWindowOwnerBundleIDs) == ["com.a", "com.b"])
    }

    @Test("Create space below active")
    func createBelow() {
        var sm = SpaceManager()
        let originalID = sm.activeSpaceID
        sm.createSpace(position: .below)
        #expect(sm.spaces.count == 2)
        #expect(sm.spaces[0].id == originalID)
        #expect(sm.activeSpaceID == sm.spaces[1].id)
    }

    @Test("Create space above active")
    func createAbove() {
        var sm = SpaceManager()
        let originalID = sm.activeSpaceID
        sm.createSpace(position: .above)
        #expect(sm.spaces.count == 2)
        #expect(sm.spaces[1].id == originalID)
    }

    @Test("Delete overflows windows up")
    func deleteOverflowUp() {
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        let secondID = sm.spaces[1].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toSpaceID: secondID)
        sm.activateSpace(id: secondID)
        sm.deleteSpace(id: secondID)
        #expect(sm.spaces.count == 1)
        #expect(sm.spaces[0].windows.count == 1)
    }

    @Test("Delete last space creates new default")
    func deleteLastSpace() {
        var sm = SpaceManager()
        sm.deleteSpace(id: sm.spaces[0].id)
        #expect(sm.spaces.count == 1)
    }

    @Test("Add and move window")
    func moveWindow() {
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        let aID = sm.spaces[0].id
        let bID = sm.spaces[1].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.x", ownerName: "X", windowTitle: "T"), toSpaceID: aID)
        sm.moveWindow(windowID: 101, fromSpaceID: aID, toSpaceID: bID)
        #expect(sm.spaces[0].windows.isEmpty)
        #expect(sm.spaces[1].windows.count == 1)
    }

    @Test("Reorder windows within a space")
    func reorderWindowsWithinSpace() {
        var sm = SpaceManager()
        let spaceID = sm.spaces[0].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: spaceID)
        sm.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: spaceID)
        sm.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toSpaceID: spaceID)

        sm.moveWindow(
            windowID: 101,
            fromSpaceID: spaceID,
            toSpaceID: spaceID,
            at: 2
        )

        #expect(sm.spaces[0].windows.map(\.windowID) == [202, 303, 101])
    }

    @Test("Insert a window at any position in another space")
    func insertWindowAcrossSpaces() {
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        let sourceID = sm.spaces[0].id
        let destinationID = sm.spaces[1].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: sourceID)
        sm.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: destinationID)
        sm.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toSpaceID: destinationID)

        sm.moveWindow(
            windowID: 101,
            fromSpaceID: sourceID,
            toSpaceID: destinationID,
            at: 1
        )

        #expect(sm.spaces[0].windows.isEmpty)
        #expect(sm.spaces[1].windows.map(\.windowID) == [202, 101, 303])
    }

    @Test("MRU: bringWindowToFront")
    func mru() {
        var sm = SpaceManager()
        let id = sm.spaces[0].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: id)
        sm.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toSpaceID: id)
        sm.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toSpaceID: id)
        sm.bringWindowToFront(windowID: 303, inSpaceID: id)
        #expect(sm.spaces[0].windows.map(\.windowID) == [303, 101, 202])
    }

    @Test("Remove all windows for bundle ID")
    func removeAllForBundle() {
        var sm = SpaceManager()
        let id = sm.spaces[0].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toSpaceID: id)
        sm.addWindow(SpaceWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2"), toSpaceID: id)
        sm.addWindow(SpaceWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3"), toSpaceID: id)
        sm.removeAllWindows(forBundleID: "com.a")
        #expect(sm.spaces[0].windows.count == 1)
        #expect(sm.spaces[0].windows[0].ownerBundleID == "com.b")
    }

    @Test("Remove windows for owner PID across spaces")
    func removeAllForOwnerPIDAcrossSpaces() {
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 10), toSpaceID: sm.spaces[0].id)
        sm.addWindow(SpaceWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2", ownerPID: 10), toSpaceID: sm.spaces[1].id)
        sm.addWindow(SpaceWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3", ownerPID: 20), toSpaceID: sm.spaces[1].id)

        let removedCount = sm.removeAllWindows(forOwnerPID: 10)

        #expect(removedCount == 2)
        #expect(sm.spaces.flatMap(\.windows).map(\.windowID) == [201])
    }

    @Test("spaceContainingWindow")
    func spaceContaining() {
        var sm = SpaceManager()
        let id = sm.spaces[0].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toSpaceID: id)
        #expect(sm.spaceContainingWindow(windowID: 101) == id)
        #expect(sm.spaceContainingWindow(windowID: 999) == nil)
    }

    @Test("Resetting the window cache removes live and dormant assignments")
    func resetWindowCache() {
        var sm = SpaceManager()
        let firstSpaceID = sm.activeSpaceID
        sm.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "com.ghost",
                ownerName: "Ghost",
                windowTitle: "Stale",
                ownerPID: 10
            ),
            toSpaceID: firstSpaceID
        )
        _ = sm.makeWindowsDormant(forOwnerPID: 10)
        sm.createSpace(position: .below)
        sm.addWindow(
            SpaceWindow(
                windowID: 202,
                ownerBundleID: "com.live",
                ownerName: "Live",
                windowTitle: "Current",
                ownerPID: 20
            ),
            toSpaceID: sm.activeSpaceID
        )

        sm.resetWindowCache()

        #expect(sm.spaces.count == 1)
        #expect(sm.spaces[0].windows.isEmpty)
        #expect(sm.activeSpaceID == sm.spaces[0].id)
        #expect(sm.dormantWindowAssignments.isEmpty)
    }

    @Test("Remove empty spaces preserves non-empty ones")
    func removeEmpty() {
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        sm.createSpace(position: .below)
        // Add a window only to the middle space (index 1)
        let bID = sm.spaces[1].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toSpaceID: bID)
        sm.removeEmptySpaces()
        #expect(sm.spaces.count == 1)
        #expect(sm.spaces[0].id == bID)
        #expect(sm.activeSpaceID == bID)
    }

    @Test("Remove empty spaces keeps all when all empty")
    func removeEmptyKeepsAll() {
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        sm.removeEmptySpaces()
        #expect(sm.spaces.count == 2) // all empty, keep all
    }

    @Test("Update window title")
    func updateTitle() {
        var sm = SpaceManager()
        let id = sm.spaces[0].id
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Old Title"), toSpaceID: id)
        sm.updateWindowTitle(windowID: 101, title: "New Title")
        #expect(sm.spaces[0].windows[0].windowTitle == "New Title")
    }

    @Test("Update window title for nonexistent window is a no-op")
    func updateTitleNonexistent() {
        var sm = SpaceManager()
        sm.updateWindowTitle(windowID: 999, title: "Whatever")
        #expect(sm.spaces.count == 1) // no crash, no changes
    }

    @Test("SpaceManager is Codable")
    func codable() throws {
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toSpaceID: sm.spaces[1].id)
        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(SpaceManager.self, from: data)
        #expect(decoded.spaces.count == 2)
        #expect(decoded.spaces[1].windows.count == 1)
    }

    @Test("App termination makes windows dormant with their space positions")
    func makeWindowsDormantPreservesAssignments() {
        var sm = SpaceManager()
        let space1 = sm.activeSpaceID
        sm.createSpace(position: .below)
        let space2 = sm.activeSpaceID
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toSpaceID: space1)
        sm.addWindow(SpaceWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Two", ownerPID: 10), toSpaceID: space2)
        sm.addWindow(SpaceWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Other", ownerPID: 20), toSpaceID: space2)

        let count = sm.makeWindowsDormant(forOwnerPID: 10)

        #expect(count == 2)
        #expect(sm.spaces.flatMap(\.windows).map(\.windowID) == [201])
        #expect(sm.dormantWindowAssignments.map(\.spaceID) == [space1, space2])
        #expect(sm.dormantWindowAssignments.map(\.windowIndex) == [0, 0])
        #expect(sm.dormantWindowAssignments.map(\.window.windowID) == [101, 102])
    }

    @Test("A single window can be made dormant without disturbing its neighbours")
    func makeWindowDormantPreservesPlacement() {
        var sm = SpaceManager()
        let space1 = sm.activeSpaceID
        sm.createSpace(position: .below)
        let space2 = sm.activeSpaceID
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toSpaceID: space2)
        sm.addWindow(SpaceWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Two", ownerPID: 10), toSpaceID: space2)
        sm.addWindow(SpaceWindow(windowID: 103, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Three", ownerPID: 10), toSpaceID: space2)

        let assignment = sm.makeWindowDormant(windowID: 102)

        #expect(assignment?.spaceID == space2)
        #expect(assignment?.windowIndex == 1)
        #expect(sm.spaces.first(where: { $0.id == space2 })?.windows.map(\.windowID) == [101, 103])
        #expect(sm.dormantWindowAssignments.map(\.window.windowID) == [102])
        #expect(sm.makeWindowDormant(windowID: 999) == nil)
        #expect(sm.spaces.first(where: { $0.id == space1 })?.windows.isEmpty == true)
    }

    @Test("Repeated dormancy replaces an older record for the same runtime window")
    func repeatedDormancyCoalescesRuntimeIdentity() throws {
        let older = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        var sm = SpaceManager()
        let spaceID = sm.activeSpaceID

        sm.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "Old tab", ownerPID: 40694),
            toSpaceID: spaceID
        )
        sm.bringWindowToFront(windowID: 4794, inSpaceID: spaceID, activatedAt: older)
        _ = sm.makeWindowDormant(windowID: 4794)

        sm.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "New tab", ownerPID: 40694),
            toSpaceID: spaceID
        )
        sm.bringWindowToFront(windowID: 4794, inSpaceID: spaceID, activatedAt: newer)
        _ = sm.makeWindowDormant(windowID: 4794)

        let assignment = try #require(sm.dormantWindowAssignments.first)
        #expect(sm.dormantWindowAssignments.count == 1)
        #expect(assignment.window.windowTitle == "New tab")
        #expect(assignment.window.lastActivatedAt == newer)

        // A later false admission with no activation stamp must not erase the real MRU record.
        sm.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "Unstamped duplicate", ownerPID: 40694),
            toSpaceID: spaceID
        )
        _ = sm.makeWindowDormant(windowID: 4794)

        let retained = try #require(sm.dormantWindowAssignments.first)
        #expect(sm.dormantWindowAssignments.count == 1)
        #expect(retained.window.windowTitle == "New tab")
        #expect(retained.window.lastActivatedAt == newer)
    }

    @Test("Dormant assignments survive persistence and legacy state still decodes")
    func dormantAssignmentsAreCodableAndForwardCompatible() throws {
        var sm = SpaceManager()
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toSpaceID: sm.activeSpaceID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)

        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(SpaceManager.self, from: data)
        #expect(decoded.dormantWindowAssignments.count == 1)

        var legacyObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "dormantWindowAssignments")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(SpaceManager.self, from: legacyData)
        #expect(legacyDecoded.dormantWindowAssignments.isEmpty)
    }

    @Test("Decoding coalesces duplicate dormant runtime identities")
    func decodingCoalescesDormantRuntimeIdentities() throws {
        let older = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        var sm = SpaceManager()
        sm.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "Old tab", ownerPID: 40694),
            toSpaceID: sm.activeSpaceID
        )
        sm.bringWindowToFront(windowID: 4794, inSpaceID: sm.activeSpaceID, activatedAt: older)
        _ = sm.makeWindowDormant(windowID: 4794)

        let encoded = try JSONEncoder().encode(sm)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var dormant = try #require(object["dormantWindowAssignments"] as? [[String: Any]])
        var duplicate = try #require(dormant.first)
        var duplicateWindow = try #require(duplicate["window"] as? [String: Any])
        duplicateWindow["id"] = UUID().uuidString
        duplicateWindow["windowTitle"] = "New tab"
        duplicateWindow["lastActivatedAt"] = newer.timeIntervalSinceReferenceDate
        duplicate["window"] = duplicateWindow
        dormant.append(duplicate)
        object["dormantWindowAssignments"] = dormant

        let duplicatedData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SpaceManager.self, from: duplicatedData)
        let assignment = try #require(decoded.dormantWindowAssignments.first)

        #expect(decoded.dormantWindowAssignments.count == 1)
        #expect(assignment.window.windowTitle == "New tab")
        #expect(assignment.window.lastActivatedAt == newer)
    }

    @Test("Decoding restores a newer dormant record shadowed by a live runtime duplicate")
    func decodingRestoresNewerDormantRuntimeIdentity() throws {
        let focusedAt = Date(timeIntervalSinceReferenceDate: 200)
        var sm = SpaceManager()
        let spaceID = sm.activeSpaceID
        sm.addWindow(
            SpaceWindow(windowID: 100, ownerBundleID: "com.mitchellh.ghostty",
                        ownerName: "Ghostty", windowTitle: "Terminal", ownerPID: 500),
            toSpaceID: spaceID
        )
        sm.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "Focused tab", ownerPID: 40694),
            toSpaceID: spaceID
        )
        let diaID = try #require(sm.spaces[0].windows.first(where: {
            $0.windowID == 4794
        })?.id)
        sm.bringWindowToFront(windowID: 4794, inSpaceID: spaceID, activatedAt: focusedAt)
        _ = sm.makeWindowDormant(windowID: 4794)

        // Reproduce state written after a transient same-process record claimed Dia's live ID.
        sm.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "", ownerPID: 40694),
            toSpaceID: spaceID
        )

        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(SpaceManager.self, from: data)
        let dia = try #require(decoded.spaces[0].windows.first(where: {
            $0.windowID == 4794
        }))

        #expect(decoded.dormantWindowAssignments.isEmpty)
        #expect(decoded.spaces[0].windows.map(\.windowID) == [4794, 100])
        #expect(dia.id == diaID)
        #expect(dia.windowTitle == "Focused tab")
        #expect(dia.lastActivatedAt == focusedAt)
    }

    @Test("Decoding discards a dormant shadow when its live runtime record is newer")
    func decodingKeepsNewerLiveRuntimeIdentity() throws {
        let older = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        var sm = SpaceManager()
        let spaceID = sm.activeSpaceID
        sm.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "Old tab", ownerPID: 40694),
            toSpaceID: spaceID
        )
        sm.bringWindowToFront(windowID: 4794, inSpaceID: spaceID, activatedAt: older)
        _ = sm.makeWindowDormant(windowID: 4794)
        sm.addWindow(
            SpaceWindow(windowID: 4794, ownerBundleID: "company.thebrowser.dia",
                        ownerName: "Dia", windowTitle: "Current tab", ownerPID: 40694),
            toSpaceID: spaceID
        )
        sm.bringWindowToFront(windowID: 4794, inSpaceID: spaceID, activatedAt: newer)

        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(SpaceManager.self, from: data)
        let dia = try #require(decoded.spaces[0].windows.first)

        #expect(decoded.dormantWindowAssignments.isEmpty)
        #expect(decoded.spaces[0].windows.count == 1)
        #expect(dia.windowTitle == "Current tab")
        #expect(dia.lastActivatedAt == newer)
    }

    @Test("Explicit removal purges a dormant assignment")
    func explicitRemovalPurgesDormantAssignment() {
        var sm = SpaceManager()
        let spaceID = sm.activeSpaceID
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toSpaceID: spaceID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)

        sm.removeWindow(windowID: 101, fromSpaceID: spaceID)

        #expect(sm.dormantWindowAssignments.isEmpty)
    }

    @Test("Excluding a bundle purges its dormant assignments")
    func bundleRemovalPurgesDormantAssignments() {
        var sm = SpaceManager()
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toSpaceID: sm.activeSpaceID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)

        sm.removeAllWindows(forBundleID: "com.a")

        #expect(sm.dormantWindowAssignments.isEmpty)
    }

    @Test("Deleting a space purges its dormant assignments")
    func spaceDeletionPurgesDormantAssignments() {
        var sm = SpaceManager()
        let spaceID = sm.activeSpaceID
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toSpaceID: spaceID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)

        sm.deleteSpace(id: spaceID)

        #expect(sm.dormantWindowAssignments.isEmpty)
    }

    @Test("Automatic empty-space pruning retains spaces with dormant assignments")
    func emptySpacePruningRetainsDormantAssignments() {
        var sm = SpaceManager()
        let dormantSpaceID = sm.activeSpaceID
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toSpaceID: dormantSpaceID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)
        sm.createSpace(position: .below)
        sm.addWindow(SpaceWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Live", ownerPID: 20), toSpaceID: sm.activeSpaceID)

        sm.removeEmptySpaces()

        #expect(sm.spaces.contains(where: { $0.id == dormantSpaceID }))
        #expect(sm.dormantWindowAssignments.first?.spaceID == dormantSpaceID)
    }
}
