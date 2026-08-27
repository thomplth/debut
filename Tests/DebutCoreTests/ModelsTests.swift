import Testing
import Foundation
@testable import DebutCore

// MARK: - SpaceWindow Tests

@Suite("SpaceWindow")
struct SpaceWindowTests {
    @Test("Create window")
    func createWindow() {
        let window = SpaceWindow(windowID: 101, ownerBundleID: "com.apple.Safari", ownerName: "Safari", windowTitle: "Google")
        #expect(window.windowID == 101)
        #expect(window.ownerBundleID == "com.apple.Safari")
        #expect(window.windowTitle == "Google")
    }

    @Test("Window is Codable and ignores the retired shared-window field")
    func windowCodable() throws {
        let window = SpaceWindow(
            windowID: 101,
            ownerBundleID: "com.apple.Safari",
            ownerName: "Safari",
            windowTitle: "Google"
        )
        let data = try JSONEncoder().encode(window)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["isShared"] == nil)

        var legacyObject = object
        legacyObject["isShared"] = true
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(SpaceWindow.self, from: legacyData)
        #expect(decoded.ownerBundleID == window.ownerBundleID)
        #expect(decoded.windowID == 101)
    }

    @Test("Window equality by windowID")
    func windowEquality() {
        let a = SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1")
        let b = SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2")
        let c = SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3")
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - Space Tests

@Suite("Space")
struct SpaceTests {
    @Test("Create space starts empty")
    func createSpace() {
        let space = Space()
        #expect(space.windows.isEmpty)
    }

    @Test("Add window to space")
    func addWindow() {
        var space = Space()
        space.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"))
        #expect(space.windows.count == 1)
    }

    @Test("Remove window from space")
    func removeWindow() {
        var space = Space()
        space.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"))
        space.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"))
        space.removeWindow(windowID: 101)
        #expect(space.windows.count == 1)
        #expect(space.windows[0].windowID == 202)
    }

    @Test("Duplicate window not added")
    func noDuplicates() {
        var space = Space()
        space.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"))
        space.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"))
        #expect(space.windows.count == 1)
    }

    @Test("Bring window to front (MRU)")
    func bringToFront() {
        var space = Space()
        space.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"))
        space.addWindow(SpaceWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"))
        space.addWindow(SpaceWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"))
        space.bringWindowToFront(windowID: 303)
        #expect(space.windows[0].windowID == 303)
        #expect(space.windows[1].windowID == 101)
        #expect(space.windows[2].windowID == 202)
    }

    @Test("Remove all windows for bundle ID")
    func removeAllForBundle() {
        var space = Space()
        space.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"))
        space.addWindow(SpaceWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2"))
        space.addWindow(SpaceWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3"))
        space.removeAllWindows(forBundleID: "com.a")
        #expect(space.windows.count == 1)
        #expect(space.windows[0].ownerBundleID == "com.b")
    }

    @Test("Remove all windows for owner PID")
    func removeAllForOwnerPID() {
        var space = Space()
        space.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 10))
        space.addWindow(SpaceWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2", ownerPID: 20))
        space.addWindow(SpaceWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3", ownerPID: 10))

        let removedCount = space.removeAllWindows(forOwnerPID: 10)

        #expect(removedCount == 2)
        #expect(space.windows.map(\.windowID) == [102])
    }

    @Test("Space is Codable")
    func spaceCodable() throws {
        var space = Space()
        space.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"))
        let data = try JSONEncoder().encode(space)
        let decoded = try JSONDecoder().decode(Space.self, from: data)
        #expect(decoded.windows.count == 1)
        #expect(decoded.id == space.id)
    }
}
