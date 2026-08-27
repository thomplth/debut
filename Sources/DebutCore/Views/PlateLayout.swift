import CoreGraphics

/// The fixed sizes every window card is drawn at.
///
/// Cards never shrink to fit: a stage with more windows than fit across the display wraps into
/// extra rows instead. Keeping the metrics in one value means the grid geometry, the rendered
/// view, and the drag projection cannot disagree about how big a card is.
public struct PlateMetrics: Equatable, Sendable {
    public let thumbnailWidth: CGFloat
    public let thumbnailHeight: CGFloat
    public let cardPadding: CGFloat
    public let titleWidthAllowance: CGFloat
    public let titleSpacing: CGFloat
    public let titleHeight: CGFloat
    public let badgeSize: CGFloat
    public let previewPlaceholderIconSize: CGFloat
    public let windowSpacing: CGFloat
    public let rowSpacing: CGFloat
    public let padding: CGFloat
    public let topPadding: CGFloat
    public let bottomPadding: CGFloat
    public let minPlateWidth: CGFloat

    public static let standard = PlateMetrics(
        thumbnailWidth: 160,
        thumbnailHeight: 100,
        cardPadding: 6,
        titleWidthAllowance: 8,
        titleSpacing: 4,
        titleHeight: 14,
        badgeSize: 40,
        previewPlaceholderIconSize: 32,
        windowSpacing: 12,
        rowSpacing: 12,
        padding: 24,
        topPadding: 24,
        bottomPadding: 24,
        minPlateWidth: 300
    )

    public var cardWidth: CGFloat {
        thumbnailWidth + titleWidthAllowance + cardPadding * 2
    }

    public var cardHeight: CGFloat {
        thumbnailHeight + titleSpacing + titleHeight + cardPadding * 2
    }

    public var titleFontSize: CGFloat {
        max(9, thumbnailWidth * 0.065)
    }
}

public struct PlateGridSlot: Equatable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Where every window card of one stage sits, and how big that makes its plate.
///
/// This is the single source of truth for the grid: the rendered view, hit testing, and the drag
/// projection all read positions from here, so a card can never be drawn somewhere the geometry
/// does not expect it. Positions are unscaled and measured from the plate's centre, which is the
/// one point that survives the focus-distance scale transform.
public struct PlateWindowLayout: Equatable, Sendable {
    public let windowCount: Int
    public let columnCapacity: Int
    public let rowSizes: [Int]
    public let metrics: PlateMetrics

    public init(windowCount: Int, availableWidth: CGFloat, metrics: PlateMetrics) {
        let capacity = Self.columnCapacity(availableWidth: availableWidth, metrics: metrics)
        self.windowCount = max(0, windowCount)
        self.columnCapacity = capacity
        self.rowSizes = Self.rowSizes(windowCount: max(0, windowCount), capacity: capacity)
        self.metrics = metrics
    }

    /// How many cards fit across the display. Always at least one, so a display too narrow for a
    /// single card lays out a column of one rather than no columns at all.
    public static func columnCapacity(availableWidth: CGFloat, metrics: PlateMetrics) -> Int {
        let contentWidth = availableWidth - metrics.padding * 2
        let stride = metrics.cardWidth + metrics.windowSpacing
        guard stride > 0 else { return 1 }
        let fitting = (contentWidth + metrics.windowSpacing) / stride
        return max(1, Int(fitting.rounded(.down)))
    }

    /// Balanced rows: the fewest rows that hold the windows, filled evenly, with any remainder
    /// going to the earlier rows. Five windows at a capacity of four are 3 + 2, not 4 + 1.
    public static func rowSizes(windowCount: Int, capacity: Int) -> [Int] {
        guard windowCount > 0, capacity > 0 else { return [] }
        let rowCount = Int((Double(windowCount) / Double(capacity)).rounded(.up))
        let base = windowCount / rowCount
        let remainder = windowCount % rowCount
        return (0..<rowCount).map { $0 < remainder ? base + 1 : base }
    }

    public var rowCount: Int { rowSizes.count }

    public var contentWidth: CGFloat {
        guard let widest = rowSizes.max() else { return 0 }
        return CGFloat(widest) * metrics.cardWidth
            + CGFloat(widest - 1) * metrics.windowSpacing
    }

    /// An empty stage is still a stage: it keeps one row of height so the stack does not
    /// collapse around it.
    public var contentHeight: CGFloat {
        let rows = CGFloat(max(1, rowCount))
        return rows * metrics.cardHeight + (rows - 1) * metrics.rowSpacing
    }

    public var plateSize: CGSize {
        CGSize(
            width: max(metrics.minPlateWidth, contentWidth + metrics.padding * 2),
            height: contentHeight + metrics.topPadding + metrics.bottomPadding
        )
    }

    public func rowStartIndex(_ row: Int) -> Int {
        rowSizes.prefix(max(0, row)).reduce(0, +)
    }

    public func slot(at index: Int) -> PlateGridSlot? {
        guard index >= 0, index < windowCount else { return nil }
        var remaining = index
        for (row, size) in rowSizes.enumerated() {
            if remaining < size { return PlateGridSlot(row: row, column: remaining) }
            remaining -= size
        }
        return nil
    }

    /// The card's centre relative to the plate's centre. Rows are individually centred, so a
    /// short final row sits under the middle of the row above it.
    public func cardOffsetFromCenter(at index: Int) -> CGSize {
        guard let slot = slot(at: index) else { return .zero }
        let rowWidth = CGFloat(rowSizes[slot.row]) * metrics.cardWidth
            + CGFloat(rowSizes[slot.row] - 1) * metrics.windowSpacing
        let rowStride = metrics.cardHeight + metrics.rowSpacing
        return CGSize(
            width: -rowWidth / 2 + metrics.cardWidth / 2
                + CGFloat(slot.column) * (metrics.cardWidth + metrics.windowSpacing),
            height: -contentHeight / 2 + metrics.cardHeight / 2
                + CGFloat(slot.row) * rowStride
                + (metrics.topPadding - metrics.bottomPadding) / 2
        )
    }
}
