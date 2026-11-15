import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Single-row fitting")
struct SingleRowFittingTests {
    private let display = CGSize(width: 1_512, height: 945)

    private var availableWidth: CGFloat {
        StageConstants.availableStageWidth(screenWidth: display.width)
    }

    private func layouts(counts: [Int], wrapsRows: Bool, requested: CGFloat = 1.5) -> [StageWindowLayout] {
        let aspects = StageConstants.contentAspects(forWindowCounts: counts)
        let metrics = StageConstants.drawnMetrics(
            stageScale: requested,
            contentAspects: aspects,
            containerSize: display,
            cardSpacing: CGFloat(AppSettings.defaultPreviewCardSpacing),
            wrapsRows: wrapsRows
        )
        return StageConstants.stageLayouts(
            forContentAspects: aspects,
            screenWidth: display.width,
            metrics: metrics
        )
    }

    private func spaceManager(windowsPerSpace counts: [Int]) -> SpaceManager {
        var manager = SpaceManager()
        var nextID: CGWindowID = 1
        for (index, count) in counts.enumerated() {
            if index > 0 {
                manager.activateSpace(id: manager.spaces[index - 1].id)
                manager.addFixtureDesktop()
            }
            let spaceID = manager.spaces[index].id
            for _ in 0..<count {
                manager.addWindow(
                    SpaceWindow(
                        windowID: nextID,
                        ownerBundleID: "com.test.\(nextID)",
                        ownerName: "App \(nextID)",
                        windowTitle: "Window \(nextID)"
                    ),
                    toSpaceID: spaceID
                )
                nextID += 1
            }
        }
        return manager
    }

    @Test("A grid that does not wrap keeps every card in one row however narrow the display")
    func unwrappedGridIsOneRow() {
        let metrics = StageMetrics.standard.wrappingRows(false)
        let layout = StageWindowLayout(windowCount: 24, availableWidth: 400, metrics: metrics)

        #expect(layout.rowSizes == [24])
    }

    @Test("A crowded switcher that does not wrap shrinks its one row to fit the display", arguments: [12, 24, 40, 120])
    func unwrappedRowFitsTheDisplay(windowCount: Int) {
        let layout = layouts(counts: [windowCount], wrapsRows: false)[0]

        #expect(layout.rowCount == 1)
        #expect(layout.stageSize.width <= availableWidth + 0.01)
        #expect(layout.stageSize.height <= StageConstants.availableStageHeight(screenHeight: display.height) + 0.01)
    }

    @Test("A crowded switcher that wraps still takes more rows")
    func wrappedRowsStillWrap() {
        #expect(layouts(counts: [24], wrapsRows: true)[0].rowCount > 1)
    }

    @Test("A switcher that already fits in one row is drawn the same whether or not it wraps")
    func uncrowdedSwitcherIsUnaffected() {
        let wrapped = layouts(counts: [3, 2], wrapsRows: true)
        let unwrapped = layouts(counts: [3, 2], wrapsRows: false)

        #expect(wrapped.map(\.stageSize) == unwrapped.map(\.stageSize))
        #expect(wrapped.map(\.thumbnailWidths) == unwrapped.map(\.thumbnailWidths))
    }

    @Test("Every stage shrinks by the same scale as the most crowded one")
    func stagesShrinkUniformly() {
        let stages = layouts(counts: [2, 30, 5], wrapsRows: false)

        #expect(stages.allSatisfy { $0.rowCount == 1 })
        #expect(stages.allSatisfy { $0.metrics == stages[0].metrics })
        #expect(Set(stages.flatMap(\.thumbnailWidths)).count == 1)
        #expect(stages[0].thumbnailWidths[0] < layouts(counts: [2, 5], wrapsRows: false)[0].thumbnailWidths[0])
    }

    @Test("Fresh settings keep Command-Tab on one row and let Option-Tab wrap")
    func freshDefaults() {
        let settings = AppSettings()

        #expect(!settings.commandTabWrapsRows)
        #expect(settings.optionTabWrapsRows)
    }

    @Test("Settings saved before row wrapping was a choice take the fresh defaults")
    func legacySettingsTakeFreshDefaults() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "commandTabWrapsRows")
        object.removeValue(forKey: "optionTabWrapsRows")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(!decoded.commandTabWrapsRows)
        #expect(decoded.optionTabWrapsRows)
    }

    @Test("Saved row-wrapping choices survive a round trip")
    func savedChoicesRoundTrip() throws {
        var settings = AppSettings()
        settings.commandTabWrapsRows = true
        settings.optionTabWrapsRows = false

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.commandTabWrapsRows)
        #expect(!decoded.optionTabWrapsRows)
    }

    @Test("The Command-Tab overlay follows its own wrap setting, not Option-Tab's", arguments: [true, false])
    func commandTabFollowsItsSetting(wraps: Bool) {
        var settings = AppSettings()
        settings.commandTabWrapsRows = wraps
        settings.optionTabWrapsRows = !wraps
        let viewModel = StageOverlayViewModel(
            spaceManager: spaceManager(windowsPerSpace: [24, 3]),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0,
            appearance: settings
        )
        let aspects = viewModel.stages.map { $0.windows.map(\.contentAspect) }
        let metrics = viewModel.drawnMetrics(contentAspects: aspects, containerSize: display)
        let layout = StageConstants.stageLayouts(
            forContentAspects: aspects,
            screenWidth: display.width,
            metrics: metrics
        )[0]

        #expect((layout.rowCount > 1) == wraps)
    }

    @Test("The Option-Tab overlay follows its own wrap setting, not Command-Tab's", arguments: [true, false])
    func optionTabFollowsItsSetting(wraps: Bool) {
        var settings = AppSettings()
        settings.optionTabWrapsRows = wraps
        settings.commandTabWrapsRows = !wraps
        let entries = spaceManager(windowsPerSpace: [12, 12]).globalWindowOrder()
        let viewModel = AltTabOverlayViewModel(entries: entries, selectedIndex: 0, appearance: settings)

        let layout = viewModel.layout(containerSize: display)

        #expect((layout.rowCount > 1) == wraps)
        #expect(layout.stageSize.width <= availableWidth + 0.01)
    }

    @Test("Restoring Appearance defaults restores both wrap choices", arguments: [true, false])
    func restoreDefaultsResetsWrapping(screenRecordingGranted: Bool) {
        var viewModel = SettingsViewModel(settings: AppSettings(), spaceManager: SpaceManager())
        viewModel.screenRecordingGranted = screenRecordingGranted
        viewModel.settings.commandTabWrapsRows = true
        viewModel.settings.optionTabWrapsRows = false

        viewModel.restoreDefaults(for: .appearance)

        #expect(!viewModel.settings.commandTabWrapsRows)
        #expect(viewModel.settings.optionTabWrapsRows)
    }
}
