import CoreGraphics
import DockGlass
import Testing
@testable import DebutCore

/// At 100% a stage is the native Command-Tab switcher's plate with previews in its icon slots.
@Suite("Native switcher geometry")
struct NativeSwitcherGeometryTests {
    private let native = DockGlass.Metrics.standard
    /// A 16:10 display gives the standard card its native 102-point slot height.
    private let display = CGSize(width: 1600, height: 1000)

    @Test("A one-row stage at 100% is the native plate around its slots")
    func oneRowStageIsTheNativePlate() {
        let metrics = StageMetrics.shaped(forDisplay: display)
            .withCardSpacing(CGFloat(AppSettings.defaultPreviewCardSpacing))
        #expect(abs(metrics.thumbnailHeight - native.iconSize) < 0.001)

        let layout = StageWindowLayout(windowCount: 3, availableWidth: 10_000, metrics: metrics)
        #expect(abs(layout.stageSize.height - native.plateHeight) < 0.001)

        // Slot edge to plate edge, and slot to slot, as native measures them.
        let slotsWidth = metrics.thumbnailWidth * 3 + native.iconSpacing * 2
        #expect(abs(layout.stageSize.width - (slotsWidth + native.horizontalPadding * 2)) < 0.001)
        let first = layout.cardOffsetFromCenter(at: 0)
        let second = layout.cardOffsetFromCenter(at: 1)
        #expect(abs((second.width - first.width) - (metrics.thumbnailWidth + native.iconSpacing)) < 0.001)
    }

    @Test("The card reserves the native highlight around its preview")
    func cardReservesNativeSelectionPadding() {
        let metrics = StageMetrics.standard
        #expect(metrics.cardPadding == native.selectionPadding)
        #expect(CGFloat(AppSettings.defaultSelectorOutset) == native.selectionPadding)
        #expect(CGFloat(AppSettings.maximumSelectorOutset) == native.selectionPadding)
        // Concentric with the preview's own corner, as native's highlight is with the icon's.
        #expect(abs(
            CGFloat(AppSettings.defaultSelectorCornerRadius)
                - (metrics.thumbnailCornerRadius + native.selectionPadding)
        ) < 0.5)
    }

    @Test("Rows leave the same gap below a title as between neighbouring highlights")
    func rowGapMatchesCardGap() {
        for spacing: CGFloat in [0, 8, 14, 36] {
            let metrics = StageMetrics.standard.withCardSpacing(spacing)
            #expect(metrics.windowSpacing == spacing)
            // A title ends one card padding above its card's lower edge.
            #expect(metrics.rowSpacing + metrics.cardPadding == max(metrics.cardPadding, spacing))
        }
    }

    @Test("Command-Tab and Option-Tab wrap rows with the same spacing")
    @MainActor
    func bothOverlaysShareTheRowRule() {
        var appearance = AppSettings()
        appearance.previewCardSpacing = 20
        let aspects: [CGFloat?] = Array(repeating: 1.6, count: 30)
        let stage = StageConstants.drawnMetrics(
            stageScale: CGFloat(appearance.stageScale),
            contentAspects: [aspects],
            containerSize: display,
            cardSpacing: CGFloat(appearance.previewCardSpacing)
        )
        let altTab = AltTabOverlayViewModel.drawnMetrics(
            appearance: appearance,
            contentAspects: aspects,
            containerSize: display
        )
        #expect(stage == altTab)
    }

    @Test("Native appearance defaults")
    func nativeDefaults() {
        let settings = AppSettings()
        #expect(settings.stageScale == 1.45)
        #expect(CGFloat(settings.stageCornerRadius) == native.plateCornerRadius)
        #expect(CGFloat(settings.previewCardSpacing) == native.iconSpacing - native.selectionPadding * 2)
        #expect(settings.selectionHighlightStrength == 1)
        #expect(settings.dockGlassStyle.selectionStrength == 1)
        #expect(CGFloat(AppSettings.maximumStageCornerRadius) >= native.plateCornerRadius)
    }

    @Test("Titles use the native label size at 100%")
    func titleUsesNativeLabelSize() {
        #expect(StageMetrics.standard.titleFontSize == DockGlass.Label.standardFontSize)
        // Fitted against native Command-Tab label ink on macOS 27 (DockGlass 0.3.0); the
        // earlier 13.5pt bold read larger than native.
        #expect(StageMetrics.standard.titleFontSize == 12.8125)
    }

    @Test("A failed capture's placeholder icon is the native 102-point artwork")
    func placeholderIconIsNativeSize() {
        // The icon canvas carries the artwork's inset; native artwork is 102 points.
        #expect(StageMetrics.placeholderIconCanvasSize == native.iconCanvasSize)
        #expect(StageMetrics.placeholderIconCanvasSize(fittingThumbnailHeight: 300) == native.iconCanvasSize)
        #expect(StageMetrics.placeholderIconCanvasSize(fittingThumbnailHeight: 80) == 80)
        #expect(AppIconCache.placeholderIconRasterSize >= native.iconCanvasSize)
    }
}
