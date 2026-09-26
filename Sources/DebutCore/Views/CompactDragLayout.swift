import CoreGraphics
import Foundation

/// The order of every space's windows, by identity. `SpaceWindow` equality compares only the
/// window-server ID, so array equality of the model cannot tell a reused ID from the same window;
/// this carries the model UUID beside it.
struct StageStructureFingerprint: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let windowID: CGWindowID
        let modelID: UUID
    }

    struct Stage: Equatable, Sendable {
        let spaceID: UUID
        let windows: [Entry]
    }

    let stages: [Stage]

    init(stages: [Stage]) {
        self.stages = stages
    }

    init(spaces: [Space]) {
        stages = spaces.map { space in
            Stage(
                spaceID: space.id,
                windows: space.windows.map { Entry(windowID: $0.windowID, modelID: $0.id) }
            )
        }
    }
}

/// Where a pointer drop lands, by the identities around it rather than by a number. A number
/// means something else once an earlier edit in the same overlay session has shifted the list.
enum PointerPlacement: Equatable, Sendable {
    case start
    case end
    case between(predecessor: CGWindowID, successor: CGWindowID)

    /// The placement of `index` in a list the dragged window has already been removed from.
    init(index: Int, in remaining: [CGWindowID]) {
        if remaining.isEmpty || index <= 0 {
            self = .start
        } else if index >= remaining.count {
            self = .end
        } else {
            self = .between(predecessor: remaining[index - 1], successor: remaining[index])
        }
    }

    /// The index to insert at in `remaining`, which must not contain the moved window. An
    /// interior gap goes before its surviving successor, else after its surviving predecessor;
    /// with neither left there is no honest place for it, and `nil` says so.
    func resolvedIndex(in remaining: [CGWindowID]) -> Int? {
        switch self {
        case .start:
            return 0
        case .end:
            return remaining.count
        case let .between(predecessor, successor):
            if let index = remaining.firstIndex(of: successor) { return index }
            if let index = remaining.firstIndex(of: predecessor) { return index + 1 }
            return nil
        }
    }
}

/// A pointer drop as the overlay saw it, for the controller to validate against the live
/// preview before it stages anything.
struct PointerWindowDropRequest: Equatable, Sendable {
    let windowID: CGWindowID
    let modelID: UUID
    let fromSpaceID: UUID
    let toSpaceID: UUID
    let logicalIndex: Int
    let placement: PointerPlacement
    let fingerprint: StageStructureFingerprint
}

enum PointerWindowDropResult: Equatable, Sendable {
    case accepted
    case noChange
    case rejected(String)
}

struct CompactCard: Equatable, Sendable {
    let windowID: CGWindowID
    /// The whole card's width in base metrics: thumbnail, title allowance and padding.
    let width: CGFloat
}

/// One stage of the compact stack. Everything here is fixed for the gesture; only which row
/// receives the placeholder, and so the drawn widths, is derived later from the intent.
struct CompactStageSnapshot: Equatable, Sendable {
    let spaceID: UUID
    /// Stage centre in overlay coordinates, after the compact scale.
    let centerY: CGFloat
    /// Unscaled height, from the frozen row count.
    let baseHeight: CGFloat
    /// Each frozen row's centre, unscaled and relative to the stage centre.
    let rowOffsets: [CGFloat]
    let originalRows: [[CompactCard]]
    /// `originalRows` with the dragged card removed exactly once and no rows rebalanced.
    let canonicalRows: [[CompactCard]]
    /// The widest this plate can be drawn during the gesture, unscaled. A fitting bound only.
    let maximumWidth: CGFloat

    var canonicalWindowIDs: [CGWindowID] { canonicalRows.flatMap { $0.map(\.windowID) } }
}

struct CompactDropIntent: Equatable, Sendable {
    let stageIndex: Int
    let spaceID: UUID
    let row: Int
    let gap: Int
    let logicalIndex: Int
    let generation: UInt64
}

/// What the compact stack draws for one intent. Card and placeholder offsets are unscaled and
/// measured from their stage's centre, the one point the compact scale leaves where it was.
struct CompactProjection: Equatable {
    let plateWidths: [CGFloat]
    let cardOffsets: [[CGWindowID: CGPoint]]
    let placeholder: CompactPlaceholder?
}

struct CompactPlaceholder: Equatable {
    let stageIndex: Int
    let offset: CGPoint
    let width: CGFloat
}

/// Everything a compact drag measures once, at pickup (KHA-553).
///
/// All stages share one scale, fixed centres and fixed heights, so the stage the pointer is over
/// never changes the geometry the pointer is aiming at. That scale is at most the focused stage's
/// size and shrinks only when the stack must, fitted against the widest each plate could grow
/// while receiving the dragged card, so no later insertion can push a plate off the screen.
struct CompactDragSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let generation: UInt64
    let fingerprint: StageStructureFingerprint
    let sourceWindowID: CGWindowID
    let sourceModelID: UUID
    let sourceStageIndex: Int
    let sourceLogicalIndex: Int
    /// The dragged card's own width in base metrics.
    let sourceCardWidth: CGFloat
    let metrics: StageMetrics
    let usableBounds: CGRect
    let scale: CGFloat
    let centerX: CGFloat
    let stages: [CompactStageSnapshot]

    static let hysteresis: CGFloat = 2
    /// Clearance above and below the stack.
    static let verticalMargin: CGFloat = 28
    /// The top strip the display-stack indicator occupies when it is shown.
    static let displayIndicatorReserve: CGFloat = 64

    /// The rectangle a compact stack may occupy. The overlay panel already excludes the menu bar,
    /// so the safe area is not subtracted again.
    static func usableBounds(containerSize: CGSize, reservesDisplayIndicator: Bool) -> CGRect {
        let horizontal = StageConstants.screenMargin
        let vertical = verticalMargin
        let top = vertical + (reservesDisplayIndicator ? displayIndicatorReserve : 0)
        let width = containerSize.width - horizontal * 2
        let height = containerSize.height - top - vertical
        // `CGRect` standardizes a negative size into a positive one, which would turn a display
        // too small for any stack into a usable rectangle.
        guard width > 0, height > 0 else { return .zero }
        return CGRect(x: horizontal, y: top, width: width, height: height)
    }

    /// `layouts` are the ordinary resting layouts, already wrapped; their row partition is frozen
    /// here rather than recomputed, so pickup costs one pass over the cards.
    private struct Draft {
        let rows: [[CompactCard]]
        let canonical: [[CompactCard]]
        let offsets: [CGFloat]
        let height: CGFloat
        let maximumWidth: CGFloat
    }

    /// `layouts` are the ordinary resting layouts. They are kept whenever the whole stack fits at
    /// the focused stage's size; only a stack that has to shrink is rewrapped, against the width
    /// shrinking it frees up. Either way the rows chosen here stay fixed for the gesture.
    static func make(
        sessionID: UUID,
        generation: UInt64,
        fingerprint: StageStructureFingerprint,
        layouts: [StageWindowLayout],
        contentAspects: [[CGFloat?]],
        sourceStageIndex: Int,
        sourceWindowIndex: Int,
        containerSize: CGSize,
        usableBounds: CGRect
    ) -> CompactDragSnapshot? {
        let stageCount = fingerprint.stages.count
        guard stageCount > 0, layouts.count == stageCount, contentAspects.count == stageCount,
              fingerprint.stages.indices.contains(sourceStageIndex),
              fingerprint.stages[sourceStageIndex].windows.indices.contains(sourceWindowIndex),
              usableBounds.width > 0, usableBounds.height > 0,
              usableBounds.width.isFinite, usableBounds.height.isFinite
        else { return nil }

        let metrics = layouts[sourceStageIndex].metrics
        let spacing = metrics.windowSpacing
        let source = fingerprint.stages[sourceStageIndex].windows[sourceWindowIndex]
        guard layouts[sourceStageIndex].windowCount
                == fingerprint.stages[sourceStageIndex].windows.count
        else { return nil }
        let sourceCardWidth = layouts[sourceStageIndex].cardWidth(at: sourceWindowIndex)
        guard sourceCardWidth > 0, sourceCardWidth.isFinite else { return nil }
        let stageSpacing = StageConstants.compactStageSpacing * metrics.scaleFactor

        func drafts(_ layouts: [StageWindowLayout]) -> [Draft]? {
            var drafts: [Draft] = []
            for (stageIndex, layout) in layouts.enumerated() {
                let ids = fingerprint.stages[stageIndex].windows.map(\.windowID)
                guard layout.windowCount == ids.count else { return nil }
                var rows: [[CompactCard]] = []
                var start = 0
                for size in layout.rowSizes {
                    rows.append((start..<(start + size)).map {
                        CompactCard(windowID: ids[$0], width: layout.cardWidth(at: $0))
                    })
                    start += size
                }
                if rows.isEmpty { rows = [[]] }

                var canonical = rows
                if stageIndex == sourceStageIndex {
                    for row in canonical.indices {
                        if let column = canonical[row].firstIndex(where: {
                            $0.windowID == source.windowID
                        }) {
                            canonical[row].remove(at: column)
                            break
                        }
                    }
                }

                let rowStride = layout.metrics.cardHeight + layout.metrics.rowSpacing
                let offsets = rows.indices.map { row in
                    -layout.contentHeight / 2 + layout.metrics.cardHeight / 2
                        + CGFloat(row) * rowStride
                        + (layout.metrics.topPadding - layout.metrics.bottomPadding) / 2
                }
                let insertedWidest = canonical.map {
                    rowWidth($0, spacing: spacing) + sourceCardWidth + ($0.isEmpty ? 0 : spacing)
                }.max() ?? sourceCardWidth
                drafts.append(Draft(
                    rows: rows,
                    canonical: canonical,
                    offsets: offsets,
                    height: layout.stageSize.height,
                    maximumWidth: max(
                        layout.stageSize.width,
                        metrics.minStageWidth,
                        insertedWidest + metrics.padding * 2
                    )
                ))
            }
            return drafts
        }

        /// The focused stage's size is the ceiling: the drag view shrinks a stack that does not
        /// fit, and never magnifies one that does past what the focused stage already shows.
        func scale(_ drafts: [Draft]) -> CGFloat? {
            let widest = drafts.map(\.maximumWidth).max() ?? 0
            let totalHeight = drafts.map(\.height).reduce(0, +)
                + CGFloat(stageCount - 1) * stageSpacing
            guard widest > 0, totalHeight > 0 else { return nil }
            let scale = min(1, usableBounds.width / widest, usableBounds.height / totalHeight)
            return scale > 0 && scale.isFinite ? scale : nil
        }

        guard var chosen = drafts(layouts), var fitted = scale(chosen) else { return nil }

        if fitted < 1 {
            // Shrinking by `c` leaves `usableWidth / c` of base width for each stage. Wrapping
            // into it, less room for the incoming card, can only take rows away, and fewer rows
            // let the stack shrink less. Candidates run from the focused size downwards, so the
            // first one whose own fit reaches it is the largest.
            let reserve = sourceCardWidth + spacing
            var candidate: CGFloat = 1
            while candidate > fitted {
                let available = usableBounds.width / candidate - reserve
                if available > metrics.padding * 2 {
                    let wrapped = contentAspects.map {
                        StageWindowLayout(
                            contentAspects: $0,
                            availableWidth: available,
                            metrics: metrics
                        )
                    }
                    if let rewrapped = drafts(wrapped), let rewrappedScale = scale(rewrapped),
                       rewrappedScale >= candidate - 0.0001 {
                        if rewrappedScale > fitted {
                            chosen = rewrapped
                            fitted = rewrappedScale
                        }
                        break
                    }
                }
                candidate -= 0.01
            }
        }

        let totalHeight = chosen.map(\.height).reduce(0, +) + CGFloat(stageCount - 1) * stageSpacing
        var runningTop = usableBounds.midY - totalHeight * fitted / 2
        var stages: [CompactStageSnapshot] = []
        for (index, draft) in chosen.enumerated() {
            stages.append(CompactStageSnapshot(
                spaceID: fingerprint.stages[index].spaceID,
                centerY: runningTop + draft.height * fitted / 2,
                baseHeight: draft.height,
                rowOffsets: draft.offsets,
                originalRows: draft.rows,
                canonicalRows: draft.canonical,
                maximumWidth: draft.maximumWidth
            ))
            runningTop += (draft.height + stageSpacing) * fitted
        }

        return CompactDragSnapshot(
            sessionID: sessionID,
            generation: generation,
            fingerprint: fingerprint,
            sourceWindowID: source.windowID,
            sourceModelID: source.modelID,
            sourceStageIndex: sourceStageIndex,
            sourceLogicalIndex: sourceWindowIndex,
            sourceCardWidth: sourceCardWidth,
            metrics: metrics,
            usableBounds: usableBounds,
            scale: fitted,
            centerX: containerSize.width / 2,
            stages: stages
        )
    }

    static func rowWidth(_ row: [CompactCard], spacing: CGFloat) -> CGFloat {
        row.reduce(0) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * spacing
    }

    // MARK: - Projection

    private func plateWidth(rowWidths: [CGFloat]) -> CGFloat {
        max(metrics.minStageWidth, (rowWidths.max() ?? 0) + metrics.padding * 2)
    }

    /// Card centres for one row laid end to end around the stage centre, unscaled.
    private func centers(of row: [CompactCard], inserting width: CGFloat?, at gap: Int)
        -> (cards: [CGFloat], placeholder: CGFloat?, rowWidth: CGFloat) {
        let spacing = metrics.windowSpacing
        var widths = row.map(\.width)
        let insertion = width.map { _ in min(max(0, gap), row.count) }
        if let insertion, let width { widths.insert(width, at: insertion) }
        let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * spacing
        var x = -total / 2
        var drawn: [CGFloat] = []
        for width in widths {
            drawn.append(x + width / 2)
            x += width + spacing
        }
        var placeholder: CGFloat?
        if let insertion {
            placeholder = drawn.remove(at: insertion)
        }
        return (drawn, placeholder, total)
    }

    /// The placeholder's centre for gap `gap` of canonical row `row`, from unshifted cards. A
    /// projected insertion lands exactly here, so drawing it can never move the anchor it chose.
    func gapAnchor(stageIndex: Int, row: Int, gap: Int) -> CGFloat? {
        guard let cards = stages[safe: stageIndex]?.canonicalRows[safe: row] else { return nil }
        guard !cards.isEmpty else { return 0 }
        let spacing = metrics.windowSpacing
        let left = -Self.rowWidth(cards, spacing: spacing) / 2
        let k = min(max(0, gap), cards.count)
        let preceding = cards.prefix(k).reduce(0) { $0 + $1.width }
        return left + preceding + CGFloat(k) * spacing - spacing / 2
    }

    func projection(for intent: CompactDropIntent?) -> CompactProjection {
        var plateWidths: [CGFloat] = []
        var cardOffsets: [[CGWindowID: CGPoint]] = []
        var placeholder: CompactPlaceholder?

        for (stageIndex, stage) in stages.enumerated() {
            var offsets: [CGWindowID: CGPoint] = [:]
            var rowWidths: [CGFloat] = []
            for (row, cards) in stage.canonicalRows.enumerated() {
                let target = intent.flatMap {
                    $0.stageIndex == stageIndex && $0.row == row ? $0.gap : nil
                }
                let laid = centers(
                    of: cards,
                    inserting: target == nil ? nil : sourceCardWidth,
                    at: target ?? 0
                )
                let y = stage.rowOffsets[safe: row] ?? 0
                for (card, x) in zip(cards, laid.cards) {
                    offsets[card.windowID] = CGPoint(x: x, y: y)
                }
                if let x = laid.placeholder {
                    placeholder = CompactPlaceholder(
                        stageIndex: stageIndex,
                        offset: CGPoint(x: x, y: y),
                        width: sourceCardWidth
                    )
                    offsets[sourceWindowID] = CGPoint(x: x, y: y)
                }
                rowWidths.append(laid.rowWidth)
            }
            if stageIndex == sourceStageIndex, offsets[sourceWindowID] == nil {
                // The hidden source keeps its node, and so its gesture, where it was picked up.
                for (row, cards) in stage.originalRows.enumerated() {
                    let laid = centers(of: cards, inserting: nil, at: 0)
                    if let column = cards.firstIndex(where: { $0.windowID == sourceWindowID }) {
                        offsets[sourceWindowID] = CGPoint(
                            x: laid.cards[column],
                            y: stage.rowOffsets[safe: row] ?? 0
                        )
                    }
                }
            }
            plateWidths.append(plateWidth(rowWidths: rowWidths))
            cardOffsets.append(offsets)
        }
        return CompactProjection(
            plateWidths: plateWidths,
            cardOffsets: cardOffsets,
            placeholder: placeholder
        )
    }

    /// A plate's drawn rectangle in overlay coordinates.
    func plateFrame(stageIndex: Int, projection: CompactProjection) -> CGRect? {
        guard let stage = stages[safe: stageIndex],
              let width = projection.plateWidths[safe: stageIndex]
        else { return nil }
        return CGRect(
            x: centerX - width * scale / 2,
            y: stage.centerY - stage.baseHeight * scale / 2,
            width: width * scale,
            height: stage.baseHeight * scale
        )
    }

    func overlayPoint(stageIndex: Int, offset: CGPoint) -> CGPoint? {
        guard let stage = stages[safe: stageIndex] else { return nil }
        return CGPoint(x: centerX + offset.x * scale, y: stage.centerY + offset.y * scale)
    }

    // MARK: - Resolution

    /// The intent under `location`, resolved once against what is drawn for `current`. Blank
    /// desktop and the gaps between plates are no destination at all.
    func resolve(at location: CGPoint, current: CompactDropIntent?) -> CompactDropIntent? {
        guard location.x.isFinite, location.y.isFinite else { return nil }
        let drawn = projection(for: current)
        guard let stageIndex = stages.indices.first(where: {
            plateFrame(stageIndex: $0, projection: drawn)?.contains(location) == true
        }) else { return nil }
        let stage = stages[stageIndex]
        let retained = current?.stageIndex == stageIndex ? current : nil

        let rowCenters = stage.rowOffsets.map { stage.centerY + $0 * scale }
        guard !rowCenters.isEmpty else { return nil }
        let row = rowCenters.indices.min { lhs, rhs in
            let lhsDistance = abs(rowCenters[lhs] - location.y)
            let rhsDistance = abs(rowCenters[rhs] - location.y)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs == retained?.row { return true }
            if rhs == retained?.row { return false }
            return lhs < rhs
        } ?? 0

        let cards = stage.canonicalRows[row]
        let spacing = metrics.windowSpacing
        let left = -Self.rowWidth(cards, spacing: spacing) / 2
        var running = left
        let midpoints: [CGFloat] = cards.map { card in
            defer { running += card.width + spacing }
            return centerX + (running + card.width / 2) * scale
        }
        var gap = midpoints.firstIndex(where: { $0 > location.x }) ?? cards.count

        if let retained, retained.row == row, retained.gap != gap,
           (0...cards.count).contains(retained.gap) {
            let lower = retained.gap > 0 ? midpoints[retained.gap - 1] : -CGFloat.infinity
            let upper = retained.gap < cards.count ? midpoints[retained.gap] : CGFloat.infinity
            let regionWidth = upper - lower
            let band = min(Self.hysteresis, regionWidth.isFinite ? regionWidth / 4 : Self.hysteresis)
            if location.x >= lower - band, location.x < upper + band {
                gap = retained.gap
            }
        }

        let preceding = stage.canonicalRows.prefix(row).reduce(0) { $0 + $1.count }
        return CompactDropIntent(
            stageIndex: stageIndex,
            spaceID: stage.spaceID,
            row: row,
            gap: gap,
            logicalIndex: preceding + gap,
            generation: generation
        )
    }

    /// Whether dropping here would leave every window where it started. A different row
    /// affinity alone is not an edit.
    func isNoOp(_ intent: CompactDropIntent) -> Bool {
        intent.stageIndex == sourceStageIndex && intent.logicalIndex == sourceLogicalIndex
    }

    func dropRequest(for intent: CompactDropIntent) -> PointerWindowDropRequest? {
        guard let destination = stages[safe: intent.stageIndex],
              let source = stages[safe: sourceStageIndex]
        else { return nil }
        let remaining = destination.canonicalWindowIDs
        return PointerWindowDropRequest(
            windowID: sourceWindowID,
            modelID: sourceModelID,
            fromSpaceID: source.spaceID,
            toSpaceID: destination.spaceID,
            logicalIndex: intent.logicalIndex,
            placement: PointerPlacement(index: intent.logicalIndex, in: remaining),
            fingerprint: fingerprint
        )
    }
}
