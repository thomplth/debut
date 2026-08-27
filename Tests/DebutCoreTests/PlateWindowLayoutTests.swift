import Testing
import Foundation
@testable import DebutCore

@Suite("PlateWindowLayout")
struct PlateWindowLayoutTests {

    private let metrics = PlateMetrics.standard

    private func layout(_ windowCount: Int, availableWidth: CGFloat) -> PlateWindowLayout {
        PlateWindowLayout(
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
        #expect(PlateWindowLayout.columnCapacity(
            availableWidth: fourColumnWidth,
            metrics: metrics
        ) == 4)
        #expect(PlateWindowLayout.columnCapacity(
            availableWidth: fourColumnWidth + metrics.cardWidth + metrics.windowSpacing,
            metrics: metrics
        ) == 5)
        #expect(PlateWindowLayout.columnCapacity(
            availableWidth: fourColumnWidth - 1,
            metrics: metrics
        ) == 3)
    }

    @Test("A width too narrow for even one card still lays out one column")
    func minimumOneColumn() {
        #expect(PlateWindowLayout.columnCapacity(availableWidth: 0, metrics: metrics) == 1)
        #expect(PlateWindowLayout.columnCapacity(availableWidth: -500, metrics: metrics) == 1)

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

    @Test("Plate width follows the widest row and plate height follows the row count")
    func plateSize() {
        let oneRow = layout(3, availableWidth: fourColumnWidth)
        #expect(oneRow.plateSize.width
            == metrics.cardWidth * 3 + metrics.windowSpacing * 2 + metrics.padding * 2)
        #expect(oneRow.plateSize.height
            == metrics.cardHeight + metrics.topPadding + metrics.bottomPadding)

        let twoRows = layout(5, availableWidth: fourColumnWidth)
        #expect(twoRows.plateSize.width
            == metrics.cardWidth * 3 + metrics.windowSpacing * 2 + metrics.padding * 2)
        #expect(twoRows.plateSize.height
            == metrics.cardHeight * 2 + metrics.rowSpacing
                + metrics.topPadding + metrics.bottomPadding)
    }

    @Test("An empty plate keeps a placeholder width and one row of height")
    func emptyPlateSize() {
        let empty = layout(0, availableWidth: fourColumnWidth)
        #expect(empty.plateSize.width == metrics.minPlateWidth)
        #expect(empty.plateSize.height
            == metrics.cardHeight + metrics.topPadding + metrics.bottomPadding)
    }

    @Test("Model order maps left to right, then top to bottom")
    func rowMajorOrder() {
        let wrapped = layout(5, availableWidth: fourColumnWidth)

        #expect(wrapped.slot(at: 0) == PlateGridSlot(row: 0, column: 0))
        #expect(wrapped.slot(at: 2) == PlateGridSlot(row: 0, column: 2))
        #expect(wrapped.slot(at: 3) == PlateGridSlot(row: 1, column: 0))
        #expect(wrapped.slot(at: 4) == PlateGridSlot(row: 1, column: 1))
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

        #expect(wrapped.cardOffsetFromCenter(at: 0).height == -rowStride / 2)
        #expect(wrapped.cardOffsetFromCenter(at: 4).height == rowStride / 2)

        let threeRows = layout(9, availableWidth: fourColumnWidth)
        #expect(threeRows.cardOffsetFromCenter(at: 0).height == -rowStride)
        #expect(threeRows.cardOffsetFromCenter(at: 4).height == 0)
        #expect(threeRows.cardOffsetFromCenter(at: 8).height == rowStride)
    }

    @Test("A wrapped plate never grows past the width it was laid out for")
    func plateStaysWithinAvailableWidth() {
        for windowCount in 1...40 {
            let wrapped = layout(windowCount, availableWidth: fourColumnWidth)
            #expect(wrapped.plateSize.width <= fourColumnWidth)
        }
    }

    @Test("Insertion slots cover every position including one past the end")
    func insertionSlots() {
        let wrapped = layout(5, availableWidth: fourColumnWidth)
        // An insertion at the end resolves against the layout the plate will have once the
        // window arrives, so the layout itself only has to answer for its own cards.
        #expect(wrapped.slot(at: 4) != nil)

        let grown = layout(6, availableWidth: fourColumnWidth)
        #expect(grown.rowSizes == [3, 3])
        #expect(grown.slot(at: 5) == PlateGridSlot(row: 1, column: 2))
    }
}
