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
        sm.createStage(position: .below)
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: sm.stages[1].id)

        try store.save(sm)
        let loaded = try store.load()

        #expect(loaded.stages.count == 2)
        #expect(loaded.stages[1].windows.count == 1)
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
        sm.createStage(position: .below)
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
        settings.plateCornerRadius = 30
        settings.overlayPresentationDelay = 0.25
        settings.quickSwitchExcludedBundleIDs = ["com.tinyspeck.slackmacgap"]
        settings.quickSwitchModifiers = ShortcutModifiers(control: true, option: true)
        settings.quickSwitchSameApplicationModifiers = ShortcutModifiers(command: true)
        settings.commandHintVisibility = .always
        _ = settings.recordCommandUsage(.newStageBelow)

        try store.saveSettings(settings)
        let loaded = try store.loadSettings()
        #expect(loaded.launchAtLogin == true)
        #expect(loaded.plateCornerRadius == 30)
        #expect(loaded.overlayPresentationDelay == 0.25)
        #expect(loaded.quickSwitchExcludedBundleIDs == ["com.tinyspeck.slackmacgap"])
        #expect(loaded.quickSwitchModifiers == ShortcutModifiers(control: true, option: true))
        #expect(loaded.quickSwitchSameApplicationModifiers == ShortcutModifiers(command: true))
        #expect(loaded.commandHintVisibility == .always)
        #expect(loaded.commandUsageCounts[.newStageBelow] == 1)
    }

    @Test("Older settings use Control and Control-Option quick-switch defaults")
    func legacySettingsDefaultQuickSwitchConfiguration() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "quickSwitchBehavior")
        object.removeValue(forKey: "quickSwitchModifiers")
        object.removeValue(forKey: "quickSwitchSameApplicationModifiers")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.quickSwitchModifiers == .control)
        #expect(decoded.quickSwitchSameApplicationModifiers == ShortcutModifiers(
            control: true,
            option: true
        ))
    }

    @Test("Older settings default quick switch exclusions to empty")
    func legacySettingsDefaultQuickSwitchExclusions() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "quickSwitchExcludedBundleIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.quickSwitchExcludedBundleIDs.isEmpty)
    }

    @Test("Older settings default overlay presentation delay to 80ms")
    func legacySettingsDefaultOverlayPresentationDelay() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "overlayPresentationDelay")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.overlayPresentationDelay == 0.08)
    }

    @Test("Older settings default the preview cache to last-active refreshes")
    func legacySettingsDefaultPreviewCache() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "previewRefreshPolicy")
        object.removeValue(forKey: "previewCacheTTL")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.previewRefreshPolicy == .lastActiveOnly)
        #expect(decoded.previewCacheTTL == AppSettings.defaultPreviewCacheTTL)
    }

    @Test("Older settings default held cycling to the standard pacing interval")
    func legacySettingsDefaultHeldCycleInterval() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "heldCycleMinimumInterval")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.heldCycleMinimumInterval == AppSettings.defaultHeldCycleMinimumInterval)
        #expect(AppSettings.defaultHeldCycleMinimumInterval == 0.1)
    }

    @Test("Older settings default command hints to automatic with no usage")
    func legacySettingsDefaultCommandHints() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "commandHintVisibility")
        object.removeValue(forKey: "commandUsageCounts")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.commandHintVisibility == .automatic)
        #expect(decoded.commandUsageCounts.isEmpty)
    }

    @Test("Settings files written before the option audit still load")
    func legacySettingsIgnoreRemovedOptions() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.plateCornerRadius = 12
        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for removed in [
            "showInMenuBar",
            "newStagePlacement",
            "confirmStageDeletion",
            "animationsEnabled",
            "selectionOpacity",
            "selectionBorderWidth",
            "selectionBorderOpacity",
        ] {
            #expect(object[removed] == nil, "\(removed) should no longer be written")
            object[removed] = "legacy"
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.launchAtLogin == true)
        #expect(decoded.plateCornerRadius == 12)
    }

    @Test("Settings defaults when no file")
    func settingsDefaults() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        let settings = try store.loadSettings()
        #expect(settings.launchAtLogin == false)
        #expect(settings.glassStyle == .clear)
    }
}
