import CoreGraphics
import DockGlass
import Testing
@testable import DebutCore

/// The badge grows with the preview, a failed capture shows a badge-sized icon, and wrapped rows
/// put each title midway between its previews and the next row's (KHA-1060).
@Suite("Badge and wrapped rows")
struct BadgeAndRowTests {
    private let display = CGSize(width: 2560, height: 1600)

    private func drawn(_ scale: CGFloat) -> StageMetrics {
        StageConstants.drawnMetrics(
            stageScale: scale,
            contentAspects: [[nil, nil]],
            containerSize: display,
            cardSpacing: CGFloat(AppSettings.defaultPreviewCardSpacing)
        )
    }

    /// The badge grows gently, with the square root of the preview's size, so a large preview
    /// does not carry an oversized icon.
    @Test("The badge grows gently with the preview, and the preview's corner with the badge")
    func badgeGrowsWithPreview() {
        let native = drawn(1)
        let enlarged = drawn(1.45)
        let growth = CGFloat(1.45).squareRoot()
        #expect(abs(enlarged.badgeSize - native.badgeSize * growth) < 1e-9)
        #expect(abs(drawn(2.5).badgeSize - native.badgeSize * CGFloat(2.5).squareRoot()) < 1e-9)
        #expect(abs(enlarged.badgeOffset - native.badgeOffset * growth) < 1e-9)
        #expect(abs(enlarged.thumbnailCornerRadius - native.thumbnailCornerRadius * growth) < 1e-9)
        // The highlight stays concentric with the preview's grown corner.
        let user = AppSettings().selectorCornerRadius
        #expect(abs(native.selectorCornerRadius(userRadius: user) - CGFloat(user)) < 1e-9)
        #expect(abs(enlarged.selectorCornerRadius(userRadius: user)
            - (CGFloat(user) + native.thumbnailCornerRadius * (growth - 1))) < 1e-9)
        // The chrome around the preview still keeps native points.
        #expect(enlarged.cardPadding == native.cardPadding)
        #expect(enlarged.titleFontSize == native.titleFontSize)
    }

    @Test("A failed capture's icon is the badge's size", arguments: [1.0, 1.45, 2.5])
    func placeholderIconMatchesBadge(scale: Double) {
        let metrics = drawn(CGFloat(scale))
        #expect(metrics.placeholderIconSize == metrics.badgeSize)
    }

    @Test("A wrapped row's title sits midway between its previews and the next row's")
    func wrappedRowsCentreTheirTitles() {
        for scale in [1.0, 1.45, 2.0] as [CGFloat] {
            for spacing in [0.0, 14, 36] as [CGFloat] {
                let metrics = StageMetrics.standard.withCardSpacing(spacing).withPreviewScale(scale)
                let layout = StageWindowLayout(windowCount: 6, availableWidth: 1, metrics: metrics)
                #expect(layout.rowCount == 6)
                let first = layout.cardOffsetFromCenter(at: 0).height
                let second = layout.cardOffsetFromCenter(at: 1).height
                let previewBottom = first - metrics.cardHeight / 2 + metrics.cardPadding + metrics.thumbnailHeight
                let nextPreviewTop = second - metrics.cardHeight / 2 + metrics.cardPadding
                // The same band the last row's title has above the plate's lower edge.
                #expect(abs((nextPreviewTop - previewBottom) - metrics.titleBandHeight) < 1e-9)
                let titleCentre = previewBottom + metrics.titleBandHeight / 2
                #expect(abs((titleCentre - previewBottom) - (nextPreviewTop - titleCentre)) < 1e-9)
            }
        }
    }
}
