import Testing
import CoreGraphics
import Foundation
@testable import DebutCore

@Suite("Plate motion")
struct PlateMotionTests {
    @Test("Deleting the first stage changes the layout animation key")
    func deletingFirstStageTriggersMotion() {
        let first = UUID()
        let second = UUID()
        let before = PlateMotion.layoutAnimationKey(
            stageIDs: [first, second],
            activeIndex: 0
        )
        let after = PlateMotion.layoutAnimationKey(
            stageIDs: [second],
            activeIndex: 0
        )

        #expect(before != after)
    }

    @Test("Stage focus uses a restrained spring")
    func stageFocusUsesRestrainedSpring() {
        #expect(
            PlateMotion.focusTransition(reduceMotion: false)
                == .spring(duration: 0.26, bounce: 0.08)
        )
    }

    @Test("Reduce Motion replaces movement with a short fade")
    func reduceMotionUsesFade() {
        #expect(
            PlateMotion.focusTransition(reduceMotion: true)
                == .fade(duration: 0.12)
        )
    }

    @Test("Window insertion uses brisk macOS-style motion")
    func windowInsertionUsesBriskMotion() {
        #expect(
            PlateMotion.windowReorderTransition(reduceMotion: false)
                == .spring(duration: 0.294, bounce: 0.06)
        )
        #expect(
            PlateMotion.windowReorderTransition(reduceMotion: true)
                == .fade(duration: 0.126)
        )
    }

    @Test("A departing window shrinks out rather than snapping")
    func windowRemovalUsesShrinkingMotion() {
        #expect(
            PlateMotion.windowRemovalTransition(reduceMotion: false)
                == .spring(duration: 0.28, bounce: 0)
        )
        #expect(
            PlateMotion.windowRemovalTransition(reduceMotion: true)
                == .fade(duration: 0.12)
        )
    }

    @Test("Window reorder motion stops when drag state is cleared")
    func windowReorderMotionEndsWithDrag() {
        #expect(
            PlateMotion.windowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: true,
                isAwaitingCommittedLayout: false
            ) == .spring(duration: 0.294, bounce: 0.06)
        )
        #expect(
            PlateMotion.windowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: true,
                isAwaitingCommittedLayout: true
            ) == nil
        )
        #expect(
            PlateMotion.windowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: false,
                isAwaitingCommittedLayout: false
            ) == nil
        )
    }

    @Test("Snapped preview waits for the committed window order")
    func snappedPreviewWaitsForCommittedLayout() {
        let request = WindowMoveRequest(
            windowID: 42,
            fromStageIndex: 0,
            fromWindowIndex: 0,
            toStageIndex: 1,
            toWindowIndex: 1
        )
        #expect(!PlateMotion.isWindowDropApplied(
            request,
            to: WindowLayoutKey(stageWindowIDs: [[42, 43], [50, 51]])
        ))
        #expect(PlateMotion.isWindowDropApplied(
            request,
            to: WindowLayoutKey(stageWindowIDs: [[43], [50, 42, 51]])
        ))
        #expect(!PlateMotion.isWindowDropApplied(
            request,
            to: WindowLayoutKey(stageWindowIDs: [[43], [42, 50, 51]])
        ))
    }

    @Test("Drag hides the stationary card and keeps the cursor preview opaque")
    func dragPreviewVisibility() {
        #expect(PlateMotion.sourceWindowOpacity(isDragging: false) == 1)
        #expect(PlateMotion.sourceWindowOpacity(isDragging: true) == 0)
        #expect(PlateMotion.sourceWindowDisablesAnimation(isDragging: false) == false)
        #expect(PlateMotion.sourceWindowDisablesAnimation(isDragging: true) == true)
        #expect(PlateMotion.cursorPreviewOpacity == 1)
    }

    @Test("The active plate receives a subtle lift")
    func activePlateLift() {
        #expect(PlateMotion.lift(isActive: true) == .init(shadowOpacity: 0.22, shadowRadius: 18, shadowY: 8))
        #expect(PlateMotion.lift(isActive: false) == .init(shadowOpacity: 0.08, shadowRadius: 6, shadowY: 2))
    }

    @Test("Plate scale falls off with distance from focus")
    func distanceBasedPlateScale() {
        #expect(PlateMotion.plateScale(distanceFromFocus: 0, inactiveScale: 0.8) == 1)
        #expect(PlateMotion.plateScale(distanceFromFocus: 1, inactiveScale: 0.8) == 0.8)
        #expect(abs(PlateMotion.plateScale(distanceFromFocus: 2, inactiveScale: 0.8) - 0.64) < 0.001)
        #expect(abs(PlateMotion.plateScale(distanceFromFocus: 8, inactiveScale: 0.8) - 0.16777216) < 0.001)
        #expect(PlateMotion.plateScale(distanceFromFocus: 20, inactiveScale: 0.8) == 0.08)
    }

    @Test("Plates occupy a fixed-height slot and reach their center by offset")
    func plateSlotOffsetCentersEachPlate() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 1,
            plateHeight: 180,
            spacing: 20,
            inactiveScale: 0.8
        )
        for index in 0..<3 {
            let offset = PlateMotion.plateSlotOffset(
                layout: layout,
                index: index,
                plateHeight: 180
            )
            #expect(abs(offset + 90 - layout.centers[index]) < 0.001)
        }
    }

    @Test("Plate slot offset is zero for an out-of-range index")
    func plateSlotOffsetOutOfRange() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 180,
            spacing: 20,
            inactiveScale: 0.8
        )
        #expect(PlateMotion.plateSlotOffset(layout: layout, index: 5, plateHeight: 180) == 0)
    }

    @Test("Plate opacity stays solid until scale falls below twenty percent")
    func scaleThresholdPlateOpacity() {
        #expect(PlateMotion.plateOpacity(scale: 1) == 1)
        #expect(PlateMotion.plateOpacity(scale: 0.21) == 1)
        #expect(PlateMotion.plateOpacity(scale: 0.2) == 1)
        #expect(PlateMotion.plateOpacity(scale: 0.1) == 0.25)
        #expect(PlateMotion.plateOpacity(scale: 0.01) == 0.12)
    }

    @Test("Hover layout remains packed around its fixed anchor")
    func hoverLayoutUsesFixedAnchorAndSpacing() {
        let baseline = PlateMotion.stackLayout(
            stageCount: 5,
            focusIndex: 1,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let hovered = PlateMotion.stackLayout(
            stageCount: 5,
            focusIndex: 3,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let anchorY = baseline.centers[3]
        let offset = PlateMotion.anchoredOffset(
            layout: hovered,
            anchorIndex: 3,
            anchorY: anchorY
        )

        #expect(abs(hovered.centers[3] + offset - anchorY) < 0.001)
        for index in 1..<hovered.centers.count {
            let precedingBottom = hovered.centers[index - 1] + hovered.heights[index - 1] / 2
            let currentTop = hovered.centers[index] - hovered.heights[index] / 2
            #expect(abs(currentTop - precedingBottom - 12) < 0.001)
        }
    }

    @Test("Hover hit testing uses stable baseline slots")
    func stableStageHitTesting() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 1,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [200, 300, 200]

        #expect(PlateInteraction.stageIndex(
            at: CGPoint(x: 250, y: layout.centers[1]),
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: widths,
            layout: layout
        ) == 1)
        #expect(PlateInteraction.stageIndex(
            at: CGPoint(x: 20, y: layout.centers[1]),
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: widths,
            layout: layout
        ) == nil)
        #expect(PlateInteraction.stageIndex(
            at: CGPoint(x: 250, y: layout.centers[1] + 56),
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: widths,
            layout: layout
        ) == nil)
    }

    @Test("Hover focus persists through a transit gap")
    func hoverFocusPersistsThroughTransitGap() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 20,
            inactiveScale: 0.8
        )

        #expect(PlateInteraction.hoveredStageIndex(
            previous: 2,
            at: CGPoint(x: 250, y: 110),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: [300, 240, 180],
            currentLayout: layout
        ) == 2)
        #expect(PlateInteraction.hoveredStageIndex(
            previous: 2,
            at: CGPoint(x: 250, y: layout.centers[1]),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: [300, 240, 180],
            currentLayout: layout
        ) == 1)
    }

    @Test("Hover hit testing follows the magnified plate frame")
    func hoverHitTestingFollowsMagnifiedPlateFrame() {
        let baseline = PlateMotion.stackLayout(
            stageCount: 4,
            focusIndex: 3,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let magnified = PlateMotion.stackLayout(
            stageCount: 4,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let baselineOffset: CGFloat = 200 - baseline.centers[3]
        let anchorY = baselineOffset + baseline.centers[0]
        let magnifiedOffset = PlateMotion.anchoredOffset(
            layout: magnified,
            anchorIndex: 0,
            anchorY: anchorY
        )
        let location = CGPoint(x: 130, y: anchorY)

        #expect(PlateInteraction.stageIndex(
            at: location,
            containerWidth: 600,
            stackOffset: baselineOffset,
            plateWidths: [400, 400, 400, 400],
            layout: baseline
        ) == nil)
        #expect(PlateInteraction.hoveredStageIndex(
            previous: 0,
            at: location,
            containerWidth: 600,
            currentStackOffset: magnifiedOffset,
            plateWidths: [400, 400, 400, 400],
            currentLayout: magnified
        ) == 0)
    }

    @Test("Hover focus clears outside the horizontal transit corridor")
    func hoverFocusClearsBesideTransitGap() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 20,
            inactiveScale: 0.8
        )

        #expect(PlateInteraction.hoveredStageIndex(
            previous: 0,
            at: CGPoint(x: 420, y: 110),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: [300, 240],
            currentLayout: layout
        ) == nil)
    }

    @Test("Hover focus clears beyond the vertical stack corridor")
    func hoverFocusClearsAboveAndBelowStack() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 20,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [300, 240]

        let top = layout.centers[0] - layout.heights[0] / 2
        let bottom = layout.centers[1] + layout.heights[1] / 2
        let reach = PlateConstants.stageInsertHoverHeight

        #expect(PlateInteraction.hoveredStageIndex(
            previous: 0,
            at: CGPoint(x: 250, y: top - reach - 1),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: widths,
            currentLayout: layout
        ) == nil)
        #expect(PlateInteraction.hoveredStageIndex(
            previous: 1,
            at: CGPoint(x: 250, y: bottom + reach + 1),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: widths,
            currentLayout: layout
        ) == nil)
    }

    @Test("Entering a transit gap without prior focus stays unfocused")
    func transitGapDoesNotCreateFocus() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 20,
            inactiveScale: 0.8
        )

        #expect(PlateInteraction.hoveredStageIndex(
            previous: nil,
            at: CGPoint(x: 250, y: 110),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: [300, 240],
            currentLayout: layout
        ) == nil)
    }

    @Test("Transit corridor interpolates between unequal plate widths")
    func unequalWidthTransitCorridor() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 20,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [400, 100]

        #expect(PlateInteraction.hoveredStageIndex(
            previous: 0,
            at: CGPoint(x: 390, y: 101),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: widths,
            currentLayout: layout
        ) == 0)
        #expect(PlateInteraction.hoveredStageIndex(
            previous: 0,
            at: CGPoint(x: 390, y: 119),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: widths,
            currentLayout: layout
        ) == nil)
    }

    @Test("A pointer or drag target becomes the gradient focus")
    func interactionFocusPriority() {
        #expect(PlateMotion.focusedStageIndex(
            active: 2, hovered: nil, dragTarget: nil, retainedDragTarget: nil, stageCount: 5
        ) == 2)
        #expect(PlateMotion.focusedStageIndex(
            active: 2, hovered: 4, dragTarget: nil, retainedDragTarget: nil, stageCount: 5
        ) == 4)
        #expect(PlateMotion.focusedStageIndex(
            active: 2, hovered: 4, dragTarget: 1, retainedDragTarget: nil, stageCount: 5
        ) == 1)
    }

    @Test("Cross-stage drag focus is retained through drop completion")
    func retainedCrossStageDragFocus() {
        #expect(PlateMotion.focusedStageIndex(
            active: 0, hovered: nil, dragTarget: 1, retainedDragTarget: nil, stageCount: 2
        ) == 1)
        #expect(PlateMotion.focusedStageIndex(
            active: 0, hovered: nil, dragTarget: nil, retainedDragTarget: 1, stageCount: 2
        ) == 1)
    }

    @Test("Focus candidates that outlived their stage are skipped")
    func staleFocusCandidatesAreIgnored() {
        #expect(PlateMotion.focusedStageIndex(
            active: 1, hovered: 6, dragTarget: nil, retainedDragTarget: nil, stageCount: 4
        ) == 1)
        #expect(PlateMotion.focusedStageIndex(
            active: 1, hovered: 2, dragTarget: 9, retainedDragTarget: nil, stageCount: 4
        ) == 2)
        #expect(PlateMotion.focusedStageIndex(
            active: 1, hovered: -1, dragTarget: nil, retainedDragTarget: nil, stageCount: 4
        ) == 1)
        #expect(PlateMotion.focusedStageIndex(
            active: 7, hovered: nil, dragTarget: nil, retainedDragTarget: nil, stageCount: 4
        ) == 3)
    }

    @Test("A stale focus index leaves the stack laid out rather than empty")
    func staleFocusKeepsStackLayout() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: PlateMotion.focusedStageIndex(
                active: 0,
                hovered: 6,
                dragTarget: nil,
                retainedDragTarget: nil,
                stageCount: 3
            ),
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )

        #expect(layout.centers.count == 3)
        #expect(layout.scales[0] == 1)
    }

    @Test("Edge hover scrolls overflow toward its boundary")
    func edgeHoverScrollDestination() {
        #expect(PlateMotion.edgeScrollDestination(
            pointerY: 20,
            containerHeight: 600,
            restingOffset: -300,
            topLimit: 48,
            bottomLimit: -948
        ) == 48)
        #expect(PlateMotion.edgeScrollDestination(
            pointerY: 580,
            containerHeight: 600,
            restingOffset: -300,
            topLimit: 48,
            bottomLimit: -948
        ) == -948)
        #expect(PlateMotion.edgeScrollDestination(
            pointerY: 300,
            containerHeight: 600,
            restingOffset: -300,
            topLimit: 48,
            bottomLimit: -948
        ) == -300)
        #expect(PlateMotion.edgeScrollDestination(
            pointerY: 20,
            containerHeight: 600,
            restingOffset: 50,
            topLimit: 48,
            bottomLimit: 52
        ) == 50)
    }

    @Test("Resting edge-scroll animation key is stable across screen sizes")
    func resizedScreenDoesNotAnimateRestingStack() {
        #expect(PlateMotion.edgeScrollTarget(
            pointerY: nil,
            containerHeight: 900,
            edgeRegion: 80
        ) == .resting)
        #expect(PlateMotion.edgeScrollTarget(
            pointerY: nil,
            containerHeight: 1_800,
            edgeRegion: 80
        ) == .resting)
    }

    @Test("Stage drag handle expands only the visual leading edge")
    func stageDragHandleExpansion() {
        #expect(PlateMotion.stageHandleExpansion(isRevealed: false) == 0)
        #expect(
            PlateMotion.stageHandleExpansion(isRevealed: true)
                == PlateConstants.stageHandleRevealWidth
        )
    }

    @Test("Plate centers use the distance-based layout scale")
    func plateCentersFollowDepthLayout() {
        let activeCenter = PlateConstants.plateCenterY(
            stageIndex: 1,
            stageCount: 3,
            activeStageIndex: 1,
            plateHeight: 164,
            inactiveScale: 0.8,
            containerHeight: 768
        )
        let precedingCenter = PlateConstants.plateCenterY(
            stageIndex: 0,
            stageCount: 3,
            activeStageIndex: 1,
            plateHeight: 164,
            inactiveScale: 0.8,
            containerHeight: 768
        )

        #expect(activeCenter == 384)
        #expect(abs((precedingCenter ?? 0) - 202.4) < 0.001)
    }

    @Test("Selected windows magnify instead of using a selection indicator")
    func selectedWindowScale() {
        #expect(PlateMotion.windowScale(isSelected: false, isDragging: false) == 1)
        #expect(PlateMotion.windowScale(isSelected: true, isDragging: false) == 1.06)
        #expect(PlateMotion.windowScale(isSelected: true, isDragging: true) == 0.96)
    }

    @Test("Only the selected window carries a lift")
    func unselectedWindowHasNoLift() {
        #expect(
            PlateMotion.windowLift(isSelected: false, isDragging: false, isDarkMode: false)
                == .init(shadowOpacity: 0, shadowRadius: 0, shadowY: 0)
        )
        #expect(
            PlateMotion.windowLift(isSelected: false, isDragging: false, isDarkMode: true)
                == .init(shadowOpacity: 0, shadowRadius: 0, shadowY: 0)
        )
    }

    @Test("The selected window keeps its light-mode shadow unchanged")
    func selectedWindowLiftInLightMode() {
        #expect(
            PlateMotion.windowLift(isSelected: true, isDragging: false, isDarkMode: false)
                == .init(shadowOpacity: 0.24, shadowRadius: 8, shadowY: 4)
        )
    }

    @Test("Dark mode deepens the selected window shadow")
    func selectedWindowLiftInDarkMode() {
        let dark = PlateMotion.windowLift(isSelected: true, isDragging: false, isDarkMode: true)
        let light = PlateMotion.windowLift(isSelected: true, isDragging: false, isDarkMode: false)

        #expect(dark.shadowOpacity > light.shadowOpacity)
        #expect(dark.shadowRadius > light.shadowRadius)
    }

    @Test("Dragging suppresses the selected window's shadow")
    func draggingWindowDropsItsLift() {
        for isDarkMode in [true, false] {
            #expect(
                PlateMotion.windowLift(
                    isSelected: true,
                    isDragging: true,
                    isDarkMode: isDarkMode
                ).shadowOpacity == 0
            )
        }
    }

    @Test("Window drops allow reordered and cross-stage positions")
    func windowDropPolicy() {
        #expect(!PlateInteraction.shouldMoveWindow(
            fromStageIndex: 1,
            fromWindowIndex: 1,
            to: WindowDropTarget(stageIndex: 1, windowIndex: 1)
        ))
        #expect(PlateInteraction.shouldMoveWindow(
            fromStageIndex: 1,
            fromWindowIndex: 1,
            to: WindowDropTarget(stageIndex: 1, windowIndex: 2)
        ))
        #expect(PlateInteraction.shouldMoveWindow(
            fromStageIndex: 1,
            fromWindowIndex: 1,
            to: WindowDropTarget(stageIndex: 2, windowIndex: 0)
        ))
        #expect(!PlateInteraction.shouldMoveWindow(
            fromStageIndex: 1,
            fromWindowIndex: 1,
            to: nil
        ))
    }

    @Test("Window drop position ignores the dragged card in its source stage")
    func windowDropPositionIgnoresDraggedCard() {
        let plateFrames = [
            0: CGRect(x: 0, y: 0, width: 360, height: 160),
            1: CGRect(x: 0, y: 180, width: 360, height: 160),
        ]
        let windowFrames = [
            WindowFrameID(stageIndex: 0, windowIndex: 0): CGRect(x: 20, y: 20, width: 90, height: 100),
            WindowFrameID(stageIndex: 0, windowIndex: 1): CGRect(x: 130, y: 20, width: 90, height: 100),
            WindowFrameID(stageIndex: 0, windowIndex: 2): CGRect(x: 240, y: 20, width: 90, height: 100),
            WindowFrameID(stageIndex: 1, windowIndex: 0): CGRect(x: 20, y: 200, width: 90, height: 100),
            WindowFrameID(stageIndex: 1, windowIndex: 1): CGRect(x: 130, y: 200, width: 90, height: 100),
        ]

        #expect(PlateInteraction.windowDropTarget(
            at: CGPoint(x: 300, y: 80),
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            plateFrames: plateFrames,
            windowFrames: windowFrames
        ) == WindowDropTarget(stageIndex: 0, windowIndex: 2))
        #expect(PlateInteraction.windowDropTarget(
            at: CGPoint(x: 125, y: 240),
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            plateFrames: plateFrames,
            windowFrames: windowFrames
        ) == WindowDropTarget(stageIndex: 1, windowIndex: 1))
    }

    @Test("Same-stage drag animates windows into their prospective MRU order")
    func sameStageWindowDragOffsets() {
        let drag = WindowDragState(
            windowID: 42,
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            location: .zero,
            dropTarget: WindowDropTarget(stageIndex: 0, windowIndex: 2)
        )

        #expect(PlateMotion.windowDragOffset(
            stageIndex: 0, windowIndex: 0, drag: drag, cardStride: 100
        ) == 200)
        #expect(PlateMotion.windowDragOffset(
            stageIndex: 0, windowIndex: 1, drag: drag, cardStride: 100
        ) == -100)
        #expect(PlateMotion.windowDragOffset(
            stageIndex: 0, windowIndex: 2, drag: drag, cardStride: 100
        ) == -100)

        let reverseDrag = WindowDragState(
            windowID: 42,
            sourceStageIndex: 0,
            sourceWindowIndex: 2,
            location: .zero,
            dropTarget: WindowDropTarget(stageIndex: 0, windowIndex: 0)
        )
        #expect(PlateMotion.windowDragOffset(
            stageIndex: 0, windowIndex: 0, drag: reverseDrag, cardStride: 100
        ) == 100)
        #expect(PlateMotion.windowDragOffset(
            stageIndex: 0, windowIndex: 2, drag: reverseDrag, cardStride: 100
        ) == -200)
    }

    @Test("Cross-stage drag opens an insertion gap and closes the source gap")
    func crossStageWindowDragOffsets() {
        let drag = WindowDragState(
            windowID: 42,
            sourceStageIndex: 0,
            sourceWindowIndex: 1,
            location: .zero,
            dropTarget: WindowDropTarget(stageIndex: 1, windowIndex: 1)
        )

        #expect(PlateMotion.displayedWindowCounts(actual: [3, 2], drag: drag) == [2, 3])
        #expect(PlateMotion.windowDragOffset(
            stageIndex: 0, windowIndex: 0, drag: drag, cardStride: 100
        ) == 0)
        #expect(PlateMotion.windowDragOffset(
            stageIndex: 0, windowIndex: 2, drag: drag, cardStride: 100
        ) == -100)
        #expect(PlateMotion.windowDragOffset(
            stageIndex: 1, windowIndex: 0, drag: drag, cardStride: 100
        ) == 0)
        #expect(PlateMotion.windowDragOffset(
            stageIndex: 1, windowIndex: 1, drag: drag, cardStride: 100
        ) == 100)
        #expect(PlateMotion.windowGridCenterOffset(
            stageIndex: 0, drag: drag, cardStride: 100
        ) == 50)
        #expect(PlateMotion.windowGridCenterOffset(
            stageIndex: 1, drag: drag, cardStride: 100
        ) == 0)
        #expect(PlateMotion.windowGridCenterOffset(
            stageIndex: 2, drag: drag, cardStride: 100
        ) == 0)
    }

    @Test("Released preview snaps to same-stage, cross-stage, and empty-stage slots")
    func releasedPreviewDestination() {
        let frames = [
            WindowFrameID(stageIndex: 0, windowIndex: 0): CGRect(x: 20, y: 20, width: 80, height: 100),
            WindowFrameID(stageIndex: 0, windowIndex: 1): CGRect(x: 120, y: 20, width: 80, height: 100),
            WindowFrameID(stageIndex: 0, windowIndex: 2): CGRect(x: 220, y: 20, width: 80, height: 100),
            WindowFrameID(stageIndex: 1, windowIndex: 0): CGRect(x: 20, y: 200, width: 80, height: 100),
            WindowFrameID(stageIndex: 1, windowIndex: 1): CGRect(x: 120, y: 200, width: 80, height: 100),
        ]
        let plates = [
            0: CGRect(x: 0, y: 0, width: 340, height: 160),
            1: CGRect(x: 0, y: 180, width: 240, height: 160),
            2: CGRect(x: 0, y: 360, width: 140, height: 160),
        ]

        #expect(PlateMotion.windowDropDestination(
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            target: WindowDropTarget(stageIndex: 0, windowIndex: 2),
            cardStride: 100,
            plateFrames: plates,
            windowFrames: frames
        ) == CGPoint(x: 260, y: 70))
        #expect(PlateMotion.windowDropDestination(
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            target: WindowDropTarget(stageIndex: 1, windowIndex: 1),
            cardStride: 100,
            plateFrames: plates,
            windowFrames: frames
        ) == CGPoint(x: 160, y: 250))
        #expect(PlateMotion.windowDropDestination(
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            target: WindowDropTarget(stageIndex: 2, windowIndex: 0),
            cardStride: 100,
            plateFrames: plates,
            windowFrames: frames
        ) == CGPoint(x: 70, y: 434))
    }

    @Test("A press without meaningful movement selects instead of starting a drag")
    func clickAndDragThreshold() {
        #expect(PlateInteraction.isWindowClick(translation: .zero))
        #expect(PlateInteraction.isWindowClick(translation: CGSize(width: 3, height: 4)))
        #expect(!PlateInteraction.isWindowClick(translation: CGSize(width: 6, height: 0)))
        #expect(!PlateInteraction.isWindowClick(translation: CGSize(width: 5, height: 5)))
    }

    @Test("Finishing a window drop clears drag state before requesting the move")
    func windowDropClearsDragBeforeMoveRequest() {
        var drag: WindowDragState? = WindowDragState(
            windowID: 42,
            sourceStageIndex: 1,
            sourceWindowIndex: 0,
            location: CGPoint(x: 100, y: 200),
            dropTarget: WindowDropTarget(stageIndex: 2, windowIndex: 3)
        )

        let request = PlateInteraction.finishWindowDrag(&drag)

        #expect(drag == nil)
        #expect(request == WindowMoveRequest(
            windowID: 42,
            fromStageIndex: 1,
            fromWindowIndex: 0,
            toStageIndex: 2,
            toWindowIndex: 3
        ))
    }

    @Test("Stage drag translation maps to a clamped destination")
    func stageDragDestination() {
        #expect(PlateInteraction.stageDestination(
            from: 1,
            translation: 49,
            plateStride: 100,
            stageCount: 4
        ) == nil)
        #expect(PlateInteraction.stageDestination(
            from: 1,
            translation: 50,
            plateStride: 100,
            stageCount: 4
        ) == 2)
        #expect(PlateInteraction.stageDestination(
            from: 2,
            translation: -100,
            plateStride: 100,
            stageCount: 4
        ) == 1)
        #expect(PlateInteraction.stageDestination(
            from: 1,
            translation: 500,
            plateStride: 100,
            stageCount: 4
        ) == 3)
        #expect(PlateInteraction.stageDestination(
            from: 2,
            translation: -500,
            plateStride: 100,
            stageCount: 4
        ) == 0)
    }

    @Test("Stage drag destination rejects invalid layouts")
    func stageDragDestinationRejectsInvalidLayouts() {
        #expect(PlateInteraction.stageDestination(
            from: 0,
            translation: 100,
            plateStride: 0,
            stageCount: 3
        ) == nil)
        #expect(PlateInteraction.stageDestination(
            from: 0,
            translation: 100,
            plateStride: 100,
            stageCount: 1
        ) == nil)
        #expect(PlateInteraction.stageDestination(
            from: -1,
            translation: 100,
            plateStride: 100,
            stageCount: 3
        ) == nil)
    }

    @Test("A held plate keeps every slot filled as it travels")
    func stageDragSlots() {
        #expect(PlateMotion.stageDragSlots(stageCount: 3, from: 1, to: 0) == [1, 0, 2])
        #expect(PlateMotion.stageDragSlots(stageCount: 3, from: 0, to: 2) == [2, 0, 1])
        #expect(PlateMotion.stageDragSlots(stageCount: 3, from: 1, to: 1) == [0, 1, 2])
        #expect(PlateMotion.stageDragSlots(stageCount: 4, from: 3, to: 1) == [0, 2, 3, 1])
    }

    @Test("An out-of-range hold leaves the stack in its resting order")
    func stageDragSlotsRejectInvalidMoves() {
        #expect(PlateMotion.stageDragSlots(stageCount: 3, from: 5, to: 0) == [0, 1, 2])
        #expect(PlateMotion.stageDragSlots(stageCount: 3, from: 0, to: 9) == [0, 1, 2])
        #expect(PlateMotion.stageDragSlots(stageCount: 0, from: 0, to: 0) == [])
    }

    /// The held plate is the focus wherever it currently sits, so it renders at full size for
    /// the whole gesture instead of shrinking as it passes over the stages it displaces.
    @Test("A held plate stays full size and the stack magnifies around its position")
    func heldPlateKeepsFocusScale() {
        let stageCount = 3
        let source = 2
        let destination = 1
        let slots = PlateMotion.stageDragSlots(
            stageCount: stageCount,
            from: source,
            to: destination
        )
        let layout = PlateMotion.stackLayout(
            stageCount: stageCount,
            focusIndex: PlateMotion.focusedStageIndex(
                active: 0,
                hovered: nil,
                dragTarget: destination,
                retainedDragTarget: nil,
                stageCount: stageCount
            ),
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )

        #expect(layout.scales[slots[source]] == 1)
        #expect(layout.scales[slots[0]] < layout.scales[slots[source]])
        #expect(layout.scales[slots[1]] < layout.scales[slots[source]])
    }

    @Test("Horizontal movement never moves a held plate")
    func stageDragIgnoresHorizontalMovement() {
        let straight = PlateInteraction.stageDragDestination(
            from: 1,
            translation: CGSize(width: 0, height: 120),
            plateStride: 100,
            stageCount: 4
        )
        let swerving = PlateInteraction.stageDragDestination(
            from: 1,
            translation: CGSize(width: 400, height: 120),
            plateStride: 100,
            stageCount: 4
        )

        #expect(straight == 2)
        #expect(swerving == straight)
    }

    @Test("A hold that has not travelled a full slot keeps its own position")
    func stageDragDestinationHoldsSourceSlot() {
        #expect(PlateInteraction.stageDragDestination(
            from: 1,
            translation: CGSize(width: 0, height: 20),
            plateStride: 100,
            stageCount: 4
        ) == 1)
        #expect(PlateInteraction.stageDragDestination(
            from: 1,
            translation: CGSize(width: 0, height: -900),
            plateStride: 100,
            stageCount: 4
        ) == 0)
    }

    @Test("The drag handle gutter still counts as the plate for magnification")
    func hoverFocusCoversHandleGutter() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 1,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let leadingEdge: CGFloat = 500 / 2 - 300 / 2

        #expect(PlateInteraction.hoveredStageIndex(
            previous: nil,
            at: CGPoint(x: leadingEdge - 10, y: layout.centers[1]),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: [200, 300, 200],
            currentLayout: layout
        ) == 1)
        #expect(PlateInteraction.hoveredStageIndex(
            previous: nil,
            at: CGPoint(
                x: leadingEdge - PlateConstants.stageHandleGutterWidth - 10,
                y: layout.centers[1]
            ),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: [200, 300, 200],
            currentLayout: layout
        ) == nil)
    }

    @Test("The drag handle reveals from the gutter of any plate, not just the current one")
    func stageHandleRevealFollowsPlateGeometry() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 1,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let inactiveWidth: CGFloat = 200 * layout.scales[2]
        let inactiveLeadingEdge: CGFloat = 500 / 2 - inactiveWidth / 2

        #expect(PlateInteraction.revealedStageHandleIndex(
            previous: nil,
            at: CGPoint(x: inactiveLeadingEdge - 6, y: layout.centers[2]),
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: [200, 300, 200],
            layout: layout
        ) == 2)
        #expect(PlateInteraction.revealedStageHandleIndex(
            previous: nil,
            at: CGPoint(x: 250, y: layout.centers[2]),
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: [200, 300, 200],
            layout: layout
        ) == nil)
    }

    /// Revealing the handle widens the plate, which slides the pointer deeper into it. Without
    /// hysteresis that immediately fails the reveal test and the handle flickers.
    @Test("A revealed handle survives the plate growing under a still pointer")
    func stageHandleRevealHoldsThroughExpansion() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let leadingEdge: CGFloat = 500 / 2 - 300 / 2
        let deeperIn = CGPoint(
            x: leadingEdge + PlateConstants.stageHandleHoverWidth + 8,
            y: layout.centers[0]
        )

        #expect(PlateInteraction.revealedStageHandleIndex(
            previous: nil,
            at: deeperIn,
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: [300, 300],
            layout: layout
        ) == nil)
        #expect(PlateInteraction.revealedStageHandleIndex(
            previous: 0,
            at: deeperIn,
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: [300, 300],
            layout: layout
        ) == 0)
    }

    @Test("The add-stage affordance reveals just beyond the first and last plate edges")
    func stageInsertionEdgeReveal() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 1,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [200, 300, 200]
        let firstTop = layout.centers[0] - layout.heights[0] / 2
        let lastBottom = layout.centers[2] + layout.heights[2] / 2
        let edge: (CGPoint) -> StageInsertionEdge? = {
            PlateInteraction.stageInsertionEdge(
                previous: nil,
                at: $0,
                containerWidth: 500,
                stackOffset: 0,
                plateWidths: widths,
                layout: layout
            )
        }

        #expect(edge(CGPoint(x: 250, y: firstTop - 10)) == .top)
        #expect(edge(CGPoint(x: 250, y: lastBottom + 10)) == .bottom)
        #expect(edge(CGPoint(x: 250, y: layout.centers[1])) == nil)
        #expect(edge(CGPoint(
            x: 250,
            y: firstTop - PlateConstants.stageInsertHoverHeight - 1
        )) == nil)
        #expect(edge(CGPoint(x: 20, y: firstTop - 10)) == nil)
    }

    /// Entering the band magnifies the end plate, which grows its edge past the stationary
    /// pointer. Without stickiness the affordance would vanish before it could be clicked.
    @Test("A revealed add-stage band survives the plate growing over the pointer")
    func stageInsertionEdgeStaysRevealedWhenThePlateGrows() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [300, 200, 200]
        let firstTop = layout.centers[0] - layout.heights[0] / 2
        let swallowed = CGPoint(x: 250, y: firstTop + 10)
        let edge: (StageInsertionEdge?, CGPoint) -> StageInsertionEdge? = {
            PlateInteraction.stageInsertionEdge(
                previous: $0,
                at: $1,
                containerWidth: 500,
                stackOffset: 0,
                plateWidths: widths,
                layout: layout
            )
        }

        #expect(edge(nil, swallowed) == nil)
        #expect(edge(.top, swallowed) == .top)
        #expect(edge(.bottom, swallowed) == nil)
        #expect(edge(.top, CGPoint(
            x: 250,
            y: firstTop + PlateConstants.stageInsertStickyDepth + 1
        )) == nil)
    }

    @Test("The add-stage band keeps the end plate magnified")
    func hoveredStageIndexFollowsTheInsertBand() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 1,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [200, 300, 200]
        let firstTop = layout.centers[0] - layout.heights[0] / 2
        let lastBottom = layout.centers[2] + layout.heights[2] / 2
        let hovered: (CGPoint) -> Int? = {
            PlateInteraction.hoveredStageIndex(
                previous: nil,
                at: $0,
                containerWidth: 500,
                currentStackOffset: 0,
                plateWidths: widths,
                currentLayout: layout
            )
        }

        #expect(hovered(CGPoint(x: 250, y: firstTop - 10)) == 0)
        #expect(hovered(CGPoint(x: 250, y: lastBottom + 10)) == 2)
        #expect(hovered(CGPoint(
            x: 250,
            y: firstTop - PlateConstants.stageInsertHoverHeight - 1
        )) == nil)
    }

    @Test("The add-stage button sits inside the band that reveals it")
    func stageInsertButtonSitsInsideItsHoverBand() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [300, 240]

        for insertionEdge in [StageInsertionEdge.top, .bottom] {
            let center = PlateMotion.stageInsertButtonCenter(
                edge: insertionEdge,
                containerWidth: 500,
                stackOffset: 40,
                layout: layout
            )
            #expect(center?.x == 250)
            #expect(PlateInteraction.stageInsertionEdge(
                previous: nil,
                at: center ?? .zero,
                containerWidth: 500,
                stackOffset: 40,
                plateWidths: widths,
                layout: layout
            ) == insertionEdge)
        }
    }

    @Test("An empty stack offers no add-stage affordance")
    func stageInsertionEdgeRequiresPlates() {
        let empty = PlateStackLayout(scales: [], heights: [], centers: [], totalHeight: 0)

        #expect(PlateInteraction.stageInsertionEdge(
            previous: nil,
            at: .zero,
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: [],
            layout: empty
        ) == nil)
        #expect(PlateMotion.stageInsertButtonCenter(
            edge: .top,
            containerWidth: 500,
            stackOffset: 0,
            layout: empty
        ) == nil)
    }

    @Test("The close affordance reveals near a plate's top-right corner")
    func stageCloseReveal() {
        let layout = PlateMotion.stackLayout(
            stageCount: 3,
            focusIndex: 1,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [200, 300, 200]
        let closeIndex: (CGPoint) -> Int? = {
            PlateInteraction.revealedStageCloseIndex(
                at: $0,
                containerWidth: 500,
                stackOffset: 0,
                plateWidths: widths,
                layout: layout,
                cornerRadius: 0
            )
        }
        let secondCorner = CGPoint(
            x: 250 + widths[1] * layout.scales[1] / 2,
            y: layout.centers[1] - layout.heights[1] / 2
        )

        #expect(closeIndex(secondCorner) == 1)
        #expect(closeIndex(CGPoint(x: 250, y: layout.centers[1])) == nil)
        #expect(closeIndex(CGPoint(
            x: secondCorner.x - PlateConstants.stageCloseHoverSize,
            y: secondCorner.y
        )) == nil)
    }

    @Test("The close button sits inside the corner zone that reveals it")
    func stageCloseButtonSitsInsideItsHoverZone() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.8
        )
        let widths: [CGFloat] = [300, 240]

        for index in 0..<2 {
            let center = PlateMotion.stageCloseButtonCenter(
                at: index,
                containerWidth: 500,
                stackOffset: 40,
                plateWidths: widths,
                layout: layout,
                cornerRadius: 40
            )
            #expect(PlateInteraction.revealedStageCloseIndex(
                at: center ?? .zero,
                containerWidth: 500,
                stackOffset: 40,
                plateWidths: widths,
                layout: layout,
                cornerRadius: 40
            ) == index)
            #expect(PlateInteraction.isStageCloseButtonHit(
                center ?? .zero,
                center: center ?? .zero
            ))
        }
    }

    /// The button has to ride the plate's visible border, so a rounded corner pulls it down and
    /// to the left along the arc; a square corner leaves it exactly on the corner point.
    @Test("The close button follows the plate corner radius")
    func stageCloseButtonFollowsCornerRadius() {
        let layout = PlateMotion.stackLayout(
            stageCount: 2,
            focusIndex: 0,
            plateHeight: 100,
            spacing: 12,
            inactiveScale: 0.5
        )
        let widths: [CGFloat] = [300, 240]
        let center: (Int, CGFloat) -> CGPoint? = {
            PlateMotion.stageCloseButtonCenter(
                at: $0,
                containerWidth: 500,
                stackOffset: 0,
                plateWidths: widths,
                layout: layout,
                cornerRadius: $1
            )
        }
        let sharpCorner: (Int) -> CGPoint = { index in
            CGPoint(
                x: 250 + widths[index] * layout.scales[index] / 2,
                y: layout.centers[index] - layout.heights[index] / 2
            )
        }

        #expect(center(0, 0) == sharpCorner(0))

        let inset = 40 * (1 - 1 / 2.0.squareRoot())
        #expect(abs((center(0, 40)?.x ?? 0) - (sharpCorner(0).x - inset)) < 0.001)
        #expect(abs((center(0, 40)?.y ?? 0) - (sharpCorner(0).y + inset)) < 0.001)

        // The scaled-down plate draws a scaled-down radius, so its inset shrinks to match.
        #expect(abs((center(1, 40)?.x ?? 0) - (sharpCorner(1).x - inset * layout.scales[1])) < 0.001)
        #expect(abs((center(1, 40)?.y ?? 0) - (sharpCorner(1).y + inset * layout.scales[1])) < 0.001)
    }

    @Test("An empty stack offers no close affordance")
    func stageCloseRequiresPlates() {
        let empty = PlateStackLayout(scales: [], heights: [], centers: [], totalHeight: 0)

        #expect(PlateInteraction.revealedStageCloseIndex(
            at: .zero,
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: [],
            layout: empty,
            cornerRadius: 0
        ) == nil)
        #expect(PlateMotion.stageCloseButtonCenter(
            at: 0,
            containerWidth: 500,
            stackOffset: 0,
            plateWidths: [],
            layout: empty,
            cornerRadius: 0
        ) == nil)
    }

    @Test("The drag handle takes whichever tint reads against the wallpaper")
    func dragHandleTintFollowsBackgroundLuminance() {
        #expect(PlateContrast.handleTintWhiteLevel(backgroundLuminance: 0) == 1)
        #expect(PlateContrast.handleTintWhiteLevel(backgroundLuminance: 0.2) == 1)
        #expect(PlateContrast.handleTintWhiteLevel(backgroundLuminance: 0.8) == 0)
        #expect(PlateContrast.handleTintWhiteLevel(backgroundLuminance: 1) == 0)

        // The crossover sits below the 0.5 midpoint, so a mid-gray wallpaper takes a dark handle.
        #expect(PlateContrast.handleTintWhiteLevel(backgroundLuminance: 0.5) == 0)
        #expect(PlateContrast.handleTintWhiteLevel(
            backgroundLuminance: PlateContrast.handleTintThreshold - 0.01
        ) == 1)
    }

    /// An unmeasured wallpaper must not darken the handle: the desktop surface paints black
    /// underneath, so a dark glyph there would be invisible.
    @Test("An unknown background leaves the drag handle light")
    func dragHandleTintDefaultsToLight() {
        #expect(PlateContrast.handleTintWhiteLevel(backgroundLuminance: nil) == 1)
    }

    /// The handle is the only draggable thing on a plate and nothing about its bars says so.
    /// The cursor is what says so, and it has to say it only where the handle actually is.
    @Test("The drag handle claims a grab cursor only while it is revealed")
    func stageHandleGrabFollowsReveal() {
        #expect(PlateInteraction.stageHandleGrab(isRevealed: false, isDragging: false) == nil)
        #expect(PlateInteraction.stageHandleGrab(isRevealed: true, isDragging: false) == .open)
        #expect(PlateInteraction.stageHandleGrab(isRevealed: true, isDragging: true) == .closed)
    }

    /// A stage drag survives the pointer wandering off the handle — that is why the handle stays
    /// revealed mid-gesture — so the hand has to stay closed for the whole drag.
    @Test("A drag keeps the closed hand even once the handle stops being revealed")
    func stageHandleGrabHoldsThroughDrag() {
        #expect(PlateInteraction.stageHandleGrab(isRevealed: false, isDragging: true) == .closed)
    }

    /// Where a tap on the overlay actually goes. The buttons are drawn with hit testing off and
    /// float over — or straddle — the plates, so this routing is the whole of their behaviour.
    @Test("A tap on a revealed stage button routes to that button, not the desktop")
    func overlayTapRoutesToStageButtons() {
        let plateFrames = [0: CGRect(x: 100, y: 100, width: 300, height: 200)]
        let insertCenter = CGPoint(x: 250, y: 60)
        let closeCenter = CGPoint(x: 390, y: 110)
        let route: (CGPoint, StageInsertionEdge?, Int?) -> OverlayTapTarget = {
            PlateInteraction.overlayTapTarget(
                at: $0,
                revealedInsertionEdge: $1,
                insertButtonCenter: insertCenter,
                revealedCloseIndex: $2,
                closeButtonCenter: closeCenter,
                plateFrames: plateFrames
            )
        }

        #expect(route(insertCenter, .top, nil) == .insertStage(.top))
        #expect(route(insertCenter, .bottom, nil) == .insertStage(.bottom))

        // The close button sits on the plate's corner, so its tap must win over the plate.
        #expect(route(closeCenter, nil, 0) == .deleteStage(0))
        #expect(route(closeCenter, nil, 2) == .deleteStage(2))

        // A button that is not revealed cannot be tapped, however close the pointer is.
        #expect(route(insertCenter, nil, nil) == .desktop)
        #expect(route(closeCenter, nil, nil) == .none)
    }

    @Test("A tap away from every stage button keeps the desktop behaviour")
    func overlayTapFallsThroughToDesktop() {
        let plateFrames = [0: CGRect(x: 100, y: 100, width: 300, height: 200)]
        let route: (CGPoint) -> OverlayTapTarget = {
            PlateInteraction.overlayTapTarget(
                at: $0,
                revealedInsertionEdge: .top,
                insertButtonCenter: CGPoint(x: 250, y: 60),
                revealedCloseIndex: 0,
                closeButtonCenter: CGPoint(x: 390, y: 110),
                plateFrames: plateFrames
            )
        }

        #expect(route(CGPoint(x: 900, y: 500)) == .desktop)
        #expect(route(CGPoint(x: 250, y: 200)) == .none)

        // Just outside a button's radius is a miss, not a near-enough hit.
        let justOutside = PlateConstants.stageInsertButtonSize / 2 + 1
        #expect(route(CGPoint(x: 250 + justOutside, y: 60)) == .desktop)
    }

    /// The buttons can overlap: the insert button sits above the first plate, near the corner
    /// its close button rides. A tap can only ever do one thing.
    @Test("Overlapping stage buttons resolve to a single action")
    func overlayTapPrefersInsertWhenButtonsOverlap() {
        let shared = CGPoint(x: 250, y: 60)

        #expect(PlateInteraction.overlayTapTarget(
            at: shared,
            revealedInsertionEdge: .top,
            insertButtonCenter: shared,
            revealedCloseIndex: 0,
            closeButtonCenter: shared,
            plateFrames: [:]
        ) == .insertStage(.top))
    }

    @Test("A stale pointer exit cannot clear the newly hovered window")
    func stalePointerExitDoesNotClearSelection() {
        let first = PointerSelection(stageIndex: 0, windowIndex: 0)
        let second = PointerSelection(stageIndex: 0, windowIndex: 1)

        #expect(PlateInteraction.pointerSelection(current: nil, target: first, isHovering: true) == first)
        #expect(PlateInteraction.pointerSelection(current: first, target: second, isHovering: true) == second)
        #expect(PlateInteraction.pointerSelection(current: second, target: first, isHovering: false) == second)
        #expect(PlateInteraction.pointerSelection(current: second, target: second, isHovering: false) == nil)
    }

    @Test("Only points outside every plate select the desktop")
    func desktopAreaSelection() {
        let plateFrames = [
            0: CGRect(x: 300, y: 200, width: 400, height: 300),
            1: CGRect(x: 350, y: 540, width: 300, height: 200),
        ]

        #expect(PlateInteraction.isDesktopArea(
            CGPoint(x: 100, y: 100),
            plateFrames: plateFrames
        ))
        #expect(!PlateInteraction.isDesktopArea(
            CGPoint(x: 500, y: 350),
            plateFrames: plateFrames
        ))
    }

    @Test("A stationary pointer is ignored until it moves after the overlay appears")
    func stationaryPointerDoesNotSelect() {
        var gate = PointerMovementGate()
        let initialLocation = CGPoint(x: 400, y: 300)

        gate.reset(at: initialLocation)

        let acceptedWithoutMovement = gate.observe(at: initialLocation)
        let acceptedAfterMovement = gate.observe(at: CGPoint(x: 401, y: 300))
        let remainedEnabled = gate.observe(at: initialLocation)

        #expect(!acceptedWithoutMovement)
        #expect(acceptedAfterMovement)
        #expect(remainedEnabled)
    }
}
