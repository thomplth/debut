import CoreGraphics
import Testing
import Foundation
import DockGlass
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
        sm.addFixtureDesktop()
        sm.addWindow(SpaceWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toSpaceID: sm.spaces[1].id)

        try store.save(sm)
        let loaded = try store.load()

        #expect(loaded.spaces.count == 2)
        #expect(loaded.spaces[1].windows.count == 1)
    }

    @Test("Process-scoped shielding cards do not survive a restart")
    func transientWindowsAreNotPersisted() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(directory: dir)
        var manager = SpaceManager()
        manager.addWindow(
            SpaceWindow(windowID: 7, ownerBundleID: TransientWindowIdentity.bundleID(for: 42),
                        ownerName: "python", windowTitle: "Game", ownerPID: 42),
            toSpaceID: manager.activeSpaceID
        )
        manager.addWindow(
            SpaceWindow(windowID: 8, ownerBundleID: "com.example.Editor", ownerName: "Editor",
                        windowTitle: "Document", ownerPID: 43),
            toSpaceID: manager.activeSpaceID
        )

        try store.save(manager)
        let loaded = try store.load()

        #expect(manager.activeSpace.windowIDs == [7, 8])
        #expect(loaded.activeSpace.windowIDs == [8])
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
        before.addFixtureDesktop()
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
        sm.addFixtureDesktop()
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

    @Test("Main-display-only overlay placement defaults on for existing settings")
    func mainDisplayOverlayLegacySettings() throws {
        var settings = AppSettings()
        #expect(settings.overlayOnMainDisplayOnly)
        settings.overlayOnMainDisplayOnly = false
        let data = try JSONEncoder().encode(settings)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "overlayOnMainDisplayOnly")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).overlayOnMainDisplayOnly)
    }

    @Test("Desktop switch indicator defaults on for existing settings")
    func desktopSwitchIndicatorLegacySettings() throws {
        var settings = AppSettings()
        settings.showsDesktopSwitchIndicator = false
        let data = try JSONEncoder().encode(settings)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "showsDesktopSwitchIndicator")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy)
            .showsDesktopSwitchIndicator)
    }

    @Test("Settings round-trip")
    func settingsRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.stageCornerRadius = 30
        settings.overlayOnMainDisplayOnly = true
        settings.showsDesktopSwitchIndicator = false
        settings.iconStageCornerRadius = 40
        settings.selectorOutset = 3
        settings.previewCornerRadius = 18
        settings.badgePlacement = .top
        settings.overlayPresentationDelay = 0.25
        settings.quickSwitchModifiers = ShortcutModifiers(control: true, option: true)
        settings.quickSwitchSameApplicationModifiers = ShortcutModifiers(command: true)

        try store.saveSettings(settings)
        let loaded = try store.loadSettings()
        #expect(loaded.launchAtLogin == true)
        #expect(loaded.stageCornerRadius == 30)
        #expect(loaded.overlayOnMainDisplayOnly)
        #expect(!loaded.showsDesktopSwitchIndicator)
        #expect(loaded.iconStageCornerRadius == 40)
        #expect(loaded.selectorOutset == 3)
        #expect(loaded.previewCornerRadius == 18)
        #expect(loaded.badgePlacement == .top)
        #expect(loaded.overlayPresentationDelay == 0.25)
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

    @Test("Quick switch exclusions are neither persisted nor restored from older settings")
    func quickSwitchExclusionsAreRemoved() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["quickSwitchExcludedBundleIDs"] == nil)

        object["quickSwitchExcludedBundleIDs"] = ["com.tinyspeck.slackmacgap"]
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        let reencoded = try JSONEncoder().encode(decoded)
        let migratedObject = try #require(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )

        #expect(migratedObject["quickSwitchExcludedBundleIDs"] == nil)
    }

    @Test("Older settings default overlay presentation delay to 100ms")
    func legacySettingsDefaultOverlayPresentationDelay() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "overlayPresentationDelay")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.overlayPresentationDelay == 0.1)
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

    @Test("Saved preview scales respect the current setting range", arguments: [0.5, 0.75, 1.0, 1.5, 2.5, 3.0, 4.0, 4.5])
    func savedStageScaleRange(scale: Double) throws {
        var settings = AppSettings()
        settings.stageScale = scale
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(AppSettings.maximumStageScale == 4)
        #expect(decoded.stageScale == min(AppSettings.maximumStageScale, max(1, scale)))
    }

    @Test("Settings written before the stage scale existed use the 150 percent default")
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

    /// Magnify was retired (KHA-1064): a file that chose it, with its sliders and the old
    /// highlight corner, loads with the highlight and the default preview corner.
    @Test("Settings that chose Magnify load with the highlight")
    func legacySettingsDropMagnify() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["windowSelectionStyle"] == nil)
        #expect(object["magnifyScale"] == nil)
        #expect(object["previewCardSpacing"] == nil, "card spacing is no longer a setting")
        object["windowSelectionStyle"] = "Magnify"
        object["magnifyScale"] = 1.14
        object["magnifyShadowStrength"] = 1.6
        object["selectorCornerRadius"] = 18
        object["previewCardSpacing"] = 30
        object.removeValue(forKey: "selectorOutset")
        object.removeValue(forKey: "previewCornerRadius")
        object.removeValue(forKey: "iconStageCornerRadius")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.selectorOutset == AppSettings.defaultSelectorOutset)
        #expect(decoded.previewCornerRadius == AppSettings.defaultPreviewCornerRadius)
        #expect(decoded.iconStageCornerRadius == AppSettings.defaultIconStageCornerRadius)
        #expect(decoded.previewCardSpacing == AppSettings.defaultPreviewCardSpacing)
    }

    /// Adaptive sizing is the new default, so a settings file written before it existed opts
    /// into it rather than staying on the uniform grid it was saved under.
    @Test("Settings written before adaptive sizing still get it on")
    func legacySettingsDefaultAdaptiveCardSizing() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "adaptiveCardSizing")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.adaptiveCardSizing)
        #expect(AppSettings().adaptiveCardSizing)
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
        #expect(settings.glassStyle == .native)
        #expect(settings.badgePlacement == .titleRow)
    }

    @Test("Settings written before Liquid Glass tuning use the native look")
    func legacySettingsDefaultLiquidGlass() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in ["glassRimStrength", "glassEdgeRefraction", "followsSystemGlassTint", "glassTintAmount",
                    "badgeGrowth", "titleHaloStrength", "titleHaloSize"] {
            object.removeValue(forKey: key)
        }
        object["glassStyle"] = "Native"
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.glassStyle == .native)
        #expect(decoded.glassRimStrength == 1)
        #expect(decoded.glassEdgeRefraction == 1)
        #expect(decoded.followsSystemGlassTint)
        #expect(decoded.dockGlassStyle == DockGlassStyle(focusState: .active))
        #expect(decoded.badgeGrowth == AppSettings.defaultBadgeGrowth)
        #expect(decoded.titleHaloStrength == 1)
        #expect(decoded.titleHaloSize == AppSettings.defaultTitleHaloSize)
    }

    @Test("Badge growth and title halo settings clamp to their ranges")
    func badgeAndHaloSettingsClamp() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["badgeGrowth"] = 3
        object["titleHaloStrength"] = -1
        object["titleHaloSize"] = 99
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.badgeGrowth == AppSettings.maximumBadgeGrowth)
        #expect(decoded.titleHaloStrength == 0)
        #expect(decoded.titleHaloSize == AppSettings.maximumTitleHaloSize)
    }

    @Test("The title halo only applies to the native and clear materials")
    func titleHaloIsOffOnRegularGlass() {
        var settings = AppSettings()
        settings.titleHaloStrength = 0.6
        for style in [GlassStyle.native, .clear] {
            settings.glassStyle = style
            #expect(settings.effectiveTitleHaloStrength == 0.6)
        }
        settings.glassStyle = .regular
        #expect(settings.effectiveTitleHaloStrength == 0)
        #expect(settings.titleHaloStrength == 0.6)
    }

    @Test("Liquid Glass settings map onto the DockGlass style and clamp")
    func liquidGlassSettingsMapToDockGlassStyle() throws {
        var settings = AppSettings()
        settings.glassRimStrength = 0.5
        settings.glassEdgeRefraction = 1.5
        settings.followsSystemGlassTint = false
        settings.glassTintAmount = 0.25
        #expect(settings.dockGlassStyle == DockGlassStyle(
            rimStrength: 0.5,
            edgeRefraction: 1.5,
            tint: .fixed(0.25),
            focusState: .active
        ))

        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["glassRimStrength"] = 9
        object["glassEdgeRefraction"] = -1
        object["glassTintAmount"] = 4
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.glassRimStrength == AppSettings.maximumGlassRimStrength)
        #expect(decoded.glassEdgeRefraction == AppSettings.minimumGlassEdgeRefraction)
        #expect(decoded.glassTintAmount == 1)
    }
}
