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

    /// A window leaving the plate is the app going away, not a layout tweak, so it settles
    /// without bounce: overshoot would read as the card trying to come back.
    static func windowRemovalTransition(reduceMotion: Bool) -> PlateFocusTransition {
        reduceMotion
            ? .fade(duration: 0.12)
            : .spring(duration: 0.28, bounce: 0)
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

    /// Maps every stage index to the slot it occupies while one plate is held, so the stack
    /// stays a complete arrangement instead of leaving a hole where the held plate started.
    static func stageDragSlots(stageCount: Int, from source: Int, to destination: Int) -> [Int] {
        let identity = Array(0..<max(0, stageCount))
        guard identity.indices.contains(source), identity.indices.contains(destination)
        else { return identity }

        return identity.map { index in
            if index == source { return destination }
            if source < destination, index > source, index <= destination { return index - 1 }
            if destination < source, index >= destination, index < source { return index + 1 }
            return index
        }
    }

    static func plateOpacity(scale: CGFloat) -> Double {
        guard scale < opacityScaleThreshold else { return 1 }
        let progress = Double(scale / opacityScaleThreshold)
        return max(minimumPlateOpacity, progress * progress)
    }

    static func focusedStageIndex(
        active: Int,
        hovered: Int?,
        dragTarget: Int?,
        retainedDragTarget: Int?
    ) -> Int {
        dragTarget ?? retainedDragTarget ?? hovered ?? active
    }

    static func stackLayout(
        stageCount: Int,
        focusIndex: Int,
        plateHeight: CGFloat,
        spacing: CGFloat,
        inactiveScale: CGFloat
    ) -> PlateStackLayout {
        guard stageCount > 0, (0..<stageCount).contains(focusIndex) else {
            return PlateStackLayout(scales: [], heights: [], centers: [], totalHeight: 0)
        }
        let scales = (0..<stageCount).map {
            plateScale(
                distanceFromFocus: abs($0 - focusIndex),
                inactiveScale: inactiveScale
            )
        }
        let heights = scales.map { plateHeight * $0 }
        var runningTop: CGFloat = 0
        var centers: [CGFloat] = []
        for height in heights {
            centers.append(runningTop + height / 2)
            runningTop += height + spacing
        }
        return PlateStackLayout(
            scales: scales,
            heights: heights,
            centers: centers,
            totalHeight: runningTop - spacing
        )
    }

    /// Every plate lays out in an identical unscaled slot so the animated scale stays a
    /// render transform; this shifts the slot so the scaled plate lands on its stack center.
    static func plateSlotOffset(
        layout: PlateStackLayout,
        index: Int,
        plateHeight: CGFloat
    ) -> CGFloat {
        guard layout.centers.indices.contains(index) else { return 0 }
        return layout.centers[index] - plateHeight / 2
    }

    /// The outer edge of the whole stack: the top of the first plate or the bottom of the last.
    static func stackBoundary(
        edge: StageInsertionEdge,
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

    static func stageInsertButtonCenter(
        edge: StageInsertionEdge,
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        layout: PlateStackLayout
    ) -> CGPoint? {
        guard let boundary = stackBoundary(
            edge: edge,
            stackOffset: stackOffset,
            layout: layout
        ) else { return nil }
        let reach = PlateConstants.stageInsertHoverHeight / 2
        return CGPoint(
            x: containerWidth / 2,
            y: edge == .top ? boundary - reach : boundary + reach
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

    static func stageHandleExpansion(isRevealed: Bool) -> CGFloat {
        isRevealed ? PlateConstants.stageHandleRevealWidth : 0
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

    static func windowDragOffset(
        stageIndex: Int,
        windowIndex: Int,
        drag: WindowDragState?,
        cardStride: CGFloat
    ) -> CGFloat {
        guard let drag, let target = drag.dropTarget else { return 0 }

        if target.stageIndex == drag.sourceStageIndex,
           stageIndex == drag.sourceStageIndex {
            if windowIndex == drag.sourceWindowIndex {
                return CGFloat(target.windowIndex - drag.sourceWindowIndex) * cardStride
            }
            if drag.sourceWindowIndex < target.windowIndex,
               windowIndex > drag.sourceWindowIndex,
               windowIndex <= target.windowIndex {
                return -cardStride
            }
            if target.windowIndex < drag.sourceWindowIndex,
               windowIndex >= target.windowIndex,
               windowIndex < drag.sourceWindowIndex {
                return cardStride
            }
            return 0
        }

        if stageIndex == drag.sourceStageIndex,
           windowIndex > drag.sourceWindowIndex {
            return -cardStride
        }
        if stageIndex == target.stageIndex,
           windowIndex >= target.windowIndex {
            return cardStride
        }
        return 0
    }

    static func windowGridCenterOffset(
        stageIndex: Int,
        drag: WindowDragState?,
        cardStride: CGFloat
    ) -> CGFloat {
        guard let drag,
              let target = drag.dropTarget,
              target.stageIndex != drag.sourceStageIndex
        else { return 0 }

        return stageIndex == drag.sourceStageIndex ? cardStride / 2 : 0
    }

    static func windowDropDestination(
        sourceStageIndex: Int,
        sourceWindowIndex: Int,
        target: WindowDropTarget,
        cardStride: CGFloat,
        plateFrames: [Int: CGRect],
        windowFrames: [WindowFrameID: CGRect]
    ) -> CGPoint? {
        let sourceID = WindowFrameID(
            stageIndex: sourceStageIndex,
            windowIndex: sourceWindowIndex
        )
        guard let sourceFrame = windowFrames[sourceID] else { return nil }

        if target.stageIndex == sourceStageIndex {
            return CGPoint(
                x: sourceFrame.midX
                    + CGFloat(target.windowIndex - sourceWindowIndex) * cardStride,
                y: sourceFrame.midY
            )
        }

        let destinationFrames = windowFrames
            .filter { $0.key.stageIndex == target.stageIndex }
            .sorted { $0.key.windowIndex < $1.key.windowIndex }
        if destinationFrames.indices.contains(target.windowIndex) {
            let frame = destinationFrames[target.windowIndex].value
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        if let lastFrame = destinationFrames.last?.value {
            return CGPoint(x: lastFrame.midX + cardStride, y: lastFrame.midY)
        }
        guard let plateFrame = plateFrames[target.stageIndex] else { return nil }
        return CGPoint(
            x: plateFrame.midX,
            y: plateFrame.minY + PlateConstants.topPadding + sourceFrame.height / 2
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
        let insertionIndex = destinationFrames.firstIndex(where: {
            location.x < $0.value.midX
        }) ?? destinationFrames.count
        return WindowDropTarget(stageIndex: stageIndex, windowIndex: insertionIndex)
    }

    static func stageDestination(
        from sourceIndex: Int,
        translation: CGFloat,
        plateStride: CGFloat,
        stageCount: Int
    ) -> Int? {
        guard stageCount > 1,
              (0..<stageCount).contains(sourceIndex),
              plateStride > 0
        else { return nil }
        let moved = Int(round(translation / plateStride))
        let destination = max(0, min(sourceIndex + moved, stageCount - 1))
        return destination == sourceIndex ? nil : destination
    }

    /// Only vertical travel counts: a plate reorders within a single column, so sideways
    /// movement during the gesture must not change where it lands.
    static func stageDragDestination(
        from sourceIndex: Int,
        translation: CGSize,
        plateStride: CGFloat,
        stageCount: Int
    ) -> Int {
        stageDestination(
            from: sourceIndex,
            translation: translation.height,
            plateStride: plateStride,
            stageCount: stageCount
        ) ?? sourceIndex
    }

    /// The drag handle sits in a gutter beside the plate. Treating that gutter as part of the
    /// plate is what lets the pointer travel out to the handle without the plate losing focus
    /// and shrinking away underneath it.
    static func revealedStageHandleIndex(
        previous: Int?,
        at location: CGPoint,
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        plateWidths: [CGFloat],
        layout: PlateStackLayout
    ) -> Int? {
        guard plateWidths.count == layout.centers.count,
              layout.scales.count == layout.centers.count,
              layout.heights.count == layout.centers.count
        else { return nil }

        for index in layout.centers.indices {
            let frame = plateFrame(
                at: index,
                containerWidth: containerWidth,
                stackOffset: stackOffset,
                plateWidths: plateWidths,
                layout: layout
            )
            guard location.y >= frame.minY, location.y <= frame.maxY else { continue }

            let scale = layout.scales[index]
            let reach = previous == index
                ? PlateConstants.stageHandleHoverWidth + PlateConstants.stageHandleRevealWidth
                : PlateConstants.stageHandleHoverWidth
            let zone = CGRect(
                x: frame.minX - PlateConstants.stageHandleGutterWidth * scale,
                y: frame.minY,
                width: (PlateConstants.stageHandleGutterWidth + reach) * scale,
                height: frame.height
            )
            if zone.contains(location) { return index }
        }
        return nil
    }

    /// A band just outside each end of the stack. The button is centered in its own band, so
    /// travelling out to it can never leave the region that revealed it.
    static func stageInsertionEdge(
        at location: CGPoint,
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        plateWidths: [CGFloat],
        layout: PlateStackLayout
    ) -> StageInsertionEdge? {
        guard plateWidths.count == layout.centers.count,
              layout.scales.count == layout.centers.count
        else { return nil }

        for edge in [StageInsertionEdge.top, .bottom] {
            guard let boundary = PlateMotion.stackBoundary(
                edge: edge,
                stackOffset: stackOffset,
                layout: layout
            ) else { return nil }
            let index = edge == .top ? 0 : layout.centers.count - 1
            let halfWidth = plateWidths[index] * layout.scales[index] / 2
            let band = CGRect(
                x: containerWidth / 2 - halfWidth,
                y: edge == .top
                    ? boundary - PlateConstants.stageInsertHoverHeight
                    : boundary,
                width: halfWidth * 2,
                height: PlateConstants.stageInsertHoverHeight
            )
            if band.contains(location) { return edge }
        }
        return nil
    }

    static func isStageInsertButtonHit(_ location: CGPoint, center: CGPoint) -> Bool {
        hypot(location.x - center.x, location.y - center.y)
            <= PlateConstants.stageInsertButtonSize / 2
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
            let frame = plateHitFrame(
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
            let upperFrame = plateFrame(
                at: upperIndex,
                containerWidth: containerWidth,
                stackOffset: currentStackOffset,
                plateWidths: plateWidths,
                layout: currentLayout
            )
            let lowerFrame = plateFrame(
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

    private static func plateFrame(
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

    /// The plate plus the gutter its drag handle lives in. Hit testing uses this so reaching
    /// for the handle never reads as leaving the plate.
    private static func plateHitFrame(
        at index: Int,
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        plateWidths: [CGFloat],
        layout: PlateStackLayout
    ) -> CGRect {
        let frame = plateFrame(
            at: index,
            containerWidth: containerWidth,
            stackOffset: stackOffset,
            plateWidths: plateWidths,
            layout: layout
        )
        let gutter = PlateConstants.stageHandleGutterWidth * layout.scales[index]
        return CGRect(
            x: frame.minX - gutter,
            y: frame.minY,
            width: frame.width + gutter,
            height: frame.height
        )
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

public struct PlateConstants {
    public static let thumbnailWidth: CGFloat = 160
    public static let thumbnailHeight: CGFloat = 100
    public static let windowSpacing: CGFloat = 12
    public static let padding: CGFloat = 24
    public static let minPlateWidth: CGFloat = 300
    public static let windowCardPadding: CGFloat = 6
    public static let windowTitleWidthAllowance: CGFloat = 8
    public static let topPadding: CGFloat = 24
    public static let bottomPadding: CGFloat = 24
    public static let screenMargin: CGFloat = 80
    public static let badgeSize: CGFloat = 40
    public static let compactStageSpacing: CGFloat = 14
    public static let stageSpacing: CGFloat = 34
    public static let commandHintFooterOffset: CGFloat = 24
    public static let stageHandleHoverWidth: CGFloat = 24
    public static let stageHandleRevealWidth: CGFloat = 36
    public static let stageHandleGutterWidth: CGFloat = 40
    public static let edgeHoverRegion: CGFloat = 56
    public static let edgeScrollMargin: CGFloat = 28
    public static let stageInsertHoverHeight: CGFloat = 44
    public static let stageInsertButtonSize: CGFloat = 26

    public static func thumbnailSize(forWindowCount count: Int, screenWidth: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let maxWidth = screenWidth - screenMargin * 2
        let availableForWindowCards = maxWidth - padding * 2
        let maxPerWindow = count > 0
            ? (availableForWindowCards - CGFloat(max(0, count - 1)) * windowSpacing) / CGFloat(count)
                - windowCardExtraWidth
            : thumbnailWidth
        let w = min(thumbnailWidth, max(80, maxPerWindow))
        let h = w * (thumbnailHeight / thumbnailWidth)
        return (w, h)
    }

    public static var windowCardExtraWidth: CGFloat {
        windowTitleWidthAllowance + windowCardPadding * 2
    }

    public static func plateHeight(thumbnailHeight: CGFloat) -> CGFloat {
        topPadding + thumbnailHeight + 16 + bottomPadding
    }

    public static func plateWidth(forWindowCount count: Int, thumbnailWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return minPlateWidth }
        let cardsWidth = CGFloat(count) * (thumbnailWidth + windowCardExtraWidth)
            + CGFloat(count - 1) * windowSpacing
        return cardsWidth + padding * 2
    }

    public static func plateWidths(forWindowCounts counts: [Int], thumbnailWidth: CGFloat) -> [CGFloat] {
        counts.map { plateWidth(forWindowCount: $0, thumbnailWidth: thumbnailWidth) }
    }

    public static func stageSpacing(hasVisibleFooterHints: Bool) -> CGFloat {
        hasVisibleFooterHints ? stageSpacing : compactStageSpacing
    }

    public static func plateCenterY(
        stageIndex: Int,
        stageCount: Int,
        activeStageIndex: Int,
        plateHeight: CGFloat,
        inactiveScale: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat? {
        guard (0..<stageCount).contains(stageIndex),
              (0..<stageCount).contains(activeStageIndex)
        else { return nil }

        let scale: (Int) -> CGFloat = {
            PlateMotion.plateScale(
                distanceFromFocus: abs($0 - activeStageIndex),
                inactiveScale: inactiveScale
            )
        }
        let top: (Int) -> CGFloat = { index in
            (0..<index).reduce(0) { partial, precedingIndex in
                partial + plateHeight * scale(precedingIndex) + stageSpacing
            }
        }
        let yOffset = containerHeight / 2 - top(activeStageIndex) - plateHeight / 2
        return yOffset + top(stageIndex) + plateHeight * scale(stageIndex) / 2
    }
}

public struct OverlaySwiftUIView: View {
    public let viewModel: OverlayViewModel
    public var onWindowSelected: ((Int, Int) -> Void)?
    public var onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)?
    public var onStageReordered: ((Int, Int) -> Void)?
    public var onStageHandleVisibilityChanged: ((Int, Bool) -> Void)?
    public var onStageInsertRequested: ((StageInsertionEdge) -> Void)?
    public var onPointerSelectionChanged: ((Int?, Int?) -> Void)?
    public var onDesktopSelected: (() -> Void)?

    @State private var revealedStageInsertionEdge: StageInsertionEdge?
    @State private var windowDrag: WindowDragState?
    @State private var settlingWindowDrop: WindowDropSettlingState?
    @State private var retainedWindowDragFocusStageIndex: Int?
    @State private var stageDrag: StageDragState?
    @State private var pointerSelection: PointerSelection?
    @State private var pointerMovementGate: PointerMovementGate
    @State private var plateFrames: [Int: CGRect] = [:]
    @State private var windowFrames: [WindowFrameID: CGRect] = [:]
    @State private var revealedStageHandleIndex: Int?
    @State private var hoveredStageIndex: Int?
    @State private var hoverPointerY: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        viewModel: OverlayViewModel,
        onWindowSelected: ((Int, Int) -> Void)? = nil,
        onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)? = nil,
        onStageReordered: ((Int, Int) -> Void)? = nil,
        onStageHandleVisibilityChanged: ((Int, Bool) -> Void)? = nil,
        onStageInsertRequested: ((StageInsertionEdge) -> Void)? = nil,
        onPointerSelectionChanged: ((Int?, Int?) -> Void)? = nil,
        onDesktopSelected: (() -> Void)? = nil
    ) {
        self.init(
            viewModel: viewModel,
            initialWindowDrag: nil,
            initialStageDrag: nil,
            initialStageInsertionEdge: nil,
            onWindowSelected: onWindowSelected,
            onWindowMoved: onWindowMoved,
            onStageReordered: onStageReordered,
            onStageHandleVisibilityChanged: onStageHandleVisibilityChanged,
            onStageInsertRequested: onStageInsertRequested,
            onPointerSelectionChanged: onPointerSelectionChanged,
            onDesktopSelected: onDesktopSelected
        )
    }

    init(
        viewModel: OverlayViewModel,
        initialWindowDrag: WindowDragState,
        onWindowSelected: ((Int, Int) -> Void)? = nil,
        onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)? = nil,
        onStageReordered: ((Int, Int) -> Void)? = nil,
        onStageHandleVisibilityChanged: ((Int, Bool) -> Void)? = nil,
        onStageInsertRequested: ((StageInsertionEdge) -> Void)? = nil,
        onPointerSelectionChanged: ((Int?, Int?) -> Void)? = nil,
        onDesktopSelected: (() -> Void)? = nil
    ) {
        self.init(
            viewModel: viewModel,
            initialWindowDrag: WindowDragState?(initialWindowDrag),
            initialStageDrag: nil,
            initialStageInsertionEdge: nil,
            onWindowSelected: onWindowSelected,
            onWindowMoved: onWindowMoved,
            onStageReordered: onStageReordered,
            onStageHandleVisibilityChanged: onStageHandleVisibilityChanged,
            onStageInsertRequested: onStageInsertRequested,
            onPointerSelectionChanged: onPointerSelectionChanged,
            onDesktopSelected: onDesktopSelected
        )
    }

    init(
        viewModel: OverlayViewModel,
        initialStageDrag: StageDragState,
        onWindowSelected: ((Int, Int) -> Void)? = nil,
        onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)? = nil,
        onStageReordered: ((Int, Int) -> Void)? = nil,
        onStageHandleVisibilityChanged: ((Int, Bool) -> Void)? = nil,
        onStageInsertRequested: ((StageInsertionEdge) -> Void)? = nil,
        onPointerSelectionChanged: ((Int?, Int?) -> Void)? = nil,
        onDesktopSelected: (() -> Void)? = nil
    ) {
        self.init(
            viewModel: viewModel,
            initialWindowDrag: nil,
            initialStageDrag: StageDragState?(initialStageDrag),
            initialStageInsertionEdge: nil,
            onWindowSelected: onWindowSelected,
            onWindowMoved: onWindowMoved,
            onStageReordered: onStageReordered,
            onStageHandleVisibilityChanged: onStageHandleVisibilityChanged,
            onStageInsertRequested: onStageInsertRequested,
            onPointerSelectionChanged: onPointerSelectionChanged,
            onDesktopSelected: onDesktopSelected
        )
    }

    init(
        viewModel: OverlayViewModel,
        initialStageInsertionEdge: StageInsertionEdge
    ) {
        self.init(
            viewModel: viewModel,
            initialWindowDrag: nil,
            initialStageDrag: nil,
            initialStageInsertionEdge: StageInsertionEdge?(initialStageInsertionEdge),
            onWindowSelected: nil,
            onWindowMoved: nil,
            onStageReordered: nil,
            onStageHandleVisibilityChanged: nil,
            onStageInsertRequested: nil,
            onPointerSelectionChanged: nil,
            onDesktopSelected: nil
        )
    }

    private init(
        viewModel: OverlayViewModel,
        initialWindowDrag: WindowDragState?,
        initialStageDrag: StageDragState?,
        initialStageInsertionEdge: StageInsertionEdge?,
        onWindowSelected: ((Int, Int) -> Void)?,
        onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)?,
        onStageReordered: ((Int, Int) -> Void)?,
        onStageHandleVisibilityChanged: ((Int, Bool) -> Void)?,
        onStageInsertRequested: ((StageInsertionEdge) -> Void)?,
        onPointerSelectionChanged: ((Int?, Int?) -> Void)?,
        onDesktopSelected: (() -> Void)?
    ) {
        self.viewModel = viewModel
        self.onWindowSelected = onWindowSelected
        self.onWindowMoved = onWindowMoved
        self.onStageReordered = onStageReordered
        self.onStageHandleVisibilityChanged = onStageHandleVisibilityChanged
        self.onStageInsertRequested = onStageInsertRequested
        self.onPointerSelectionChanged = onPointerSelectionChanged
        self.onDesktopSelected = onDesktopSelected
        _windowDrag = State(initialValue: initialWindowDrag)
        _stageDrag = State(initialValue: initialStageDrag)
        _revealedStageInsertionEdge = State(initialValue: initialStageInsertionEdge)
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
        let maxWindows = displayedWindowCounts.max() ?? 0
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
            let tSize = PlateConstants.thumbnailSize(forWindowCount: maxWindows, screenWidth: geo.size.width)
            let pHeight = PlateConstants.plateHeight(thumbnailHeight: tSize.height)
            let plateWidths = PlateConstants.plateWidths(
                forWindowCounts: displayedWindowCounts,
                thumbnailWidth: tSize.width
            )

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
            let dragTargetIndex = layoutWindowDrag?.dropTarget?.stageIndex
                ?? stageDrag?.destinationIndex
            let dragSlots = stageDrag.map {
                PlateMotion.stageDragSlots(
                    stageCount: plates.count,
                    from: $0.stageIndex,
                    to: $0.destinationIndex
                )
            }
            let focusedStageIndex = PlateMotion.focusedStageIndex(
                active: viewModel.activeStageIndex,
                hovered: hoveredStageIndex ?? revealedStageHandleIndex,
                dragTarget: dragTargetIndex,
                retainedDragTarget: retainedWindowDragFocusStageIndex
            )
            let baselineLayout = PlateMotion.stackLayout(
                stageCount: plates.count,
                focusIndex: viewModel.activeStageIndex,
                plateHeight: pHeight,
                spacing: spacing,
                inactiveScale: inactiveScale
            )
            let visualLayout = PlateMotion.stackLayout(
                stageCount: plates.count,
                focusIndex: focusedStageIndex,
                plateHeight: pHeight,
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
                        let isActive = index == viewModel.activeStageIndex
                        let isStageDragging = stageDrag?.stageIndex == index
                        let isStageHandleRevealed = revealedStageHandleIndex == index
                        let stageHandleExpansion = PlateMotion.stageHandleExpansion(
                            isRevealed: isStageHandleRevealed
                        )
                        let slotIndex = dragSlots?[safe: index] ?? index
                        let isInteractionTarget = slotIndex == focusedStageIndex
                        let scale = visualLayout.scales[slotIndex]
                        let slotOffset = PlateMotion.plateSlotOffset(
                            layout: visualLayout,
                            index: slotIndex,
                            plateHeight: pHeight
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
                            thumbnailWidth: tSize.width,
                            thumbnailHeight: tSize.height,
                            appearance: viewModel.appearance,
                            stageNumberHint: stageNumberHint,
                            footerHints: footerHints,
                            stageHandleExpansion: stageHandleExpansion,
                            isStageHandleRevealed: isStageHandleRevealed,
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
                                    cardStride: tSize.width
                                        + PlateConstants.windowCardExtraWidth
                                        + PlateConstants.windowSpacing
                                )
                            },
                            onStageDragChanged: { translation in
                                updateStageDrag(
                                    index: index,
                                    plate: plate,
                                    translation: translation,
                                    plateStride: pHeight * inactiveScale + spacing
                                )
                            },
                            onStageDragEnded: {
                                finishStageDrag()
                            }
                        )
                        .frame(width: plateWidth + stageHandleExpansion, height: pHeight)
                        .offset(x: -stageHandleExpansion / 2)
                        .frame(width: plateWidth, height: pHeight)
                        .background {
                            PlateSurfaceView(
                                stageIndex: index,
                                size: CGSize(width: plateWidth, height: pHeight),
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
                        .opacity(plateOpacity * (isStageDragging ? 0.78 : 1.0))
                        .offset(y: slotOffset)
                        .zIndex(isStageDragging ? 3 : (isActive || isInteractionTarget ? 2 : 0))
                    }
                }
                .frame(width: geo.size.width, height: pHeight, alignment: .top)
                .offset(y: yOffset)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if let settlingWindowDrop {
                    WindowPreviewView(
                        window: settlingWindowDrop.window,
                        isWindowSelected: true,
                        isDragging: true,
                        thumbnailWidth: tSize.width,
                        thumbnailHeight: tSize.height,
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
                        thumbnailWidth: tSize.width,
                        thumbnailHeight: tSize.height,
                        appearance: viewModel.appearance
                    )
                    .opacity(PlateMotion.cursorPreviewOpacity)
                    .position(drag.location)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let center = stageInsertButtonCenter(
                    containerWidth: geo.size.width,
                    stackOffset: yOffset,
                    layout: visualLayout
                ) {
                    StageInsertButton()
                        .position(center)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.14), value: revealedStageInsertionEdge)
            .id(focusTransition.usesSpatialMotion ? -1 : viewModel.activeStageIndex)
            .transition(focusTransition.usesSpatialMotion ? .identity : .opacity)
            .animation(focusTransition.animation, value: layoutAnimationKey)
            .animation(focusTransition.animation, value: focusedStageIndex)
            .animation(focusTransition.animation, value: pointerSelection)
            .animation(activeWindowReorderTransition?.animation, value: layoutWindowDrag?.dropTarget)
            .animation(focusTransition.animation, value: dragSlots)
            .coordinateSpace(name: "overlay")
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("overlay"))
                    .onEnded { event in
                        // The insert button lives outside every plate frame, so it has to be
                        // claimed here or the same tap would read as a desktop click.
                        if let edge = revealedStageInsertionEdge,
                           let center = stageInsertButtonCenter(
                               containerWidth: geo.size.width,
                               stackOffset: yOffset,
                               layout: visualLayout
                           ),
                           PlateInteraction.isStageInsertButtonHit(event.location, center: center) {
                            onStageInsertRequested?(edge)
                            return
                        }
                        guard PlateInteraction.isDesktopArea(
                            event.location,
                            plateFrames: plateFrames
                        ) else { return }
                        onDesktopSelected?()
                    }
            )
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
                    updateRevealedStageHandle(
                        PlateInteraction.revealedStageHandleIndex(
                            previous: revealedStageHandleIndex,
                            at: location,
                            containerWidth: geo.size.width,
                            stackOffset: yOffset,
                            plateWidths: plateWidths,
                            layout: visualLayout
                        )
                    )
                    revealedStageInsertionEdge = windowDrag == nil && stageDrag == nil
                        ? PlateInteraction.stageInsertionEdge(
                            at: location,
                            containerWidth: geo.size.width,
                            stackOffset: yOffset,
                            plateWidths: plateWidths,
                            layout: visualLayout
                        )
                        : nil
                case .ended:
                    hoverPointerY = nil
                    hoveredStageIndex = nil
                    revealedStageInsertionEdge = nil
                    updateRevealedStageHandle(nil)
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
        cardStride: CGFloat
    ) {
        guard let drag = windowDrag,
              let target = drag.dropTarget,
              let plate = viewModel.plates[safe: drag.sourceStageIndex],
              let window = plate.windows[safe: drag.sourceWindowIndex],
              let destination = PlateMotion.windowDropDestination(
                  sourceStageIndex: drag.sourceStageIndex,
                  sourceWindowIndex: drag.sourceWindowIndex,
                  target: target,
                  cardStride: cardStride,
                  plateFrames: plateFrames,
                  windowFrames: windowFrames
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

    /// The held plate is kept in the stack's own coordinate system: only its slot changes, so
    /// it can never be dragged out from under the other plates.
    private func updateStageDrag(
        index: Int,
        plate: PlateData,
        translation: CGSize,
        plateStride: CGFloat
    ) {
        guard windowDrag == nil else { return }
        let destination = PlateInteraction.stageDragDestination(
            from: index,
            translation: translation,
            plateStride: plateStride,
            stageCount: viewModel.plates.count
        )
        if stageDrag == nil {
            guard viewModel.plates.count > 1 else { return }
            stageDrag = StageDragState(
                stageIndex: index,
                stageID: plate.id,
                verticalTranslation: translation.height,
                destinationIndex: destination
            )
        } else {
            stageDrag?.verticalTranslation = translation.height
            stageDrag?.destinationIndex = destination
        }
    }

    private func finishStageDrag() {
        guard let drag = stageDrag else { return }
        stageDrag = nil
        guard drag.destinationIndex != drag.stageIndex else { return }
        onStageReordered?(drag.stageIndex, drag.destinationIndex)
    }

    private func stageInsertButtonCenter(
        containerWidth: CGFloat,
        stackOffset: CGFloat,
        layout: PlateStackLayout
    ) -> CGPoint? {
        guard let edge = revealedStageInsertionEdge else { return nil }
        return PlateMotion.stageInsertButtonCenter(
            edge: edge,
            containerWidth: containerWidth,
            stackOffset: stackOffset,
            layout: layout
        )
    }

    private func updateRevealedStageHandle(_ index: Int?) {
        guard index != revealedStageHandleIndex else { return }
        if let previous = revealedStageHandleIndex {
            // The plate being dragged keeps its handle: the pointer wanders off it mid-gesture.
            guard stageDrag?.stageIndex != previous else { return }
            onStageHandleVisibilityChanged?(previous, false)
        }
        revealedStageHandleIndex = index
        if let index {
            onStageHandleVisibilityChanged?(index, true)
        }
    }
}

struct PlateSwiftUIView: View {
    let plate: PlateData
    let selectedWindowIndex: Int?
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let appearance: AppSettings
    let stageNumberHint: CommandHintPresentation?
    let footerHints: [CommandHintPresentation]
    let stageHandleExpansion: CGFloat
    let isStageHandleRevealed: Bool
    @Binding var windowDrag: WindowDragState?
    let layoutWindowDrag: WindowDragState?
    let settlingWindowID: CGWindowID?
    @Binding var plateFrames: [Int: CGRect]
    @Binding var windowFrames: [WindowFrameID: CGRect]
    let stageIndex: Int
    var onPointerSelectionChanged: ((PointerSelection, Bool, CGPoint) -> Void)?
    var onWindowSelected: ((Int, Int) -> Void)?
    var onWindowDropRequested: ((WindowMoveRequest) -> Void)?
    var onStageDragChanged: ((CGSize) -> Void)?
    var onStageDragEnded: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var removalTransition: PlateFocusTransition {
        PlateMotion.windowRemovalTransition(reduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PlateConstants.windowSpacing) {
                if plate.windows.isEmpty {
                    Text("Empty")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(plate.windows.enumerated()), id: \.element.id) { index, window in
                        let isDragging = layoutWindowDrag?.sourceStageIndex == stageIndex
                            && layoutWindowDrag?.sourceWindowIndex == index
                        let isSettling = settlingWindowID == window.windowID
                        let cardStride = thumbnailWidth
                            + PlateConstants.windowCardExtraWidth
                            + PlateConstants.windowSpacing
                        let dragOffset = PlateMotion.windowDragOffset(
                            stageIndex: stageIndex,
                            windowIndex: index,
                            drag: layoutWindowDrag,
                            cardStride: cardStride
                        )
                        WindowPreviewView(
                            window: window,
                            isWindowSelected: selectedWindowIndex == index,
                            isDragging: isDragging,
                            thumbnailWidth: thumbnailWidth,
                            thumbnailHeight: thumbnailHeight,
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
                        .offset(x: dragOffset)
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
                            .scale(scale: 0.82).combined(with: .opacity)
                        )
                    }
                }
            }
            // Keyed on the count, not the IDs: a drag reorder keeps the count and must keep
            // its own motion, while an arrival or departure is what this animates.
            .animation(removalTransition.animation, value: plate.windows.count)
            .padding(.leading, PlateConstants.padding + stageHandleExpansion)
            .padding(.trailing, PlateConstants.padding)
            .padding(.top, PlateConstants.topPadding)
            .offset(x: PlateMotion.windowGridCenterOffset(
                stageIndex: stageIndex,
                drag: layoutWindowDrag,
                cardStride: thumbnailWidth
                    + PlateConstants.windowCardExtraWidth
                    + PlateConstants.windowSpacing
            ))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            if isStageHandleRevealed {
                StageDragHandle()
                    .frame(width: PlateConstants.stageHandleRevealWidth)
                    .contentShape(Rectangle())
                    .gesture(stageHandleDragGesture)
                    .transition(.opacity)
            }
        }
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
        .animation(.easeOut(duration: 0.14), value: isStageHandleRevealed)
    }

    private var stageHandleDragGesture: some Gesture {
        DragGesture(coordinateSpace: .named("overlay"))
            .onChanged { value in
                onStageDragChanged?(value.translation)
            }
            .onEnded { _ in
                onStageDragEnded?()
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

private struct StageInsertButton: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(
                width: PlateConstants.stageInsertButtonSize,
                height: PlateConstants.stageInsertButtonSize
            )
            .background(.black.opacity(0.55), in: Circle())
            .overlay {
                Circle().stroke(.white.opacity(0.16), lineWidth: 0.5)
            }
            .help("Add stage")
            .accessibilityLabel("Add stage")
    }
}

private struct StageDragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.8))
            .frame(maxHeight: .infinity)
            .help("Drag to reorder stage")
            .accessibilityLabel("Reorder stage")
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
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let appearance: AppSettings
    var commandHints: [CommandHintPresentation] = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let lift = PlateMotion.windowLift(
            isSelected: isWindowSelected,
            isDragging: isDragging,
            isDarkMode: colorScheme == .dark
        )
        return VStack(spacing: 4) {
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
                                AppIconImage(bundleID: window.ownerBundleID, name: window.ownerName, iconSize: 32)
                                    .frame(width: 32, height: 32)
                            }
                    }
                }
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .overlay(alignment: .bottomTrailing) {
                    if !commandHints.isEmpty {
                        CommandHintStrip(hints: commandHints)
                            .padding(6)
                    }
                }

                AppIconImage(bundleID: window.ownerBundleID, name: window.ownerName, iconSize: PlateConstants.badgeSize)
                    .frame(width: PlateConstants.badgeSize, height: PlateConstants.badgeSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(x: -4, y: -4)
            }

            Text(window.windowTitle.isEmpty ? window.ownerName : window.windowTitle)
                .font(.system(size: max(9, thumbnailWidth * 0.065)))
                .foregroundStyle(isWindowSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: thumbnailWidth + PlateConstants.windowTitleWidthAllowance)
        }
        .padding(PlateConstants.windowCardPadding)
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
        if #available(macOS 26.0, *) {
            let glass: Glass = appearance.glassStyle == .clear ? .clear : .regular
            content
                .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
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
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: iconSize, height: iconSize)
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
