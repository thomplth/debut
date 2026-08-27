import AppKit
import SwiftUI
import CoreGraphics

enum PlateFocusTransition: Equatable {
    case spring(duration: TimeInterval, bounce: Double)
    case fade(duration: TimeInterval)

    var animation: Animation {
        switch self {
        case let .spring(duration, bounce):
            .spring(duration: duration, bounce: bounce)
        case let .fade(duration):
            .easeOut(duration: duration)
        }
    }

    var usesSpatialMotion: Bool {
        switch self {
        case .spring: true
        case .fade: false
        }
    }

    var duration: TimeInterval {
        switch self {
        case let .spring(duration, _), let .fade(duration): duration
        }
    }
}

struct PlateLift: Equatable {
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat
}

struct WindowLift: Equatable {
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat
}

struct PlateStackLayout: Equatable {
    let scales: [CGFloat]
    /// Each plate's own unscaled height. Plates wrap independently, so this is per stage rather
    /// than one shared row height.
    let baseHeights: [CGFloat]
    let heights: [CGFloat]
    let centers: [CGFloat]
    let totalHeight: CGFloat
}

struct PlateLayoutAnimationKey: Equatable {
    let stageIDs: [UUID]
    let activeStageID: UUID?
}

enum PlateEdgeScrollTarget: Equatable {
    case resting
    case top
    case bottom
}

enum PlateMotion {
    static let minimumPlateScale: CGFloat = 0.08
    static let minimumPlateOpacity: Double = 0.12
    static let opacityScaleThreshold: CGFloat = 0.2
    static let windowRemovalScale: CGFloat = 0.55

    static func layoutAnimationKey(
        stageIDs: [UUID],
        activeIndex: Int
    ) -> PlateLayoutAnimationKey {
        PlateLayoutAnimationKey(
            stageIDs: stageIDs,
            activeStageID: stageIDs.indices.contains(activeIndex) ? stageIDs[activeIndex] : nil
        )
    }

    static func focusTransition(reduceMotion: Bool) -> PlateFocusTransition {
        reduceMotion
            ? .fade(duration: 0.12)
            : .spring(duration: 0.26, bounce: 0.08)
    }

    static func windowReorderTransition(reduceMotion: Bool) -> PlateFocusTransition {
        reduceMotion
            ? .fade(duration: 0.126)
            : .spring(duration: 0.294, bounce: 0.06)
    }

    static func windowReorderTransition(
        reduceMotion: Bool,
        hasActiveDrag: Bool,
        isAwaitingCommittedLayout: Bool
    ) -> PlateFocusTransition? {
        guard hasActiveDrag, !isAwaitingCommittedLayout else { return nil }
        return windowReorderTransition(reduceMotion: reduceMotion)
    }

    /// A keyboard reorder is the one layout change with nothing to announce it: the window count
    /// is unchanged, so the removal animation cannot see it, and no drag is in flight, so the drag
    /// reorder animation is not armed. It is the exact complement of the drag case, and the two
    /// must stay mutually exclusive or a drop would be animated against its own handoff.
    static func keyboardWindowReorderTransition(
        reduceMotion: Bool,
        hasActiveDrag: Bool,
        isAwaitingCommittedLayout: Bool
    ) -> PlateFocusTransition? {
        guard !hasActiveDrag, !isAwaitingCommittedLayout else { return nil }
        return windowReorderTransition(reduceMotion: reduceMotion)
    }

    /// A window leaving the plate is the app going away, not a layout tweak, so it settles
    /// without bounce: overshoot would read as the card trying to come back.
    static func windowRemovalTransition(reduceMotion: Bool) -> PlateFocusTransition {
        reduceMotion
            ? .fade(duration: 0.12)
            : .spring(duration: 0.36, bounce: 0)
    }

    static func windowLayoutKey(for plates: [PlateData]) -> WindowLayoutKey {
        WindowLayoutKey(stageWindowIDs: plates.map { $0.windows.map(\.windowID) })
    }

    static func isWindowDropApplied(
        _ request: WindowMoveRequest,
        to layout: WindowLayoutKey
    ) -> Bool {
        guard layout.stageWindowIDs.indices.contains(request.toStageIndex),
              layout.stageWindowIDs[request.toStageIndex].indices.contains(request.toWindowIndex)
        else { return false }
        return layout.stageWindowIDs[request.toStageIndex][request.toWindowIndex]
            == request.windowID
    }

    static func lift(isActive: Bool) -> PlateLift {
        isActive
            ? PlateLift(shadowOpacity: 0.22, shadowRadius: 18, shadowY: 8)
            : PlateLift(shadowOpacity: 0.08, shadowRadius: 6, shadowY: 2)
    }

    static func plateScale(
        distanceFromFocus: Int,
        inactiveScale: CGFloat
    ) -> CGFloat {
        guard distanceFromFocus > 0 else { return 1 }
        return max(
            minimumPlateScale,
            pow(inactiveScale, CGFloat(distanceFromFocus))
        )
    }

    static func plateOpacity(scale: CGFloat) -> Double {
        guard scale < opacityScaleThreshold else { return 1 }
        let progress = Double(scale / opacityScaleThreshold)
        return max(minimumPlateOpacity, progress * progress)
    }

    /// Every candidate is pointer or drag state that can outlive the stage it named, so a
    /// candidate past the end has to be skipped rather than carried into layout: `stackLayout`
    /// answers an out-of-range focus with an empty stack, which its callers then index into.
    static func focusedStageIndex(
        active: Int,
        hovered: Int?,
        dragTarget: Int?,
        retainedDragTarget: Int?,
        stageCount: Int
    ) -> Int {
        let slots = 0..<max(0, stageCount)
        guard !slots.isEmpty else { return 0 }
        let candidate = [dragTarget, retainedDragTarget, hovered]
            .compactMap { $0 }
            .first(where: slots.contains)
        return candidate ?? min(max(active, 0), slots.upperBound - 1)
    }

    static func stackLayout(
        plateHeights: [CGFloat],
        focusIndex: Int,
        spacing: CGFloat,
        inactiveScale: CGFloat
    ) -> PlateStackLayout {
        guard plateHeights.indices.contains(focusIndex) else {
            return PlateStackLayout(
                scales: [], baseHeights: [], heights: [], centers: [], totalHeight: 0
            )
        }
        let scales = plateHeights.indices.map {
            plateScale(
                distanceFromFocus: abs($0 - focusIndex),
                inactiveScale: inactiveScale
            )
        }
        let heights = zip(plateHeights, scales).map(*)
        var runningTop: CGFloat = 0
        var centers: [CGFloat] = []
        for height in heights {
            centers.append(runningTop + height / 2)
            runningTop += height + spacing
        }
        return PlateStackLayout(
            scales: scales,
            baseHeights: plateHeights,
            heights: heights,
            centers: centers,
            totalHeight: runningTop - spacing
        )
    }

    /// Every plate lays out at its own unscaled height so the animated scale stays a render
    /// transform; this shifts the slot so the scaled plate lands on its stack center.
    static func plateSlotOffset(layout: PlateStackLayout, index: Int) -> CGFloat {
        guard layout.centers.indices.contains(index),
              layout.baseHeights.indices.contains(index)
        else { return 0 }
        return layout.centers[index] - layout.baseHeights[index] / 2
    }

    /// The outer edge of the whole stack: the top of the first plate or the bottom of the last.
    static func stackBoundary(
        edge: StageStackEdge,
        stackOffset: CGFloat,
        layout: PlateStackLayout
    ) -> CGFloat? {
        guard !layout.centers.isEmpty,
              layout.heights.count == layout.centers.count
        else { return nil }
        let index = edge == .top ? 0 : layout.centers.count - 1
        let center = stackOffset + layout.centers[index]
        let halfHeight = layout.heights[index] / 2
        return edge == .top ? center - halfHeight : center + halfHeight
    }

    static func plateFrame(
        at index: Int,
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        plateWidths: [CGFloat],
        layout: PlateStackLayout
    ) -> CGRect {
        let width = plateWidths[index] * layout.scales[index]
        let center = CGPoint(
            x: containerWidth / 2,
            y: stackOffset + layout.centers[index]
        )
        return CGRect(
            x: center.x - width / 2,
            y: center.y - layout.heights[index] / 2,
            width: width,
            height: layout.heights[index]
        )
    }

    static func anchoredOffset(
        layout: PlateStackLayout,
        anchorIndex: Int,
        anchorY: CGFloat
    ) -> CGFloat {
        guard layout.centers.indices.contains(anchorIndex) else { return 0 }
        return anchorY - layout.centers[anchorIndex]
    }

    static func edgeScrollDestination(
        pointerY: CGFloat?,
        containerHeight: CGFloat,
        restingOffset: CGFloat,
        topLimit: CGFloat,
        bottomLimit: CGFloat,
        edgeRegion: CGFloat = PlateConstants.edgeHoverRegion
    ) -> CGFloat {
        edgeScrollDestination(
            target: edgeScrollTarget(
                pointerY: pointerY,
                containerHeight: containerHeight,
                edgeRegion: edgeRegion
            ),
            restingOffset: restingOffset,
            topLimit: topLimit,
            bottomLimit: bottomLimit
        )
    }

    static func edgeScrollTarget(
        pointerY: CGFloat?,
        containerHeight: CGFloat,
        edgeRegion: CGFloat = PlateConstants.edgeHoverRegion
    ) -> PlateEdgeScrollTarget {
        guard let pointerY else { return .resting }
        if pointerY <= edgeRegion { return .top }
        if pointerY >= containerHeight - edgeRegion { return .bottom }
        return .resting
    }

    static func edgeScrollDestination(
        target: PlateEdgeScrollTarget,
        restingOffset: CGFloat,
        topLimit: CGFloat,
        bottomLimit: CGFloat
    ) -> CGFloat {
        guard topLimit > bottomLimit else { return restingOffset }
        switch target {
        case .resting: return restingOffset
        case .top: return topLimit
        case .bottom: return bottomLimit
        }
    }

    static func windowScale(isSelected: Bool, isDragging: Bool) -> CGFloat {
        if isDragging { return 0.96 }
        return isSelected ? 1.06 : 1
    }

    static func sourceWindowOpacity(isDragging: Bool) -> Double {
        isDragging ? 0 : 1
    }

    static func sourceWindowDisablesAnimation(isDragging: Bool) -> Bool {
        isDragging
    }

    static let cursorPreviewOpacity: Double = 1

    static func displayedWindowCounts(
        actual: [Int],
        drag: WindowDragState?
    ) -> [Int] {
        guard let drag,
              let target = drag.dropTarget,
              target.stageIndex != drag.sourceStageIndex,
              actual.indices.contains(drag.sourceStageIndex),
              actual.indices.contains(target.stageIndex),
              actual[drag.sourceStageIndex] > 0
        else { return actual }

        var displayed = actual
        displayed[drag.sourceStageIndex] -= 1
        displayed[target.stageIndex] += 1
        return displayed
    }

    /// The slot a card holds while a drag is in flight, or `nil` if the drag takes it off this
    /// stage entirely. Insertion is expressed against the order left behind once the dragged
    /// card is removed, which is the same contract `WindowDropTarget.windowIndex` carries.
    static func prospectiveWindowIndex(
        stageIndex: Int,
        windowIndex: Int,
        drag: WindowDragState
    ) -> Int? {
        guard let target = drag.dropTarget else { return windowIndex }

        if stageIndex == drag.sourceStageIndex, target.stageIndex == stageIndex {
            if windowIndex == drag.sourceWindowIndex { return target.windowIndex }
            var slot = windowIndex > drag.sourceWindowIndex ? windowIndex - 1 : windowIndex
            if slot >= target.windowIndex { slot += 1 }
            return slot
        }
        if stageIndex == drag.sourceStageIndex {
            guard windowIndex != drag.sourceWindowIndex else { return nil }
            return windowIndex > drag.sourceWindowIndex ? windowIndex - 1 : windowIndex
        }
        if stageIndex == target.stageIndex {
            return windowIndex >= target.windowIndex ? windowIndex + 1 : windowIndex
        }
        return nil
    }

    /// The slot a card is laid out in, which is not always the slot it is drawn in.
    ///
    /// A card leaving this stage takes its later neighbours' slots with it and the plate
    /// recentres around them, so their anchors have to move. A reorder within one stage must
    /// leave anchors alone: they are what the drop target is resolved against, and a target
    /// that moved the cards it was measured from would chase its own feedback.
    static func windowAnchorIndex(
        stageIndex: Int,
        windowIndex: Int,
        drag: WindowDragState?
    ) -> Int {
        guard let drag, let target = drag.dropTarget,
              stageIndex == drag.sourceStageIndex,
              target.stageIndex != stageIndex,
              windowIndex > drag.sourceWindowIndex
        else { return windowIndex }
        return windowIndex - 1
    }

    /// How far a card is drawn from the slot it is laid out in. Balanced rows mean a single
    /// insertion can push a card onto another row, so this is a delta between two grid
    /// positions rather than a multiple of one card's width.
    static func windowSlotOffset(
        stageIndex: Int,
        windowIndex: Int,
        drag: WindowDragState?,
        layout: PlateWindowLayout
    ) -> CGSize {
        guard let drag, drag.dropTarget != nil,
              let slot = prospectiveWindowIndex(
                  stageIndex: stageIndex,
                  windowIndex: windowIndex,
                  drag: drag
              )
        else { return .zero }

        let anchor = layout.cardOffsetFromCenter(at: windowAnchorIndex(
            stageIndex: stageIndex,
            windowIndex: windowIndex,
            drag: drag
        ))
        let drawn = layout.cardOffsetFromCenter(at: slot)
        return CGSize(
            width: drawn.width - anchor.width,
            height: drawn.height - anchor.height
        )
    }

    /// Where the released preview settles: the exact slot the destination plate has already
    /// opened for it, in the overlay's coordinate space.
    static func windowDropDestination(
        target: WindowDropTarget,
        plateFrames: [Int: CGRect],
        layouts: [PlateWindowLayout],
        scales: [CGFloat]
    ) -> CGPoint? {
        guard let plateFrame = plateFrames[target.stageIndex],
              layouts.indices.contains(target.stageIndex),
              scales.indices.contains(target.stageIndex)
        else { return nil }

        let scale = scales[target.stageIndex]
        let offset = layouts[target.stageIndex].cardOffsetFromCenter(at: target.windowIndex)
        return CGPoint(
            x: plateFrame.midX + offset.width * scale,
            y: plateFrame.midY + offset.height * scale
        )
    }

    // A black shadow over the dark plate behind it needs more density and spread to
    // read as depth than it does in light mode. macOS scales the shadow this way rather
    // than inverting it to white.
    static func windowLift(
        isSelected: Bool,
        isDragging: Bool,
        isDarkMode: Bool
    ) -> WindowLift {
        guard isSelected else {
            return WindowLift(shadowOpacity: 0, shadowRadius: 0, shadowY: 0)
        }
        let lifted = isDarkMode
            ? WindowLift(shadowOpacity: 0.5, shadowRadius: 14, shadowY: 6)
            : WindowLift(shadowOpacity: 0.24, shadowRadius: 8, shadowY: 4)
        guard !isDragging else {
            return WindowLift(
                shadowOpacity: 0,
                shadowRadius: lifted.shadowRadius,
                shadowY: lifted.shadowY
            )
        }
        return lifted
    }
}

enum PlateInteraction {
    static let minimumWindowDragDistance: CGFloat = 6

    static func isWindowClick(
        translation: CGSize,
        minimumDragDistance: CGFloat = minimumWindowDragDistance
    ) -> Bool {
        hypot(translation.width, translation.height) < minimumDragDistance
    }

    static func isDesktopArea(
        _ location: CGPoint,
        plateFrames: [Int: CGRect]
    ) -> Bool {
        guard !plateFrames.isEmpty else { return false }
        return !plateFrames.values.contains(where: { $0.contains(location) })
    }

    static func shouldMoveWindow(
        fromStageIndex: Int,
        fromWindowIndex: Int,
        to target: WindowDropTarget?
    ) -> Bool {
        guard let target else { return false }
        return target.stageIndex != fromStageIndex
            || target.windowIndex != fromWindowIndex
    }

    static func finishWindowDrag(
        _ windowDrag: inout WindowDragState?
    ) -> WindowMoveRequest? {
        guard let completedDrag = windowDrag else { return nil }
        windowDrag = nil
        return windowMoveRequest(for: completedDrag)
    }

    static func windowMoveRequest(for completedDrag: WindowDragState) -> WindowMoveRequest? {
        guard shouldMoveWindow(
            fromStageIndex: completedDrag.sourceStageIndex,
            fromWindowIndex: completedDrag.sourceWindowIndex,
            to: completedDrag.dropTarget
        ), let target = completedDrag.dropTarget
        else { return nil }
        return WindowMoveRequest(
            windowID: completedDrag.windowID,
            fromStageIndex: completedDrag.sourceStageIndex,
            fromWindowIndex: completedDrag.sourceWindowIndex,
            toStageIndex: target.stageIndex,
            toWindowIndex: target.windowIndex
        )
    }

    static func windowDropTarget(
        at location: CGPoint,
        sourceStageIndex: Int,
        sourceWindowIndex: Int,
        plateFrames: [Int: CGRect],
        windowFrames: [WindowFrameID: CGRect]
    ) -> WindowDropTarget? {
        guard let stageIndex = plateFrames.keys.sorted().first(where: {
            plateFrames[$0]?.contains(location) == true
        }) else { return nil }

        let destinationFrames = windowFrames
            .filter { id, _ in
                id.stageIndex == stageIndex
                    && !(stageIndex == sourceStageIndex && id.windowIndex == sourceWindowIndex)
            }
            .sorted { $0.key.windowIndex < $1.key.windowIndex }
            .map(\.value)
        let rows = cardRows(destinationFrames)

        guard let rowIndex = rowIndex(at: location.y, rows: rows) else {
            return WindowDropTarget(stageIndex: stageIndex, windowIndex: 0)
        }
        let row = rows[rowIndex]
        let withinRow = row.firstIndex(where: { location.x < $0.midX }) ?? row.count
        let precedingCards = rows.prefix(rowIndex).reduce(0) { $0 + $1.count }
        return WindowDropTarget(
            stageIndex: stageIndex,
            windowIndex: precedingCards + withinRow
        )
    }

    /// Groups row-major card frames into their rendered rows. A wrapped plate has no other
    /// record of where its rows fell by the time the pointer needs one.
    private static func cardRows(_ frames: [CGRect]) -> [[CGRect]] {
        var rows: [[CGRect]] = []
        for frame in frames {
            if let current = rows.last?.first,
               abs(current.midY - frame.midY) < current.height / 2 {
                rows[rows.count - 1].append(frame)
            } else {
                rows.append([frame])
            }
        }
        return rows
    }

    /// The row the pointer is over, or the nearest one when it sits in the gap between rows or
    /// past the last. Space between rows must resolve to a slot, not to nothing.
    private static func rowIndex(at y: CGFloat, rows: [[CGRect]]) -> Int? {
        guard !rows.isEmpty else { return nil }
        if let containing = rows.firstIndex(where: { row in
            row.contains { $0.minY <= y && y <= $0.maxY }
        }) {
            return containing
        }
        return rows.indices.min(by: { lhs, rhs in
            let lhsDistance = rows[lhs].map { abs($0.midY - y) }.min() ?? .greatestFiniteMagnitude
            let rhsDistance = rows[rhs].map { abs($0.midY - y) }.min() ?? .greatestFiniteMagnitude
            return lhsDistance < rhsDistance
        })
    }

    /// Whether the pointer is over a plate or over the bare overlay around it. The desktop
    /// fall-through lives off-plate and is invisible to diagnostics until something reports that
    /// the pointer reached that region at all.
    static func pointerRegion(at location: CGPoint, plateFrames: [Int: CGRect]) -> String {
        plateFrames.values.contains { $0.contains(location) } ? "plate" : "outside"
    }

    /// What a tap on the overlay container meant. A tap that resolves to nothing is otherwise
    /// indistinguishable from a tap that never arrived.
    static func overlayTapTarget(
        at location: CGPoint,
        plateFrames: [Int: CGRect]
    ) -> OverlayTapTarget {
        isDesktopArea(location, plateFrames: plateFrames) ? .desktop : .none
    }

    /// Stage scrolling is available across the entire overlay, including the bare desktop around
    /// the rendered plates.
    static func isInStageScrollArea(
        _ location: CGPoint,
        containerSize: CGSize
    ) -> Bool {
        guard containerSize.width > 0, containerSize.height > 0 else { return false }
        return CGRect(origin: .zero, size: containerSize).contains(location)
    }

    /// Scrolling stops at the ends rather than wrapping, so a long flick cannot land somewhere
    /// unrelated to where it started. A move to where the selection already is means no move.
    static func stageScrollDestination(current: Int, steps: Int, stageCount: Int) -> Int? {
        guard stageCount > 0, steps != 0 else { return nil }
        let target = min(max(current - steps, 0), stageCount - 1)
        return target == current ? nil : target
    }

    static func pointerSelection(
        current: PointerSelection?,
        target: PointerSelection,
        isHovering: Bool
    ) -> PointerSelection? {
        if isHovering { return target }
        return current == target ? nil : current
    }

    static func stageIndex(
        at location: CGPoint,
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        plateWidths: [CGFloat],
        layout: PlateStackLayout
    ) -> Int? {
        guard plateWidths.count == layout.centers.count else { return nil }
        for index in layout.centers.indices {
            let frame = PlateMotion.plateFrame(
                at: index,
                containerWidth: containerWidth,
                stackOffset: stackOffset,
                plateWidths: plateWidths,
                layout: layout
            )
            if frame.contains(location) { return index }
        }
        return nil
    }

    static func hoveredStageIndex(
        previous: Int?,
        at location: CGPoint,
        containerWidth: CGFloat,
        currentStackOffset: CGFloat,
        plateWidths: [CGFloat],
        currentLayout: PlateStackLayout
    ) -> Int? {
        guard plateWidths.count == currentLayout.centers.count,
              currentLayout.scales.count == currentLayout.centers.count,
              currentLayout.heights.count == currentLayout.centers.count
        else { return nil }

        if let hit = stageIndex(
            at: location,
            containerWidth: containerWidth,
            stackOffset: currentStackOffset,
            plateWidths: plateWidths,
            layout: currentLayout
        ) {
            return hit
        }

        for upperIndex in currentLayout.centers.indices.dropLast() {
            let lowerIndex = upperIndex + 1
            let upperFrame = PlateMotion.plateFrame(
                at: upperIndex,
                containerWidth: containerWidth,
                stackOffset: currentStackOffset,
                plateWidths: plateWidths,
                layout: currentLayout
            )
            let lowerFrame = PlateMotion.plateFrame(
                at: lowerIndex,
                containerWidth: containerWidth,
                stackOffset: currentStackOffset,
                plateWidths: plateWidths,
                layout: currentLayout
            )
            let gapHeight = lowerFrame.minY - upperFrame.maxY
            guard gapHeight > 0,
                  location.y >= upperFrame.maxY,
                  location.y <= lowerFrame.minY
            else { continue }

            let progress = (location.y - upperFrame.maxY) / gapHeight
            let halfWidth = upperFrame.width / 2
                + (lowerFrame.width / 2 - upperFrame.width / 2) * progress
            if abs(location.x - containerWidth / 2) <= halfWidth {
                return previous
            }
        }

        return nil
    }

}

enum OverlayTapTarget: Equatable {
    case desktop
    case none

    var diagnosticName: String {
        switch self {
        case .desktop: "desktop"
        case .none: "none"
        }
    }
}

/// Everything needed to explain, after the fact, why a tap on the overlay did what it did.
struct OverlayTapDiagnostic {
    let location: CGPoint
    let target: OverlayTapTarget
}

/// Every stage of a scroll's journey: where it landed, whether that counted as the stack, and
/// what it did. A scroll that changes nothing is otherwise indistinguishable from one the window
/// never received.
struct OverlayScrollDiagnostic {
    let location: CGPoint
    let deltaY: CGFloat
    let isInScrollArea: Bool
    let steps: Int
    let destination: Int?
}

/// Where the pointer is relative to the plates, plus the outer edges of the stack, so a pointer
/// that seems to be nowhere can be placed against the geometry it was measured in.
struct OverlayPointerRegionDiagnostic {
    let region: String
    let location: CGPoint
    let topBoundary: CGFloat?
    let bottomBoundary: CGFloat?
}

/// A wheel reports whole notches and a trackpad a stream of points, and both have to become
/// whole stage steps. The leftover travel has to survive between events, or a slow scroll would
/// never accumulate into a step at all.
struct StageScrollAccumulator {
    private var travel: CGFloat = 0

    mutating func steps(deltaY: CGFloat, isPrecise: Bool) -> Int {
        travel += isPrecise ? deltaY : deltaY * PlateConstants.stageScrollTravelPerStage
        let whole = (travel / PlateConstants.stageScrollTravelPerStage).rounded(.towardZero)
        travel -= whole * PlateConstants.stageScrollTravelPerStage
        return Int(whole)
    }

    /// A gesture starts from rest, so a flick left over from the last one cannot leak into it.
    mutating func reset() {
        travel = 0
    }
}

struct PointerMovementGate {
    private var initialLocation: CGPoint?
    private(set) var hasMoved = false

    init(initialLocation: CGPoint? = nil) {
        self.initialLocation = initialLocation
    }

    mutating func reset(at location: CGPoint) {
        initialLocation = location
        hasMoved = false
    }

    mutating func observe(at location: CGPoint) -> Bool {
        if hasMoved { return true }
        guard let initialLocation else {
            reset(at: location)
            return false
        }
        hasMoved = initialLocation != location
        return hasMoved
    }
}

/// Overlay-wide geometry. Everything a single window card is made of lives in `PlateMetrics`.
public struct PlateConstants {
    public static let screenMargin: CGFloat = 80
    public static let compactStageSpacing: CGFloat = 14
    public static let stageSpacing: CGFloat = 34
    public static let commandHintFooterOffset: CGFloat = 24
    public static let edgeHoverRegion: CGFloat = 56
    public static let edgeScrollMargin: CGFloat = 28
    public static let stageScrollTravelPerStage: CGFloat = 30

    /// The width a plate may occupy before its windows wrap onto another row.
    public static func availablePlateWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth - screenMargin * 2
    }

    public static func plateLayouts(
        forWindowCounts counts: [Int],
        screenWidth: CGFloat,
        metrics: PlateMetrics = .standard
    ) -> [PlateWindowLayout] {
        let availableWidth = availablePlateWidth(screenWidth: screenWidth)
        return counts.map {
            PlateWindowLayout(
                windowCount: $0,
                availableWidth: availableWidth,
                metrics: metrics
            )
        }
    }

    public static func stageSpacing(hasVisibleFooterHints: Bool) -> CGFloat {
        hasVisibleFooterHints ? stageSpacing : compactStageSpacing
    }

    public static func plateCenterY(
        stageIndex: Int,
        plateHeights: [CGFloat],
        activeStageIndex: Int,
        inactiveScale: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat? {
        guard plateHeights.indices.contains(stageIndex),
              plateHeights.indices.contains(activeStageIndex)
        else { return nil }

        let layout = PlateMotion.stackLayout(
            plateHeights: plateHeights,
            focusIndex: activeStageIndex,
            spacing: stageSpacing,
            inactiveScale: inactiveScale
        )
        return containerHeight / 2
            - layout.centers[activeStageIndex]
            + layout.centers[stageIndex]
    }

    /// Where a window card is drawn, for callers outside the view hierarchy. E2E clicks and drags
    /// real screen coordinates; a second copy of the grid math there drifts from what the overlay
    /// draws without either side failing.
    public static func windowCardCenter(
        stageIndex: Int,
        windowIndex: Int,
        windowCounts: [Int],
        activeStageIndex: Int,
        inactiveScale: CGFloat,
        containerSize: CGSize,
        metrics: PlateMetrics = .standard
    ) -> CGPoint? {
        let layouts = plateLayouts(
            forWindowCounts: windowCounts,
            screenWidth: containerSize.width,
            metrics: metrics
        )
        guard layouts.indices.contains(stageIndex),
              (0..<windowCounts[stageIndex]).contains(windowIndex),
              let centerY = plateCenterY(
                  stageIndex: stageIndex,
                  plateHeights: layouts.map(\.plateSize.height),
                  activeStageIndex: activeStageIndex,
                  inactiveScale: inactiveScale,
                  containerHeight: containerSize.height
              )
        else { return nil }

        let scale = PlateMotion.plateScale(
            distanceFromFocus: abs(stageIndex - activeStageIndex),
            inactiveScale: inactiveScale
        )
        let offset = layouts[stageIndex].cardOffsetFromCenter(at: windowIndex)
        return CGPoint(
            x: containerSize.width / 2 + offset.width * scale,
            y: centerY + offset.height * scale
        )
    }
}

public struct OverlaySwiftUIView: View {
    public let viewModel: OverlayViewModel
    public var onWindowSelected: ((Int, Int) -> Void)?
    public var onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)?
    public var onPointerSelectionChanged: ((Int?, Int?) -> Void)?
    public var onDesktopSelected: (() -> Void)?
    var onOverlayTapRouted: ((OverlayTapDiagnostic) -> Void)?
    var onStageScrollSelected: ((Int) -> Void)?
    var onStageScrollRouted: ((OverlayScrollDiagnostic) -> Void)?
    var scrollRelay: OverlayScrollRelay?
    var onOverlayPointerRegionChanged: ((OverlayPointerRegionDiagnostic) -> Void)?

    @State private var windowDrag: WindowDragState?
    @State private var settlingWindowDrop: WindowDropSettlingState?
    @State private var retainedWindowDragFocusStageIndex: Int?
    @State private var pointerSelection: PointerSelection?
    @State private var reportedPointerRegion: String?
    @State private var pointerMovementGate: PointerMovementGate
    @State private var plateFrames: [Int: CGRect] = [:]
    @State private var windowFrames: [WindowFrameID: CGRect] = [:]
    @State private var hoveredStageIndex: Int?
    @State private var hoverPointerY: CGFloat?
    @State private var scrollAccumulator = StageScrollAccumulator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        viewModel: OverlayViewModel,
        onWindowSelected: ((Int, Int) -> Void)? = nil,
        onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)? = nil,
        onPointerSelectionChanged: ((Int?, Int?) -> Void)? = nil,
        onDesktopSelected: (() -> Void)? = nil
    ) {
        self.init(
            viewModel: viewModel,
            initialWindowDrag: nil,
            onWindowSelected: onWindowSelected,
            onWindowMoved: onWindowMoved,
            onPointerSelectionChanged: onPointerSelectionChanged,
            onDesktopSelected: onDesktopSelected
        )
    }

    init(
        viewModel: OverlayViewModel,
        initialWindowDrag: WindowDragState,
        onWindowSelected: ((Int, Int) -> Void)? = nil,
        onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)? = nil,
        onPointerSelectionChanged: ((Int?, Int?) -> Void)? = nil,
        onDesktopSelected: (() -> Void)? = nil
    ) {
        self.init(
            viewModel: viewModel,
            initialWindowDrag: WindowDragState?(initialWindowDrag),
            onWindowSelected: onWindowSelected,
            onWindowMoved: onWindowMoved,
            onPointerSelectionChanged: onPointerSelectionChanged,
            onDesktopSelected: onDesktopSelected
        )
    }

    private init(
        viewModel: OverlayViewModel,
        initialWindowDrag: WindowDragState?,
        onWindowSelected: ((Int, Int) -> Void)?,
        onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)?,
        onPointerSelectionChanged: ((Int?, Int?) -> Void)?,
        onDesktopSelected: (() -> Void)?
    ) {
        self.viewModel = viewModel
        self.onWindowSelected = onWindowSelected
        self.onWindowMoved = onWindowMoved
        self.onPointerSelectionChanged = onPointerSelectionChanged
        self.onDesktopSelected = onDesktopSelected
        _windowDrag = State(initialValue: initialWindowDrag)
        _pointerMovementGate = State(
            initialValue: PointerMovementGate(initialLocation: NSEvent.mouseLocation)
        )
    }

    public var body: some View {
        let plates = viewModel.plates
        let windowLayoutKey = PlateMotion.windowLayoutKey(for: plates)
        let hasCommittedSettlingDrop = settlingWindowDrop.map {
            PlateMotion.isWindowDropApplied($0.request, to: windowLayoutKey)
        } ?? false
        let layoutWindowDrag = hasCommittedSettlingDrop ? nil : windowDrag
        let displayedWindowCounts = PlateMotion.displayedWindowCounts(
            actual: plates.map(\.windows.count),
            drag: layoutWindowDrag
        )
        let activeStageIndex = viewModel.activeStageIndex
        let activePlate = plates[safe: activeStageIndex]
        let activeSelectedWindowIndex = pointerSelection?.stageIndex == activeStageIndex
            ? pointerSelection?.windowIndex
            : viewModel.selectedWindowIndex
        let activeFooterHints = activePlate.map { plate in
            CommandHintCatalog.plateFooterHints(
                stageIndex: activeStageIndex,
                isActive: true,
                hasSelectedWindow: activeSelectedWindowIndex != nil
                    && !plate.windows.isEmpty,
                settings: viewModel.appearance
            )
        } ?? []

        GeometryReader { geo in
            let metrics = PlateMetrics.standard
            // Two grids per stage: the one its own cards rest in, and the one the drag would
            // give it. A card's drag offset is the delta between them.
            let displayedLayouts = PlateConstants.plateLayouts(
                forWindowCounts: displayedWindowCounts,
                screenWidth: geo.size.width,
                metrics: metrics
            )
            let plateWidths = displayedLayouts.map(\.plateSize.width)
            let plateHeights = displayedLayouts.map(\.plateSize.height)
            let tallestPlateHeight = plateHeights.max() ?? 0

            let inactiveScale = CGFloat(viewModel.appearance.inactivePlateScale)
            let spacing = PlateConstants.stageSpacing(
                hasVisibleFooterHints: !activeFooterHints.isEmpty
            )
            let focusTransition = PlateMotion.focusTransition(reduceMotion: reduceMotion)
            let layoutAnimationKey = PlateMotion.layoutAnimationKey(
                stageIDs: plates.map(\.id),
                activeIndex: viewModel.activeStageIndex
            )
            let windowReorderTransition = PlateMotion.windowReorderTransition(
                reduceMotion: reduceMotion
            )
            let activeWindowReorderTransition = PlateMotion.windowReorderTransition(
                reduceMotion: reduceMotion,
                hasActiveDrag: layoutWindowDrag != nil,
                isAwaitingCommittedLayout: settlingWindowDrop != nil
            )
            let keyboardWindowReorderTransition = PlateMotion.keyboardWindowReorderTransition(
                reduceMotion: reduceMotion,
                hasActiveDrag: layoutWindowDrag != nil,
                isAwaitingCommittedLayout: settlingWindowDrop != nil
            )
            let dragTargetIndex = layoutWindowDrag?.dropTarget?.stageIndex
            let focusedStageIndex = PlateMotion.focusedStageIndex(
                active: viewModel.activeStageIndex,
                hovered: hoveredStageIndex,
                dragTarget: dragTargetIndex,
                retainedDragTarget: retainedWindowDragFocusStageIndex,
                stageCount: plates.count
            )
            let baselineLayout = PlateMotion.stackLayout(
                plateHeights: plateHeights,
                focusIndex: viewModel.activeStageIndex,
                spacing: spacing,
                inactiveScale: inactiveScale
            )
            let visualLayout = PlateMotion.stackLayout(
                plateHeights: plateHeights,
                focusIndex: focusedStageIndex,
                spacing: spacing,
                inactiveScale: inactiveScale
            )
            let baselineOffset = geo.size.height / 2
                - baselineLayout.centers[viewModel.activeStageIndex]
            let anchorY = baselineOffset + baselineLayout.centers[focusedStageIndex]
            let restingOffset = PlateMotion.anchoredOffset(
                layout: visualLayout,
                anchorIndex: focusedStageIndex,
                anchorY: anchorY
            )
            let edgeScrollTarget = PlateMotion.edgeScrollTarget(
                pointerY: hoveredStageIndex == nil ? nil : hoverPointerY,
                containerHeight: geo.size.height
            )
            let yOffset = PlateMotion.edgeScrollDestination(
                target: edgeScrollTarget,
                restingOffset: restingOffset,
                topLimit: PlateConstants.edgeScrollMargin,
                bottomLimit: geo.size.height - PlateConstants.edgeScrollMargin
                    - visualLayout.totalHeight
            )

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .top) {
                    ForEach(Array(plates.enumerated()), id: \.element.id) { index, plate in
                        let plateWidth = plateWidths[index]
                        let plateHeight = plateHeights[index]
                        let isActive = index == viewModel.activeStageIndex
                        let isInteractionTarget = index == focusedStageIndex
                        let scale = visualLayout.scales[index]
                        let slotOffset = PlateMotion.plateSlotOffset(
                            layout: visualLayout,
                            index: index
                        )
                        let plateOpacity = PlateMotion.plateOpacity(scale: scale)
                        let lift = PlateMotion.lift(isActive: isInteractionTarget)
                        let selectedWindowIndex = pointerSelection?.stageIndex == index
                            ? pointerSelection?.windowIndex
                            : (isActive ? viewModel.selectedWindowIndex : nil)
                        let stageNumberHint = CommandHintCatalog.stageNumberHint(
                            stageIndex: index,
                            settings: viewModel.appearance
                        )
                        let footerHints = isActive ? activeFooterHints : []

                        PlateSwiftUIView(
                            plate: plate,
                            selectedWindowIndex: selectedWindowIndex,
                            layout: displayedLayouts[index],
                            appearance: viewModel.appearance,
                            wallpaperLuminance: viewModel.wallpaperLuminance,
                            stageNumberHint: stageNumberHint,
                            footerHints: footerHints,
                            windowDrag: $windowDrag,
                            layoutWindowDrag: layoutWindowDrag,
                            settlingWindowID: settlingWindowDrop?.request.windowID,
                            plateFrames: $plateFrames,
                            windowFrames: $windowFrames,
                            stageIndex: index,
                            onPointerSelectionChanged: { selection, isHovering, location in
                                if isHovering && !pointerMovementGate.observe(at: location) {
                                    return
                                }
                                let nextSelection = PlateInteraction.pointerSelection(
                                    current: pointerSelection,
                                    target: selection,
                                    isHovering: isHovering
                                )
                                guard nextSelection != pointerSelection else { return }
                                pointerSelection = nextSelection
                                onPointerSelectionChanged?(
                                    nextSelection?.stageIndex,
                                    nextSelection?.windowIndex
                                )
                            },
                            onWindowSelected: onWindowSelected,
                            onWindowDropRequested: { request in
                                finishWindowDrop(
                                    request,
                                    transition: windowReorderTransition,
                                    layouts: displayedLayouts,
                                    scales: visualLayout.scales
                                )
                            }
                        )
                        .frame(width: plateWidth, height: plateHeight)
                        .background {
                            PlateSurfaceView(
                                stageIndex: index,
                                size: CGSize(width: plateWidth, height: plateHeight),
                                cornerRadius: CGFloat(viewModel.appearance.plateCornerRadius),
                                appearance: viewModel.appearance
                            )
                        }
                        .background(
                            GeometryReader { plateGeo in
                                Color.clear.preference(
                                    key: PlateFramePreferenceKey.self,
                                    value: [index: plateGeo.frame(in: .named("overlay"))]
                                )
                            }
                        )
                        .scaleEffect(scale)
                        .shadow(
                            color: .black.opacity(lift.shadowOpacity),
                            radius: lift.shadowRadius,
                            y: lift.shadowY
                        )
                        .opacity(plateOpacity)
                        .offset(y: slotOffset)
                        .zIndex(isActive || isInteractionTarget ? 2 : 0)
                    }
                }
                .frame(width: geo.size.width, height: tallestPlateHeight, alignment: .top)
                .offset(y: yOffset)

                if viewModel.shouldShowDisplayStackIndicator {
                    HStack(spacing: 8) {
                        Text(viewModel.displayStackName)
                            .fontWeight(.semibold)
                        Text("\(viewModel.displayStackPosition) of \(viewModel.displayStackCount)")
                            .foregroundStyle(.secondary)
                        if !viewModel.displayStackShortcut.isEmpty {
                            HStack(spacing: viewModel.displayStackShortcutSpacing) {
                                Text("⌘")
                                Text(viewModel.displayStackShortcut)
                            }
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.18), in: Capsule())
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .frame(width: geo.size.width)
                    .padding(.top, viewModel.displayStackIndicatorTopPadding)
                    .allowsHitTesting(false)
                    .accessibilityLabel(
                        "\(viewModel.displayStackName), display stack "
                            + "\(viewModel.displayStackPosition) of \(viewModel.displayStackCount)"
                    )
                    .zIndex(4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // The frame above only grows the layout bounds; hit testing still follows the drawn
            // plates. Everything the stage buttons need lives in the space it adds — the insert
            // band beyond the stack, the outer half of the corner delete button, the desktop
            // fall-through — so without a content shape none of it can be hovered or clicked.
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let settlingWindowDrop {
                    WindowPreviewView(
                        window: settlingWindowDrop.window,
                        isWindowSelected: true,
                        isDragging: true,
                        metrics: metrics,
                        appearance: viewModel.appearance
                    )
                    .opacity(PlateMotion.cursorPreviewOpacity)
                    .position(settlingWindowDrop.destination)
                    .allowsHitTesting(false)
                } else if let drag = windowDrag,
                   let plate = plates[safe: drag.sourceStageIndex],
                   let window = plate.windows[safe: drag.sourceWindowIndex] {
                    WindowPreviewView(
                        window: window,
                        isWindowSelected: true,
                        isDragging: true,
                        metrics: metrics,
                        appearance: viewModel.appearance
                    )
                    .opacity(PlateMotion.cursorPreviewOpacity)
                    .position(drag.location)
                    .allowsHitTesting(false)
                }
            }
            .id(focusTransition.usesSpatialMotion ? -1 : viewModel.activeStageIndex)
            .transition(focusTransition.usesSpatialMotion ? .identity : .opacity)
            .animation(focusTransition.animation, value: layoutAnimationKey)
            .animation(focusTransition.animation, value: focusedStageIndex)
            .animation(focusTransition.animation, value: pointerSelection)
            .animation(activeWindowReorderTransition?.animation, value: layoutWindowDrag?.dropTarget)
            .animation(keyboardWindowReorderTransition?.animation, value: windowLayoutKey)
            .coordinateSpace(name: "overlay")
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("overlay"))
                    .onEnded { event in
                        let target = PlateInteraction.overlayTapTarget(
                            at: event.location,
                            plateFrames: plateFrames
                        )
                        onOverlayTapRouted?(OverlayTapDiagnostic(
                            location: event.location,
                            target: target
                        ))
                        switch target {
                        case .desktop:
                            onDesktopSelected?()
                        case .none:
                            break
                        }
                    }
            )
            .onChange(of: scrollRelay?.latest) { _, event in
                if let event { handleStageScroll(event, containerSize: geo.size) }
            }
            .onPreferenceChange(PlateFramePreferenceKey.self) { frames in
                plateFrames = frames
            }
            .onPreferenceChange(WindowFramePreferenceKey.self) { frames in
                windowFrames = frames
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    hoverPointerY = location.y
                    let region = PlateInteraction.pointerRegion(
                        at: location,
                        plateFrames: plateFrames
                    )
                    if region != reportedPointerRegion {
                        reportedPointerRegion = region
                        onOverlayPointerRegionChanged?(OverlayPointerRegionDiagnostic(
                            region: region,
                            location: location,
                            topBoundary: PlateMotion.stackBoundary(
                                edge: .top, stackOffset: yOffset, layout: visualLayout
                            ),
                            bottomBoundary: PlateMotion.stackBoundary(
                                edge: .bottom, stackOffset: yOffset, layout: visualLayout
                            )
                        ))
                    }
                    guard pointerMovementGate.observe(at: NSEvent.mouseLocation) else {
                        return
                    }
                    if settlingWindowDrop == nil {
                        retainedWindowDragFocusStageIndex = nil
                    }
                    hoveredStageIndex = PlateInteraction.hoveredStageIndex(
                        previous: hoveredStageIndex,
                        at: location,
                        containerWidth: geo.size.width,
                        currentStackOffset: yOffset,
                        plateWidths: plateWidths,
                        currentLayout: visualLayout
                    )
                case .ended:
                    hoverPointerY = nil
                    hoveredStageIndex = nil
                    if reportedPointerRegion != "ended" {
                        reportedPointerRegion = "ended"
                        onOverlayPointerRegionChanged?(OverlayPointerRegionDiagnostic(
                            region: "ended", location: .zero,
                            topBoundary: nil, bottomBoundary: nil
                        ))
                    }
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 1.15),
                value: edgeScrollTarget
            )
            .onChange(of: viewModel.activeStageIndex) { _, _ in
                hoveredStageIndex = nil
                hoverPointerY = nil
            }
            .onChange(of: windowLayoutKey) { _, committedLayout in
                finishWindowDropHandoff(ifAppliedTo: committedLayout)
            }
            .onAppear {
                finishWindowDropHandoff(ifAppliedTo: windowLayoutKey)
            }
        }
    }

    private func finishWindowDrop(
        _ request: WindowMoveRequest,
        transition: PlateFocusTransition,
        layouts: [PlateWindowLayout],
        scales: [CGFloat]
    ) {
        guard let drag = windowDrag,
              let target = drag.dropTarget,
              let plate = viewModel.plates[safe: drag.sourceStageIndex],
              let window = plate.windows[safe: drag.sourceWindowIndex],
              let destination = PlateMotion.windowDropDestination(
                  target: target,
                  plateFrames: plateFrames,
                  layouts: layouts,
                  scales: scales
              )
        else {
            commitWindowDrop(request)
            return
        }

        retainedWindowDragFocusStageIndex = target.stageIndex

        withAnimation(transition.animation) {
            windowDrag?.location = destination
        } completion: {
            settlingWindowDrop = WindowDropSettlingState(
                request: request,
                window: window,
                destination: destination
            )
            onWindowMoved?(
                request.windowID,
                request.fromStageIndex,
                request.fromWindowIndex,
                request.toStageIndex,
                request.toWindowIndex
            )
        }
    }

    private func commitWindowDrop(_ request: WindowMoveRequest) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            windowDrag = nil
            onWindowMoved?(
                request.windowID,
                request.fromStageIndex,
                request.fromWindowIndex,
                request.toStageIndex,
                request.toWindowIndex
            )
        }
    }

    private func finishWindowDropHandoff(ifAppliedTo layout: WindowLayoutKey) {
        guard let settlingWindowDrop,
              PlateMotion.isWindowDropApplied(settlingWindowDrop.request, to: layout)
        else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            windowDrag = nil
            self.settlingWindowDrop = nil
        }
    }

    /// Reported at every stage, because a scroll that changes nothing is otherwise
    /// indistinguishable from a scroll the window never received.
    private func handleStageScroll(_ event: OverlayScrollEvent, containerSize: CGSize) {
        if event.isGestureStart { scrollAccumulator.reset() }
        let inArea = windowDrag == nil
            && PlateInteraction.isInStageScrollArea(
                event.location,
                containerSize: containerSize
            )
        let steps = inArea
            ? scrollAccumulator.steps(deltaY: event.deltaY, isPrecise: event.isPrecise)
            : 0
        let destination = PlateInteraction.stageScrollDestination(
            current: viewModel.activeStageIndex,
            steps: steps,
            stageCount: viewModel.plates.count
        )

        onStageScrollRouted?(OverlayScrollDiagnostic(
            location: event.location,
            deltaY: event.deltaY,
            isInScrollArea: inArea,
            steps: steps,
            destination: destination
        ))

        guard let destination else { return }
        // The stack re-lays out under a stationary pointer, and whichever plate lands beneath it
        // would otherwise take the magnify straight back off the stage the scroll just chose.
        hoveredStageIndex = nil
        pointerMovementGate.reset(at: NSEvent.mouseLocation)
        onStageScrollSelected?(destination)
    }
}

struct PlateSwiftUIView: View {
    let plate: PlateData
    let selectedWindowIndex: Int?
    let layout: PlateWindowLayout
    let appearance: AppSettings
    let wallpaperLuminance: Double?
    let stageNumberHint: CommandHintPresentation?
    let footerHints: [CommandHintPresentation]
    @Binding var windowDrag: WindowDragState?
    let layoutWindowDrag: WindowDragState?
    let settlingWindowID: CGWindowID?
    @Binding var plateFrames: [Int: CGRect]
    @Binding var windowFrames: [WindowFrameID: CGRect]
    let stageIndex: Int
    var onPointerSelectionChanged: ((PointerSelection, Bool, CGPoint) -> Void)?
    var onWindowSelected: ((Int, Int) -> Void)?
    var onWindowDropRequested: ((WindowMoveRequest) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var removalTransition: PlateFocusTransition {
        PlateMotion.windowRemovalTransition(reduceMotion: reduceMotion)
    }

    var body: some View {
        // Cards are placed, not stacked and nudged: `.offset` is a render transform, so a grid
        // built from it would report every card at the plate's centre and leave drop targeting
        // with nothing to aim at.
        GeometryReader { plateGeo in
            let plateCenter = CGPoint(
                x: plateGeo.size.width / 2,
                y: plateGeo.size.height / 2
            )
            ZStack(alignment: .topLeading) {
                if plate.windows.isEmpty {
                    Text("Empty")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .position(plateCenter)
                } else {
                    ForEach(Array(plate.windows.enumerated()), id: \.element.id) { index, window in
                        let isDragging = layoutWindowDrag?.sourceStageIndex == stageIndex
                            && layoutWindowDrag?.sourceWindowIndex == index
                        let isSettling = settlingWindowID == window.windowID
                        let anchorOffset = layout.cardOffsetFromCenter(
                            at: PlateMotion.windowAnchorIndex(
                                stageIndex: stageIndex,
                                windowIndex: index,
                                drag: layoutWindowDrag
                            )
                        )
                        let dragOffset = PlateMotion.windowSlotOffset(
                            stageIndex: stageIndex,
                            windowIndex: index,
                            drag: layoutWindowDrag,
                            layout: layout
                        )
                        WindowPreviewView(
                            window: window,
                            isWindowSelected: selectedWindowIndex == index,
                            isDragging: isDragging,
                            metrics: layout.metrics,
                            appearance: appearance,
                            commandHints: CommandHintCatalog.windowHints(
                                windowIndex: index,
                                selectedWindowIndex: selectedWindowIndex ?? -1,
                                windowCount: plate.windows.count,
                                settings: appearance
                            )
                        )
                        .opacity(PlateMotion.sourceWindowOpacity(
                            isDragging: isDragging || isSettling
                        ))
                        .transaction { transaction in
                            if PlateMotion.sourceWindowDisablesAnimation(
                                isDragging: isDragging || isSettling
                            ) {
                                transaction.animation = nil
                            }
                        }
                        // The drag reflow stays a render transform on purpose, and the frame
                        // anchor is read outside it: the reported frames are the resting slots
                        // the drop target is resolved against.
                        .offset(dragOffset)
                        .background(
                            GeometryReader { windowGeo in
                                Color.clear.preference(
                                    key: WindowFramePreferenceKey.self,
                                    value: [
                                        WindowFrameID(
                                            stageIndex: stageIndex,
                                            windowIndex: index
                                        ): windowGeo.frame(in: .named("overlay"))
                                    ]
                                )
                            }
                        )
                        .onContinuousHover { phase in
                            let selection = PointerSelection(
                                stageIndex: stageIndex,
                                windowIndex: index
                            )
                            switch phase {
                            case .active:
                                onPointerSelectionChanged?(
                                    selection,
                                    true,
                                    NSEvent.mouseLocation
                                )
                            case .ended:
                                onPointerSelectionChanged?(
                                    selection,
                                    false,
                                    NSEvent.mouseLocation
                                )
                            }
                        }
                        .highPriorityGesture(windowDragGesture(window: window, windowIndex: index))
                        .transition(
                            .scale(scale: PlateMotion.windowRemovalScale)
                                .combined(with: .opacity)
                        )
                        .position(
                            x: plateCenter.x + anchorOffset.width,
                            y: plateCenter.y + anchorOffset.height
                        )
                    }
                }
            }
        }
        // Keyed on the count, not the IDs: a drag reorder keeps the count and must keep
        // its own motion, while an arrival or departure is what this animates.
        .animation(removalTransition.animation, value: plate.windows.count)
        .overlay(alignment: .leading) {
            if let stageNumberHint {
                CommandHintStrip(hints: [stageNumberHint])
                    .offset(x: -18)
            }
        }
        .overlay(alignment: .bottom) {
            if !footerHints.isEmpty {
                CommandHintStrip(hints: footerHints)
                    .offset(y: PlateConstants.commandHintFooterOffset)
            }
        }
    }

    private func windowDragGesture(window: PlateWindowData, windowIndex: Int) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named("overlay")
        )
            .onChanged { value in
                guard !PlateInteraction.isWindowClick(translation: value.translation) else {
                    return
                }
                if windowDrag == nil {
                    windowDrag = WindowDragState(
                        windowID: window.windowID,
                        sourceStageIndex: stageIndex,
                        sourceWindowIndex: windowIndex,
                        location: value.location,
                        dropTarget: dropTarget(
                            at: value.location,
                            sourceWindowIndex: windowIndex
                        )
                    )
                } else {
                    windowDrag?.location = value.location
                    if let drag = windowDrag {
                        windowDrag?.dropTarget = dropTarget(
                            at: value.location,
                            sourceWindowIndex: drag.sourceWindowIndex
                        )
                    }
                }
            }
            .onEnded { value in
                if PlateInteraction.isWindowClick(translation: value.translation) {
                    onWindowSelected?(stageIndex, windowIndex)
                    return
                }
                guard let drag = windowDrag,
                      let request = PlateInteraction.windowMoveRequest(for: drag)
                else {
                    windowDrag = nil
                    return
                }
                onWindowDropRequested?(request)
            }
    }

    private func dropTarget(
        at location: CGPoint,
        sourceWindowIndex: Int
    ) -> WindowDropTarget? {
        PlateInteraction.windowDropTarget(
            at: location,
            sourceStageIndex: stageIndex,
            sourceWindowIndex: sourceWindowIndex,
            plateFrames: plateFrames,
            windowFrames: windowFrames
        )
    }
}

private struct PlateSurfaceView: View {
    let stageIndex: Int
    let size: CGSize
    let cornerRadius: CGFloat
    let appearance: AppSettings

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .modifier(LiquidGlassModifier(
                cornerRadius: cornerRadius,
                appearance: appearance
            ))
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PlateSurfaceFramePreferenceKey.self,
                        value: [stageIndex: geometry.frame(in: .named("overlay"))]
                    )
                }
            }
            .allowsHitTesting(false)
    }
}

struct WindowPreviewView: View {
    let window: PlateWindowData
    let isWindowSelected: Bool
    var isDragging: Bool = false
    let metrics: PlateMetrics
    let appearance: AppSettings
    var commandHints: [CommandHintPresentation] = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let lift = PlateMotion.windowLift(
            isSelected: isWindowSelected,
            isDragging: isDragging,
            isDarkMode: colorScheme == .dark
        )
        return VStack(spacing: metrics.titleSpacing) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let cgImage = window.previewImage {
                        Image(decorative: cgImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.3))
                            .overlay {
                                AppIconImage(
                                    bundleID: window.ownerBundleID,
                                    name: window.ownerName,
                                    iconSize: metrics.previewPlaceholderIconSize
                                )
                                .frame(
                                    width: metrics.previewPlaceholderIconSize,
                                    height: metrics.previewPlaceholderIconSize
                                )
                            }
                    }
                }
                .frame(width: metrics.thumbnailWidth, height: metrics.thumbnailHeight)
                .overlay(alignment: .bottomTrailing) {
                    if !commandHints.isEmpty {
                        CommandHintStrip(hints: commandHints)
                            .padding(6)
                    }
                }

                AppIconImage(bundleID: window.ownerBundleID, name: window.ownerName, iconSize: metrics.badgeSize)
                    .frame(width: metrics.badgeSize, height: metrics.badgeSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(x: -4, y: -4)
            }

            Text(window.windowTitle.isEmpty ? window.ownerName : window.windowTitle)
                .font(.system(size: metrics.titleFontSize))
                .foregroundStyle(isWindowSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: metrics.thumbnailWidth + metrics.titleWidthAllowance, height: metrics.titleHeight)
        }
        .padding(metrics.cardPadding)
        .scaleEffect(PlateMotion.windowScale(isSelected: isWindowSelected, isDragging: isDragging))
        .shadow(
            color: .black.opacity(lift.shadowOpacity),
            radius: lift.shadowRadius,
            y: lift.shadowY
        )
        .animation(.spring(duration: 0.18, bounce: 0.08), value: isWindowSelected)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }
}

struct CommandHintStrip: View {
    let hints: [CommandHintPresentation]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(hints) { hint in
                HStack(spacing: 3) {
                    if let iconSystemName = hint.iconSystemName {
                        Image(systemName: iconSystemName)
                            .font(.system(size: 8, weight: .semibold))
                    }
                    Text(hint.shortcut)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay {
                        Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5)
                    }
                    .help("\(hint.label): \(hint.shortcut)")
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            hints.map { "\($0.label), \($0.shortcut)" }.joined(separator: "; ")
        )
    }
}

struct LiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let appearance: AppSettings

    func body(content: Content) -> some View {
        let glass: Glass = appearance.glassStyle == .clear ? .clear : .regular
        content
            .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
    }
}

struct AppIconImage: NSViewRepresentable {
    let bundleID: String
    let name: String
    var iconSize: CGFloat = 128

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = resolveIcon()
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = resolveIcon()
    }

    private func resolveIcon() -> NSImage {
        // Never hand back NSWorkspace's lazy icon: it rasterizes at draw time, on the main
        // thread, inside the Core Animation commit (KHA-481).
        if let icon = AppIconCache.shared.cachedOrRasterize(bundleID: bundleID, size: iconSize) {
            return icon
        }
        let size = iconSize
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: size - 16, height: size - 16), xRadius: 20, yRadius: 20).fill()
        let label = String(name.prefix(2)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.3),
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: size / 2 - sz.width / 2, y: size / 2 - sz.height / 2), withAttributes: attrs)
        img.unlockFocus()
        return img
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
