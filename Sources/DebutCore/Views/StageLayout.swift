import CoreGraphics

/// The sizes every window card on one display is drawn at.
///
/// Cards never shrink to fit: a space with more windows than fit across the display wraps into
/// extra rows instead. Keeping the metrics in one value means the grid geometry, the rendered
/// view, and the drag projection cannot disagree about how big a card is.
///
/// The card takes the shape of the display it is drawn on, since a window nearly always has
/// roughly the shape of the screen it lives on and a card of some other shape would letterbox
/// its preview. Cards stay uniform within one overlay — the shape comes from the display, not
/// from the individual window.
public struct StageMetrics: Equatable, Sendable {
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
    public let minStageWidth: CGFloat

    /// The visual scale these metrics were built at. Stored rather than derived, because the
    /// thumbnail's width also moves with the display's shape and so cannot stand in for it.
    public let scale: CGFloat

    public static let standard = StageMetrics(
        thumbnailWidth: 160,
        thumbnailHeight: 100,
        cardPadding: 6,
        titleWidthAllowance: 8,
        // This centers the title in the gap between the preview and the stage's lower edge,
        // while leaving the selector around the preview clear of the text.
        titleSpacing: 10,
        titleHeight: 14,
        badgeSize: 40,
        previewPlaceholderIconSize: 32,
        windowSpacing: 12,
        rowSpacing: 12,
        padding: 24,
        topPadding: 24,
        // The original one-row stage was 164 points high. The card itself is 130 points once
        // its vertical padding is represented explicitly, leaving ten points below the card and
        // preserving the original seven-point downward optical offset inside the stage.
        bottomPadding: 4,
        minStageWidth: 300,
        scale: 1
    )

    /// The card shape for a display of the given size, at scale 1.
    ///
    /// Area is preserved rather than width. Holding the width at its standard 160 points would
    /// make a 9:16 monitor's card 284 points tall, which `fittedStageScale` then has to shrink
    /// the whole overlay to absorb; holding the area instead gives a portrait card the same
    /// visual weight as a landscape one, so only the shape changes.
    public static func shaped(forDisplay displaySize: CGSize) -> StageMetrics {
        let standard = Self.standard
        guard displaySize.width > 0, displaySize.height > 0 else { return standard }

        let aspect = displaySize.width / displaySize.height
        let area = standard.thumbnailWidth * standard.thumbnailHeight
        let width = (area * aspect).squareRoot()

        return StageMetrics(
            thumbnailWidth: width,
            thumbnailHeight: width / aspect,
            cardPadding: standard.cardPadding,
            titleWidthAllowance: standard.titleWidthAllowance,
            titleSpacing: standard.titleSpacing,
            titleHeight: standard.titleHeight,
            badgeSize: standard.badgeSize,
            previewPlaceholderIconSize: standard.previewPlaceholderIconSize,
            windowSpacing: standard.windowSpacing,
            rowSpacing: standard.rowSpacing,
            padding: standard.padding,
            topPadding: standard.topPadding,
            bottomPadding: standard.bottomPadding,
            minStageWidth: standard.minStageWidth,
            scale: standard.scale
        )
    }

    public var cardWidth: CGFloat {
        thumbnailWidth + titleWidthAllowance + cardPadding * 2
    }

    public var cardHeight: CGFloat {
        thumbnailHeight + titleSpacing + titleHeight + cardPadding * 2
    }

    /// Taken from the scale, not the thumbnail's width: an ultrawide display widens the card
    /// and a portrait display narrows it, and neither should move the title's size.
    public var titleFontSize: CGFloat {
        max(9, Self.standard.thumbnailWidth * 0.065 * scale)
    }

    public var thumbnailCornerRadius: CGFloat { cardPadding }

    /// The visual scale represented by these metrics. Rendering code uses this for the few
    /// non-layout details that belong to a stage, such as its corner radius and command hints.
    public var scaleFactor: CGFloat { scale }

    /// Every dimension scales together, so a card only ever grows or shrinks — it never changes
    /// shape, and the title stays legible against the thumbnail it labels.
    public func scaled(by scale: CGFloat) -> StageMetrics {
        StageMetrics(
            thumbnailWidth: thumbnailWidth * scale,
            thumbnailHeight: thumbnailHeight * scale,
            cardPadding: cardPadding * scale,
            titleWidthAllowance: titleWidthAllowance * scale,
            titleSpacing: titleSpacing * scale,
            titleHeight: titleHeight * scale,
            badgeSize: badgeSize * scale,
            previewPlaceholderIconSize: previewPlaceholderIconSize * scale,
            windowSpacing: windowSpacing * scale,
            rowSpacing: rowSpacing * scale,
            padding: padding * scale,
            topPadding: topPadding * scale,
            bottomPadding: bottomPadding * scale,
            minStageWidth: minStageWidth * scale,
            scale: self.scale * scale
        )
    }
}

public struct StageGridSlot: Equatable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Where every window card of one space sits, and how big that makes its stage.
///
/// This is the single source of truth for the grid: the rendered view, hit testing, and the drag
/// projection all read positions from here, so a card can never be drawn somewhere the geometry
/// does not expect it. Positions are unscaled and measured from the stage's centre, which is the
/// one point that survives the focus-distance scale transform.
public struct StageWindowLayout: Equatable, Sendable {
    public let windowCount: Int
    public let columnCapacity: Int
    public let rowSizes: [Int]
    public let metrics: StageMetrics

    public init(windowCount: Int, availableWidth: CGFloat, metrics: StageMetrics) {
        let capacity = Self.columnCapacity(availableWidth: availableWidth, metrics: metrics)
        self.windowCount = max(0, windowCount)
        self.columnCapacity = capacity
        self.rowSizes = Self.rowSizes(windowCount: max(0, windowCount), capacity: capacity)
        self.metrics = metrics
    }

    /// How many cards fit across the display. Always at least one, so a display too narrow for a
    /// single card lays out a column of one rather than no columns at all.
    public static func columnCapacity(availableWidth: CGFloat, metrics: StageMetrics) -> Int {
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

    /// An empty space is still a space: it keeps one row of height so the stack does not
    /// collapse around it.
    public var contentHeight: CGFloat {
        let rows = CGFloat(max(1, rowCount))
        return rows * metrics.cardHeight + (rows - 1) * metrics.rowSpacing
    }

    public var stageSize: CGSize {
        CGSize(
            width: max(metrics.minStageWidth, contentWidth + metrics.padding * 2),
            height: contentHeight + metrics.topPadding + metrics.bottomPadding
        )
    }

    public func rowStartIndex(_ row: Int) -> Int {
        rowSizes.prefix(max(0, row)).reduce(0, +)
    }

    public func slot(at index: Int) -> StageGridSlot? {
        guard index >= 0, index < windowCount else { return nil }
        var remaining = index
        for (row, size) in rowSizes.enumerated() {
            if remaining < size { return StageGridSlot(row: row, column: remaining) }
            remaining -= size
        }
        return nil
    }

    /// The card's centre relative to the stage's centre. Rows are individually centred, so a
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
