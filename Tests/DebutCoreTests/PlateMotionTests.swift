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

    @Test("Pointer and drag targets magnify to full plate scale")
    func interactionTargetPlateScale() {
        #expect(PlateMotion.plateScale(isSelected: false, isInteractionTarget: false, inactiveScale: 0.72) == 0.72)
        #expect(PlateMotion.plateScale(isSelected: false, isInteractionTarget: true, inactiveScale: 0.72) == 1)
        #expect(PlateMotion.plateScale(isSelected: true, isInteractionTarget: false, inactiveScale: 0.72) == 1)
    }

    @Test("Magnifying a drag target does not expand its layout slot")
    func interactionTargetKeepsInactiveLayoutScale() {
        let visualScale = PlateMotion.plateScale(
            isSelected: false,
            isInteractionTarget: true,
            inactiveScale: 0.72
        )
        let layoutScale = PlateMotion.plateLayoutScale(
            isSelected: false,
            inactiveScale: 0.72
        )

        #expect(visualScale == 1)
        #expect(layoutScale == 0.72)
        #expect(PlateMotion.plateLayoutScale(isSelected: true, inactiveScale: 0.72) == 1)
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

    @Test("Plate centers keep the active stage centered")
    func plateCentersFollowOverlayLayout() {
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

    @Test("Window drops only move across stages")
    func crossStageDropPolicy() {
        #expect(!PlateInteraction.shouldMoveWindow(fromStageIndex: 1, toStageIndex: 1))
        #expect(PlateInteraction.shouldMoveWindow(fromStageIndex: 1, toStageIndex: 2))
        #expect(!PlateInteraction.shouldMoveWindow(fromStageIndex: 1, toStageIndex: nil))
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
            dropTargetStageIndex: 2
        )

        let request = PlateInteraction.finishWindowDrag(&drag)

        #expect(drag == nil)
        #expect(request == WindowMoveRequest(windowID: 42, fromStageIndex: 1, toStageIndex: 2))
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
