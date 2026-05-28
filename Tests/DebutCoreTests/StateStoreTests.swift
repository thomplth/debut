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
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: sm.stages[1].id)
        sm.saveStageAsTemplate(stageID: sm.stages[1].id, templateName: "Dev")

        try store.save(sm)
        let loaded = try store.load()

        #expect(loaded.stages.count == 2)
        #expect(loaded.stages[1].name == "Coding")
        #expect(loaded.stages[1].windows.count == 1)
        #expect(loaded.templates.count == 1)
    }

    @Test("Load returns default when no file exists")
    func loadEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        let result = try store.load()
        #expect(result.stages.count == 1)
    }

    @Test("Creates directory if missing")
    func createsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTests-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let store = StateStore(directory: dir)
        var sm = StageManager()
        sm.createStage(name: "Test", position: .below)
        try store.save(sm)
        let loaded = try store.load()
        #expect(loaded.stages.count == 2)
    }

    @Test("Settings round-trip")
    func settingsRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.defaultStageName = "Workspace"

        try store.saveSettings(settings)
        let loaded = try store.loadSettings()
        #expect(loaded.launchAtLogin == true)
        #expect(loaded.defaultStageName == "Workspace")
    }

    @Test("Settings defaults when no file")
    func settingsDefaults() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        let settings = try store.loadSettings()
        #expect(settings.launchAtLogin == false)
        #expect(settings.showInMenuBar == true)
    }
}
