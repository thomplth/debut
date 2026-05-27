import Testing
import Foundation
@testable import DebutCore

@Suite("StateStore")
struct StateStoreTests {

    private func makeTempDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("Save and load round-trip")
    func saveAndLoad() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        var sm = StageManager()
        sm.createStage(name: "Coding", position: .below)
        sm.addWindow(
            StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false),
            toStageID: sm.stages[1].id
        )
        sm.saveStageAsTemplate(stageID: sm.stages[1].id, templateName: "Dev")

        try store.save(sm)
        let loaded = try store.load()

        #expect(loaded.stages.count == 2)
        #expect(loaded.stages[1].name == "Coding")
        #expect(loaded.stages[1].windows.count == 1)
        #expect(loaded.templates.count == 1)
        #expect(loaded.templates[0].name == "Dev")
    }

    @Test("Load returns nil when no file exists")
    func loadEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        let result = try store.load()
        #expect(result.stages.count == 1) // fresh default
    }

    @Test("Creates directory if missing")
    func createsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTests-\(UUID().uuidString)")
            .appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let store = StateStore(directory: dir)
        var sm = StageManager()
        sm.createStage(name: "Test", position: .below)

        try store.save(sm)
        let loaded = try store.load()
        #expect(loaded.stages.count == 2)
    }

    @Test("Overwrite existing state")
    func overwrite() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)

        var sm1 = StageManager()
        sm1.createStage(name: "First", position: .below)
        try store.save(sm1)

        var sm2 = StageManager()
        sm2.createStage(name: "Second", position: .below)
        sm2.createStage(name: "Third", position: .below)
        try store.save(sm2)

        let loaded = try store.load()
        #expect(loaded.stages.count == 3)
        #expect(loaded.stages[2].name == "Third")
    }

    @Test("Settings save and load")
    func settingsRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.defaultStageName = "Workspace"
        settings.confirmStageDeletion = false

        try store.saveSettings(settings)
        let loaded = try store.loadSettings()

        #expect(loaded.launchAtLogin == true)
        #expect(loaded.defaultStageName == "Workspace")
        #expect(loaded.confirmStageDeletion == false)
    }

    @Test("Settings load defaults when no file")
    func settingsDefaults() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        let settings = try store.loadSettings()

        #expect(settings.launchAtLogin == false)
        #expect(settings.showInMenuBar == true)
        #expect(settings.defaultStageName == "Stage")
        #expect(settings.confirmStageDeletion == true)
        #expect(settings.animationsEnabled == true)
    }
}
