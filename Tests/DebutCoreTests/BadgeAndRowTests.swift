import CoreGraphics
import Foundation
import DockGlass
import Testing
@testable import DebutCore

/// The badge grows with the preview, a failed capture shows a badge-sized icon, and wrapped rows
/// put each title midway between its previews and the next row's (KHA-1060).
@Suite("Badge and wrapped rows")
struct BadgeAndRowTests {
    private let display = CGSize(width: 2560, height: 1600)

    private func drawn(_ scale: CGFloat, badgeGrowth: Double = AppSettings.defaultBadgeGrowth) -> StageMetrics {
        StageConstants.drawnMetrics(
            stageScale: scale,
            contentAspects: [[nil, nil]],
            containerSize: display,
            cardSpacing: CGFloat(AppSettings.defaultPreviewCardSpacing),
            badgeGrowth: CGFloat(badgeGrowth)
        )
    }

    /// The badge grows with the preview on an adjustable curve: the preview's size raised to
    /// the badge growth setting (KHA-1062). 0 keeps it at native size, 1 grows it in proportion.
    @Test("The badge grows on the configured curve",
          arguments: [0.0, 0.5, 0.8, 1.0])
    func badgeGrowsOnTheConfiguredCurve(growth: Double) {
        let native = drawn(1, badgeGrowth: growth)
        let enlarged = drawn(1.45, badgeGrowth: growth)
        let factor = pow(CGFloat(1.45), CGFloat(growth))
        #expect(abs(native.badgeSize - StageMetrics.standard.badgeSize) < 1e-9)
        #expect(abs(enlarged.badgeSize - native.badgeSize * factor) < 1e-9)
        // The preview corner is a setting in points (KHA-1064); it no longer follows the badge.
        let user = AppSettings().previewCornerRadius
        #expect(enlarged.previewCornerRadius(userRadius: user) == CGFloat(user))
        #expect(enlarged.cardPadding == native.cardPadding)
        #expect(enlarged.titleFontSize == native.titleFontSize)
    }

    @Test("The default curve is 0.5")
    func defaultBadgeGrowth() {
        #expect(AppSettings().badgeGrowth == 0.5)
        #expect(abs(drawn(1.5).badgeSize - 40 * pow(1.5, 0.5)) < 1e-9)
    }

    /// Mission Control's placement: centred, just inside the preview's lower edge, so it never
    /// meets the title below (KHA-1062).
    @Test("The badge sits at the bottom centre, inside the preview's edge", arguments: [1.0, 1.45, 2.5])
    func badgeSitsBottomCentre(scale: Double) {
        let metrics = drawn(CGFloat(scale))
        #expect(abs(metrics.drawnBadgeSize - metrics.badgeSize * 1.15) < 1e-9)
        let centre = metrics.badgeCentre(in: metrics.previewImageRect(forImageAspect: nil))
        #expect(abs(centre.x - metrics.thumbnailWidth / 2) < 1e-9)
        #expect(abs(centre.y + metrics.drawnBadgeSize / 2 - (metrics.thumbnailHeight - 6)) < 1e-9)
    }

    @Test("A failed capture's icon is the badge's size", arguments: [1.0, 1.45, 2.5])
    func placeholderIconMatchesBadge(scale: Double) {
        let metrics = drawn(CGFloat(scale))
        #expect(metrics.placeholderIconSize == metrics.drawnBadgeSize)
    }

    @Test("The narrowest card still holds the centred badge")
    func narrowestCardHoldsBadge() {
        for growth in [0.0, 0.8, 1.0] {
            let metrics = drawn(2.5, badgeGrowth: growth)
            let narrow = metrics.adapted(toContentAspect: 0.05)
            #expect(narrow.thumbnailWidth >= metrics.drawnBadgeSize + 12)
        }
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
