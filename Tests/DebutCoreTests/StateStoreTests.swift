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
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toSpaceID: sm.spaces[1].id)

        try store.save(sm)
        let loaded = try store.load()

        #expect(loaded.spaces.count == 2)
        #expect(loaded.spaces[1].windows.count == 1)
    }

    @Test("Load returns default when no file exists")
    func loadEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        let result = try store.load()
        #expect(result.spaces.count == 1)
    }

    @Test("Creates directory if missing")
    func createsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTests-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let store = StateStore(directory: dir)
        var sm = SpaceManager()
        sm.createSpace(position: .below)
        try store.save(sm)
        let loaded = try store.load()
        #expect(loaded.spaces.count == 2)
    }

    @Test("Settings round-trip")
    func settingsRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.stageCornerRadius = 30
        settings.overlayPresentationDelay = 0.25
        settings.quickSwitchExcludedBundleIDs = ["com.tinyspeck.slackmacgap"]
        settings.quickSwitchModifiers = ShortcutModifiers(control: true, option: true)
        settings.quickSwitchSameApplicationModifiers = ShortcutModifiers(command: true)
        settings.commandHintVisibility = .always
        _ = settings.recordCommandUsage(.moveWindowLeft)

        try store.saveSettings(settings)
        let loaded = try store.loadSettings()
        #expect(loaded.launchAtLogin == true)
        #expect(loaded.stageCornerRadius == 30)
        #expect(loaded.overlayPresentationDelay == 0.25)
        #expect(loaded.quickSwitchExcludedBundleIDs == ["com.tinyspeck.slackmacgap"])
        #expect(loaded.quickSwitchModifiers == ShortcutModifiers(control: true, option: true))
        #expect(loaded.quickSwitchSameApplicationModifiers == ShortcutModifiers(command: true))
        #expect(loaded.commandHintVisibility == .always)
        #expect(loaded.commandUsageCounts[.moveWindowLeft] == 1)
    }

    @Test("Older settings drop usage counts for retired commands")
    func legacySettingsDropRetiredCommandUsage() throws {
        var settings = AppSettings()
        _ = settings.recordCommandUsage(.moveWindowLeft)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        var counts = try #require(object["commandUsageCounts"] as? [Any])
        counts.append("swapSpaceUp")
        counts.append(7)
        object["commandUsageCounts"] = counts

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.commandUsageCounts[.moveWindowLeft] == 1)
        #expect(decoded.commandUsageCounts.count == 1)
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

    @Test("Older settings default overlay presentation delay to 75ms")
    func legacySettingsDefaultOverlayPresentationDelay() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "overlayPresentationDelay")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.overlayPresentationDelay == 0.075)
    }

    // Settings written before this key existed also include the `spaceSwitchVelocity` it
    // replaced. That key is now unknown and must be ignored rather than fought over, so
    // upgrading lands on the new default instead of failing to decode.
    @Test("Older settings default the desktop switch duration")
    func legacySettingsDefaultSpaceSwitchDuration() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "spaceSwitchDuration")
        object["spaceSwitchVelocity"] = 400
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.spaceSwitchDuration == AppSettings.defaultSpaceSwitchDuration)
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
        #expect(AppSettings.defaultHeldCycleMinimumInterval == 0.06)
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

    @Test("Settings written before the stage scale existed take the larger new default")
    func legacySettingsDefaultStageScale() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "stageScale")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.stageScale == AppSettings.defaultStageScale)
        #expect(AppSettings.defaultStageScale == 1.5)
    }

    @Test("Settings files written before the option audit still load")
    func legacySettingsIgnoreRemovedOptions() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.stageCornerRadius = 12
        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for removed in [
            "showInMenuBar",
            "newSpacePlacement",
            "confirmSpaceDeletion",
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
        #expect(decoded.stageCornerRadius == 12)
    }

    @Test("Settings defaults when no file")
    func settingsDefaults() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        let settings = try store.loadSettings()
        #expect(settings.launchAtLogin == true)
        #expect(settings.glassStyle == .clear)
    }
}
