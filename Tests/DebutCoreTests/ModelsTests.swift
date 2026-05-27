import Testing
import Foundation
@testable import DebutCore

// MARK: - StageApp Tests

@Suite("StageApp")
struct StageAppTests {
    @Test("Create app")
    func createApp() {
        let app = StageApp(bundleID: "com.apple.Safari", name: "Safari")
        #expect(app.bundleID == "com.apple.Safari")
        #expect(app.name == "Safari")
        #expect(app.isShared == false)
    }

    @Test("App is Codable")
    func appCodable() throws {
        let app = StageApp(bundleID: "com.apple.Safari", name: "Safari", isShared: true)
        let data = try JSONEncoder().encode(app)
        let decoded = try JSONDecoder().decode(StageApp.self, from: data)
        #expect(decoded.bundleID == app.bundleID)
        #expect(decoded.isShared == true)
    }

    @Test("App equality by bundleID")
    func appEquality() {
        let a = StageApp(bundleID: "com.a", name: "A")
        let b = StageApp(bundleID: "com.a", name: "A")
        let c = StageApp(bundleID: "com.b", name: "B")
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
        #expect(stage.apps.isEmpty)
    }

    @Test("Add app to stage")
    func addApp() {
        var stage = Stage(name: "Work")
        stage.addApp(StageApp(bundleID: "com.a", name: "A"))
        #expect(stage.apps.count == 1)
    }

    @Test("Remove app from stage")
    func removeApp() {
        var stage = Stage(name: "Work")
        stage.addApp(StageApp(bundleID: "com.a", name: "A"))
        stage.addApp(StageApp(bundleID: "com.b", name: "B"))
        stage.removeApp(bundleID: "com.a")
        #expect(stage.apps.count == 1)
        #expect(stage.apps[0].bundleID == "com.b")
    }

    @Test("Duplicate app not added")
    func noDuplicates() {
        var stage = Stage(name: "Work")
        stage.addApp(StageApp(bundleID: "com.a", name: "A"))
        stage.addApp(StageApp(bundleID: "com.a", name: "A"))
        #expect(stage.apps.count == 1)
    }

    @Test("Bring app to front (MRU)")
    func bringToFront() {
        var stage = Stage(name: "Work")
        stage.addApp(StageApp(bundleID: "com.a", name: "A"))
        stage.addApp(StageApp(bundleID: "com.b", name: "B"))
        stage.addApp(StageApp(bundleID: "com.c", name: "C"))
        stage.bringAppToFront(bundleID: "com.c")
        #expect(stage.apps[0].bundleID == "com.c")
        #expect(stage.apps[1].bundleID == "com.a")
        #expect(stage.apps[2].bundleID == "com.b")
    }

    @Test("Stage is Codable")
    func stageCodable() throws {
        var stage = Stage(name: "Coding")
        stage.addApp(StageApp(bundleID: "com.a", name: "A"))
        let data = try JSONEncoder().encode(stage)
        let decoded = try JSONDecoder().decode(Stage.self, from: data)
        #expect(decoded.name == "Coding")
        #expect(decoded.apps.count == 1)
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
    }
}
