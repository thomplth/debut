import Testing
import CoreGraphics
@testable import DebutCore

@Suite("Plate motion")
struct PlateMotionTests {
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

        #expect(PlateInteraction.hoveredStageIndex(
            previous: 0,
            at: CGPoint(x: 250, y: -1),
            containerWidth: 500,
            currentStackOffset: 0,
            plateWidths: widths,
            currentLayout: layout
        ) == nil)
        #expect(PlateInteraction.hoveredStageIndex(
            previous: 1,
            at: CGPoint(x: 250, y: 201),
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
        #expect(PlateMotion.focusedStageIndex(active: 2, hovered: nil, dragTarget: nil) == 2)
        #expect(PlateMotion.focusedStageIndex(active: 2, hovered: 4, dragTarget: nil) == 4)
        #expect(PlateMotion.focusedStageIndex(active: 2, hovered: 4, dragTarget: 1) == 1)
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

    @Test("Stage drag handle expands only the visual leading edge")
    func stageDragHandleExpansion() {
        #expect(PlateMotion.stageHandleExpansion(isRevealed: false) == 0)
        #expect(
            PlateMotion.stageHandleExpansion(isRevealed: true)
                == PlateConstants.stageHandleRevealWidth
        )
    }

    @Test("Stage drag handle hotspot uses hysteresis while revealed")
    func stageDragHandleHotspot() {
        #expect(PlateInteraction.isStageHandleHotspot(locationX: 12, isRevealed: false))
        #expect(!PlateInteraction.isStageHandleHotspot(locationX: 40, isRevealed: false))
        #expect(PlateInteraction.isStageHandleHotspot(locationX: 58, isRevealed: true))
        #expect(!PlateInteraction.isStageHandleHotspot(locationX: 80, isRevealed: true))
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

    @Test("A stale pointer exit cannot clear the newly hovered window")
    func stalePointerExitDoesNotClearSelection() {
        let first = PointerSelection(stageIndex: 0, windowIndex: 0)
        let second = PointerSelection(stageIndex: 0, windowIndex: 1)

        #expect(PlateInteraction.pointerSelection(current: nil, target: first, isHovering: true) == first)
        #expect(PlateInteraction.pointerSelection(current: first, target: second, isHovering: true) == second)
        #expect(PlateInteraction.pointerSelection(current: second, target: first, isHovering: false) == second)
        #expect(PlateInteraction.pointerSelection(current: second, target: second, isHovering: false) == nil)
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
