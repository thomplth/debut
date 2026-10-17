import DebutCore
import Foundation
import Testing
@testable import DebutDemo

/// Captures show Debut as a new user sees it, so the driver starts from the app's fresh
/// defaults and changes only what the fixture itself needs (KHA-1117).
struct CaptureSettingsTests {
    @Test func captureStartsFromFreshDefaultsWithOnlyFixtureDeltas() {
        var expected = AppSettings()
        expected.launchAtLogin = false
        expected.excludedBundleIDs = []
        expected.features.fasterDesktopSwitching = false
        #expect(captureSettings() == expected)
        #expect(captureSettings().previewAppearance == AppSettings().previewAppearance)
        #expect(captureSettings().iconAppearance == AppSettings().iconAppearance)
    }

    @Test func instantSideOnlyEnablesFasterSwitching() {
        var expected = AppSettings()
        expected.launchAtLogin = false
        expected.excludedBundleIDs = []
        expected.features.fasterDesktopSwitching = true
        #expect(captureSettings(fasterDesktopSwitching: true) == expected)
        // The comparison is labelled "Instant": the fresh default must remain an instant cut.
        #expect(captureSettings(fasterDesktopSwitching: true).spaceSwitchDuration == 0)
    }

    @Test func noPreviewStillsDrawTheIconModeDefaults() {
        let settings = captureSettings(windowPreviews: false)
        #expect(!settings.features.windowPreviews)
        #expect(settings.appearance(for: OverlayCardStyle(previewsAvailable: settings.features.windowPreviews))
            == AppSettings().iconAppearance)
        #expect(captureSettings().appearance(for: .previews) == AppSettings().previewAppearance)
    }

    @Test func writtenSettingsUseTheAppsCurrentEncoding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("debut-capture-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = captureSettings(fasterDesktopSwitching: true)
        try writeCaptureSettings(settings, to: directory)

        #expect(try StateStore(directory: directory).loadSettings() == settings)
        let data = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["previewAppearance"] is [String: Any])
        #expect(json["iconAppearance"] is [String: Any])
        // The retired flat keys would be read as a legacy preview appearance and override defaults.
        for legacy in ["glassStyle", "stageScale", "stageCornerRadius", "inactiveStageScale"] {
            #expect(json[legacy] == nil, "top-level \(legacy) overrides the per-mode defaults")
        }
    }
}
