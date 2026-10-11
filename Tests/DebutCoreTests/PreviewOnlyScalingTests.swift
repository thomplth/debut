import CoreGraphics
import DockGlass
import Testing
@testable import DebutCore

/// The size setting enlarges only the preview (or icon). Everything around it keeps the native
/// switcher's point sizes (KHA-1059).
@Suite("Preview-only scaling")
struct PreviewOnlyScalingTests {
    private let display = CGSize(width: 2560, height: 1600)

    private func drawn(_ scale: CGFloat, style: OverlayCardStyle = .previews) -> StageMetrics {
        StageConstants.drawnMetrics(
            stageScale: scale,
            contentAspects: [[nil, nil]],
            containerSize: display,
            cardSpacing: CGFloat(AppSettings.defaultPreviewCardSpacing),
            cardStyle: style
        )
    }

    @Test("Only the preview grows with the size setting", arguments: [OverlayCardStyle.previews, .icons])
    func onlyThePreviewGrows(style: OverlayCardStyle) {
        let native = drawn(1, style: style)
        let enlarged = drawn(2, style: style)

        #expect(abs(enlarged.thumbnailWidth - native.thumbnailWidth * 2) < 1e-9)
        #expect(abs(enlarged.thumbnailHeight - native.thumbnailHeight * 2) < 1e-9)
        #expect(abs(enlarged.previewScale - 2) < 1e-9)

        // The chrome stays at native point sizes.
        #expect(enlarged.scaleFactor == 1)
        #expect(enlarged.cardPadding == native.cardPadding)
        #expect(enlarged.padding == native.padding)
        #expect(enlarged.topPadding == native.topPadding)
        #expect(enlarged.bottomPadding == native.bottomPadding)
        #expect(enlarged.windowSpacing == native.windowSpacing)
        #expect(enlarged.rowSpacing == native.rowSpacing)
        #expect(enlarged.titleSpacing == native.titleSpacing)
        #expect(enlarged.titleHeight == native.titleHeight)
        #expect(enlarged.titleBandHeight == native.titleBandHeight)
        #expect(enlarged.titleFontSize == DockGlass.Label.standardFontSize)
        #expect(enlarged.minStageWidth == native.minStageWidth)
    }

    @Test("A one-row plate grows by exactly the preview's extra height")
    func plateGrowsByPreviewOnly() {
        let native = DockGlass.Metrics.standard
        let metrics = drawn(1.45)
        let layout = StageWindowLayout(windowCount: 1, availableWidth: 10_000, metrics: metrics)
        #expect(abs(layout.stageSize.height
            - (native.plateHeight - native.iconSize + metrics.thumbnailHeight)) < 1e-9)
    }

    @Test("An icon's corner and highlight follow the icon")
    func iconCornersFollowTheIcon() {
        let settings = AppSettings()
        let native = DockGlass.Metrics.standard
        let icons = drawn(2, style: .icons)
        let iconCorner = native.selectionCornerRadius - native.selectionPadding
        #expect(abs(icons.thumbnailCornerRadius - iconCorner * 2) < 1e-9)
        // Concentric: the icon's own corner plus the fixed highlight padding.
        #expect(abs(icons.selectorCornerRadius(userRadius: settings.previewCornerRadius, outset: settings.selectorOutset)
            - (iconCorner * 2 + CGFloat(settings.selectorOutset))) < 1e-9)
    }

    @Test("The drag view still zooms a stage uniformly")
    func dragZoomStaysUniform() {
        let metrics = drawn(1.45)
        let zoomed = metrics.scaled(by: 0.5)
        #expect(zoomed.scaleFactor == 0.5)
        #expect(abs(zoomed.thumbnailWidth - metrics.thumbnailWidth / 2) < 1e-9)
        #expect(zoomed.cardPadding == metrics.cardPadding / 2)
        #expect(zoomed.padding == metrics.padding / 2)
        #expect(zoomed.titleFontSize == metrics.titleFontSize / 2)
        let layout = StageWindowLayout(windowCount: 3, availableWidth: 10_000, metrics: metrics)
        let zoomedLayout = StageWindowLayout(windowCount: 3, availableWidth: 10_000, metrics: zoomed)
        #expect(abs(zoomedLayout.stageSize.width - layout.stageSize.width / 2) < 1e-9)
        #expect(abs(zoomedLayout.stageSize.height - layout.stageSize.height / 2) < 1e-9)
    }

    @Test("Automatic fitting shrinks previews, not the chrome")
    func fittingShrinksPreviewsOnly() {
        let crowded: [[CGFloat?]] = [Array(repeating: nil, count: 60)]
        let metrics = StageConstants.drawnMetrics(
            stageScale: 1.45,
            contentAspects: crowded,
            containerSize: CGSize(width: 1440, height: 900),
            cardSpacing: CGFloat(AppSettings.defaultPreviewCardSpacing)
        )
        #expect(metrics.previewScale < 1.45)
        #expect(metrics.scaleFactor == 1)
        #expect(metrics.cardPadding == StageMetrics.standard.cardPadding)
    }
}
