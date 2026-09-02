import CoreGraphics

/// The sizes every window card on one display is drawn at.
///
/// Cards never shrink to fit: a space with more windows than fit across the display wraps into
/// extra rows instead. Keeping the metrics in one value means the grid geometry, the rendered
/// view, and the drag projection cannot disagree about how big a card is.
///
/// The card takes the shape of the display it is drawn on, since a window nearly always has
/// roughly the shape of the screen it lives on and a card of some other shape would letterbox
/// its preview. `adapted(toContentAspect:)` reshapes one card to its own window instead, which
/// is the display's shape again for a window that fills its screen.
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

    /// How far a card may stray from the display's own shape. One very tall window would
    /// otherwise set the height of every row it appears in, and one very wide one would push
    /// its row off the display.
    public static let minimumAdaptiveWidthRatio: CGFloat = 0.6
    public static let maximumAdaptiveWidthRatio: CGFloat = 1.6

    /// These metrics with the card narrowed or widened to one window's shape.
    ///
    /// The height is what the row shares, so only the width moves: a narrow window then takes
    /// less horizontal room than the widest one beside it. An aspect of `nil` is a window whose
    /// size has not been discovered, and the display's shape is the honest answer for it.
    public func adapted(toContentAspect aspect: CGFloat?) -> StageMetrics {
        guard let aspect, aspect > 0, thumbnailWidth > 0 else { return self }
        return withThumbnailWidth(min(
            max(thumbnailHeight * aspect, thumbnailWidth * Self.minimumAdaptiveWidthRatio),
            thumbnailWidth * Self.maximumAdaptiveWidthRatio
        ))
    }

    /// These metrics with the thumbnail set to an already-decided width. The grid measures a
    /// card once and the renderer draws it from the same number, rather than reshaping twice.
    func withThumbnailWidth(_ width: CGFloat) -> StageMetrics {
        StageMetrics(
            thumbnailWidth: width,
            thumbnailHeight: thumbnailHeight,
            cardPadding: cardPadding,
            titleWidthAllowance: titleWidthAllowance,
            titleSpacing: titleSpacing,
            titleHeight: titleHeight,
            badgeSize: badgeSize,
            previewPlaceholderIconSize: previewPlaceholderIconSize,
            windowSpacing: windowSpacing,
            rowSpacing: rowSpacing,
            padding: padding,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            minStageWidth: minStageWidth,
            scale: scale
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
    /// Every card's own thumbnail width, in model order. A card is as wide as its window is
    /// shaped, so this is what the grid, the renderer and the drop projection all measure
    /// against; none of them may re-derive a width of their own.
    public let thumbnailWidths: [CGFloat]
    public let rowSizes: [Int]
    public let metrics: StageMetrics

    /// A stage whose cards each take their own window's shape. `nil` is a window whose size is
    /// not known, which takes the display's shape like every card did before.
    public init(contentAspects: [CGFloat?], availableWidth: CGFloat, metrics: StageMetrics) {
        let thumbnailWidths = contentAspects.map {
            metrics.adapted(toContentAspect: $0).thumbnailWidth
        }
        self.thumbnailWidths = thumbnailWidths
        self.rowSizes = Self.rowSizes(
            cardWidths: thumbnailWidths.map {
                $0 + metrics.titleWidthAllowance + metrics.cardPadding * 2
            },
            contentWidth: availableWidth - metrics.padding * 2,
            spacing: metrics.windowSpacing
        )
        self.metrics = metrics
    }

    /// A stage of uniform, display-shaped cards.
    public init(windowCount: Int, availableWidth: CGFloat, metrics: StageMetrics) {
        self.init(
            contentAspects: Array(repeating: nil, count: max(0, windowCount)),
            availableWidth: availableWidth,
            metrics: metrics
        )
    }

    public var windowCount: Int { thumbnailWidths.count }

    /// Balanced rows: the fewest rows that hold the cards, chosen so their widths come out as
    /// even as the order allows, with any surplus going to the earlier rows. Cards keep their
    /// model order, so a row is always a run of consecutive cards.
    ///
    /// Balance is by width rather than by count because a row of narrow cards and a row of wide
    /// ones are only the same length by accident. Equal-width cards make the two the same
    /// question again: five of them at a capacity of four are still 3 + 2, not 4 + 1.
    static func rowSizes(
        cardWidths: [CGFloat],
        contentWidth: CGFloat,
        spacing: CGFloat
    ) -> [Int] {
        let count = cardWidths.count
        guard count > 0 else { return [] }

        // Running row widths, so any row's width is one subtraction. `prefix[i]` is the width of
        // the first `i` cards laid end to end with a gap after each.
        var prefix = [CGFloat](repeating: 0, count: count + 1)
        for index in 0..<count {
            prefix[index + 1] = prefix[index] + cardWidths[index] + spacing
        }
        func width(_ start: Int, _ end: Int) -> CGFloat { prefix[end] - prefix[start] - spacing }
        // A single card that overflows on its own has nowhere else to go.
        func fits(_ start: Int, _ end: Int) -> Bool {
            end - start == 1 || width(start, end) <= contentWidth
        }

        // Greedily filling rows uses the fewest of them, which is the row count to then balance
        // within: wrapping earlier would only make the stage taller.
        var rowCount = 1
        var rowStart = 0
        for index in 1..<count where !fits(rowStart, index + 1) {
            rowCount += 1
            rowStart = index
        }

        // Minimising the sum of the squared row widths is what evens them out. Ties are broken
        // towards a shorter last row, which is what puts the surplus in the earlier rows.
        let unreachable = CGFloat.greatestFiniteMagnitude
        var cost = [[CGFloat]](
            repeating: [CGFloat](repeating: unreachable, count: count + 1),
            count: rowCount + 1
        )
        var split = [[Int]](repeating: [Int](repeating: 0, count: count + 1), count: rowCount + 1)
        cost[0][0] = 0
        for row in 1...rowCount {
            for end in row...count {
                for start in (row - 1)..<end where cost[row - 1][start] < unreachable {
                    guard fits(start, end) else { continue }
                    let rowWidth = width(start, end)
                    let candidate = cost[row - 1][start] + rowWidth * rowWidth
                    if candidate <= cost[row][end] {
                        cost[row][end] = candidate
                        split[row][end] = start
                    }
                }
            }
        }

        var sizes = [Int](repeating: 0, count: rowCount)
        var end = count
        for row in stride(from: rowCount, through: 1, by: -1) {
            let start = split[row][end]
            sizes[row - 1] = end - start
            end = start
        }
        return sizes
    }

    public var rowCount: Int { rowSizes.count }

    /// How wide one row of cards is drawn, gaps included.
    public func rowWidth(_ row: Int) -> CGFloat {
        guard rowSizes.indices.contains(row) else { return 0 }
        let start = rowStartIndex(row)
        let size = rowSizes[row]
        return (start..<(start + size)).reduce(0) { $0 + cardWidth(at: $1) }
            + CGFloat(size - 1) * metrics.windowSpacing
    }

    public var contentWidth: CGFloat {
        (0..<rowCount).map { rowWidth($0) }.max() ?? 0
    }

    public func cardWidth(at index: Int) -> CGFloat {
        cardMetrics(at: index).cardWidth
    }

    /// The metrics one card is drawn with. Taken from the width its own slot was measured at, so
    /// the drawn card cannot be a different size from the space the grid left for it.
    public func cardMetrics(at index: Int) -> StageMetrics {
        guard thumbnailWidths.indices.contains(index) else { return metrics }
        return metrics.withThumbnailWidth(thumbnailWidths[index])
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
    /// short final row sits under the middle of the row above it. Cards have their own widths,
    /// so the horizontal position is the running width of the row up to this card rather than a
    /// multiple of one card's stride.
    public func cardOffsetFromCenter(at index: Int) -> CGSize {
        guard let slot = slot(at: index) else { return .zero }
        let start = rowStartIndex(slot.row)
        let precedingWidth = (start..<index).reduce(0) { $0 + cardWidth(at: $1) }
            + CGFloat(slot.column) * metrics.windowSpacing
        let rowStride = metrics.cardHeight + metrics.rowSpacing
        return CGSize(
            width: -rowWidth(slot.row) / 2 + precedingWidth + cardWidth(at: index) / 2,
            height: -contentHeight / 2 + metrics.cardHeight / 2
                + CGFloat(slot.row) * rowStride
                + (metrics.topPadding - metrics.bottomPadding) / 2
        )
    }
}
