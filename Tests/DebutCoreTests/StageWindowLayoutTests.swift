import Testing
import Foundation
@testable import DebutCore

@Suite("StageWindowLayout")
struct StageWindowLayoutTests {

    private let metrics = StageMetrics.standard

    private func layout(_ windowCount: Int, availableWidth: CGFloat) -> StageWindowLayout {
        StageWindowLayout(
            windowCount: windowCount,
            availableWidth: availableWidth,
            metrics: metrics
        )
    }

    /// The width that fits exactly four cards, so the ticket's worked examples have a capacity
    /// to be worked against.
    private var fourColumnWidth: CGFloat {
        metrics.padding * 2
            + metrics.cardWidth * 4
            + metrics.windowSpacing * 3
    }

    /// A row holds as many cards as the width has room for, which is what the available width
    /// buys: one card more and the row breaks a card earlier.
    @Test("A row fills the available width and no further")
    func rowFillsTheAvailableWidth() {
        #expect(layout(4, availableWidth: fourColumnWidth).rowSizes == [4])
        #expect(layout(5, availableWidth: fourColumnWidth).rowSizes == [3, 2])
        #expect(layout(
            5,
            availableWidth: fourColumnWidth + metrics.cardWidth + metrics.windowSpacing
        ).rowSizes == [5])
        #expect(layout(4, availableWidth: fourColumnWidth - 1).rowSizes == [2, 2])
    }

    @Test("A width too narrow for even one card still lays out one column")
    func minimumOneColumn() {
        #expect(layout(3, availableWidth: 0).rowSizes == [1, 1, 1])
        #expect(layout(3, availableWidth: -500).rowSizes == [1, 1, 1])
    }

    @Test("Rows are balanced rather than greedily filled")
    func balancedRows() {
        #expect(layout(5, availableWidth: fourColumnWidth).rowSizes == [3, 2])
        #expect(layout(9, availableWidth: fourColumnWidth).rowSizes == [3, 3, 3])
        #expect(layout(10, availableWidth: fourColumnWidth).rowSizes == [4, 3, 3])
    }

    @Test("Row sizes never differ by more than one, and earlier rows take the remainder")
    func rowSizesDifferByAtMostOne() {
        for windowCount in 0...40 {
            let rows = layout(windowCount, availableWidth: fourColumnWidth).rowSizes
            #expect(rows.reduce(0, +) == windowCount)
            #expect(rows.allSatisfy { $0 <= 4 })
            if let smallest = rows.min(), let largest = rows.max() {
                #expect(largest - smallest <= 1)
            }
            #expect(rows == rows.sorted(by: >))
        }
    }

    @Test("Windows that fit across the display stay on a single row")
    func singleRowWhenItFits() {
        #expect(layout(4, availableWidth: fourColumnWidth).rowSizes == [4])
        #expect(layout(1, availableWidth: fourColumnWidth).rowSizes == [1])
        #expect(layout(0, availableWidth: fourColumnWidth).rowSizes == [])
    }

    @Test("Stage width follows the widest row and stage height follows the row count")
    func stageSize() {
        let oneRow = layout(3, availableWidth: fourColumnWidth)
        #expect(oneRow.stageSize.width
            == metrics.cardWidth * 3 + metrics.windowSpacing * 2 + metrics.padding * 2)
        #expect(oneRow.stageSize.height
            == metrics.cardHeight + metrics.topPadding + metrics.bottomPadding)

        let twoRows = layout(5, availableWidth: fourColumnWidth)
        #expect(twoRows.stageSize.width
            == metrics.cardWidth * 3 + metrics.windowSpacing * 2 + metrics.padding * 2)
        #expect(twoRows.stageSize.height
            == metrics.cardHeight * 2 + metrics.rowSpacing
                + metrics.topPadding + metrics.bottomPadding)
    }

    @Test("An empty stage keeps a placeholder width and one row of height")
    func emptyStageSize() {
        let empty = layout(0, availableWidth: fourColumnWidth)
        #expect(empty.stageSize.width == metrics.minStageWidth)
        #expect(empty.stageSize.height
            == metrics.cardHeight + metrics.topPadding + metrics.bottomPadding)
    }

    @Test("Model order maps left to right, then top to bottom")
    func rowMajorOrder() {
        let wrapped = layout(5, availableWidth: fourColumnWidth)

        #expect(wrapped.slot(at: 0) == StageGridSlot(row: 0, column: 0))
        #expect(wrapped.slot(at: 2) == StageGridSlot(row: 0, column: 2))
        #expect(wrapped.slot(at: 3) == StageGridSlot(row: 1, column: 0))
        #expect(wrapped.slot(at: 4) == StageGridSlot(row: 1, column: 1))
        #expect(wrapped.slot(at: 5) == nil)
    }

    @Test("Every row is horizontally centered, including a shorter last row")
    func rowsAreCentered() {
        let wrapped = layout(5, availableWidth: fourColumnWidth)

        let firstRow = (0..<3).map { wrapped.cardOffsetFromCenter(at: $0).width }
        let lastRow = (3..<5).map { wrapped.cardOffsetFromCenter(at: $0).width }

        #expect(firstRow.reduce(0, +) == 0)
        #expect(lastRow.reduce(0, +) == 0)

        let stride = metrics.cardWidth + metrics.windowSpacing
        #expect(firstRow == [-stride, 0, stride])
        #expect(lastRow == [-stride / 2, stride / 2])
    }

    @Test("Rows stack downward by a whole card height")
    func rowsStackVertically() {
        let wrapped = layout(5, availableWidth: fourColumnWidth)
        let rowStride = metrics.cardHeight + metrics.rowSpacing
        let opticalOffset = (metrics.topPadding - metrics.bottomPadding) / 2

        #expect(wrapped.cardOffsetFromCenter(at: 0).height
            == -rowStride / 2 + opticalOffset)
        #expect(wrapped.cardOffsetFromCenter(at: 4).height
            == rowStride / 2 + opticalOffset)

        let threeRows = layout(9, availableWidth: fourColumnWidth)
        #expect(threeRows.cardOffsetFromCenter(at: 0).height == -rowStride + opticalOffset)
        #expect(threeRows.cardOffsetFromCenter(at: 4).height == opticalOffset)
        #expect(threeRows.cardOffsetFromCenter(at: 8).height == rowStride + opticalOffset)
    }

    @Test("A wrapped stage never grows past the width it was laid out for")
    func stageStaysWithinAvailableWidth() {
        for windowCount in 1...40 {
            let wrapped = layout(windowCount, availableWidth: fourColumnWidth)
            #expect(wrapped.stageSize.width <= fourColumnWidth)
        }
    }

    @Test("Insertion slots cover every position including one past the end")
    func insertionSlots() {
        let wrapped = layout(5, availableWidth: fourColumnWidth)
        // An insertion at the end resolves against the layout the stage will have once the
        // window arrives, so the layout itself only has to answer for its own cards.
        #expect(wrapped.slot(at: 4) != nil)

        let grown = layout(6, availableWidth: fourColumnWidth)
        #expect(grown.rowSizes == [3, 3])
        #expect(grown.slot(at: 5) == StageGridSlot(row: 1, column: 2))
    }

    @Test("Scaling multiplies every dimension, so a card keeps its proportions")
    func scaledMetrics() {
        let scaled = metrics.scaled(by: 1.5)

        #expect(scaled.thumbnailWidth == metrics.thumbnailWidth * 1.5)
        #expect(scaled.thumbnailHeight == metrics.thumbnailHeight * 1.5)
        #expect(scaled.badgeSize == metrics.badgeSize * 1.5)
        #expect(scaled.previewPlaceholderIconSize == metrics.previewPlaceholderIconSize * 1.5)
        #expect(scaled.windowSpacing == metrics.windowSpacing * 1.5)
        #expect(scaled.rowSpacing == metrics.rowSpacing * 1.5)
        #expect(scaled.padding == metrics.padding * 1.5)
        #expect(scaled.minStageWidth == metrics.minStageWidth * 1.5)

        #expect(scaled.cardWidth == metrics.cardWidth * 1.5)
        #expect(scaled.cardHeight == metrics.cardHeight * 1.5)
        #expect(scaled.titleFontSize == metrics.titleFontSize * 1.5)
        #expect(scaled.thumbnailCornerRadius == metrics.thumbnailCornerRadius * 1.5)
        #expect(metrics.scaled(by: 1) == metrics)
    }

    @Test("The standard stage stays compact while its cards make selector clearance")
    func standardSingleRowVerticalProfile() {
        let stage = layout(3, availableWidth: fourColumnWidth)

        #expect(stage.stageSize.height == 164)
        #expect(stage.cardOffsetFromCenter(at: 0).height == 10)

        let enlarged = StageWindowLayout(
            windowCount: 3,
            availableWidth: fourColumnWidth * 1.5,
            metrics: metrics.scaled(by: 1.5)
        )
        #expect(enlarged.stageSize.height == stage.stageSize.height * 1.5)
        #expect(enlarged.cardOffsetFromCenter(at: 0).height
            == stage.cardOffsetFromCenter(at: 0).height * 1.5)
    }

    @Test("The title sits midway between the preview and the stage edge")
    func titleUsesSelectorClearance() {
        let previewBottom = metrics.topPadding
            + metrics.cardPadding
            + metrics.thumbnailHeight
        let titleCenter = previewBottom
            + metrics.titleSpacing
            + metrics.titleHeight / 2
        let stageBottom = layout(1, availableWidth: fourColumnWidth).stageSize.height

        #expect(titleCenter == (previewBottom + stageBottom) / 2)
        #expect(metrics.titleSpacing > 4)
        #expect(CGFloat(AppSettings.maximumSelectorOutset) <= metrics.cardPadding)
    }

    @Test("A larger scale fits fewer cards across the same display")
    func scaleReducesColumnCapacity() {
        let capacities = [1.0, 1.5, 2.0].map { scale in
            StageWindowLayout(
                windowCount: 12,
                availableWidth: 1_200,
                metrics: metrics.scaled(by: CGFloat(scale))
            ).rowSizes[0]
        }

        #expect(capacities == capacities.sorted(by: >))
        #expect(capacities.first! > capacities.last!)
    }

    @Test("Stage height never shrinks as the scale grows, which is what makes the fit searchable")
    func stageHeightIsMonotoneInScale() {
        // Scale, capacity and row count are circular: a bigger card fits fewer per row, which
        // adds rows, which adds height. The fitted scale is found by walking candidates down,
        // and that only finds the largest fitting scale if height never dips on the way up.
        for windowCount in [1, 5, 8, 17, 30] {
            let heights = stride(from: 0.5, through: 2.5, by: 0.05).map { scale in
                StageWindowLayout(
                    windowCount: windowCount,
                    availableWidth: 1_400,
                    metrics: metrics.scaled(by: CGFloat(scale))
                ).stageSize.height
            }
            #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 },
                    "height dipped as scale grew for \(windowCount) windows")
        }
    }
}

@Suite("Display-shaped stage metrics")
struct DisplayShapedMetricsTests {

    private let standardArea = StageMetrics.standard.thumbnailWidth
        * StageMetrics.standard.thumbnailHeight

    private func shaped(_ width: CGFloat, _ height: CGFloat) -> StageMetrics {
        StageMetrics.shaped(forDisplay: CGSize(width: width, height: height))
    }

    @Test("A card takes the shape of the display it is drawn on")
    func cardMatchesDisplayAspect() {
        for display in [
            CGSize(width: 1_920, height: 1_080),
            CGSize(width: 3_440, height: 1_440),
            CGSize(width: 1_080, height: 1_920),
            CGSize(width: 1_512, height: 982),
        ] {
            let metrics = StageMetrics.shaped(forDisplay: display)
            let displayAspect = display.width / display.height
            let cardAspect = metrics.thumbnailWidth / metrics.thumbnailHeight
            #expect(abs(cardAspect - displayAspect) < 0.0001,
                    "\(display) drew a \(cardAspect) card")
        }
    }

    @Test("Reshaping preserves card area, so a portrait display does not inflate the card")
    func areaIsPreservedAcrossAspects() {
        for display in [
            CGSize(width: 1_920, height: 1_080),
            CGSize(width: 3_440, height: 1_440),
            CGSize(width: 1_080, height: 1_920),
            CGSize(width: 1_000, height: 1_000),
        ] {
            let metrics = StageMetrics.shaped(forDisplay: display)
            let area = metrics.thumbnailWidth * metrics.thumbnailHeight
            #expect(abs(area - standardArea) < 0.5, "\(display) drew a \(area)pt card")
        }
    }

    @Test("A 16:10 display reproduces the standard card exactly")
    func sixteenTenIsUnchanged() {
        let metrics = shaped(1_680, 1_050)
        #expect(abs(metrics.thumbnailWidth - StageMetrics.standard.thumbnailWidth) < 0.0001)
        #expect(abs(metrics.thumbnailHeight - StageMetrics.standard.thumbnailHeight) < 0.0001)
    }

    @Test("A portrait display makes a taller card than a landscape one")
    func portraitIsTallerThanLandscape() {
        let portrait = shaped(1_080, 1_920)
        let landscape = shaped(1_920, 1_080)

        #expect(portrait.thumbnailHeight > portrait.thumbnailWidth)
        #expect(landscape.thumbnailWidth > landscape.thumbnailHeight)
        #expect(portrait.thumbnailHeight > landscape.thumbnailHeight)
        #expect(portrait.thumbnailWidth < landscape.thumbnailWidth)
    }

    /// A container arrives as `.zero` on SwiftUI's first layout pass, and an aspect cannot be
    /// taken from it. The standard card is the honest answer until a real size arrives.
    @Test("A display with no area falls back to the standard card")
    func degenerateDisplayFallsBack() {
        #expect(shaped(0, 0) == StageMetrics.standard)
        #expect(shaped(1_920, 0) == StageMetrics.standard)
        #expect(shaped(-100, 500) == StageMetrics.standard)
    }

    @Test("Scale is what these metrics report, not a width the aspect also moved")
    func scaleFactorIsIndependentOfAspect() {
        #expect(StageMetrics.standard.scaleFactor == 1)

        for display in [CGSize(width: 3_440, height: 1_440), CGSize(width: 1_080, height: 1_920)] {
            let metrics = StageMetrics.shaped(forDisplay: display)
            #expect(metrics.scaleFactor == 1)
            #expect(metrics.scaled(by: 1.5).scaleFactor == 1.5)
        }
    }

    /// A portrait card is under 160pt wide and an ultrawide card is over it, so a font taken
    /// from the thumbnail width would shrink and swell with the monitor rather than the slider.
    @Test("Title size follows the scale, not the display's shape")
    func titleSizeFollowsScaleOnly() {
        let ultrawide = shaped(3_440, 1_440)
        let portrait = shaped(1_080, 1_920)

        #expect(ultrawide.titleFontSize == StageMetrics.standard.titleFontSize)
        #expect(portrait.titleFontSize == StageMetrics.standard.titleFontSize)
        #expect(ultrawide.scaled(by: 1.5).titleFontSize
            == StageMetrics.standard.scaled(by: 1.5).titleFontSize)
    }

    @Test("Scaling a reshaped card keeps its shape")
    func scalingPreservesShape() {
        let portrait = shaped(1_080, 1_920)
        let enlarged = portrait.scaled(by: 1.5)

        #expect(abs(enlarged.thumbnailWidth / enlarged.thumbnailHeight
            - portrait.thumbnailWidth / portrait.thumbnailHeight) < 0.0001)
        #expect(enlarged.thumbnailWidth == portrait.thumbnailWidth * 1.5)
    }

    @Test("The metrics the overlay draws at are shaped by the display it draws on")
    func drawnMetricsFollowTheContainer() {
        let portrait = StageConstants.drawnMetrics(
            stageScale: 1,
            windowCounts: [3],
            containerSize: CGSize(width: 1_080, height: 1_920)
        )
        #expect(portrait.thumbnailHeight > portrait.thumbnailWidth)

        let widescreen = StageConstants.drawnMetrics(
            stageScale: 1,
            windowCounts: [3],
            containerSize: CGSize(width: 1_920, height: 1_080)
        )
        #expect(abs(widescreen.thumbnailWidth / widescreen.thumbnailHeight - 16.0 / 9.0) < 0.0001)
    }
}

@Suite("Fitted stage scale")
struct FittedStageScaleTests {

    private let roomyDisplay = CGSize(width: 2_560, height: 1_440)

    private func fitted(_ requested: Double, windowCounts: [Int], display: CGSize) -> CGFloat {
        StageConstants.fittedStageScale(
            requested: CGFloat(requested),
            windowCounts: windowCounts,
            containerSize: display
        )
    }

    @Test("A stack that already fits keeps the scale it asked for")
    func requestedScaleSurvivesWhenItFits() {
        #expect(fitted(1.5, windowCounts: [3, 5], display: roomyDisplay) == 1.5)
        #expect(fitted(1.0, windowCounts: [3, 5], display: roomyDisplay) == 1.0)
    }

    @Test("The requested scale is clamped to the range the slider offers")
    func requestedScaleIsClamped() {
        #expect(fitted(9, windowCounts: [1], display: roomyDisplay)
            == CGFloat(AppSettings.maximumStageScale))
        #expect(fitted(0.01, windowCounts: [1], display: roomyDisplay)
            == CGFloat(AppSettings.minimumStageScale))
    }

    @Test("A stage too tall for the display scales down until it fits")
    func tallStageScalesDown() {
        let display = CGSize(width: 1_440, height: 900)
        let scale = fitted(1.5, windowCounts: [24], display: display)

        #expect(scale < 1.5)
        #expect(scale >= CGFloat(AppSettings.minimumStageScale))

        let fittedHeight = StageConstants.stageLayouts(
            forWindowCounts: [24],
            screenWidth: display.width,
            metrics: StageMetrics.standard.scaled(by: scale)
        )[0].stageSize.height
        #expect(fittedHeight <= StageConstants.availableStageHeight(screenHeight: display.height))
    }

    @Test("The tallest stage sets the scale for the whole stack")
    func tallestStageBinds() {
        let display = CGSize(width: 1_440, height: 900)
        let alone = fitted(1.5, windowCounts: [24], display: display)
        let inStack = fitted(1.5, windowCounts: [1, 24, 2], display: display)

        #expect(inStack == alone)
    }

    @Test("A display too small at every scale still returns a usable scale")
    func impossibleFitFallsBackToTheFloor() {
        let scale = fitted(1.5, windowCounts: [200], display: CGSize(width: 600, height: 400))
        #expect(scale == CGFloat(AppSettings.minimumStageScale))
    }

    @Test("Fitting never leaves a stage wider than the display")
    func fittedStagesStayWithinWidth() {
        for display in [CGSize(width: 1_280, height: 800), CGSize(width: 3_840, height: 2_160)] {
            for count in [1, 4, 9, 18] {
                let scale = fitted(2.5, windowCounts: [count], display: display)
                let width = StageConstants.stageLayouts(
                    forWindowCounts: [count],
                    screenWidth: display.width,
                    metrics: StageMetrics.standard.scaled(by: scale)
                )[0].stageSize.width
                #expect(width <= StageConstants.availableStageWidth(screenWidth: display.width)
                    || scale == CGFloat(AppSettings.minimumStageScale))
            }
        }
    }

    @Test("Fitted scales land on the slider's own steps")
    func fittedScaleStaysOnTheSliderGrid() {
        let display = CGSize(width: 1_440, height: 900)
        for count in 1...30 {
            let scale = fitted(2.5, windowCounts: [count], display: display)
            let steps = (scale - CGFloat(AppSettings.minimumStageScale))
                / CGFloat(AppSettings.stageScaleStep)
            #expect(abs(steps - steps.rounded()) < 0.0001, "\(scale) is off the step grid")
        }
    }
}

@Suite("Adaptive card sizing")
struct AdaptiveCardSizingTests {

    /// A 16:10 display, so its shaped metrics are the standard card exactly and every width
    /// below can be read against `StageMetrics.standard`.
    private let metrics = StageMetrics.shaped(forDisplay: CGSize(width: 1_680, height: 1_050))

    private func layout(
        _ aspects: [CGFloat?],
        availableWidth: CGFloat
    ) -> StageWindowLayout {
        StageWindowLayout(
            contentAspects: aspects,
            availableWidth: availableWidth,
            metrics: metrics
        )
    }

    private var displayAspect: CGFloat { metrics.thumbnailWidth / metrics.thumbnailHeight }

    private var fourColumnWidth: CGFloat {
        metrics.padding * 2 + metrics.cardWidth * 4 + metrics.windowSpacing * 3
    }

    @Test("A card takes its own window's shape, at the row's fixed height")
    func cardFollowsItsOwnWindow() {
        let narrow = metrics.adapted(toContentAspect: 1.2)
        #expect(narrow.thumbnailHeight == metrics.thumbnailHeight)
        #expect(narrow.thumbnailWidth == metrics.thumbnailHeight * 1.2)
        #expect(narrow.thumbnailWidth < metrics.thumbnailWidth)

        let wide = metrics.adapted(toContentAspect: 2)
        #expect(wide.thumbnailHeight == metrics.thumbnailHeight)
        #expect(wide.thumbnailWidth == metrics.thumbnailHeight * 2)
        #expect(wide.thumbnailWidth > metrics.thumbnailWidth)
    }

    @Test("A window shaped like the display draws the card the display already asked for")
    func displayShapedWindowIsUnchanged() {
        #expect(metrics.adapted(toContentAspect: displayAspect) == metrics)
    }

    /// Nothing announces a window's size before it has been discovered, and a card with no
    /// answer must still be drawn.
    @Test("An unknown shape falls back to the display's own")
    func unknownAspectFallsBack() {
        #expect(metrics.adapted(toContentAspect: nil) == metrics)
        #expect(metrics.adapted(toContentAspect: 0) == metrics)
        #expect(metrics.adapted(toContentAspect: -2) == metrics)
    }

    /// One very tall window would otherwise set the height of every row it appears in, and one
    /// very wide one would push its whole row off the display.
    @Test("Card width is clamped to a band around the display's own card")
    func widthIsClamped() {
        let sliver = metrics.adapted(toContentAspect: 0.05)
        let banner = metrics.adapted(toContentAspect: 40)

        #expect(sliver.thumbnailWidth
            == metrics.thumbnailWidth * StageMetrics.minimumAdaptiveWidthRatio)
        #expect(banner.thumbnailWidth
            == metrics.thumbnailWidth * StageMetrics.maximumAdaptiveWidthRatio)
    }

    @Test("Narrow cards leave room for more of them on a row")
    func narrowCardsPackTighter() {
        let uniform = layout(Array(repeating: nil, count: 5), availableWidth: fourColumnWidth)
        let narrow = layout(Array(repeating: 1.0, count: 5), availableWidth: fourColumnWidth)

        #expect(uniform.rowSizes == [3, 2])
        #expect(narrow.rowSizes == [5])
        #expect(narrow.stageSize.height < uniform.stageSize.height)
    }

    @Test("A stage of adaptive cards still never grows past the width it was laid out for")
    func adaptiveStagesStayWithinAvailableWidth() {
        var generator = SystemRandomNumberGenerator()
        for windowCount in 1...30 {
            let aspects: [CGFloat?] = (0..<windowCount).map { _ in
                CGFloat.random(in: 0.2...4, using: &generator)
            }
            let stage = layout(aspects, availableWidth: fourColumnWidth)
            #expect(stage.rowSizes.reduce(0, +) == windowCount)
            #expect(stage.stageSize.width <= fourColumnWidth)
        }
    }

    /// The rows are chosen by the width they take, so a stage of mixed shapes does not split
    /// evenly by count into a row that then overflows.
    @Test("Rows balance by width, not by card count")
    func rowsBalanceByWidth() {
        // Three cards at the widest the clamp allows, then three at the narrowest. Splitting
        // three and three would overflow the first row; splitting by width does not.
        let aspects: [CGFloat?] = [2.56, 2.56, 2.56, 0.5, 0.5, 0.5]
        let stage = layout(aspects, availableWidth: fourColumnWidth)
        let contentWidth = fourColumnWidth - metrics.padding * 2

        #expect(stage.rowSizes == [2, 4])
        for row in 0..<stage.rowCount {
            #expect(stage.rowWidth(row) <= contentWidth)
        }
    }

    @Test("Cards sit at their row's running width, and every row stays centered")
    func offsetsArePrefixSums() {
        let aspects: [CGFloat?] = [0.5, 2.0, 1.0]
        let stage = layout(aspects, availableWidth: fourColumnWidth * 2)

        #expect(stage.rowSizes == [3])
        let offsets = (0..<3).map { stage.cardOffsetFromCenter(at: $0).width }
        let widths = (0..<3).map { stage.cardWidth(at: $0) }

        let rowWidth = widths.reduce(0, +) + metrics.windowSpacing * 2
        var edge = -rowWidth / 2
        for index in 0..<3 {
            #expect(abs(offsets[index] - (edge + widths[index] / 2)) < 0.0001)
            edge += widths[index] + metrics.windowSpacing
        }
    }

    @Test("The stage is as wide as its widest row")
    func stageWidthFollowsWidestRow() {
        let aspects: [CGFloat?] = [1.6, 1.6, 1.6, 0.5]
        let stage = layout(aspects, availableWidth: fourColumnWidth)
        let widest = (0..<stage.rowCount).map { stage.rowWidth($0) }.max() ?? 0

        #expect(stage.contentWidth == widest)
    }

    /// The per-card metrics the renderer draws with have to be the ones the grid measured, or
    /// a card is drawn at a width its own slot was never sized for.
    @Test("The metrics a card is drawn with are the ones its slot was measured at")
    func cardMetricsMatchTheGrid() {
        let aspects: [CGFloat?] = [0.5, 2.0, nil]
        let stage = layout(aspects, availableWidth: fourColumnWidth * 2)

        for index in 0..<3 {
            #expect(stage.cardMetrics(at: index).cardWidth == stage.cardWidth(at: index))
        }
        #expect(stage.cardMetrics(at: 2).thumbnailWidth == metrics.thumbnailWidth)
    }

    /// Every existing stage is a stage of display-shaped cards, so the adaptive grid has to
    /// reproduce the uniform one exactly rather than merely approximate it.
    @Test("Uniform shapes reproduce the fixed-width grid exactly")
    func uniformShapesMatchTheFixedGrid() {
        for windowCount in 0...40 {
            let fixed = StageWindowLayout(
                windowCount: windowCount,
                availableWidth: fourColumnWidth,
                metrics: metrics
            )
            let adaptive = layout(
                Array(repeating: displayAspect, count: windowCount),
                availableWidth: fourColumnWidth
            )

            #expect(fixed.rowSizes == adaptive.rowSizes)
            #expect(fixed.stageSize == adaptive.stageSize)
            for index in 0..<windowCount {
                #expect(fixed.cardOffsetFromCenter(at: index)
                    == adaptive.cardOffsetFromCenter(at: index))
            }
        }
    }

    /// A card wider than the stage can hold has nowhere else to go, and dropping it or wrapping
    /// it into an empty row would lose it.
    @Test("A card too wide for the stage still gets a row of its own")
    func oversizedCardKeepsItsRow() {
        let narrowStage = metrics.padding * 2 + metrics.cardWidth / 2
        let stage = layout([2.0, 2.0], availableWidth: narrowStage)

        #expect(stage.rowSizes == [1, 1])
    }
}
