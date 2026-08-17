import Testing
import Foundation
@testable import DebutCore

// MARK: - StageWindow Tests

@Suite("StageWindow")
struct StageWindowTests {
    @Test("Create window")
    func createWindow() {
        let window = StageWindow(windowID: 101, ownerBundleID: "com.apple.Safari", ownerName: "Safari", windowTitle: "Google")
        #expect(window.windowID == 101)
        #expect(window.ownerBundleID == "com.apple.Safari")
        #expect(window.windowTitle == "Google")
    }

    @Test("Window is Codable and ignores the retired shared-window field")
    func windowCodable() throws {
        let window = StageWindow(
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
        let decoded = try JSONDecoder().decode(StageWindow.self, from: legacyData)
        #expect(decoded.ownerBundleID == window.ownerBundleID)
        #expect(decoded.windowID == 101)
    }

    @Test("Window equality by windowID")
    func windowEquality() {
        let a = StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1")
        let b = StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2")
        let c = StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3")
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - Stage Tests

@Suite("Stage")
struct StageTests {
    @Test("Create stage starts empty")
    func createStage() {
        let stage = Stage()
        #expect(stage.windows.isEmpty)
    }

    @Test("Add window to stage")
    func addWindow() {
        var stage = Stage()
        stage.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"))
        #expect(stage.windows.count == 1)
    }

    @Test("Remove window from stage")
    func removeWindow() {
        var stage = Stage()
        stage.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"))
        stage.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"))
        stage.removeWindow(windowID: 101)
        #expect(stage.windows.count == 1)
        #expect(stage.windows[0].windowID == 202)
    }

    @Test("Duplicate window not added")
    func noDuplicates() {
        var stage = Stage()
        stage.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"))
        stage.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"))
        #expect(stage.windows.count == 1)
    }

    @Test("Bring window to front (MRU)")
    func bringToFront() {
        var stage = Stage()
        stage.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"))
        stage.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"))
        stage.addWindow(StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"))
        stage.bringWindowToFront(windowID: 303)
        #expect(stage.windows[0].windowID == 303)
        #expect(stage.windows[1].windowID == 101)
        #expect(stage.windows[2].windowID == 202)
    }

    @Test("Remove all windows for bundle ID")
    func removeAllForBundle() {
        var stage = Stage()
        stage.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"))
        stage.addWindow(StageWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2"))
        stage.addWindow(StageWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3"))
        stage.removeAllWindows(forBundleID: "com.a")
        #expect(stage.windows.count == 1)
        #expect(stage.windows[0].ownerBundleID == "com.b")
    }

    @Test("Remove all windows for owner PID")
    func removeAllForOwnerPID() {
        var stage = Stage()
        stage.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 10))
        stage.addWindow(StageWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2", ownerPID: 20))
        stage.addWindow(StageWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3", ownerPID: 10))

        let removedCount = stage.removeAllWindows(forOwnerPID: 10)

        #expect(removedCount == 2)
        #expect(stage.windows.map(\.windowID) == [102])
    }

    @Test("Stage is Codable")
    func stageCodable() throws {
        var stage = Stage()
        stage.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"))
        let data = try JSONEncoder().encode(stage)
        let decoded = try JSONDecoder().decode(Stage.self, from: data)
        #expect(decoded.windows.count == 1)
        #expect(decoded.id == stage.id)
    }
}
