import Testing
import Foundation
@testable import DebutCore

// MARK: - StageWindow Tests

@Suite("StageWindow")
struct StageWindowTests {
    @Test("Create window with app info")
    func createWindow() {
        let window = StageWindow(
            windowID: 42,
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            isShared: false
        )
        #expect(window.windowID == 42)
        #expect(window.appBundleID == "com.apple.Safari")
        #expect(window.appName == "Safari")
        #expect(window.isShared == false)
    }

    @Test("Window is Codable")
    func windowCodable() throws {
        let window = StageWindow(
            windowID: 42,
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            isShared: true
        )
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(StageWindow.self, from: data)
        #expect(decoded.windowID == window.windowID)
        #expect(decoded.appBundleID == window.appBundleID)
        #expect(decoded.appName == window.appName)
        #expect(decoded.isShared == window.isShared)
    }

    @Test("Window equality by ID")
    func windowEquality() {
        let a = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        let b = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        let c = StageWindow(windowID: 2, appBundleID: "com.a", appName: "A", isShared: false)
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - Stage Tests

@Suite("Stage")
struct StageTests {
    @Test("Create stage with name")
    func createStage() {
        let stage = Stage(name: "Coding")
        #expect(stage.name == "Coding")
        #expect(stage.windows.isEmpty)
    }

    @Test("Add window to stage")
    func addWindow() {
        var stage = Stage(name: "Work")
        let window = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        stage.addWindow(window)
        #expect(stage.windows.count == 1)
        #expect(stage.windows[0].windowID == 1)
    }

    @Test("Remove window from stage")
    func removeWindow() {
        var stage = Stage(name: "Work")
        let w1 = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        let w2 = StageWindow(windowID: 2, appBundleID: "com.b", appName: "B", isShared: false)
        stage.addWindow(w1)
        stage.addWindow(w2)
        stage.removeWindow(byID: 1)
        #expect(stage.windows.count == 1)
        #expect(stage.windows[0].windowID == 2)
    }

    @Test("Remove window that doesn't exist is no-op")
    func removeNonexistentWindow() {
        var stage = Stage(name: "Work")
        let w = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        stage.addWindow(w)
        stage.removeWindow(byID: 999)
        #expect(stage.windows.count == 1)
    }

    @Test("Duplicate window not added")
    func noDuplicateWindows() {
        var stage = Stage(name: "Work")
        let w = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        stage.addWindow(w)
        stage.addWindow(w)
        #expect(stage.windows.count == 1)
    }

    @Test("Stage has unique app bundle IDs")
    func appBundleIDs() {
        var stage = Stage(name: "Work")
        stage.addWindow(StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false))
        stage.addWindow(StageWindow(windowID: 2, appBundleID: "com.a", appName: "A", isShared: false))
        stage.addWindow(StageWindow(windowID: 3, appBundleID: "com.b", appName: "B", isShared: false))
        #expect(stage.appBundleIDs == ["com.a", "com.b"])
    }

    @Test("Stage is Codable")
    func stageCodable() throws {
        var stage = Stage(name: "Coding")
        stage.addWindow(StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false))
        let data = try JSONEncoder().encode(stage)
        let decoded = try JSONDecoder().decode(Stage.self, from: data)
        #expect(decoded.name == "Coding")
        #expect(decoded.windows.count == 1)
        #expect(decoded.id == stage.id)
    }

    @Test("Stage rename")
    func rename() {
        var stage = Stage(name: "Old")
        stage.name = "New"
        #expect(stage.name == "New")
    }
}

// MARK: - Template Tests

@Suite("Template")
struct TemplateTests {
    @Test("Create template with apps")
    func createTemplate() {
        let template = Template(name: "Coding", appBundleIDs: ["com.apple.Terminal", "com.microsoft.VSCode"])
        #expect(template.name == "Coding")
        #expect(template.appBundleIDs.count == 2)
    }

    @Test("Template is Codable")
    func templateCodable() throws {
        let template = Template(name: "Review", appBundleIDs: ["com.apple.Safari"])
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(Template.self, from: data)
        #expect(decoded.name == "Review")
        #expect(decoded.appBundleIDs == ["com.apple.Safari"])
        #expect(decoded.id == template.id)
    }

    @Test("Template equality")
    func templateEquality() {
        let a = Template(name: "A", appBundleIDs: ["com.a"])
        let b = Template(name: "A", appBundleIDs: ["com.a"])
        #expect(a != b) // different IDs
    }
}
