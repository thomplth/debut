import AppKit
import SwiftUI
import CoreGraphics

enum StageFocusTransition: Equatable {
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

struct StageLift: Equatable {
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat
}

struct WindowLift: Equatable {
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat
}

struct StageStackLayout: Equatable {
    let scales: [CGFloat]
    /// Each stage's own unscaled height. Stages wrap independently, so this is per space rather
    /// than one shared row height.
    let baseHeights: [CGFloat]
    let heights: [CGFloat]
    let centers: [CGFloat]
    let totalHeight: CGFloat
}

struct StageLayoutAnimationKey: Equatable {
    let spaceIDs: [UUID]
    let activeSpaceID: UUID?
}

enum StageEdgeScrollTarget: Equatable {
    case resting
    case top
    case bottom
}

enum StageMotion {
    static let minimumStageScale: CGFloat = 0.08
    static let minimumStageOpacity: Double = 0.12
    static let opacityScaleThreshold: CGFloat = 0.2
    static let windowRemovalScale: CGFloat = 0.55

    static func layoutAnimationKey(
        spaceIDs: [UUID],
        activeIndex: Int
    ) -> StageLayoutAnimationKey {
        StageLayoutAnimationKey(
            spaceIDs: spaceIDs,
            activeSpaceID: spaceIDs.indices.contains(activeIndex) ? spaceIDs[activeIndex] : nil
        )
    }

    static func focusTransition(reduceMotion: Bool) -> StageFocusTransition {
        reduceMotion
            ? .fade(duration: 0.12)
            : .spring(duration: 0.26, bounce: 0.08)
    }

    static func windowReorderTransition(reduceMotion: Bool) -> StageFocusTransition {
        reduceMotion
            ? .fade(duration: 0.126)
            : .spring(duration: 0.294, bounce: 0.06)
    }

    static func windowReorderTransition(
        reduceMotion: Bool,
        hasActiveDrag: Bool,
        isAwaitingCommittedLayout: Bool
    ) -> StageFocusTransition? {
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
    ) -> StageFocusTransition? {
        guard !hasActiveDrag, !isAwaitingCommittedLayout else { return nil }
        return windowReorderTransition(reduceMotion: reduceMotion)
    }

    /// A window leaving the stage is the app going away, not a layout tweak, so it settles
    /// without bounce: overshoot would read as the card trying to come back.
    static func windowRemovalTransition(reduceMotion: Bool) -> StageFocusTransition {
        reduceMotion
            ? .fade(duration: 0.12)
            : .spring(duration: 0.36, bounce: 0)
    }

    static func windowLayoutKey(for stages: [StageData]) -> WindowLayoutKey {
        WindowLayoutKey(spaceWindowIDs: stages.map { $0.windows.map(\.windowID) })
    }

    static func isWindowDropApplied(
        _ request: WindowMoveRequest,
        to layout: WindowLayoutKey
    ) -> Bool {
        guard layout.spaceWindowIDs.indices.contains(request.toSpaceIndex),
              layout.spaceWindowIDs[request.toSpaceIndex].indices.contains(request.toWindowIndex)
        else { return false }
        return layout.spaceWindowIDs[request.toSpaceIndex][request.toWindowIndex]
            == request.windowID
    }

    static func lift(isActive: Bool) -> StageLift {
        isActive
            ? StageLift(shadowOpacity: 0.22, shadowRadius: 18, shadowY: 8)
            : StageLift(shadowOpacity: 0.08, shadowRadius: 6, shadowY: 2)
    }

    static func stageScale(
        distanceFromFocus: Int,
        inactiveScale: CGFloat
    ) -> CGFloat {
        guard distanceFromFocus > 0 else { return 1 }
        return max(
            minimumStageScale,
            pow(inactiveScale, CGFloat(distanceFromFocus))
        )
    }

    static func stageOpacity(scale: CGFloat) -> Double {
        guard scale < opacityScaleThreshold else { return 1 }
        let progress = Double(scale / opacityScaleThreshold)
        return max(minimumStageOpacity, progress * progress)
    }

    /// Every candidate is pointer or drag state that can outlive the space it named, so a
    /// candidate past the end has to be skipped rather than carried into layout: `stackLayout`
    /// answers an out-of-range focus with an empty stack, which its callers then index into.
    static func focusedSpaceIndex(
        active: Int,
        hovered: Int?,
        dragTarget: Int?,
        retainedDragTarget: Int?,
        spaceCount: Int
    ) -> Int {
        let slots = 0..<max(0, spaceCount)
        guard !slots.isEmpty else { return 0 }
        let candidate = [dragTarget, retainedDragTarget, hovered]
            .compactMap { $0 }
            .first(where: slots.contains)
        return candidate ?? min(max(active, 0), slots.upperBound - 1)
    }

    static func stackLayout(
        stageHeights: [CGFloat],
        focusIndex: Int,
        spacing: CGFloat,
        inactiveScale: CGFloat
    ) -> StageStackLayout {
        guard stageHeights.indices.contains(focusIndex) else {
            return StageStackLayout(
                scales: [], baseHeights: [], heights: [], centers: [], totalHeight: 0
            )
        }
        let scales = stageHeights.indices.map {
            stageScale(
                distanceFromFocus: abs($0 - focusIndex),
                inactiveScale: inactiveScale
            )
        }
        let heights = zip(stageHeights, scales).map(*)
        var runningTop: CGFloat = 0
        var centers: [CGFloat] = []
        for height in heights {
            centers.append(runningTop + height / 2)
            runningTop += height + spacing
        }
        return StageStackLayout(
            scales: scales,
            baseHeights: stageHeights,
            heights: heights,
            centers: centers,
            totalHeight: runningTop - spacing
        )
    }

    /// Every stage lays out at its own unscaled height so the animated scale stays a render
    /// transform; this shifts the slot so the scaled stage lands on its stack center.
    static func stageSlotOffset(layout: StageStackLayout, index: Int) -> CGFloat {
        guard layout.centers.indices.contains(index),
              layout.baseHeights.indices.contains(index)
        else { return 0 }
        return layout.centers[index] - layout.baseHeights[index] / 2
    }

    /// The outer edge of the whole stack: the top of the first stage or the bottom of the last.
    static func stackBoundary(
        edge: SpaceStackEdge,
        stackOffset: CGFloat,
        layout: StageStackLayout
    ) -> CGFloat? {
        guard !layout.centers.isEmpty,
              layout.heights.count == layout.centers.count
        else { return nil }
        let index = edge == .top ? 0 : layout.centers.count - 1
        let center = stackOffset + layout.centers[index]
        let halfHeight = layout.heights[index] / 2
        return edge == .top ? center - halfHeight : center + halfHeight
    }

    static func stageFrame(
        at index: Int,
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        stageWidths: [CGFloat],
        layout: StageStackLayout
    ) -> CGRect {
        let width = stageWidths[index] * layout.scales[index]
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
        layout: StageStackLayout,
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
        edgeRegion: CGFloat = StageConstants.edgeHoverRegion
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
        edgeRegion: CGFloat = StageConstants.edgeHoverRegion
    ) -> StageEdgeScrollTarget {
        guard let pointerY else { return .resting }
        if pointerY <= edgeRegion { return .top }
        if pointerY >= containerHeight - edgeRegion { return .bottom }
        return .resting
    }

    static func edgeScrollDestination(
        target: StageEdgeScrollTarget,
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
              target.spaceIndex != drag.sourceSpaceIndex,
              actual.indices.contains(drag.sourceSpaceIndex),
              actual.indices.contains(target.spaceIndex),
              actual[drag.sourceSpaceIndex] > 0
        else { return actual }

        var displayed = actual
        displayed[drag.sourceSpaceIndex] -= 1
        displayed[target.spaceIndex] += 1
        return displayed
    }

    /// The slot a card holds while a drag is in flight, or `nil` if the drag takes it off this
    /// space entirely. Insertion is expressed against the order left behind once the dragged
    /// card is removed, which is the same contract `WindowDropTarget.windowIndex` carries.
    static func prospectiveWindowIndex(
        spaceIndex: Int,
        windowIndex: Int,
        drag: WindowDragState
    ) -> Int? {
        guard let target = drag.dropTarget else { return windowIndex }

        if spaceIndex == drag.sourceSpaceIndex, target.spaceIndex == spaceIndex {
            if windowIndex == drag.sourceWindowIndex { return target.windowIndex }
            var slot = windowIndex > drag.sourceWindowIndex ? windowIndex - 1 : windowIndex
            if slot >= target.windowIndex { slot += 1 }
            return slot
        }
        if spaceIndex == drag.sourceSpaceIndex {
            guard windowIndex != drag.sourceWindowIndex else { return nil }
            return windowIndex > drag.sourceWindowIndex ? windowIndex - 1 : windowIndex
        }
        if spaceIndex == target.spaceIndex {
            return windowIndex >= target.windowIndex ? windowIndex + 1 : windowIndex
        }
        return nil
    }

    /// The slot a card is laid out in, which is not always the slot it is drawn in.
    ///
    /// A card leaving this space takes its later neighbours' slots with it and the stage
    /// recentres around them, so their anchors have to move. A reorder within one space must
    /// leave anchors alone: they are what the drop target is resolved against, and a target
    /// that moved the cards it was measured from would chase its own feedback.
    static func windowAnchorIndex(
        spaceIndex: Int,
        windowIndex: Int,
        drag: WindowDragState?
    ) -> Int {
        guard let drag, let target = drag.dropTarget,
              spaceIndex == drag.sourceSpaceIndex,
              target.spaceIndex != spaceIndex,
              windowIndex > drag.sourceWindowIndex
        else { return windowIndex }
        return windowIndex - 1
    }

    /// How far a card is drawn from the slot it is laid out in. Balanced rows mean a single
    /// insertion can push a card onto another row, so this is a delta between two grid
    /// positions rather than a multiple of one card's width.
    static func windowSlotOffset(
        spaceIndex: Int,
        windowIndex: Int,
        drag: WindowDragState?,
        layout: StageWindowLayout
    ) -> CGSize {
        guard let drag, drag.dropTarget != nil,
              let slot = prospectiveWindowIndex(
                  spaceIndex: spaceIndex,
                  windowIndex: windowIndex,
                  drag: drag
              )
        else { return .zero }

        let anchor = layout.cardOffsetFromCenter(at: windowAnchorIndex(
            spaceIndex: spaceIndex,
            windowIndex: windowIndex,
            drag: drag
        ))
        let drawn = layout.cardOffsetFromCenter(at: slot)
        return CGSize(
            width: drawn.width - anchor.width,
            height: drawn.height - anchor.height
        )
    }

    /// Where the released preview settles: the exact slot the destination stage has already
    /// opened for it, in the overlay's coordinate space.
    static func windowDropDestination(
        target: WindowDropTarget,
        stageFrames: [Int: CGRect],
        layouts: [StageWindowLayout],
        scales: [CGFloat]
    ) -> CGPoint? {
        guard let stageFrame = stageFrames[target.spaceIndex],
              layouts.indices.contains(target.spaceIndex),
              scales.indices.contains(target.spaceIndex)
        else { return nil }

        let scale = scales[target.spaceIndex]
        let offset = layouts[target.spaceIndex].cardOffsetFromCenter(at: target.windowIndex)
        return CGPoint(
            x: stageFrame.midX + offset.width * scale,
            y: stageFrame.midY + offset.height * scale
        )
    }

    // A black shadow over the dark stage behind it needs more density and spread to
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

enum StageInteraction {
    static let minimumWindowDragDistance: CGFloat = 6

    static func isWindowClick(
        translation: CGSize,
        minimumDragDistance: CGFloat = minimumWindowDragDistance
    ) -> Bool {
        hypot(translation.width, translation.height) < minimumDragDistance
    }

    static func isDesktopArea(
        _ location: CGPoint,
        stageFrames: [Int: CGRect]
    ) -> Bool {
        guard !stageFrames.isEmpty else { return false }
        return !stageFrames.values.contains(where: { $0.contains(location) })
    }

    static func shouldMoveWindow(
        fromSpaceIndex: Int,
        fromWindowIndex: Int,
        to target: WindowDropTarget?
    ) -> Bool {
        guard let target else { return false }
        return target.spaceIndex != fromSpaceIndex
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
            fromSpaceIndex: completedDrag.sourceSpaceIndex,
            fromWindowIndex: completedDrag.sourceWindowIndex,
            to: completedDrag.dropTarget
        ), let target = completedDrag.dropTarget
        else { return nil }
        return WindowMoveRequest(
            windowID: completedDrag.windowID,
            fromSpaceIndex: completedDrag.sourceSpaceIndex,
            fromWindowIndex: completedDrag.sourceWindowIndex,
            toSpaceIndex: target.spaceIndex,
            toWindowIndex: target.windowIndex
        )
    }

    static func windowDropTarget(
        at location: CGPoint,
        sourceSpaceIndex: Int,
        sourceWindowIndex: Int,
        stageFrames: [Int: CGRect],
        windowFrames: [WindowFrameID: CGRect]
    ) -> WindowDropTarget? {
        guard let spaceIndex = stageFrames.keys.sorted().first(where: {
            stageFrames[$0]?.contains(location) == true
        }) else { return nil }

        let destinationFrames = windowFrames
            .filter { id, _ in
                id.spaceIndex == spaceIndex
                    && !(spaceIndex == sourceSpaceIndex && id.windowIndex == sourceWindowIndex)
            }
            .sorted { $0.key.windowIndex < $1.key.windowIndex }
            .map(\.value)
        let rows = cardRows(destinationFrames)

        guard let rowIndex = rowIndex(at: location.y, rows: rows) else {
            return WindowDropTarget(spaceIndex: spaceIndex, windowIndex: 0)
        }
        let row = rows[rowIndex]
        let withinRow = row.firstIndex(where: { location.x < $0.midX }) ?? row.count
        let precedingCards = rows.prefix(rowIndex).reduce(0) { $0 + $1.count }
        return WindowDropTarget(
            spaceIndex: spaceIndex,
            windowIndex: precedingCards + withinRow
        )
    }

    /// Groups row-major card frames into their rendered rows. A wrapped stage has no other
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

    /// Whether the pointer is over a stage or over the bare overlay around it. The desktop
    /// fall-through lives off-stage and is invisible to diagnostics until something reports that
    /// the pointer reached that region at all.
    static func pointerRegion(at location: CGPoint, stageFrames: [Int: CGRect]) -> String {
        stageFrames.values.contains { $0.contains(location) } ? "stage" : "outside"
    }

    /// What a tap on the overlay container meant. A tap that resolves to nothing is otherwise
    /// indistinguishable from a tap that never arrived.
    static func overlayTapTarget(
        at location: CGPoint,
        stageFrames: [Int: CGRect]
    ) -> OverlayTapTarget {
        isDesktopArea(location, stageFrames: stageFrames) ? .desktop : .none
    }

    /// Space scrolling is available across the entire overlay, including the bare desktop around
    /// the rendered stages.
    static func isInSpaceScrollArea(
        _ location: CGPoint,
        containerSize: CGSize
    ) -> Bool {
        guard containerSize.width > 0, containerSize.height > 0 else { return false }
        return CGRect(origin: .zero, size: containerSize).contains(location)
    }

    /// Scrolling stops at the ends rather than wrapping, so a long flick cannot land somewhere
    /// unrelated to where it started. A move to where the selection already is means no move.
    static func spaceScrollDestination(current: Int, steps: Int, spaceCount: Int) -> Int? {
        guard spaceCount > 0, steps != 0 else { return nil }
        let target = min(max(current - steps, 0), spaceCount - 1)
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

    static func spaceIndex(
        at location: CGPoint,
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        stageWidths: [CGFloat],
        layout: StageStackLayout
    ) -> Int? {
        guard stageWidths.count == layout.centers.count else { return nil }
        for index in layout.centers.indices {
            let frame = StageMotion.stageFrame(
                at: index,
                containerWidth: containerWidth,
                stackOffset: stackOffset,
                stageWidths: stageWidths,
                layout: layout
            )
            if frame.contains(location) { return index }
        }
        return nil
    }

    static func hoveredSpaceIndex(
        previous: Int?,
        at location: CGPoint,
        containerWidth: CGFloat,
        currentStackOffset: CGFloat,
        stageWidths: [CGFloat],
        currentLayout: StageStackLayout
    ) -> Int? {
        guard stageWidths.count == currentLayout.centers.count,
              currentLayout.scales.count == currentLayout.centers.count,
              currentLayout.heights.count == currentLayout.centers.count
        else { return nil }

        if let hit = spaceIndex(
            at: location,
            containerWidth: containerWidth,
            stackOffset: currentStackOffset,
            stageWidths: stageWidths,
            layout: currentLayout
        ) {
            return hit
        }

        for upperIndex in currentLayout.centers.indices.dropLast() {
            let lowerIndex = upperIndex + 1
            let upperFrame = StageMotion.stageFrame(
                at: upperIndex,
                containerWidth: containerWidth,
                stackOffset: currentStackOffset,
                stageWidths: stageWidths,
                layout: currentLayout
            )
            let lowerFrame = StageMotion.stageFrame(
                at: lowerIndex,
                containerWidth: containerWidth,
                stackOffset: currentStackOffset,
                stageWidths: stageWidths,
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

/// Every space of a scroll's journey: where it landed, whether that counted as the stack, and
/// what it did. A scroll that changes nothing is otherwise indistinguishable from one the window
/// never received.
struct OverlayScrollDiagnostic {
    let location: CGPoint
    let deltaY: CGFloat
    let isInScrollArea: Bool
    let steps: Int
    let destination: Int?
}

/// Where the pointer is relative to the stages, plus the outer edges of the stack, so a pointer
/// that seems to be nowhere can be placed against the geometry it was measured in.
struct OverlayPointerRegionDiagnostic {
    let region: String
    let location: CGPoint
    let topBoundary: CGFloat?
    let bottomBoundary: CGFloat?
}

/// A wheel reports whole notches and a trackpad a stream of points, and both have to become
/// whole space steps. The leftover travel has to survive between events, or a slow scroll would
/// never accumulate into a step at all.
struct SpaceScrollAccumulator {
    private var travel: CGFloat = 0

    mutating func steps(deltaY: CGFloat, isPrecise: Bool) -> Int {
        travel += isPrecise ? deltaY : deltaY * StageConstants.spaceScrollTravelPerSpace
        let whole = (travel / StageConstants.spaceScrollTravelPerSpace).rounded(.towardZero)
        travel -= whole * StageConstants.spaceScrollTravelPerSpace
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

/// Overlay-wide geometry. Everything a single window card is made of lives in `StageMetrics`.
public struct StageConstants {
    public static let screenMargin: CGFloat = 80
    public static let compactStageSpacing: CGFloat = 14
    public static let stageSpacing: CGFloat = 34
    public static let commandHintFooterOffset: CGFloat = 24
    public static let edgeHoverRegion: CGFloat = 56
    public static let edgeScrollMargin: CGFloat = 28
    public static let spaceScrollTravelPerSpace: CGFloat = 30

    /// The width a stage may occupy before its windows wrap onto another row.
    public static func availableStageWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth - screenMargin * 2
    }

    /// The height a stage may occupy before the overlay gives scale back to fit it.
    public static func availableStageHeight(screenHeight: CGFloat) -> CGFloat {
        screenHeight - screenMargin * 2
    }

    /// The largest requested scale at which every stage still fits the display.
    ///
    /// Scale, column capacity and row count are circular — a bigger card fits fewer per row, and
    /// more rows make a taller stage — so the fit is searched for rather than solved. Stage height
    /// only ever grows with scale, so walking the slider's own steps downward finds the largest
    /// scale that fits, and staying on those steps keeps the setting and the drawn size in step.
    public static func fittedStageScale(
        requested: CGFloat,
        windowCounts: [Int],
        containerSize: CGSize,
        metrics: StageMetrics = .standard
    ) -> CGFloat {
        let floor = CGFloat(AppSettings.minimumStageScale)
        let ceiling = CGFloat(AppSettings.maximumStageScale)
        let step = CGFloat(AppSettings.stageScaleStep)
        let clamped = min(ceiling, max(floor, requested))
        let availableWidth = availableStageWidth(screenWidth: containerSize.width)
        let availableHeight = availableStageHeight(screenHeight: containerSize.height)

        let steps = Int((((clamped - floor) / step)).rounded())
        for candidateStep in stride(from: steps, through: 0, by: -1) {
            let candidate = floor + CGFloat(candidateStep) * step
            let fits = stageLayouts(
                forWindowCounts: windowCounts,
                screenWidth: containerSize.width,
                metrics: metrics.scaled(by: candidate)
            ).allSatisfy {
                $0.stageSize.width <= availableWidth && $0.stageSize.height <= availableHeight
            }
            if fits { return candidate }
        }
        return floor
    }

    /// The metrics the overlay actually draws at. E2E aims at real screen coordinates, so a
    /// second derivation of the scale there would put its clicks somewhere the overlay never
    /// drew without either side failing.
    public static func drawnMetrics(
        stageScale: CGFloat,
        windowCounts: [Int],
        containerSize: CGSize
    ) -> StageMetrics {
        StageMetrics.standard.scaled(by: fittedStageScale(
            requested: stageScale,
            windowCounts: windowCounts,
            containerSize: containerSize
        ))
    }

    public static func stageLayouts(
        forWindowCounts counts: [Int],
        screenWidth: CGFloat,
        metrics: StageMetrics = .standard
    ) -> [StageWindowLayout] {
        let availableWidth = availableStageWidth(screenWidth: screenWidth)
        return counts.map {
            StageWindowLayout(
                windowCount: $0,
                availableWidth: availableWidth,
                metrics: metrics
            )
        }
    }

    public static func stageSpacing(
        hasVisibleFooterHints: Bool,
        scale: CGFloat = 1
    ) -> CGFloat {
        (hasVisibleFooterHints ? stageSpacing : compactStageSpacing) * scale
    }

    public static func stageCenterY(
        spaceIndex: Int,
        stageHeights: [CGFloat],
        activeSpaceIndex: Int,
        inactiveScale: CGFloat,
        containerHeight: CGFloat,
        stageScale: CGFloat = 1
    ) -> CGFloat? {
        guard stageHeights.indices.contains(spaceIndex),
              stageHeights.indices.contains(activeSpaceIndex)
        else { return nil }

        let layout = StageMotion.stackLayout(
            stageHeights: stageHeights,
            focusIndex: activeSpaceIndex,
            spacing: stageSpacing * stageScale,
            inactiveScale: inactiveScale
        )
        return containerHeight / 2
            - layout.centers[activeSpaceIndex]
            + layout.centers[spaceIndex]
    }

    /// Where a window card is drawn, for callers outside the view hierarchy. E2E clicks and drags
    /// real screen coordinates; a second copy of the grid math there drifts from what the overlay
    /// draws without either side failing.
    public static func windowCardCenter(
        spaceIndex: Int,
        windowIndex: Int,
        windowCounts: [Int],
        activeSpaceIndex: Int,
        inactiveScale: CGFloat,
        containerSize: CGSize,
        metrics: StageMetrics = .standard
    ) -> CGPoint? {
        let layouts = stageLayouts(
            forWindowCounts: windowCounts,
            screenWidth: containerSize.width,
            metrics: metrics
        )
        guard layouts.indices.contains(spaceIndex),
              (0..<windowCounts[spaceIndex]).contains(windowIndex),
              let centerY = stageCenterY(
                  spaceIndex: spaceIndex,
                  stageHeights: layouts.map(\.stageSize.height),
                  activeSpaceIndex: activeSpaceIndex,
                  inactiveScale: inactiveScale,
                  containerHeight: containerSize.height,
                  stageScale: metrics.scaleFactor
              )
        else { return nil }

        let scale = StageMotion.stageScale(
            distanceFromFocus: abs(spaceIndex - activeSpaceIndex),
            inactiveScale: inactiveScale
        )
        let offset = layouts[spaceIndex].cardOffsetFromCenter(at: windowIndex)
        return CGPoint(
            x: containerSize.width / 2 + offset.width * scale,
            y: centerY + offset.height * scale
        )
    }
}

public struct StageOverlayView: View {
    public let viewModel: StageOverlayViewModel
    public var onWindowSelected: ((Int, Int) -> Void)?
    public var onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)?
    public var onPointerSelectionChanged: ((Int?, Int?) -> Void)?
    public var onDesktopSelected: (() -> Void)?
    var onOverlayTapRouted: ((OverlayTapDiagnostic) -> Void)?
    var onSpaceScrollSelected: ((Int) -> Void)?
    var onSpaceScrollRouted: ((OverlayScrollDiagnostic) -> Void)?
    var scrollRelay: OverlayScrollRelay?
    var onOverlayPointerRegionChanged: ((OverlayPointerRegionDiagnostic) -> Void)?

    @State private var windowDrag: WindowDragState?
    @State private var settlingWindowDrop: WindowDropSettlingState?
    @State private var retainedWindowDragFocusSpaceIndex: Int?
    @State private var pointerSelection: PointerSelection?
    @State private var reportedPointerRegion: String?
    @State private var pointerMovementGate: PointerMovementGate
    @State private var stageFrames: [Int: CGRect] = [:]
    @State private var windowFrames: [WindowFrameID: CGRect] = [:]
    @State private var hoveredSpaceIndex: Int?
    @State private var hoverPointerY: CGFloat?
    @State private var scrollAccumulator = SpaceScrollAccumulator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        viewModel: StageOverlayViewModel,
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
        viewModel: StageOverlayViewModel,
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
        viewModel: StageOverlayViewModel,
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
        let stages = viewModel.stages
        let windowLayoutKey = StageMotion.windowLayoutKey(for: stages)
        let hasCommittedSettlingDrop = settlingWindowDrop.map {
            StageMotion.isWindowDropApplied($0.request, to: windowLayoutKey)
        } ?? false
        let layoutWindowDrag = hasCommittedSettlingDrop ? nil : windowDrag
        let displayedWindowCounts = StageMotion.displayedWindowCounts(
            actual: stages.map(\.windows.count),
            drag: layoutWindowDrag
        )
        let activeSpaceIndex = viewModel.activeSpaceIndex
        let activeStage = stages[safe: activeSpaceIndex]
        let activeSelectedWindowIndex = pointerSelection?.spaceIndex == activeSpaceIndex
            ? pointerSelection?.windowIndex
            : viewModel.selectedWindowIndex
        let activeFooterHints = activeStage.map { stage in
            CommandHintCatalog.stageFooterHints(
                spaceIndex: activeSpaceIndex,
                isActive: true,
                hasSelectedWindow: activeSelectedWindowIndex != nil
                    && !stage.windows.isEmpty,
                settings: viewModel.appearance
            )
        } ?? []

        GeometryReader { geo in
            // Fitted against the resting window counts, not the displaced ones: a drag that
            // moves a card between spaces must not resize every other card while it is in
            // flight.
            let metrics = StageConstants.drawnMetrics(
                stageScale: CGFloat(viewModel.appearance.stageScale),
                windowCounts: stages.map(\.windows.count),
                containerSize: geo.size
            )
            // Two grids per space: the one its own cards rest in, and the one the drag would
            // give it. A card's drag offset is the delta between them.
            let displayedLayouts = StageConstants.stageLayouts(
                forWindowCounts: displayedWindowCounts,
                screenWidth: geo.size.width,
                metrics: metrics
            )
            let stageWidths = displayedLayouts.map(\.stageSize.width)
            let stageHeights = displayedLayouts.map(\.stageSize.height)
            let tallestStageHeight = stageHeights.max() ?? 0

            let inactiveScale = CGFloat(viewModel.appearance.inactiveStageScale)
            let spacing = StageConstants.stageSpacing(
                hasVisibleFooterHints: !activeFooterHints.isEmpty,
                scale: metrics.scaleFactor
            )
            let focusTransition = StageMotion.focusTransition(reduceMotion: reduceMotion)
            let layoutAnimationKey = StageMotion.layoutAnimationKey(
                spaceIDs: stages.map(\.id),
                activeIndex: viewModel.activeSpaceIndex
            )
            let windowReorderTransition = StageMotion.windowReorderTransition(
                reduceMotion: reduceMotion
            )
            let activeWindowReorderTransition = StageMotion.windowReorderTransition(
                reduceMotion: reduceMotion,
                hasActiveDrag: layoutWindowDrag != nil,
                isAwaitingCommittedLayout: settlingWindowDrop != nil
            )
            let keyboardWindowReorderTransition = StageMotion.keyboardWindowReorderTransition(
                reduceMotion: reduceMotion,
                hasActiveDrag: layoutWindowDrag != nil,
                isAwaitingCommittedLayout: settlingWindowDrop != nil
            )
            let dragTargetIndex = layoutWindowDrag?.dropTarget?.spaceIndex
            let focusedSpaceIndex = StageMotion.focusedSpaceIndex(
                active: viewModel.activeSpaceIndex,
                hovered: hoveredSpaceIndex,
                dragTarget: dragTargetIndex,
                retainedDragTarget: retainedWindowDragFocusSpaceIndex,
                spaceCount: stages.count
            )
            let baselineLayout = StageMotion.stackLayout(
                stageHeights: stageHeights,
                focusIndex: viewModel.activeSpaceIndex,
                spacing: spacing,
                inactiveScale: inactiveScale
            )
            let visualLayout = StageMotion.stackLayout(
                stageHeights: stageHeights,
                focusIndex: focusedSpaceIndex,
                spacing: spacing,
                inactiveScale: inactiveScale
            )
            let baselineOffset = geo.size.height / 2
                - baselineLayout.centers[viewModel.activeSpaceIndex]
            let anchorY = baselineOffset + baselineLayout.centers[focusedSpaceIndex]
            let restingOffset = StageMotion.anchoredOffset(
                layout: visualLayout,
                anchorIndex: focusedSpaceIndex,
                anchorY: anchorY
            )
            let edgeScrollTarget = StageMotion.edgeScrollTarget(
                pointerY: hoveredSpaceIndex == nil ? nil : hoverPointerY,
                containerHeight: geo.size.height
            )
            let yOffset = StageMotion.edgeScrollDestination(
                target: edgeScrollTarget,
                restingOffset: restingOffset,
                topLimit: StageConstants.edgeScrollMargin,
                bottomLimit: geo.size.height - StageConstants.edgeScrollMargin
                    - visualLayout.totalHeight
            )

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .top) {
                    ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                        let stageWidth = stageWidths[index]
                        let stageHeight = stageHeights[index]
                        let isActive = index == viewModel.activeSpaceIndex
                        let isInteractionTarget = index == focusedSpaceIndex
                        let scale = visualLayout.scales[index]
                        let slotOffset = StageMotion.stageSlotOffset(
                            layout: visualLayout,
                            index: index
                        )
                        let stageOpacity = StageMotion.stageOpacity(scale: scale)
                        let lift = StageMotion.lift(isActive: isInteractionTarget)
                        let visualScale = metrics.scaleFactor
                        let selectedWindowIndex = pointerSelection?.spaceIndex == index
                            ? pointerSelection?.windowIndex
                            : (isActive ? viewModel.selectedWindowIndex : nil)
                        let spaceNumberHint = CommandHintCatalog.spaceNumberHint(
                            spaceIndex: index,
                            settings: viewModel.appearance
                        )
                        let footerHints = isActive ? activeFooterHints : []

                        StageSwiftUIView(
                            stage: stage,
                            selectedWindowIndex: selectedWindowIndex,
                            layout: displayedLayouts[index],
                            appearance: viewModel.appearance,
                            wallpaperLuminance: viewModel.wallpaperLuminance,
                            spaceNumberHint: spaceNumberHint,
                            footerHints: footerHints,
                            windowDrag: $windowDrag,
                            layoutWindowDrag: layoutWindowDrag,
                            settlingWindowID: settlingWindowDrop?.request.windowID,
                            stageFrames: $stageFrames,
                            windowFrames: $windowFrames,
                            spaceIndex: index,
                            onPointerSelectionChanged: { selection, isHovering, location in
                                if isHovering && !pointerMovementGate.observe(at: location) {
                                    return
                                }
                                let nextSelection = StageInteraction.pointerSelection(
                                    current: pointerSelection,
                                    target: selection,
                                    isHovering: isHovering
                                )
                                guard nextSelection != pointerSelection else { return }
                                pointerSelection = nextSelection
                                onPointerSelectionChanged?(
                                    nextSelection?.spaceIndex,
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
                        .frame(width: stageWidth, height: stageHeight)
                        .background {
                            StageSurfaceView(
                                spaceIndex: index,
                                size: CGSize(width: stageWidth, height: stageHeight),
                                cornerRadius: CGFloat(viewModel.appearance.stageCornerRadius)
                                    * visualScale,
                                appearance: viewModel.appearance
                            )
                        }
                        .background(
                            GeometryReader { stageGeo in
                                Color.clear.preference(
                                    key: StageFramePreferenceKey.self,
                                    value: [index: stageGeo.frame(in: .named("overlay"))]
                                )
                            }
                        )
                        .scaleEffect(scale)
                        .shadow(
                            color: .black.opacity(lift.shadowOpacity),
                            radius: lift.shadowRadius * visualScale,
                            y: lift.shadowY * visualScale
                        )
                        .opacity(stageOpacity)
                        .offset(y: slotOffset)
                        .zIndex(isActive || isInteractionTarget ? 2 : 0)
                    }
                }
                .frame(width: geo.size.width, height: tallestStageHeight, alignment: .top)
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
            // stages. Everything the space buttons need lives in the space it adds — the insert
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
                    .opacity(StageMotion.cursorPreviewOpacity)
                    .position(settlingWindowDrop.destination)
                    .allowsHitTesting(false)
                } else if let drag = windowDrag,
                   let stage = stages[safe: drag.sourceSpaceIndex],
                   let window = stage.windows[safe: drag.sourceWindowIndex] {
                    WindowPreviewView(
                        window: window,
                        isWindowSelected: true,
                        isDragging: true,
                        metrics: metrics,
                        appearance: viewModel.appearance
                    )
                    .opacity(StageMotion.cursorPreviewOpacity)
                    .position(drag.location)
                    .allowsHitTesting(false)
                }
            }
            .id(focusTransition.usesSpatialMotion ? -1 : viewModel.activeSpaceIndex)
            .transition(focusTransition.usesSpatialMotion ? .identity : .opacity)
            .animation(focusTransition.animation, value: layoutAnimationKey)
            .animation(focusTransition.animation, value: focusedSpaceIndex)
            .animation(focusTransition.animation, value: pointerSelection)
            .animation(activeWindowReorderTransition?.animation, value: layoutWindowDrag?.dropTarget)
            .animation(keyboardWindowReorderTransition?.animation, value: windowLayoutKey)
            .coordinateSpace(name: "overlay")
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("overlay"))
                    .onEnded { event in
                        let target = StageInteraction.overlayTapTarget(
                            at: event.location,
                            stageFrames: stageFrames
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
                if let event { handleSpaceScroll(event, containerSize: geo.size) }
            }
            .onPreferenceChange(StageFramePreferenceKey.self) { frames in
                stageFrames = frames
            }
            .onPreferenceChange(WindowFramePreferenceKey.self) { frames in
                windowFrames = frames
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    hoverPointerY = location.y
                    let region = StageInteraction.pointerRegion(
                        at: location,
                        stageFrames: stageFrames
                    )
                    if region != reportedPointerRegion {
                        reportedPointerRegion = region
                        onOverlayPointerRegionChanged?(OverlayPointerRegionDiagnostic(
                            region: region,
                            location: location,
                            topBoundary: StageMotion.stackBoundary(
                                edge: .top, stackOffset: yOffset, layout: visualLayout
                            ),
                            bottomBoundary: StageMotion.stackBoundary(
                                edge: .bottom, stackOffset: yOffset, layout: visualLayout
                            )
                        ))
                    }
                    guard pointerMovementGate.observe(at: NSEvent.mouseLocation) else {
                        return
                    }
                    if settlingWindowDrop == nil {
                        retainedWindowDragFocusSpaceIndex = nil
                    }
                    hoveredSpaceIndex = StageInteraction.hoveredSpaceIndex(
                        previous: hoveredSpaceIndex,
                        at: location,
                        containerWidth: geo.size.width,
                        currentStackOffset: yOffset,
                        stageWidths: stageWidths,
                        currentLayout: visualLayout
                    )
                case .ended:
                    hoverPointerY = nil
                    hoveredSpaceIndex = nil
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
            .onChange(of: viewModel.activeSpaceIndex) { _, _ in
                hoveredSpaceIndex = nil
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
        transition: StageFocusTransition,
        layouts: [StageWindowLayout],
        scales: [CGFloat]
    ) {
        guard let drag = windowDrag,
              let target = drag.dropTarget,
              let stage = viewModel.stages[safe: drag.sourceSpaceIndex],
              let window = stage.windows[safe: drag.sourceWindowIndex],
              let destination = StageMotion.windowDropDestination(
                  target: target,
                  stageFrames: stageFrames,
                  layouts: layouts,
                  scales: scales
              )
        else {
            commitWindowDrop(request)
            return
        }

        retainedWindowDragFocusSpaceIndex = target.spaceIndex

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
                request.fromSpaceIndex,
                request.fromWindowIndex,
                request.toSpaceIndex,
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
                request.fromSpaceIndex,
                request.fromWindowIndex,
                request.toSpaceIndex,
                request.toWindowIndex
            )
        }
    }

    private func finishWindowDropHandoff(ifAppliedTo layout: WindowLayoutKey) {
        guard let settlingWindowDrop,
              StageMotion.isWindowDropApplied(settlingWindowDrop.request, to: layout)
        else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            windowDrag = nil
            self.settlingWindowDrop = nil
        }
    }

    /// Reported at every space, because a scroll that changes nothing is otherwise
    /// indistinguishable from a scroll the window never received.
    private func handleSpaceScroll(_ event: OverlayScrollEvent, containerSize: CGSize) {
        if event.isGestureStart { scrollAccumulator.reset() }
        let inArea = windowDrag == nil
            && StageInteraction.isInSpaceScrollArea(
                event.location,
                containerSize: containerSize
            )
        let steps = inArea
            ? scrollAccumulator.steps(deltaY: event.deltaY, isPrecise: event.isPrecise)
            : 0
        let destination = StageInteraction.spaceScrollDestination(
            current: viewModel.activeSpaceIndex,
            steps: steps,
            spaceCount: viewModel.stages.count
        )

        onSpaceScrollRouted?(OverlayScrollDiagnostic(
            location: event.location,
            deltaY: event.deltaY,
            isInScrollArea: inArea,
            steps: steps,
            destination: destination
        ))

        guard let destination else { return }
        // The stack re-lays out under a stationary pointer, and whichever stage lands beneath it
        // would otherwise take the magnify straight back off the space the scroll just chose.
        hoveredSpaceIndex = nil
        pointerMovementGate.reset(at: NSEvent.mouseLocation)
        onSpaceScrollSelected?(destination)
    }
}

struct StageSwiftUIView: View {
    let stage: StageData
    let selectedWindowIndex: Int?
    let layout: StageWindowLayout
    let appearance: AppSettings
    let wallpaperLuminance: Double?
    let spaceNumberHint: CommandHintPresentation?
    let footerHints: [CommandHintPresentation]
    @Binding var windowDrag: WindowDragState?
    let layoutWindowDrag: WindowDragState?
    let settlingWindowID: CGWindowID?
    @Binding var stageFrames: [Int: CGRect]
    @Binding var windowFrames: [WindowFrameID: CGRect]
    let spaceIndex: Int
    var onPointerSelectionChanged: ((PointerSelection, Bool, CGPoint) -> Void)?
    var onWindowSelected: ((Int, Int) -> Void)?
    var onWindowDropRequested: ((WindowMoveRequest) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var removalTransition: StageFocusTransition {
        StageMotion.windowRemovalTransition(reduceMotion: reduceMotion)
    }

    var body: some View {
        let visualScale = layout.metrics.scaleFactor
        // Cards are placed, not stacked and nudged: `.offset` is a render transform, so a grid
        // built from it would report every card at the stage's centre and leave drop targeting
        // with nothing to aim at.
        GeometryReader { stageGeo in
            let stageCenter = CGPoint(
                x: stageGeo.size.width / 2,
                y: stageGeo.size.height / 2
            )
            ZStack(alignment: .topLeading) {
                if stage.windows.isEmpty {
                    Text("Empty")
                        .font(.system(size: 13 * visualScale))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .position(stageCenter)
                } else {
                    ForEach(Array(stage.windows.enumerated()), id: \.element.id) { index, window in
                        let isDragging = layoutWindowDrag?.sourceSpaceIndex == spaceIndex
                            && layoutWindowDrag?.sourceWindowIndex == index
                        let isSettling = settlingWindowID == window.windowID
                        let anchorOffset = layout.cardOffsetFromCenter(
                            at: StageMotion.windowAnchorIndex(
                                spaceIndex: spaceIndex,
                                windowIndex: index,
                                drag: layoutWindowDrag
                            )
                        )
                        let dragOffset = StageMotion.windowSlotOffset(
                            spaceIndex: spaceIndex,
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
                                windowCount: stage.windows.count,
                                settings: appearance
                            )
                        )
                        .opacity(StageMotion.sourceWindowOpacity(
                            isDragging: isDragging || isSettling
                        ))
                        .transaction { transaction in
                            if StageMotion.sourceWindowDisablesAnimation(
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
                                            spaceIndex: spaceIndex,
                                            windowIndex: index
                                        ): windowGeo.frame(in: .named("overlay"))
                                    ]
                                )
                            }
                        )
                        .onContinuousHover { phase in
                            let selection = PointerSelection(
                                spaceIndex: spaceIndex,
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
                            .scale(scale: StageMotion.windowRemovalScale)
                                .combined(with: .opacity)
                        )
                        .position(
                            x: stageCenter.x + anchorOffset.width,
                            y: stageCenter.y + anchorOffset.height
                        )
                    }
                }
            }
        }
        // Keyed on the count, not the IDs: a drag reorder keeps the count and must keep
        // its own motion, while an arrival or departure is what this animates.
        .animation(removalTransition.animation, value: stage.windows.count)
        .overlay(alignment: .leading) {
            if let spaceNumberHint {
                CommandHintStrip(hints: [spaceNumberHint], scale: visualScale)
                    .offset(x: -18 * visualScale)
            }
        }
        .overlay(alignment: .bottom) {
            if !footerHints.isEmpty {
                CommandHintStrip(hints: footerHints, scale: visualScale)
                    .offset(y: StageConstants.commandHintFooterOffset * visualScale)
            }
        }
    }

    private func windowDragGesture(window: StageWindowData, windowIndex: Int) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named("overlay")
        )
            .onChanged { value in
                guard !StageInteraction.isWindowClick(translation: value.translation) else {
                    return
                }
                if windowDrag == nil {
                    windowDrag = WindowDragState(
                        windowID: window.windowID,
                        sourceSpaceIndex: spaceIndex,
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
                if StageInteraction.isWindowClick(translation: value.translation) {
                    onWindowSelected?(spaceIndex, windowIndex)
                    return
                }
                guard let drag = windowDrag,
                      let request = StageInteraction.windowMoveRequest(for: drag)
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
        StageInteraction.windowDropTarget(
            at: location,
            sourceSpaceIndex: spaceIndex,
            sourceWindowIndex: sourceWindowIndex,
            stageFrames: stageFrames,
            windowFrames: windowFrames
        )
    }
}

private struct StageSurfaceView: View {
    let spaceIndex: Int
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
                        key: StageSurfaceFramePreferenceKey.self,
                        value: [spaceIndex: geometry.frame(in: .named("overlay"))]
                    )
                }
            }
            .allowsHitTesting(false)
    }
}

struct WindowPreviewView: View {
    let window: StageWindowData
    let isWindowSelected: Bool
    var isDragging: Bool = false
    let metrics: StageMetrics
    let appearance: AppSettings
    var commandHints: [CommandHintPresentation] = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let lift = StageMotion.windowLift(
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
                            .clipShape(RoundedRectangle(cornerRadius: metrics.thumbnailCornerRadius))
                    } else {
                        RoundedRectangle(cornerRadius: metrics.thumbnailCornerRadius)
                            .fill(.quaternary.opacity(0.3))
                            .overlay {
                                // Rasterized at a scale-independent size and framed at the
                                // drawn one, so moving the stage scale never invalidates the
                                // warmed icons.
                                AppIconImage(
                                    bundleID: window.ownerBundleID,
                                    name: window.ownerName,
                                    iconSize: AppIconCache.placeholderIconRasterSize,
                                    fallbackBaseSize: StageMetrics.standard.previewPlaceholderIconSize
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
                        CommandHintStrip(hints: commandHints, scale: metrics.scaleFactor)
                            .padding(6 * metrics.scaleFactor)
                    }
                }

                AppIconImage(
                    bundleID: window.ownerBundleID,
                    name: window.ownerName,
                    iconSize: AppIconCache.badgeRasterSize,
                    fallbackBaseSize: StageMetrics.standard.badgeSize
                )
                    .frame(width: metrics.badgeSize, height: metrics.badgeSize)
                    .shadow(
                        color: .black.opacity(0.3),
                        radius: 2 * metrics.scaleFactor,
                        x: 0,
                        y: metrics.scaleFactor
                    )
                    .offset(x: -4 * metrics.scaleFactor, y: -4 * metrics.scaleFactor)
            }

            Text(window.displayTitle)
                .font(.system(size: metrics.titleFontSize))
                .foregroundStyle(isWindowSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: metrics.thumbnailWidth + metrics.titleWidthAllowance, height: metrics.titleHeight)
        }
        .padding(metrics.cardPadding)
        .scaleEffect(StageMotion.windowScale(isSelected: isWindowSelected, isDragging: isDragging))
        .shadow(
            color: .black.opacity(lift.shadowOpacity),
            radius: lift.shadowRadius * metrics.scaleFactor,
            y: lift.shadowY * metrics.scaleFactor
        )
        .animation(.spring(duration: 0.18, bounce: 0.08), value: isWindowSelected)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }
}

struct CommandHintStrip: View {
    let hints: [CommandHintPresentation]
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 4 * scale) {
            ForEach(hints) { hint in
                HStack(spacing: 3 * scale) {
                    if let iconSystemName = hint.iconSystemName {
                        Image(systemName: iconSystemName)
                            .font(.system(size: 8 * scale, weight: .semibold))
                    }
                    Text(hint.shortcut)
                        .font(.system(
                            size: 9 * scale,
                            weight: .semibold,
                            design: .monospaced
                        ))
                }
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 3 * scale)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay {
                        Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5 * scale)
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

struct AppIconImage: View {
    let bundleID: String
    let name: String
    var iconSize: CGFloat = 128
    var fallbackBaseSize: CGFloat = 128

    var body: some View {
        // `iconSize` is the cache's raster size, not this view's layout size. A resizable SwiftUI
        // image accepts the frame proposed by its caller; NSImageView instead retained the
        // maximum-scale bitmap's intrinsic 100/80-point size and overflowed that frame.
        Image(nsImage: resolveIcon())
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    private func resolveIcon() -> NSImage {
        // Never hand back NSWorkspace's lazy icon: it rasterizes at draw time, on the main
        // thread, inside the Core Animation commit (KHA-481).
        if let icon = AppIconCache.shared.cachedOrRasterize(bundleID: bundleID, size: iconSize) {
            return icon
        }
        // Draw the original fallback design at the cache's larger raster size. It is later
        // downsampled by the resizable Image, just like a real application icon.
        let size = iconSize
        let rasterScale = size / fallbackBaseSize
        let inset = 8 * rasterScale
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
            xRadius: 20 * rasterScale,
            yRadius: 20 * rasterScale
        ).fill()
        let label = String(name.prefix(2)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40 * rasterScale, weight: .semibold),
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
