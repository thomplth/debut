import CoreGraphics
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

    // Old state.json files carry a bootSessionID key alongside the spaces, written by the
    // boot stamp this store no longer keeps. Nothing compares that key anymore, so it must
    // decode as an unknown field rather than as a reason to lose every live assignment.
    @Test("A legacy file with a bootSessionID key still loads with its assignments live")
    func legacyBootSessionIDStillLoadsLive() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var sm = SpaceManager()
        sm.addWindow(
            SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T", ownerPID: 10),
            toSpaceID: sm.activeSpaceID
        )
        let encoded = try JSONEncoder().encode(sm)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["bootSessionID"] = "1234567.89"
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try legacyData.write(to: dir.appendingPathComponent("state.json"))

        let loaded = try StateStore(directory: dir).load()

        #expect(loaded.activeSpace.windows.map(\.windowID) == [101])
        #expect(loaded.dormantWindowAssignments.isEmpty)
    }

    // Observed after a restart: Debut showed windows macOS no longer had, duplicated the
    // ones it did have, and rendered previews of whatever now owned the recycled window
    // ID — including its own overlay. A window ID surviving a restart is not evidence it
    // still names the same window, so a live window found under a stale ID must be judged
    // by its identity (bundle ID), not by the number alone.
    @Test("A reboot leaves no pre-reboot window ID live under its old identity")
    func rebootLeavesNoGhostWindowIDs() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var before = SpaceManager()
        before.createSpace(position: .below)
        let terminalSpaceID = before.spaces[0].id
        before.addWindow(
            SpaceWindow(
                windowID: 115,
                ownerBundleID: "com.mitchellh.ghostty",
                ownerName: "Ghostty",
                windowTitle: "~/Dropbox/Viewer-player",
                ownerPID: 706
            ),
            toSpaceID: terminalSpaceID
        )
        before.addWindow(
            SpaceWindow(
                windowID: 121,
                ownerBundleID: "company.thebrowser.dia",
                ownerName: "Dia",
                windowTitle: "Develop: Configure environment",
                ownerPID: 724
            ),
            toSpaceID: before.spaces[1].id
        )
        try StateStore(directory: dir).save(before)

        // The new boot relaunched Ghostty, so its bundle ID is running again under a new
        // PID with a new window ID. Dia's process is still running in the background —
        // as browsers do once their last window closes — so the stopped-process sweep
        // alone cannot explain away window ID 121: macOS reissued it to Notes, a window
        // Debut has never seen before. Only comparing identity at that ID catches it.
        let windowService = MockWindowService()
        windowService.apps = [
            AppInfo(bundleID: "com.mitchellh.ghostty", name: "Ghostty", pid: 653, isHidden: false),
            AppInfo(bundleID: "company.thebrowser.dia", name: "Dia", pid: 800, isHidden: false),
        ]
        windowService.windowList = [
            WindowInfo(
                windowID: 78,
                ownerBundleID: "com.mitchellh.ghostty",
                ownerName: "Ghostty",
                ownerPID: 653,
                title: "~/Dropbox/Viewer-player",
                bounds: .zero,
                isOnScreen: true
            ),
            WindowInfo(
                windowID: 121,
                ownerBundleID: "com.apple.Notes",
                ownerName: "Notes",
                ownerPID: 900,
                title: "Untitled Note",
                bounds: .zero,
                isOnScreen: true
            ),
        ]
        windowService.allWindowIDList = [78, 121]

        var manager = try StateStore(directory: dir).load()
        WindowDiscoveryService(
            windowService: windowService,
            processExitMonitor: MockProcessExitMonitor()
        ).reconcileWindows(&manager)

        let liveWindows = manager.allSpaces.flatMap(\.windows)
        #expect(liveWindows.map(\.windowID).sorted() == [78, 121])
        #expect(manager.spaceContainingWindow(windowID: 78) == terminalSpaceID)
        // Notes, not Dia, owns window 121 now — the recycled ID carries the new window's
        // identity, never the assignment that used to sit under it.
        #expect(liveWindows.first(where: { $0.windowID == 121 })?.ownerBundleID == "com.apple.Notes")
        // Dia is gone, but where its window belonged is not — it stays recoverable.
        #expect(manager.dormantWindowAssignments.map(\.window.ownerBundleID) == ["company.thebrowser.dia"])
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

    @Test("AX contradictions round-trip")
    func contradictionsRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        try store.saveContradictions([
            AXContradictionRecord(windowID: 17776, ownerPID: 89895, ownerBundleID: "com.google.Chrome")
        ])
        #expect(try store.loadContradictions() == [
            AXContradictionRecord(windowID: 17776, ownerPID: 89895, ownerBundleID: "com.google.Chrome")
        ])
    }

    @Test("Contradictions load as empty when no file exists")
    func contradictionsLoadEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try StateStore(directory: dir).loadContradictions().isEmpty)
    }

    @Test("Retired windows round-trip")
    func retiredWindowsRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        try store.saveRetiredWindows([
            RetiredWindowRecord(
                windowID: 28846, ownerPID: 89848, ownerBundleID: "com.omnigroup.OmniDiskSweeper"
            )
        ])
        #expect(try store.loadRetiredWindows() == [
            RetiredWindowRecord(
                windowID: 28846, ownerPID: 89848, ownerBundleID: "com.omnigroup.OmniDiskSweeper"
            )
        ])
    }

    @Test("Retired windows load as empty when no file exists")
    func retiredWindowsLoadEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try StateStore(directory: dir).loadRetiredWindows().isEmpty)
    }

    @Test("Settings round-trip")
    func settingsRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.stageCornerRadius = 30
        settings.windowSelectionStyle = .magnify
        settings.selectorOutset = 3
        settings.selectorCornerRadius = 18
        settings.magnifyScale = 1.14
        settings.magnifyShadowStrength = 1.6
        settings.overlayPresentationDelay = 0.25
        settings.quickSwitchExcludedBundleIDs = ["com.tinyspeck.slackmacgap"]
        settings.quickSwitchModifiers = ShortcutModifiers(control: true, option: true)
        settings.quickSwitchSameApplicationModifiers = ShortcutModifiers(command: true)

        try store.saveSettings(settings)
        let loaded = try store.loadSettings()
        #expect(loaded.launchAtLogin == true)
        #expect(loaded.stageCornerRadius == 30)
        #expect(loaded.windowSelectionStyle == .magnify)
        #expect(loaded.selectorOutset == 3)
        #expect(loaded.selectorCornerRadius == 18)
        #expect(loaded.magnifyScale == 1.14)
        #expect(loaded.magnifyShadowStrength == 1.6)
        #expect(loaded.overlayPresentationDelay == 0.25)
        #expect(loaded.quickSwitchExcludedBundleIDs == ["com.tinyspeck.slackmacgap"])
        #expect(loaded.quickSwitchModifiers == ShortcutModifiers(control: true, option: true))
        #expect(loaded.quickSwitchSameApplicationModifiers == ShortcutModifiers(command: true))
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

    @Test("Settings written before the stage scale existed use the 100 percent default")
    func legacySettingsDefaultStageScale() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "stageScale")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.stageScale == AppSettings.defaultStageScale)
        #expect(AppSettings.defaultStageScale == 1.0)
    }

    @Test("Settings written before selector customization use the macOS filled defaults")
    func legacySettingsDefaultSelector() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "windowSelectionStyle",
            "selectorOutset",
            "selectorCornerRadius",
            "magnifyScale",
            "magnifyShadowStrength",
        ] {
            object.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.windowSelectionStyle == .filled)
        #expect(decoded.selectorOutset == AppSettings.defaultSelectorOutset)
        #expect(decoded.selectorCornerRadius == AppSettings.defaultSelectorCornerRadius)
        #expect(decoded.magnifyScale == AppSettings.defaultMagnifyScale)
        #expect(decoded.magnifyShadowStrength == AppSettings.defaultMagnifyShadowStrength)
    }

    @Test("The short-lived outline style migrates to the filled selector")
    func outlineStyleMigratesToFilled() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["windowSelectionStyle"] = "Outline"
        object.removeValue(forKey: "selectorOutset")
        object["selectorBorderWidth"] = 4

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.windowSelectionStyle == .filled)
        #expect(decoded.selectorOutset == AppSettings.defaultSelectorOutset)
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
        #expect(settings.windowSelectionStyle == .filled)
    }
}
