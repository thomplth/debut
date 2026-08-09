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
