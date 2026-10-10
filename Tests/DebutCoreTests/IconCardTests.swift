import CoreGraphics
import DockGlass
import Foundation
import Testing
@testable import DebutCore

/// Without previews, every window is a native Command-Tab switcher icon slot.
@Suite("Icon cards")
struct IconCardTests {
    private let native = DockGlass.Metrics.standard

    @Test("Icon slots are native's square 102-point slots on a 134-point pitch")
    func iconSlotsAreNative() {
        let metrics = StageMetrics.icons.withCardSpacing(CGFloat(AppSettings.defaultPreviewCardSpacing))
        #expect(metrics.cardStyle == .icons)
        #expect(metrics.thumbnailWidth == native.iconSize)
        #expect(metrics.thumbnailHeight == native.iconSize)

        let layout = StageWindowLayout(windowCount: 4, availableWidth: 10_000, metrics: metrics)
        #expect(layout.stageSize.height == native.plateHeight)
        #expect(layout.stageSize.width == native.plateWidth(iconCount: 4))
        #expect(layout.cardOffsetFromCenter(at: 1).width - layout.cardOffsetFromCenter(at: 0).width
            == native.iconPitch)
    }

    @Test("Icon slots never take a window's or a display's shape")
    func iconSlotsIgnoreShapes() {
        let metrics = StageMetrics.icons
        #expect(metrics.adapted(toContentAspect: 0.3) == metrics)
        #expect(metrics.adapted(toContentAspect: 4) == metrics)
        #expect(StageMetrics.shaped(forDisplay: CGSize(width: 900, height: 1600), cardStyle: .icons) == metrics)
        #expect(StageMetrics.shaped(forDisplay: CGSize(width: 900, height: 1600)).cardStyle == .previews)
    }

    @Test("The icon highlight is native's, concentric with the icon")
    func iconHighlightIsNative() {
        let settings = AppSettings()
        let icons = StageMetrics.icons
        #expect(icons.selectorCornerRadius(userRadius: settings.selectorCornerRadius)
            == native.selectionCornerRadius)
        #expect(abs(StageMetrics.standard.selectorCornerRadius(userRadius: settings.selectorCornerRadius)
            - CGFloat(settings.selectorCornerRadius)) < 1e-9)
        // A user's change keeps its offset from concentric in both styles.
        #expect(icons.selectorCornerRadius(userRadius: settings.selectorCornerRadius + 4)
            == native.selectionCornerRadius + 4)
        #expect(icons.scaled(by: 2).selectorCornerRadius(userRadius: settings.selectorCornerRadius)
            == native.selectionCornerRadius * 2)
    }

    @Test("Icon size is stored apart from preview size and defaults to native")
    func iconScaleDefaultsAndPersists() throws {
        var settings = AppSettings()
        #expect(settings.iconScale == 1)
        #expect(settings.overlayScale(for: .icons) == 1)
        #expect(settings.overlayScale(for: .previews) == AppSettings.defaultStageScale)

        settings.iconScale = 1.3
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: encoded).iconScale == 1.3)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "iconScale")
        #expect(try JSONDecoder().decode(
            AppSettings.self, from: JSONSerialization.data(withJSONObject: object)
        ).iconScale == 1)
        object["iconScale"] = 9
        #expect(try JSONDecoder().decode(
            AppSettings.self, from: JSONSerialization.data(withJSONObject: object)
        ).iconScale == AppSettings.maximumStageScale)
    }

    @Test("Fitting draws icons at the icon size and ignores window shapes")
    func fittingUsesIconScale() {
        var settings = AppSettings()
        settings.iconScale = 1.2
        let display = CGSize(width: 1600, height: 1000)
        let metrics = StageConstants.drawnMetrics(
            stageScale: CGFloat(settings.overlayScale(for: .icons)),
            contentAspects: [[0.4, 3, nil]],
            containerSize: display,
            cardSpacing: CGFloat(settings.previewCardSpacing),
            cardStyle: .icons
        )
        #expect(metrics.cardStyle == .icons)
        #expect(abs(metrics.previewScale - 1.2) < 1e-9)
        #expect(metrics.scaleFactor == 1)
        #expect(abs(metrics.thumbnailHeight - native.iconSize * 1.2) < 1e-9)
        #expect(metrics.thumbnailWidth == metrics.thumbnailHeight)
    }

    @Test("Both switchers draw icons when previews are unavailable")
    @MainActor
    func viewModelsCarryTheCardStyle() {
        var altTab = AltTabOverlayViewModel(entries: [], selectedIndex: 0)
        #expect(altTab.cardStyle == .previews)
        altTab.cardStyle = .icons
        #expect(altTab.metrics(containerSize: CGSize(width: 1600, height: 1000)).cardStyle == .icons)

        var stage = StageOverlayViewModel(spaceManager: SpaceManager(), activeSpaceIndex: 0, selectedWindowIndex: 0)
        #expect(stage.cardStyle == .previews)
        stage.cardStyle = .icons
        #expect(stage.cardStyle == .icons)
    }

    @Test("Icons are drawn without previews, whether the toggle or the permission is missing")
    func cardStyleFollowsCapability() {
        #expect(OverlayCardStyle(previewsAvailable: true) == .previews)
        #expect(OverlayCardStyle(previewsAvailable: false) == .icons)

        var vm = SettingsViewModel()
        vm.screenRecordingGranted = true
        #expect(vm.overlayCardStyle == .previews)
        vm.settings.features.windowPreviews = false
        #expect(vm.overlayCardStyle == .icons)
        vm.settings.features.windowPreviews = true
        vm.screenRecordingGranted = false
        #expect(vm.overlayCardStyle == .icons)
    }

    @Test("One size slider edits whichever size the switcher is drawing")
    func sizeSliderFollowsTheCardStyle() {
        var vm = SettingsViewModel()
        vm.screenRecordingGranted = true
        vm.overlaySize = 1.6
        #expect(vm.settings.stageScale == 1.6)
        #expect(vm.settings.iconScale == 1)

        vm.screenRecordingGranted = false
        #expect(vm.overlaySize == 1)
        vm.overlaySize = 1.25
        #expect(vm.settings.iconScale == 1.25)
        #expect(vm.settings.stageScale == 1.6)
    }

    @Test("Drag drops aim at icon slots when icons are drawn")
    func dragDropPointUsesIconSlots() throws {
        // Twelve windows wrap into more rows as previews than as narrower icon slots, which
        // moves the destination's first row.
        let aspects: [[CGFloat?]] = [[1.6], Array(repeating: 1.6, count: 12)]
        let container = CGSize(width: 1200, height: 900)
        func point(_ style: OverlayCardStyle) -> CGPoint? {
            StageConstants.dragViewDropPoint(
                contentAspects: aspects, stageScale: 1, cardSpacing: 14,
                containerSize: container, reservesDisplayIndicator: false,
                sourceSpaceIndex: 0, sourceWindowIndex: 0, destinationSpaceIndex: 1,
                cardStyle: style
            )
        }
        let previews = try #require(point(.previews))
        let icons = try #require(point(.icons))
        #expect(previews != icons)
    }

    @Test("Native-size icon cards cost no extra raster; larger ones warm one more")
    func iconRastersFollowIconSize() {
        #expect(AppIconCache.overlayIconSizes(iconScale: 1) == [StageMetrics.placeholderIconCanvasSize])
        #expect(AppIconCache.iconSlotRasterSize(iconScale: 1) == StageMetrics.placeholderIconCanvasSize)
        let large = AppIconCache.overlayIconSizes(iconScale: 1.5)
        #expect(large.count == 2)
        #expect(large.max() == StageMetrics.placeholderIconCanvasSize * CGFloat(AppSettings.maximumStageScale))
        #expect(AppIconCache.iconSlotRasterSize(iconScale: 1.5) == large.max())
    }
}
