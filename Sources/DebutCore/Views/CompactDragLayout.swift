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
    /// Set when the drop landed on a new-desktop target, so `toSpaceID` names a desktop the
    /// session stages first, at the top or bottom of the stack, rather than one the preview
    /// already has.
    var newDesktopPosition: NewDesktopPosition? = nil

    var createsDesktop: Bool { newDesktopPosition != nil }
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
    /// A held plate only: where in the stack its empty slot stands. A merge keeps the slot it
    /// had, so reaching into a plate never slides the plates under the pointer. An intent whose
    /// `stageIndex` is the held plate's own is a reorder to this slot.
    var slot: Int? = nil
}

/// A held plate released over the stack.
struct PlateDropRequest: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Its windows join the destination at the gap the pointer opened.
        case merge(into: UUID, placement: PointerPlacement)
        /// It moves to straight after `predecessor`, or to the top when that is nil.
        case reorder(after: UUID?)
    }

    let spaceID: UUID
    let action: Action
    let fingerprint: StageStructureFingerprint
}

/// What the compact stack draws for one intent. Card and placeholder offsets are unscaled and
/// measured from their stage's centre, the one point the compact scale leaves where it was.
struct CompactProjection: Equatable {
    let plateWidths: [CGFloat]
    let cardOffsets: [[CGWindowID: CGPoint]]
    let placeholder: CompactPlaceholder?
    /// How far each plate is drawn from its frozen centre, in overlay points. Only a held
    /// plate's moving slot shifts plates; everything else is drawn where it was frozen.
    var stageShifts: [CGFloat] = []
    /// How far each plate's cards are shrunk to take a held plate's cards in one row.
    var contentScales: [CGFloat] = []
    /// Where a held plate's open slot is centred, in overlay points.
    var slotCenterY: CGFloat? = nil
}

struct CompactPlaceholder: Equatable {
    let stageIndex: Int
    let offset: CGPoint
    let width: CGFloat
}

/// A + at one end of the drag view. Collapsed it reserves only its own circle; the window
/// reaching it swaps in the snapshot laid out with it opened into an empty plate.
struct CompactNewDesktopTarget: Equatable, Sendable {
    let position: NewDesktopPosition
    /// The id the desktop is staged under if the window is dropped there.
    let spaceID: UUID
    /// The +'s centre in overlay coordinates, and its drawn diameter.
    let center: CGPoint
    let diameter: CGFloat

    var frame: CGRect {
        CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
               width: diameter, height: diameter)
    }
}

/// One compact drag laid out with every + collapsed, and once per + with it opened into a
/// plate. All share a generation and the rows frozen at pickup, so swapping between them moves
/// plates but never rewraps a card or invalidates what the pointer already aims at.
struct CompactDragVariants: Equatable, Sendable {
    let collapsed: CompactDragSnapshot
    let expanded: [NewDesktopPosition: CompactDragSnapshot]
    /// A held plate's stack at the scale that leaves room for its full slot. The drag view
    /// starts roomier, without the plate, and moves to this once, the first time a slot opens.
    var slotted: CompactDragSnapshot? = nil

    init(collapsed: CompactDragSnapshot, expanded: [NewDesktopPosition: CompactDragSnapshot]) {
        self.collapsed = collapsed
        self.expanded = expanded
    }

    /// The layout a held plate's resolved intent calls for: the slotted one while it asks for
    /// a slot, and the held one, with no room kept for a slot, once it merges or leaves the
    /// stack. Nil keeps `current`.
    func plateLayout(for intent: CompactDropIntent?, from current: CompactDragSnapshot)
        -> CompactDragSnapshot? {
        guard let slotted else { return nil }
        let wanted = intent?.slot != nil ? slotted : collapsed
        return wanted == current ? nil : wanted
    }

    /// The layout the pointer calls for from `current`: a + it reaches opens, and an open plate
    /// it leaves closes. Nil keeps `current`.
    func layout(at location: CGPoint, from current: CompactDragSnapshot) -> CompactDragSnapshot? {
        if let open = current.expandedNewDesktop {
            guard let plate = current.expandedNewDesktopFrame,
                  !plate.insetBy(dx: -CompactDragSnapshot.expansionHysteresis,
                                 dy: -CompactDragSnapshot.expansionHysteresis).contains(location)
            else { return nil }
            // Leaving one plate straight for the other end's + opens that one instead.
            let reached = newDesktop(at: location, over: collapsed)
            return reached.flatMap { $0 == open ? nil : expanded[$0] } ?? collapsed
        }
        return newDesktop(at: location, over: current).flatMap { expanded[$0] }
    }

    /// The + whose opened plate would hold `location`, so a window opens it anywhere in the
    /// room it would take rather than only over the circle. A real plate drawn there wins.
    private func newDesktop(at location: CGPoint, over layout: CompactDragSnapshot) -> NewDesktopPosition? {
        let reach = -CompactDragSnapshot.expansionHysteresis
        let targets = layout.newDesktopTargets
        if let onButton = targets.first(where: { $0.frame.insetBy(dx: reach, dy: reach).contains(location) }) {
            return onButton.position
        }
        let projection = layout.projection(for: nil)
        let overRealPlate = layout.fingerprint.stages.indices.contains {
            layout.plateFrame(stageIndex: $0, projection: projection)?.contains(location) == true
        }
        guard !overRealPlate else { return nil }
        return targets.first {
            expanded[$0.position]?.expandedNewDesktopFrame?
                .insetBy(dx: reach, dy: reach).contains(location) == true
        }?.position
    }
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
    /// The dragged card's own width in base metrics. For a held plate, the width of all its
    /// cards laid end to end: the gap it opens in a plate it would merge into.
    let sourceCardWidth: CGFloat
    let metrics: StageMetrics
    let usableBounds: CGRect
    let scale: CGFloat
    let centerX: CGFloat
    let stages: [CompactStageSnapshot]
    /// A whole plate is held rather than one card; `sourceStageIndex` names it.
    var movesWholeStage = false
    /// The held plate's windows, in order.
    var sourceWindowIDs: [CGWindowID] = []
    /// How tall the slot a held plate would land in opens, drawn.
    var slotHeight: CGFloat = 0
    /// The + buttons drawn collapsed at the ends of the stack.
    var newDesktopTargets: [CompactNewDesktopTarget] = []
    /// The + opened into an empty plate in this layout, if any. That plate is the last entry of
    /// `stages` wherever it is drawn, so every real stage keeps its index across layouts.
    var expandedNewDesktop: NewDesktopPosition? = nil
    var newDesktopStageIndex: Int? = nil

    static let hysteresis: CGFloat = 2
    /// How far past an opened plate the pointer may stray before it closes again.
    static let expansionHysteresis: CGFloat = 6
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
        sourceWindowIndex: Int?,
        containerSize: CGSize,
        usableBounds: CGRect,
        newDesktopIDs: [NewDesktopPosition: UUID] = [:]
    ) -> CompactDragSnapshot? {
        makeVariants(
            sessionID: sessionID, generation: generation, fingerprint: fingerprint,
            layouts: layouts, contentAspects: contentAspects,
            sourceStageIndex: sourceStageIndex, sourceWindowIndex: sourceWindowIndex,
            containerSize: containerSize, usableBounds: usableBounds,
            newDesktopIDs: newDesktopIDs
        )?.collapsed
    }

    /// `newDesktopIDs` names the + at each end that offers a new desktop, keyed `.top` or
    /// `.bottom`, with the id that desktop would be staged under. A nil `sourceWindowIndex`
    /// holds the whole plate.
    static func makeVariants(
        sessionID: UUID,
        generation: UInt64,
        fingerprint: StageStructureFingerprint,
        layouts: [StageWindowLayout],
        contentAspects: [[CGFloat?]],
        sourceStageIndex: Int,
        sourceWindowIndex: Int?,
        containerSize: CGSize,
        usableBounds: CGRect,
        newDesktopIDs: [NewDesktopPosition: UUID] = [:]
    ) -> CompactDragVariants? {
        let stageCount = fingerprint.stages.count
        guard stageCount > 0, layouts.count == stageCount, contentAspects.count == stageCount,
              fingerprint.stages.indices.contains(sourceStageIndex),
              sourceWindowIndex.map({
                  fingerprint.stages[sourceStageIndex].windows.indices.contains($0)
              }) ?? (stageCount > 1),
              usableBounds.width > 0, usableBounds.height > 0,
              usableBounds.width.isFinite, usableBounds.height.isFinite
        else { return nil }

        let metrics = layouts[sourceStageIndex].metrics
        let spacing = metrics.windowSpacing
        let heldWindows = fingerprint.stages[sourceStageIndex].windows
        let source = sourceWindowIndex.map { heldWindows[$0] }
            ?? .init(windowID: 0, modelID: fingerprint.stages[sourceStageIndex].spaceID)
        guard layouts[sourceStageIndex].windowCount == heldWindows.count else { return nil }
        let sourceCardWidth = sourceWindowIndex.map { layouts[sourceStageIndex].cardWidth(at: $0) }
            ?? (heldWindows.indices.map { layouts[sourceStageIndex].cardWidth(at: $0) }.reduce(0, +)
                + CGFloat(max(0, heldWindows.count - 1)) * spacing)
        guard sourceCardWidth.isFinite, sourceWindowIndex == nil || sourceCardWidth > 0
        else { return nil }
        // The stack is fitted as a held card fits it, whatever is held, so a held plate's drag
        // view looks exactly like a held window's. A plate whose row cannot also take a held
        // plate's cards across the screen compresses its own cards instead; see `projection`.
        let fitCardWidth = sourceWindowIndex == nil
            ? heldWindows.indices.map { layouts[sourceStageIndex].cardWidth(at: $0) }.max() ?? 0
            : sourceCardWidth
        let stageSpacing = StageConstants.compactStageSpacing * metrics.scaleFactor
        let ends = [NewDesktopPosition.top, .bottom].filter { newDesktopIDs[$0] != nil }
        let buttonBase = DesktopControlGeometry.addButtonDiameter * metrics.scaleFactor
        let minimumButton = DesktopControlGeometry.minimumDropTargetDiameter

        func draft(_ layout: StageWindowLayout, ids: [CGWindowID], isSource: Bool) -> Draft? {
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
            if isSource {
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
                rowWidth($0, spacing: spacing) + fitCardWidth + ($0.isEmpty ? 0 : spacing)
            }.max() ?? fitCardWidth
            return Draft(
                rows: rows,
                canonical: canonical,
                offsets: offsets,
                height: layout.stageSize.height,
                maximumWidth: max(
                    layout.stageSize.width,
                    metrics.minStageWidth,
                    insertedWidest + metrics.padding * 2
                )
            )
        }

        func drafts(_ layouts: [StageWindowLayout]) -> [Draft]? {
            var drafts: [Draft] = []
            for (stageIndex, layout) in layouts.enumerated() {
                guard let made = draft(
                    layout,
                    ids: fingerprint.stages[stageIndex].windows.map(\.windowID),
                    isSource: sourceWindowIndex != nil && stageIndex == sourceStageIndex
                ) else { return nil }
                drafts.append(made)
            }
            return drafts
        }

        guard let emptyPlate = draft(
            StageWindowLayout(contentAspects: [], availableWidth: .greatestFiniteMagnitude,
                              metrics: metrics),
            ids: [], isSource: false
        ) else { return nil }

        /// A collapsed + takes its own height in the stack, and never draws smaller than a
        /// legible minimum however far the stack shrinks, so the fit solves for both regimes.
        func buttonDiameter(at scale: CGFloat) -> CGFloat { max(buttonBase * scale, minimumButton) }

        /// The focused stage's size is the ceiling: the drag view shrinks a stack that does not
        /// fit, and never magnifies one that does past what the focused stage already shows.
        func scale(_ all: [Draft], buttons: Int, leavingHeld: Bool = false) -> CGFloat? {
            let drafts = leavingHeld
                ? all.enumerated().filter { $0.offset != sourceStageIndex }.map(\.element) : all
            let widest = drafts.map(\.maximumWidth).max() ?? 0
            let items = drafts.count + buttons
            let plates = drafts.map(\.height).reduce(0, +) + CGFloat(items - 1) * stageSpacing
            guard widest > 0, plates > 0 else { return nil }
            var fit = usableBounds.height / (plates + CGFloat(buttons) * buttonBase)
            if buttons > 0, buttonBase * fit < minimumButton {
                fit = (usableBounds.height - CGFloat(buttons) * minimumButton) / plates
            }
            let scale = min(1, usableBounds.width / widest, fit)
            return scale > 0 && scale.isFinite ? scale : nil
        }

        guard var chosen = drafts(layouts), var fitted = scale(chosen, buttons: ends.count)
        else { return nil }

        if fitted < 1 {
            // Shrinking by `c` leaves `usableWidth / c` of base width for each stage. Wrapping
            // into it, less room for the incoming card, can only take rows away, and fewer rows
            // let the stack shrink less. Candidates run from the focused size downwards, so the
            // first one whose own fit reaches it is the largest.
            let reserve = fitCardWidth + spacing
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
                    if let rewrapped = drafts(wrapped),
                       let rewrappedScale = scale(rewrapped, buttons: ends.count),
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

        // Rows are chosen exactly as for a held window, so a held plate's drag view wraps as a
        // held window's does. Then the held plate leaves the stack and the rest share its room,
        // which can only let them grow.
        // Holding the plate's height back in is the scale a slot for it needs.
        let slottedScale = fitted
        if sourceWindowIndex == nil, let roomier = scale(chosen, buttons: ends.count, leavingHeld: true) {
            fitted = max(fitted, roomier)
        }

        enum Item { case stage(Int), plate, button(NewDesktopPosition) }

        /// Lays the frozen rows out top to bottom with `open` drawn as a plate, then slides the
        /// whole stack, inside the usable bounds, until that plate covers the + it opened from,
        /// so the pointer that opened it is still over it.
        func layout(open: NewDesktopPosition?, keeping anchor: CGRect?,
                    at fixedScale: CGFloat? = nil) -> CompactDragSnapshot? {
            let plateDrafts = chosen + (open == nil ? [] : [emptyPlate])
            guard let drawnScale = open == nil
                ? fixedScale ?? fitted
                : scale(plateDrafts, buttons: ends.count - 1).map({ min($0, fitted) })
            else { return nil }
            let diameter = buttonDiameter(at: drawnScale)
            var items: [Item] = chosen.indices
                .filter { sourceWindowIndex != nil || $0 != sourceStageIndex }
                .map { .stage($0) }
            if ends.contains(.top) { items.insert(open == .top ? .plate : .button(.top), at: 0) }
            if ends.contains(.bottom) { items.append(open == .bottom ? .plate : .button(.bottom)) }

            func drawnHeight(_ item: Item) -> CGFloat {
                switch item {
                case let .stage(index): chosen[index].height * drawnScale
                case .plate: emptyPlate.height * drawnScale
                case .button: diameter
                }
            }
            let total = items.map(drawnHeight).reduce(0, +)
                + CGFloat(items.count - 1) * stageSpacing * drawnScale
            var centers: [CGFloat] = []
            var running = usableBounds.midY - total / 2
            for item in items {
                centers.append(running + drawnHeight(item) / 2)
                running += drawnHeight(item) + stageSpacing * drawnScale
            }
            if let anchor, let plate = items.firstIndex(where: {
                if case .plate = $0 { true } else { false }
            }) {
                let half = drawnHeight(items[plate]) / 2
                var shift: CGFloat = 0
                if anchor.minY < centers[plate] - half { shift = anchor.minY - (centers[plate] - half) }
                if anchor.maxY > centers[plate] + half { shift = anchor.maxY - (centers[plate] + half) }
                let top = usableBounds.midY - total / 2
                shift = min(max(shift, usableBounds.minY - top), usableBounds.maxY - (top + total))
                centers = centers.map { $0 + shift }
            }

            var stages: [CompactStageSnapshot?] = Array(repeating: nil, count: chosen.count)
            if sourceWindowIndex == nil {
                // Held, it is drawn under the pointer, not in the stack.
                let draft = chosen[sourceStageIndex]
                stages[sourceStageIndex] = CompactStageSnapshot(
                    spaceID: fingerprint.stages[sourceStageIndex].spaceID,
                    centerY: usableBounds.midY,
                    baseHeight: draft.height,
                    rowOffsets: draft.offsets,
                    originalRows: draft.rows,
                    canonicalRows: draft.canonical,
                    maximumWidth: draft.maximumWidth
                )
            }
            var expandedStage: CompactStageSnapshot?
            var targets: [CompactNewDesktopTarget] = []
            for (item, center) in zip(items, centers) {
                switch item {
                case let .stage(index):
                    let draft = chosen[index]
                    stages[index] = CompactStageSnapshot(
                        spaceID: fingerprint.stages[index].spaceID,
                        centerY: center,
                        baseHeight: draft.height,
                        rowOffsets: draft.offsets,
                        originalRows: draft.rows,
                        canonicalRows: draft.canonical,
                        maximumWidth: draft.maximumWidth
                    )
                case .plate:
                    guard let open, let spaceID = newDesktopIDs[open] else { return nil }
                    expandedStage = CompactStageSnapshot(
                        spaceID: spaceID,
                        centerY: center,
                        baseHeight: emptyPlate.height,
                        rowOffsets: emptyPlate.offsets,
                        originalRows: emptyPlate.rows,
                        canonicalRows: emptyPlate.canonical,
                        maximumWidth: emptyPlate.maximumWidth
                    )
                case let .button(position):
                    guard let spaceID = newDesktopIDs[position] else { return nil }
                    targets.append(CompactNewDesktopTarget(
                        position: position,
                        spaceID: spaceID,
                        center: CGPoint(x: containerSize.width / 2, y: center),
                        diameter: diameter
                    ))
                }
            }
            var snapshot = CompactDragSnapshot(
                sessionID: sessionID,
                generation: generation,
                fingerprint: fingerprint,
                sourceWindowID: source.windowID,
                sourceModelID: source.modelID,
                sourceStageIndex: sourceStageIndex,
                sourceLogicalIndex: sourceWindowIndex ?? 0,
                sourceCardWidth: sourceCardWidth,
                metrics: metrics,
                usableBounds: usableBounds,
                scale: drawnScale,
                centerX: containerSize.width / 2,
                stages: stages.compactMap { $0 } + (expandedStage.map { [$0] } ?? []),
                newDesktopTargets: targets,
                expandedNewDesktop: expandedStage == nil ? nil : open,
                newDesktopStageIndex: expandedStage == nil ? nil : stageCount
            )
            snapshot.movesWholeStage = sourceWindowIndex == nil
            if sourceWindowIndex == nil {
                // A slot it could drop into opens only as far as the room the stack has spare,
                // so opening one never pushes a plate off the screen.
                let spare = usableBounds.height - total - stageSpacing * drawnScale
                snapshot.slotHeight = min(chosen[sourceStageIndex].height * drawnScale,
                                          max(spare, stageSpacing * drawnScale))
            }
            snapshot.sourceWindowIDs = sourceWindowIndex == nil
                ? heldWindows.map(\.windowID) : [source.windowID]
            return snapshot
        }

        guard let collapsed = layout(open: nil, keeping: nil) else { return nil }
        var expanded: [NewDesktopPosition: CompactDragSnapshot] = [:]
        for target in collapsed.newDesktopTargets {
            expanded[target.position] = layout(open: target.position, keeping: target.frame)
        }
        var variants = CompactDragVariants(collapsed: collapsed, expanded: expanded)
        if sourceWindowIndex == nil, slottedScale < collapsed.scale - 0.0001 {
            variants.slotted = layout(open: nil, keeping: nil, at: slottedScale)
        }
        return variants
    }

    /// The opened plate's drawn rectangle, when a + is open.
    var expandedNewDesktopFrame: CGRect? {
        newDesktopStageIndex.flatMap { plateFrame(stageIndex: $0, projection: projection(for: nil)) }
    }

    /// Where `stageIndex` of this snapshot stands in the model once a drop there is accepted:
    /// an opened top plate becomes the first stage.
    func modelStageIndex(forStageIndex stageIndex: Int) -> Int {
        guard stageIndex == newDesktopStageIndex else { return stageIndex }
        return expandedNewDesktop == .top ? 0 : fingerprint.stages.count
    }

    /// The stage the stack holds in focus once a window lands: the plate it joined, unless that
    /// plate is a desktop the drop created.
    func focusedStageIndex(afterDropping intent: CompactDropIntent) -> Int? {
        intent.stageIndex == newDesktopStageIndex ? nil : modelStageIndex(forStageIndex: intent.stageIndex)
    }

    static func rowWidth(_ row: [CompactCard], spacing: CGFloat) -> CGFloat {
        row.reduce(0) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * spacing
    }

    // MARK: - Projection

    private func plateWidth(rowWidths: [CGFloat]) -> CGFloat {
        max(metrics.minStageWidth, (rowWidths.max() ?? 0) + metrics.padding * 2)
    }

    /// Card centres for one row laid end to end around the stage centre, unscaled. `compress`
    /// shrinks the cards and their spacing alike, for a row making room for a held plate.
    private func centers(of row: [CompactCard], inserting width: CGFloat?, at gap: Int,
                         compress: CGFloat = 1)
        -> (cards: [CGFloat], placeholder: CGFloat?, rowWidth: CGFloat) {
        let spacing = metrics.windowSpacing * compress
        var widths = row.map { $0.width * compress }
        let width = width.map { $0 * compress }
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

    /// The widest a row may be drawn, unscaled: the usable width at the drag view's scale.
    private var widestRow: CGFloat { usableBounds.width / scale - metrics.padding * 2 }

    func projection(for intent: CompactDropIntent?) -> CompactProjection {
        var plateWidths: [CGFloat] = []
        var cardOffsets: [[CGWindowID: CGPoint]] = []
        var contentScales: [CGFloat] = []
        var placeholder: CompactPlaceholder?

        for (stageIndex, stage) in stages.enumerated() {
            var offsets: [CGWindowID: CGPoint] = [:]
            var rowWidths: [CGFloat] = []
            // A held plate aimed at itself is moving its slot, not opening a gap.
            func target(_ row: Int) -> Int? {
                intent.flatMap {
                    $0.stageIndex == stageIndex && $0.row == row
                        && !(movesWholeStage && stageIndex == sourceStageIndex) ? $0.gap : nil
                }
            }
            // An empty held plate brings no windows, so it opens no gap.
            func inserting(_ row: Int) -> CGFloat? {
                target(row) == nil || (movesWholeStage && sourceWindowIDs.isEmpty) ? nil : sourceCardWidth
            }
            // A row that cannot take a held plate's cards across the screen shrinks its cards,
            // and theirs, rather than the whole drag view; the plate keeps its place and height.
            let widest = stage.canonicalRows.indices.map {
                centers(of: stage.canonicalRows[$0], inserting: inserting($0), at: target($0) ?? 0).rowWidth
            }.max() ?? 0
            let compress = movesWholeStage && widest > widestRow && widestRow > 0
                ? widestRow / widest : 1
            for (row, cards) in stage.canonicalRows.enumerated() {
                let laid = centers(of: cards, inserting: inserting(row), at: target(row) ?? 0,
                                   compress: compress)
                let y = stage.rowOffsets[safe: row] ?? 0
                for (card, x) in zip(cards, laid.cards) {
                    offsets[card.windowID] = CGPoint(x: x, y: y)
                }
                if let x = laid.placeholder {
                    placeholder = CompactPlaceholder(
                        stageIndex: stageIndex,
                        offset: CGPoint(x: x, y: y),
                        width: sourceCardWidth * compress
                    )
                    if movesWholeStage {
                        // A held plate's cards land side by side across the gap they opened.
                        var left = x - sourceCardWidth * compress / 2
                        for card in stages[sourceStageIndex].originalRows.joined() {
                            offsets[card.windowID] = CGPoint(x: left + card.width * compress / 2, y: y)
                            left += (card.width + metrics.windowSpacing) * compress
                        }
                    } else {
                        offsets[sourceWindowID] = CGPoint(x: x, y: y)
                    }
                }
                rowWidths.append(laid.rowWidth)
            }
            if !movesWholeStage, stageIndex == sourceStageIndex, offsets[sourceWindowID] == nil {
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
            contentScales.append(compress)
        }
        return CompactProjection(
            plateWidths: plateWidths,
            cardOffsets: cardOffsets,
            placeholder: placeholder,
            stageShifts: stageShifts(slot: intent?.slot).shifts,
            contentScales: contentScales,
            slotCenterY: stageShifts(slot: intent?.slot).slotCenter
        )
    }

    /// The plates left in the stack while one is held, in order.
    var stackedPlates: [Int] {
        stages.indices.filter { !movesWholeStage || $0 != sourceStageIndex }
    }

    /// The stack order with the held plate at `slot` among the plates left.
    func plateOrder(slot: Int) -> [Int] {
        var order = stackedPlates
        order.insert(sourceStageIndex, at: min(max(0, slot), order.count))
        return order
    }

    /// Parts the plates left at `slot` to open the held plate's slot, as cards in a row part
    /// for a held card, keeping the stack centred. No slot, no parting.
    private func stageShifts(slot: Int?) -> (shifts: [CGFloat], slotCenter: CGFloat?) {
        var shifts = Array(repeating: CGFloat(0), count: stages.count)
        let plates = stackedPlates
        guard movesWholeStage, let slot,
              let top = plates.map({ stages[$0].centerY - stages[$0].baseHeight * scale / 2 }).min()
        else { return (shifts, nil) }
        let spacing = StageConstants.compactStageSpacing * metrics.scaleFactor * scale
        if slot <= 0 || slot >= plates.count {
            return endSlotShifts(atTop: slot <= 0, top: top, spacing: spacing, count: shifts.count)
        }
        var running = top - (slotHeight + spacing) / 2
        var slotCenter = running + slotHeight / 2
        for (position, index) in plates.enumerated() {
            if position == slot {
                slotCenter = running + slotHeight / 2
                running += slotHeight + spacing
            }
            let height = stages[index].baseHeight * scale
            shifts[index] = running + height / 2 - stages[index].centerY
            running += height + spacing
        }
        if slot >= plates.count { slotCenter = running + slotHeight / 2 }
        return (shifts, slotCenter)
    }

    /// A slot past either end opens outward, leaving the plates where they are measured, and
    /// moves them only as far as keeps the slot on screen. Parted like a middle slot, it was
    /// drawn over the end plate's measured place, so a drop into it merged instead.
    private func endSlotShifts(atTop: Bool, top: CGFloat, spacing: CGFloat,
                               count: Int) -> (shifts: [CGFloat], slotCenter: CGFloat?) {
        let plates = stackedPlates
        let bottom = plates.map { stages[$0].centerY + stages[$0].baseHeight * scale / 2 }.max() ?? top
        let center = atTop ? top - spacing - slotHeight / 2 : bottom + spacing + slotHeight / 2
        let shift = atTop
            ? max(0, usableBounds.minY - (center - slotHeight / 2))
            : min(0, usableBounds.maxY - (center + slotHeight / 2))
        var shifts = Array(repeating: CGFloat(0), count: count)
        for index in plates { shifts[index] = shift }
        return (shifts, center + shift)
    }

    func isEndSlot(_ intent: CompactDropIntent) -> Bool {
        guard let slot = intent.slot else { return false }
        return slot <= 0 || slot >= stackedPlates.count
    }

    /// The hole a held plate's slot opens, as drawn, reaching halfway to its neighbours.
    func openSlotFrame(for intent: CompactDropIntent) -> CGRect? {
        let drawn = projection(for: intent)
        guard intent.slot != nil, let center = drawn.slotCenterY else { return nil }
        let widths = stackedPlates.map { drawn.plateWidths[safe: $0] ?? 0 }
        guard let width = widths.max(), width > 0 else { return nil }
        let height = slotHeight + StageConstants.compactStageSpacing * metrics.scaleFactor * scale
        return CGRect(x: centerX - width * scale / 2, y: center - height / 2,
                      width: width * scale, height: height)
    }

    /// A plate's drawn rectangle in overlay coordinates.
    func plateFrame(stageIndex: Int, projection: CompactProjection) -> CGRect? {
        guard let stage = stages[safe: stageIndex],
              let width = projection.plateWidths[safe: stageIndex]
        else { return nil }
        let shift = projection.stageShifts[safe: stageIndex] ?? 0
        return CGRect(
            x: centerX - width * scale / 2,
            y: stage.centerY + shift - stage.baseHeight * scale / 2,
            width: width * scale,
            height: stage.baseHeight * scale
        )
    }

    func overlayPoint(stageIndex: Int, offset: CGPoint,
                      projection: CompactProjection? = nil) -> CGPoint? {
        guard let stage = stages[safe: stageIndex] else { return nil }
        let shift = projection?.stageShifts[safe: stageIndex] ?? 0
        return CGPoint(x: centerX + offset.x * scale, y: stage.centerY + shift + offset.y * scale)
    }

    // MARK: - Resolution

    /// The intent under `location`, resolved once against what is drawn for `current`. Blank
    /// desktop and the gaps between plates are no destination at all.
    func resolve(at location: CGPoint, current: CompactDropIntent?) -> CompactDropIntent? {
        guard location.x.isFinite, location.y.isFinite else { return nil }
        if movesWholeStage { return resolvePlate(at: location, current: current) }
        let drawn = projection(for: current)
        guard let stageIndex = stages.indices.first(where: {
            plateFrame(stageIndex: $0, projection: drawn)?.contains(location) == true
        }) else { return nil }
        return gapIntent(stageIndex: stageIndex, at: location, current: current)
    }

    /// How deep into a plate's top or bottom edge a held plate reorders rather than merges.
    static func reorderBand(plateHeight: CGFloat) -> CGFloat { min(plateHeight / 4, 24) }

    /// A held plate's target, resolved against the stack with no slot open, as it is drawn
    /// while merging: over another plate's top or bottom edge, or the room between plates, a
    /// slot opens there; over the rest of a plate it merges into the gap the pointer opens.
    /// An open slot moves the plates around it, sometimes by more than a plate's height, so
    /// measuring against the drawn slot would carry the plate the pointer heads for away from
    /// it. A plate already merging keeps the merge through the inner half of its edge bands.
    /// Anywhere above or below the stack, in its column, it goes to that end; beside the stack
    /// it has no destination.
    private func resolvePlate(at location: CGPoint, current: CompactDropIntent?) -> CompactDropIntent? {
        let slot = current?.slot
        let drawn = projection(for: slot == nil ? current : nil)
        let plates = stackedPlates
        let frames = plates.compactMap { plateFrame(stageIndex: $0, projection: drawn) }
        guard frames.count == plates.count, !frames.isEmpty,
              let left = frames.map(\.minX).min(), let right = frames.map(\.maxX).max(),
              location.x >= left, location.x <= right
        else { return nil }
        if location.y < frames[0].minY { return reorder(0) }
        if location.y > frames[frames.count - 1].maxY { return reorder(frames.count) }

        for (position, frame) in frames.enumerated() {
            let band = Self.reorderBand(plateHeight: frame.height)
            guard location.y >= frame.minY - band, location.y <= frame.maxY + band else { continue }
            let merging = slot == nil && current?.stageIndex == plates[position]
            let inner = merging ? band / 2 : band
            if location.y < frame.minY + inner { return reorder(position) }
            if location.y > frame.maxY - inner { return reorder(position + 1) }
            return gapIntent(stageIndex: plates[position], at: location,
                             current: slot == nil ? current : nil)
        }
        // Between two plates the nearer edge decides.
        guard let nearest = frames.indices.min(by: {
            min(abs(frames[$0].minY - location.y), abs(frames[$0].maxY - location.y))
                < min(abs(frames[$1].minY - location.y), abs(frames[$1].maxY - location.y))
        }) else { return nil }
        return reorder(location.y < frames[nearest].midY ? nearest : nearest + 1)
    }

    private func reorder(_ slot: Int) -> CompactDropIntent {
        CompactDropIntent(stageIndex: sourceStageIndex, spaceID: stages[sourceStageIndex].spaceID,
                          row: 0, gap: 0, logicalIndex: 0, generation: generation, slot: slot)
    }

    /// The gap the pointer opens in one plate's rows.
    private func gapIntent(stageIndex: Int, at location: CGPoint,
                           current: CompactDropIntent?) -> CompactDropIntent? {
        let stage = stages[stageIndex]
        let retained = current?.stageIndex == stageIndex ? current : nil

        let shift = projection(for: current).stageShifts[safe: stageIndex] ?? 0
        let rowCenters = stage.rowOffsets.map { stage.centerY + shift + $0 * scale }
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
        // Measured against the cards as drawn, which a plate taking a held plate's cards has
        // shrunk; the shrink does not depend on the gap, so it cannot feed back into it.
        let compress = retained == nil ? 1
            : projection(for: current).contentScales[safe: stageIndex] ?? 1
        let spacing = metrics.windowSpacing
        var running = -Self.rowWidth(cards, spacing: spacing) / 2
        let midpoints: [CGFloat] = cards.map { card in
            defer { running += card.width + spacing }
            return centerX + (running + card.width / 2) * compress * scale
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
        if movesWholeStage {
            // Its own place among the plates left is the position it was picked up from.
            return intent.stageIndex == sourceStageIndex
                && (intent.slot ?? sourceStageIndex) == sourceStageIndex
        }
        return intent.stageIndex == sourceStageIndex && intent.logicalIndex == sourceLogicalIndex
    }

    func plateRequest(for intent: CompactDropIntent) -> PlateDropRequest? {
        guard movesWholeStage, let source = stages[safe: sourceStageIndex] else { return nil }
        if intent.stageIndex == sourceStageIndex {
            let order = plateOrder(slot: intent.slot ?? sourceStageIndex)
            guard let position = order.firstIndex(of: sourceStageIndex) else { return nil }
            let predecessor = position > 0 ? stages[order[position - 1]].spaceID : nil
            return PlateDropRequest(spaceID: source.spaceID, action: .reorder(after: predecessor),
                                    fingerprint: fingerprint)
        }
        guard let destination = stages[safe: intent.stageIndex] else { return nil }
        return PlateDropRequest(
            spaceID: source.spaceID,
            action: .merge(
                into: destination.spaceID,
                placement: PointerPlacement(index: intent.logicalIndex,
                                            in: destination.canonicalWindowIDs)
            ),
            fingerprint: fingerprint
        )
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
            fingerprint: fingerprint,
            newDesktopPosition: intent.stageIndex == newDesktopStageIndex ? expandedNewDesktop : nil
        )
    }
}
