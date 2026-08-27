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

    @Test("Column capacity comes from the available width and the fixed card width")
    func columnCapacity() {
        #expect(StageWindowLayout.columnCapacity(
            availableWidth: fourColumnWidth,
            metrics: metrics
        ) == 4)
        #expect(StageWindowLayout.columnCapacity(
            availableWidth: fourColumnWidth + metrics.cardWidth + metrics.windowSpacing,
            metrics: metrics
        ) == 5)
        #expect(StageWindowLayout.columnCapacity(
            availableWidth: fourColumnWidth - 1,
            metrics: metrics
        ) == 3)
    }

    @Test("A width too narrow for even one card still lays out one column")
    func minimumOneColumn() {
        #expect(StageWindowLayout.columnCapacity(availableWidth: 0, metrics: metrics) == 1)
        #expect(StageWindowLayout.columnCapacity(availableWidth: -500, metrics: metrics) == 1)

        let single = layout(3, availableWidth: 0)
        #expect(single.rowSizes == [1, 1, 1])
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

    @Test("The standard single-row stage preserves the original vertical profile")
    func standardSingleRowVerticalProfile() {
        let stage = layout(3, availableWidth: fourColumnWidth)

        #expect(stage.stageSize.height == 164)
        #expect(stage.cardOffsetFromCenter(at: 0).height == 7)

        let enlarged = StageWindowLayout(
            windowCount: 3,
            availableWidth: fourColumnWidth * 1.5,
            metrics: metrics.scaled(by: 1.5)
        )
        #expect(enlarged.stageSize.height == stage.stageSize.height * 1.5)
        #expect(enlarged.cardOffsetFromCenter(at: 0).height
            == stage.cardOffsetFromCenter(at: 0).height * 1.5)
    }

    @Test("A larger scale fits fewer cards across the same display")
    func scaleReducesColumnCapacity() {
        let width: CGFloat = 1_200
        let capacities = [1.0, 1.5, 2.0].map { scale in
            StageWindowLayout.columnCapacity(
                availableWidth: width,
                metrics: metrics.scaled(by: CGFloat(scale))
            )
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
