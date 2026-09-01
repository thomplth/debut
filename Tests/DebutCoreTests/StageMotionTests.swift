import Testing
import CoreGraphics
import Foundation
@testable import DebutCore

@Suite("Stage motion")
struct StageMotionTests {
    /// A stage laid out on a display exactly wide enough for `capacity` cards.
    private func grid(_ windowCount: Int, capacity: Int) -> StageWindowLayout {
        let metrics = StageMetrics.standard
        return StageWindowLayout(
            windowCount: windowCount,
            availableWidth: metrics.padding * 2
                + metrics.cardWidth * CGFloat(capacity)
                + metrics.windowSpacing * CGFloat(capacity - 1),
            metrics: metrics
        )
    }

    private func uniformStack(
        _ spaceCount: Int,
        focus: Int,
        height: CGFloat,
        spacing: CGFloat,
        inactiveScale: CGFloat
    ) -> StageStackLayout {
        StageMotion.stackLayout(
            stageHeights: Array(repeating: height, count: spaceCount),
            focusIndex: focus,
            spacing: spacing,
            inactiveScale: inactiveScale
        )
    }

    @Test("Deleting the first space changes the layout animation key")
    func deletingFirstSpaceTriggersMotion() {
        let first = UUID()
        let second = UUID()
        let before = StageMotion.layoutAnimationKey(
            spaceIDs: [first, second],
            activeIndex: 0
        )
        let after = StageMotion.layoutAnimationKey(
            spaceIDs: [second],
            activeIndex: 0
        )

        #expect(before != after)
    }

    @Test("Space focus keeps its duration while settling without bounce")
    func stageFocusSettlesWithoutBounce() {
        #expect(
            StageMotion.focusTransition(reduceMotion: false)
                == .spring(duration: 0.26, bounce: 0)
        )
    }

    @Test("Reduce Motion replaces movement with a short fade")
    func reduceMotionUsesFade() {
        #expect(
            StageMotion.focusTransition(reduceMotion: true)
                == .fade(duration: 0.12)
        )
    }

    @Test("Window insertion uses brisk macOS-style motion")
    func windowInsertionUsesBriskMotion() {
        #expect(
            StageMotion.windowReorderTransition(reduceMotion: false)
                == .spring(duration: 0.294, bounce: 0.06)
        )
        #expect(
            StageMotion.windowReorderTransition(reduceMotion: true)
                == .fade(duration: 0.126)
        )
    }

    @Test("A departing window shrinks out rather than snapping")
    func windowRemovalUsesShrinkingMotion() {
        #expect(
            StageMotion.windowRemovalTransition(reduceMotion: false)
                == .spring(duration: 0.36, bounce: 0)
        )
        #expect(StageMotion.windowRemovalScale == 0.55)
        #expect(
            StageMotion.windowRemovalTransition(reduceMotion: true)
                == .fade(duration: 0.12)
        )
    }

    @Test("Window reorder motion stops when drag state is cleared")
    func windowReorderMotionEndsWithDrag() {
        #expect(
            StageMotion.windowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: true,
                isAwaitingCommittedLayout: false
            ) == .spring(duration: 0.294, bounce: 0.06)
        )
        #expect(
            StageMotion.windowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: true,
                isAwaitingCommittedLayout: true
            ) == nil
        )
        #expect(
            StageMotion.windowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: false,
                isAwaitingCommittedLayout: false
            ) == nil
        )
    }

    @Test("A keyboard reorder animates only when no drag is in flight")
    func keyboardWindowReorderMotionYieldsToDrag() {
        #expect(
            StageMotion.keyboardWindowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: false,
                isAwaitingCommittedLayout: false
            ) == .spring(duration: 0.294, bounce: 0.06)
        )
        #expect(
            StageMotion.keyboardWindowReorderTransition(
                reduceMotion: true,
                hasActiveDrag: false,
                isAwaitingCommittedLayout: false
            ) == .fade(duration: 0.126)
        )
        #expect(
            StageMotion.keyboardWindowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: true,
                isAwaitingCommittedLayout: false
            ) == nil
        )
        #expect(
            StageMotion.keyboardWindowReorderTransition(
                reduceMotion: false,
                hasActiveDrag: false,
                isAwaitingCommittedLayout: true
            ) == nil
        )
    }

    @Test("The window layout key sees a reorder that leaves the count alone")
    func windowLayoutKeyTracksOrderWithinASpace() {
        func stage(_ ids: [CGWindowID]) -> StageData {
            StageData(
                id: UUID(),
                windows: ids.map {
                    StageWindowData(
                        id: $0,
                        windowID: $0,
                        ownerBundleID: "com.example",
                        ownerName: "Example",
                        windowTitle: "Window \($0)",
                        previewImage: nil
                    )
                },
                isActive: true,
                index: 0
            )
        }

        let original = StageMotion.windowLayoutKey(for: [stage([1, 2, 3])])
        #expect(StageMotion.windowLayoutKey(for: [stage([1, 2, 3])]) == original)
        #expect(StageMotion.windowLayoutKey(for: [stage([2, 1, 3])]) != original)
    }

    @Test("Snapped preview waits for the committed window order")
    func snappedPreviewWaitsForCommittedLayout() {
        let request = WindowMoveRequest(
            windowID: 42,
            fromSpaceIndex: 0,
            fromWindowIndex: 0,
            toSpaceIndex: 1,
            toWindowIndex: 1
        )
        #expect(!StageMotion.isWindowDropApplied(
            request,
            to: WindowLayoutKey(spaceWindowIDs: [[42, 43], [50, 51]])
        ))
        #expect(StageMotion.isWindowDropApplied(
            request,
            to: WindowLayoutKey(spaceWindowIDs: [[43], [50, 42, 51]])
        ))
        #expect(!StageMotion.isWindowDropApplied(
            request,
            to: WindowLayoutKey(spaceWindowIDs: [[43], [42, 50, 51]])
        ))
    }

    @Test("Drag hides the stationary card and keeps the cursor preview opaque")
    func dragPreviewVisibility() {
        #expect(StageMotion.sourceWindowOpacity(isDragging: false) == 1)
        #expect(StageMotion.sourceWindowOpacity(isDragging: true) == 0)
        #expect(StageMotion.sourceWindowDisablesAnimation(isDragging: false) == false)
        #expect(StageMotion.sourceWindowDisablesAnimation(isDragging: true) == true)
        #expect(StageMotion.cursorPreviewOpacity == 1)
    }

    @Test("The active stage receives a subtle lift")
    func activeStageLift() {
        #expect(StageMotion.lift(isActive: true) == .init(shadowOpacity: 0.22, shadowRadius: 18, shadowY: 8))
        #expect(StageMotion.lift(isActive: false) == .init(shadowOpacity: 0.08, shadowRadius: 6, shadowY: 2))
    }

    @Test("Stage scale falls off with distance from focus")
    func distanceBasedStageScale() {
        #expect(StageMotion.stageScale(distanceFromFocus: 0, inactiveScale: 0.8) == 1)
        #expect(StageMotion.stageScale(distanceFromFocus: 1, inactiveScale: 0.8) == 0.8)
        #expect(abs(StageMotion.stageScale(distanceFromFocus: 2, inactiveScale: 0.8) - 0.64) < 0.001)
        #expect(abs(StageMotion.stageScale(distanceFromFocus: 8, inactiveScale: 0.8) - 0.16777216) < 0.001)
        #expect(StageMotion.stageScale(distanceFromFocus: 20, inactiveScale: 0.8) == 0.08)
    }

    @Test("Stages lay out in their own unscaled slot and reach their center by offset")
    func stageSlotOffsetCentersEachStage() {
        let layout = uniformStack(3, focus: 1, height: 180, spacing: 20, inactiveScale: 0.8)
        for index in 0..<3 {
            let offset = StageMotion.stageSlotOffset(layout: layout, index: index)
            #expect(abs(offset + 90 - layout.centers[index]) < 0.001)
        }
    }

    @Test("Stage slot offset is zero for an out-of-range index")
    func stageSlotOffsetOutOfRange() {
        let layout = uniformStack(2, focus: 0, height: 180, spacing: 20, inactiveScale: 0.8)
        #expect(StageMotion.stageSlotOffset(layout: layout, index: 5) == 0)
    }

    @Test("Spaces of unequal height keep their own scale, spacing, and centers")
    func variableHeightStack() {
        let layout = StageMotion.stackLayout(
            stageHeights: [180, 310, 180],
            focusIndex: 1,
            spacing: 20,
            inactiveScale: 0.5
        )

        #expect(layout.baseHeights == [180, 310, 180])
        #expect(layout.scales == [0.5, 1, 0.5])
        #expect(layout.heights == [90, 310, 90])
        #expect(layout.centers == [45, 265, 485])
        #expect(layout.totalHeight == 530)

        // Each stage reaches its stack center from its own unscaled slot, not a shared one.
        let firstSlot: CGFloat = 45 - 180 / 2
        let focusSlot: CGFloat = 265 - 310 / 2
        #expect(StageMotion.stageSlotOffset(layout: layout, index: 0) == firstSlot)
        #expect(StageMotion.stageSlotOffset(layout: layout, index: 1) == focusSlot)
    }

    @Test("A taller neighbour does not shift a stage off its own center")
    func variableHeightStageFrames() {
        let layout = StageMotion.stackLayout(
            stageHeights: [180, 310],
            focusIndex: 0,
            spacing: 20,
            inactiveScale: 0.5
        )
        let frame = StageMotion.stageFrame(
            at: 1,
            containerWidth: 600,
            stackOffset: 0,
            stageWidths: [400, 500],
            layout: layout
        )

        #expect(frame.midY == layout.centers[1])
        #expect(frame.height == 155)
        #expect(frame.width == 250)
    }

    @Test("Stage opacity stays solid until scale falls below twenty percent")
    func scaleThresholdStageOpacity() {
        #expect(StageMotion.stageOpacity(scale: 1) == 1)
        #expect(StageMotion.stageOpacity(scale: 0.21) == 1)
        #expect(StageMotion.stageOpacity(scale: 0.2) == 1)
        #expect(StageMotion.stageOpacity(scale: 0.1) == 0.25)
        #expect(StageMotion.stageOpacity(scale: 0.01) == 0.12)
    }

    @Test("Hover layout remains packed around its fixed anchor")
    func hoverLayoutUsesFixedAnchorAndSpacing() {
        let baseline = uniformStack(5, focus: 1, height: 100, spacing: 12, inactiveScale: 0.8)
        let hovered = uniformStack(5, focus: 3, height: 100, spacing: 12, inactiveScale: 0.8)
        let anchorY = baseline.centers[3]
        let offset = StageMotion.anchoredOffset(
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
    func stableSpaceHitTesting() {
        let layout = uniformStack(3, focus: 1, height: 100, spacing: 12, inactiveScale: 0.8)
        let widths: [CGFloat] = [200, 300, 200]

        #expect(StageInteraction.spaceIndex(
            at: CGPoint(x: 250, y: layout.centers[1]),
            containerWidth: 500,
            stackOffset: 0,
            stageWidths: widths,
            layout: layout
        ) == 1)
        #expect(StageInteraction.spaceIndex(
            at: CGPoint(x: 20, y: layout.centers[1]),
            containerWidth: 500,
            stackOffset: 0,
            stageWidths: widths,
            layout: layout
        ) == nil)
        #expect(StageInteraction.spaceIndex(
            at: CGPoint(x: 250, y: layout.centers[1] + 56),
            containerWidth: 500,
            stackOffset: 0,
            stageWidths: widths,
            layout: layout
        ) == nil)
    }

    @Test("Hover focus persists through a transit gap")
    func hoverFocusPersistsThroughTransitGap() {
        let layout = uniformStack(3, focus: 0, height: 100, spacing: 20, inactiveScale: 0.8)

        #expect(StageInteraction.hoveredSpaceIndex(
            previous: 2,
            at: CGPoint(x: 250, y: 110),
            containerWidth: 500,
            currentStackOffset: 0,
            stageWidths: [300, 240, 180],
            currentLayout: layout
        ) == 2)
        #expect(StageInteraction.hoveredSpaceIndex(
            previous: 2,
            at: CGPoint(x: 250, y: layout.centers[1]),
            containerWidth: 500,
            currentStackOffset: 0,
            stageWidths: [300, 240, 180],
            currentLayout: layout
        ) == 1)
    }

    @Test("Hover hit testing follows the magnified stage frame")
    func hoverHitTestingFollowsMagnifiedStageFrame() {
        let baseline = uniformStack(4, focus: 3, height: 100, spacing: 12, inactiveScale: 0.8)
        let magnified = uniformStack(4, focus: 0, height: 100, spacing: 12, inactiveScale: 0.8)
        let baselineOffset: CGFloat = 200 - baseline.centers[3]
        let anchorY = baselineOffset + baseline.centers[0]
        let magnifiedOffset = StageMotion.anchoredOffset(
            layout: magnified,
            anchorIndex: 0,
            anchorY: anchorY
        )
        let location = CGPoint(x: 130, y: anchorY)

        #expect(StageInteraction.spaceIndex(
            at: location,
            containerWidth: 600,
            stackOffset: baselineOffset,
            stageWidths: [400, 400, 400, 400],
            layout: baseline
        ) == nil)
        #expect(StageInteraction.hoveredSpaceIndex(
            previous: 0,
            at: location,
            containerWidth: 600,
            currentStackOffset: magnifiedOffset,
            stageWidths: [400, 400, 400, 400],
            currentLayout: magnified
        ) == 0)
    }

    @Test("Hover focus clears outside the horizontal transit corridor")
    func hoverFocusClearsBesideTransitGap() {
        let layout = uniformStack(2, focus: 0, height: 100, spacing: 20, inactiveScale: 0.8)

        #expect(StageInteraction.hoveredSpaceIndex(
            previous: 0,
            at: CGPoint(x: 420, y: 110),
            containerWidth: 500,
            currentStackOffset: 0,
            stageWidths: [300, 240],
            currentLayout: layout
        ) == nil)
    }

    @Test("Hover focus clears beyond the vertical stack corridor")
    func hoverFocusClearsAboveAndBelowStack() {
        let layout = uniformStack(2, focus: 0, height: 100, spacing: 20, inactiveScale: 0.8)
        let widths: [CGFloat] = [300, 240]

        let top = layout.centers[0] - layout.heights[0] / 2
        let bottom = layout.centers[1] + layout.heights[1] / 2

        #expect(StageInteraction.hoveredSpaceIndex(
            previous: 0,
            at: CGPoint(x: 250, y: top - 1),
            containerWidth: 500,
            currentStackOffset: 0,
            stageWidths: widths,
            currentLayout: layout
        ) == nil)
        #expect(StageInteraction.hoveredSpaceIndex(
            previous: 1,
            at: CGPoint(x: 250, y: bottom + 1),
            containerWidth: 500,
            currentStackOffset: 0,
            stageWidths: widths,
            currentLayout: layout
        ) == nil)
    }

    @Test("Entering a transit gap without prior focus stays unfocused")
    func transitGapDoesNotCreateFocus() {
        let layout = uniformStack(2, focus: 0, height: 100, spacing: 20, inactiveScale: 0.8)

        #expect(StageInteraction.hoveredSpaceIndex(
            previous: nil,
            at: CGPoint(x: 250, y: 110),
            containerWidth: 500,
            currentStackOffset: 0,
            stageWidths: [300, 240],
            currentLayout: layout
        ) == nil)
    }

    @Test("Transit corridor interpolates between unequal stage widths")
    func unequalWidthTransitCorridor() {
        let layout = uniformStack(2, focus: 0, height: 100, spacing: 20, inactiveScale: 0.8)
        let widths: [CGFloat] = [400, 100]

        #expect(StageInteraction.hoveredSpaceIndex(
            previous: 0,
            at: CGPoint(x: 390, y: 101),
            containerWidth: 500,
            currentStackOffset: 0,
            stageWidths: widths,
            currentLayout: layout
        ) == 0)
        #expect(StageInteraction.hoveredSpaceIndex(
            previous: 0,
            at: CGPoint(x: 390, y: 119),
            containerWidth: 500,
            currentStackOffset: 0,
            stageWidths: widths,
            currentLayout: layout
        ) == nil)
    }

    @Test("A pointer or drag target becomes the gradient focus")
    func interactionFocusPriority() {
        #expect(StageMotion.focusedSpaceIndex(
            active: 2, hovered: nil, dragTarget: nil, retainedDragTarget: nil, spaceCount: 5
        ) == 2)
        #expect(StageMotion.focusedSpaceIndex(
            active: 2, hovered: 4, dragTarget: nil, retainedDragTarget: nil, spaceCount: 5
        ) == 4)
        #expect(StageMotion.focusedSpaceIndex(
            active: 2, hovered: 4, dragTarget: 1, retainedDragTarget: nil, spaceCount: 5
        ) == 1)
    }

    @Test("Cross-space drag focus is retained through drop completion")
    func retainedCrossSpaceDragFocus() {
        #expect(StageMotion.focusedSpaceIndex(
            active: 0, hovered: nil, dragTarget: 1, retainedDragTarget: nil, spaceCount: 2
        ) == 1)
        #expect(StageMotion.focusedSpaceIndex(
            active: 0, hovered: nil, dragTarget: nil, retainedDragTarget: 1, spaceCount: 2
        ) == 1)
    }

    @Test("Focus candidates that outlived their space are skipped")
    func staleFocusCandidatesAreIgnored() {
        #expect(StageMotion.focusedSpaceIndex(
            active: 1, hovered: 6, dragTarget: nil, retainedDragTarget: nil, spaceCount: 4
        ) == 1)
        #expect(StageMotion.focusedSpaceIndex(
            active: 1, hovered: 2, dragTarget: 9, retainedDragTarget: nil, spaceCount: 4
        ) == 2)
        #expect(StageMotion.focusedSpaceIndex(
            active: 1, hovered: -1, dragTarget: nil, retainedDragTarget: nil, spaceCount: 4
        ) == 1)
        #expect(StageMotion.focusedSpaceIndex(
            active: 7, hovered: nil, dragTarget: nil, retainedDragTarget: nil, spaceCount: 4
        ) == 3)
    }

    @Test("A stale focus index leaves the stack laid out rather than empty")
    func staleFocusKeepsStackLayout() {
        let layout = uniformStack(
            3,
            focus: StageMotion.focusedSpaceIndex(
                active: 0,
                hovered: 6,
                dragTarget: nil,
                retainedDragTarget: nil,
                spaceCount: 3
            ),
            height: 100,
            spacing: 12,
            inactiveScale: 0.8
        )

        #expect(layout.centers.count == 3)
        #expect(layout.scales[0] == 1)
    }

    @Test("Edge hover scrolls overflow toward its boundary")
    func edgeHoverScrollDestination() {
        #expect(StageMotion.edgeScrollDestination(
            pointerY: 20,
            containerHeight: 600,
            restingOffset: -300,
            topLimit: 48,
            bottomLimit: -948
        ) == 48)
        #expect(StageMotion.edgeScrollDestination(
            pointerY: 580,
            containerHeight: 600,
            restingOffset: -300,
            topLimit: 48,
            bottomLimit: -948
        ) == -948)
        #expect(StageMotion.edgeScrollDestination(
            pointerY: 300,
            containerHeight: 600,
            restingOffset: -300,
            topLimit: 48,
            bottomLimit: -948
        ) == -300)
        #expect(StageMotion.edgeScrollDestination(
            pointerY: 20,
            containerHeight: 600,
            restingOffset: 50,
            topLimit: 48,
            bottomLimit: 52
        ) == 50)
    }

    @Test("Resting edge-scroll animation key is stable across screen sizes")
    func resizedScreenDoesNotAnimateRestingStack() {
        #expect(StageMotion.edgeScrollTarget(
            pointerY: nil,
            containerHeight: 900,
            edgeRegion: 80
        ) == .resting)
        #expect(StageMotion.edgeScrollTarget(
            pointerY: nil,
            containerHeight: 1_800,
            edgeRegion: 80
        ) == .resting)
    }

    @Test("Stage centers use the distance-based layout scale")
    func stageCentersFollowDepthLayout() {
        let stageHeights: [CGFloat] = [164, 164, 164]
        let activeCenter = StageConstants.stageCenterY(
            spaceIndex: 1,
            stageHeights: stageHeights,
            activeSpaceIndex: 1,
            inactiveScale: 0.8,
            containerHeight: 768
        )
        let precedingCenter = StageConstants.stageCenterY(
            spaceIndex: 0,
            stageHeights: stageHeights,
            activeSpaceIndex: 1,
            inactiveScale: 0.8,
            containerHeight: 768
        )

        #expect(activeCenter == 384)
        #expect(abs((precedingCenter ?? 0) - 202.4) < 0.001)
    }

    @Test("The default filled selector does not magnify its window")
    func filledWindowScale() {
        #expect(StageMotion.windowScale(
            isSelected: false,
            isDragging: false,
            style: .filled,
            magnifyScale: 1.12
        ) == 1)
        #expect(StageMotion.windowScale(
            isSelected: true,
            isDragging: false,
            style: .filled,
            magnifyScale: 1.12
        ) == 1)
    }

    @Test("Magnify selection uses the configured scale")
    func magnifiedWindowScale() {
        #expect(StageMotion.windowScale(
            isSelected: true,
            isDragging: false,
            style: .magnify,
            magnifyScale: 1.12
        ) == 1.12)
        #expect(StageMotion.windowScale(
            isSelected: true,
            isDragging: true,
            style: .magnify,
            magnifyScale: 1.12
        ) == 0.96)
    }

    @Test("The fill appears only on a selected window resting in its stage")
    func filledVisibility() {
        #expect(StageMotion.showsWindowSelector(
            isSelected: true,
            isDragging: false,
            style: .filled
        ))
        #expect(!StageMotion.showsWindowSelector(
            isSelected: true,
            isDragging: true,
            style: .filled
        ))
        #expect(!StageMotion.showsWindowSelector(
            isSelected: true,
            isDragging: false,
            style: .magnify
        ))
    }

    @Test("The fill uses the specified adaptive grays at full opacity")
    func filledColors() {
        #expect(StageMotion.windowSelectorGray(isDarkMode: true) == 103.0 / 255.0)
        #expect(StageMotion.windowSelectorGray(isDarkMode: false) == 167.0 / 255.0)
    }

    @Test("The fill expands behind the preview by the configured outset")
    func filledSelectorSize() {
        #expect(StageMotion.windowSelectorSize(
            thumbnailSize: CGSize(width: 160, height: 100),
            outset: 6
        ) == CGSize(width: 172, height: 112))
    }

    @Test("Only the selected window carries a lift")
    func unselectedWindowHasNoLift() {
        #expect(
            StageMotion.windowLift(isSelected: false, isDragging: false, isDarkMode: false)
                == .init(shadowOpacity: 0, shadowRadius: 0, shadowY: 0)
        )
        #expect(
            StageMotion.windowLift(isSelected: false, isDragging: false, isDarkMode: true)
                == .init(shadowOpacity: 0, shadowRadius: 0, shadowY: 0)
        )
    }

    @Test("The selected window keeps its light-mode shadow unchanged")
    func selectedWindowLiftInLightMode() {
        #expect(
            StageMotion.windowLift(
                isSelected: true,
                isDragging: false,
                isDarkMode: false,
                style: .magnify,
                shadowStrength: 1
            )
                == .init(shadowOpacity: 0.24, shadowRadius: 8, shadowY: 4)
        )
    }

    @Test("Dark mode deepens the selected window shadow")
    func selectedWindowLiftInDarkMode() {
        let dark = StageMotion.windowLift(
            isSelected: true,
            isDragging: false,
            isDarkMode: true,
            style: .magnify,
            shadowStrength: 1
        )
        let light = StageMotion.windowLift(
            isSelected: true,
            isDragging: false,
            isDarkMode: false,
            style: .magnify,
            shadowStrength: 1
        )

        #expect(dark.shadowOpacity > light.shadowOpacity)
        #expect(dark.shadowRadius > light.shadowRadius)
    }

    @Test("Dragging suppresses the selected window's shadow")
    func draggingWindowDropsItsLift() {
        for isDarkMode in [true, false] {
            #expect(
                StageMotion.windowLift(
                    isSelected: true,
                    isDragging: true,
                    isDarkMode: isDarkMode,
                    style: .magnify,
                    shadowStrength: 1
                ).shadowOpacity == 0
            )
        }
    }

    @Test("Filled selection never adds a window lift")
    func filledWindowHasNoLift() {
        #expect(StageMotion.windowLift(
            isSelected: true,
            isDragging: false,
            isDarkMode: true,
            style: .filled,
            shadowStrength: 2
        ) == .init(shadowOpacity: 0, shadowRadius: 0, shadowY: 0))
    }

    @Test("Magnify shadow strength scales the existing lift")
    func magnifyShadowStrength() {
        #expect(StageMotion.windowLift(
            isSelected: true,
            isDragging: false,
            isDarkMode: false,
            style: .magnify,
            shadowStrength: 0.5
        ) == .init(shadowOpacity: 0.12, shadowRadius: 4, shadowY: 2))
    }

    @Test("Window drops allow reordered and cross-space positions")
    func windowDropPolicy() {
        #expect(!StageInteraction.shouldMoveWindow(
            fromSpaceIndex: 1,
            fromWindowIndex: 1,
            to: WindowDropTarget(spaceIndex: 1, windowIndex: 1)
        ))
        #expect(StageInteraction.shouldMoveWindow(
            fromSpaceIndex: 1,
            fromWindowIndex: 1,
            to: WindowDropTarget(spaceIndex: 1, windowIndex: 2)
        ))
        #expect(StageInteraction.shouldMoveWindow(
            fromSpaceIndex: 1,
            fromWindowIndex: 1,
            to: WindowDropTarget(spaceIndex: 2, windowIndex: 0)
        ))
        #expect(!StageInteraction.shouldMoveWindow(
            fromSpaceIndex: 1,
            fromWindowIndex: 1,
            to: nil
        ))
    }

    @Test("Window drop position ignores the dragged card in its source space")
    func windowDropPositionIgnoresDraggedCard() {
        let stageFrames = [
            0: CGRect(x: 0, y: 0, width: 360, height: 160),
            1: CGRect(x: 0, y: 180, width: 360, height: 160),
        ]
        let windowFrames = [
            WindowFrameID(spaceIndex: 0, windowIndex: 0): CGRect(x: 20, y: 20, width: 90, height: 100),
            WindowFrameID(spaceIndex: 0, windowIndex: 1): CGRect(x: 130, y: 20, width: 90, height: 100),
            WindowFrameID(spaceIndex: 0, windowIndex: 2): CGRect(x: 240, y: 20, width: 90, height: 100),
            WindowFrameID(spaceIndex: 1, windowIndex: 0): CGRect(x: 20, y: 200, width: 90, height: 100),
            WindowFrameID(spaceIndex: 1, windowIndex: 1): CGRect(x: 130, y: 200, width: 90, height: 100),
        ]

        #expect(StageInteraction.windowDropTarget(
            at: CGPoint(x: 300, y: 80),
            sourceSpaceIndex: 0,
            sourceWindowIndex: 0,
            stageFrames: stageFrames,
            windowFrames: windowFrames
        ) == WindowDropTarget(spaceIndex: 0, windowIndex: 2))
        #expect(StageInteraction.windowDropTarget(
            at: CGPoint(x: 125, y: 240),
            sourceSpaceIndex: 0,
            sourceWindowIndex: 0,
            stageFrames: stageFrames,
            windowFrames: windowFrames
        ) == WindowDropTarget(spaceIndex: 1, windowIndex: 1))
    }

    @Test("A wrapped stage resolves the drop row from the pointer's height")
    func wrappedWindowDropTarget() {
        // Two rows of three, the second row holding indices 3 and 4 after the dragged card
        // is excluded.
        let stageFrames = [0: CGRect(x: 0, y: 0, width: 620, height: 320)]
        let windowFrames = [
            WindowFrameID(spaceIndex: 0, windowIndex: 1): CGRect(x: 30, y: 30, width: 180, height: 130),
            WindowFrameID(spaceIndex: 0, windowIndex: 2): CGRect(x: 222, y: 30, width: 180, height: 130),
            WindowFrameID(spaceIndex: 0, windowIndex: 3): CGRect(x: 414, y: 30, width: 180, height: 130),
            WindowFrameID(spaceIndex: 0, windowIndex: 4): CGRect(x: 126, y: 172, width: 180, height: 130),
            WindowFrameID(spaceIndex: 0, windowIndex: 5): CGRect(x: 318, y: 172, width: 180, height: 130),
        ]
        let target: (CGFloat, CGFloat) -> WindowDropTarget? = { x, y in
            StageInteraction.windowDropTarget(
                at: CGPoint(x: x, y: y),
                sourceSpaceIndex: 0,
                sourceWindowIndex: 0,
                stageFrames: stageFrames,
                windowFrames: windowFrames
            )
        }

        #expect(target(100, 95) == WindowDropTarget(spaceIndex: 0, windowIndex: 0))
        #expect(target(300, 95) == WindowDropTarget(spaceIndex: 0, windowIndex: 1))
        #expect(target(600, 95) == WindowDropTarget(spaceIndex: 0, windowIndex: 3))
        // The same x lands in different slots depending on which row the pointer is over.
        #expect(target(300, 237) == WindowDropTarget(spaceIndex: 0, windowIndex: 4))
        #expect(target(600, 237) == WindowDropTarget(spaceIndex: 0, windowIndex: 5))
    }

    @Test("The gap between rows resolves to the nearer row rather than to nothing")
    func dropTargetBetweenRows() {
        let stageFrames = [0: CGRect(x: 0, y: 0, width: 620, height: 320)]
        let windowFrames = [
            WindowFrameID(spaceIndex: 0, windowIndex: 0): CGRect(x: 30, y: 30, width: 180, height: 130),
            WindowFrameID(spaceIndex: 0, windowIndex: 1): CGRect(x: 222, y: 172, width: 180, height: 130),
        ]

        #expect(StageInteraction.windowDropTarget(
            at: CGPoint(x: 300, y: 165),
            sourceSpaceIndex: 1,
            sourceWindowIndex: 0,
            stageFrames: stageFrames,
            windowFrames: windowFrames
        ) == WindowDropTarget(spaceIndex: 0, windowIndex: 1))
        #expect(StageInteraction.windowDropTarget(
            at: CGPoint(x: 400, y: 310),
            sourceSpaceIndex: 1,
            sourceWindowIndex: 0,
            stageFrames: stageFrames,
            windowFrames: windowFrames
        ) == WindowDropTarget(spaceIndex: 0, windowIndex: 2))
    }

    @Test("An empty destination stage accepts a drop at its only slot")
    func dropTargetOnEmptyStage() {
        #expect(StageInteraction.windowDropTarget(
            at: CGPoint(x: 150, y: 80),
            sourceSpaceIndex: 1,
            sourceWindowIndex: 0,
            stageFrames: [0: CGRect(x: 0, y: 0, width: 300, height: 178)],
            windowFrames: [:]
        ) == WindowDropTarget(spaceIndex: 0, windowIndex: 0))
    }

    @Test("Same-space drag animates windows into their prospective MRU order")
    func sameSpaceWindowDragOffsets() {
        let layout = grid(3, capacity: 4)
        let stride = StageMetrics.standard.cardWidth + StageMetrics.standard.windowSpacing
        let drag = WindowDragState(
            windowID: 42,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 0,
            location: .zero,
            dropTarget: WindowDropTarget(spaceIndex: 0, windowIndex: 2)
        )
        let offset: (Int, WindowDragState) -> CGSize = { index, drag in
            StageMotion.windowSlotOffset(
                spaceIndex: 0,
                windowIndex: index,
                drag: drag,
                layout: layout
            )
        }

        #expect(offset(0, drag) == CGSize(width: stride * 2, height: 0))
        #expect(offset(1, drag) == CGSize(width: -stride, height: 0))
        #expect(offset(2, drag) == CGSize(width: -stride, height: 0))

        let reverseDrag = WindowDragState(
            windowID: 42,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 2,
            location: .zero,
            dropTarget: WindowDropTarget(spaceIndex: 0, windowIndex: 0)
        )
        #expect(offset(0, reverseDrag) == CGSize(width: stride, height: 0))
        #expect(offset(2, reverseDrag) == CGSize(width: -stride * 2, height: 0))
    }

    @Test("A drag across a row boundary moves cards in both axes")
    func wrappedDragOffsetsCrossRows() {
        let layout = grid(5, capacity: 3)
        let metrics = StageMetrics.standard
        let rowStride = metrics.cardHeight + metrics.rowSpacing
        #expect(layout.rowSizes == [3, 2])

        // Dragging the first card to the end pushes every other card back one slot, which for
        // the first card of the second row means up a row and across to the end of the first.
        let drag = WindowDragState(
            windowID: 42,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 0,
            location: .zero,
            dropTarget: WindowDropTarget(spaceIndex: 0, windowIndex: 4)
        )
        let moved = StageMotion.windowSlotOffset(
            spaceIndex: 0,
            windowIndex: 3,
            drag: drag,
            layout: layout
        )

        #expect(moved.height == -rowStride)
        #expect(moved.width > 0)
    }

    @Test("Cross-space drag opens an insertion gap and closes the source gap")
    func crossSpaceWindowDragOffsets() {
        let metrics = StageMetrics.standard
        let stride = metrics.cardWidth + metrics.windowSpacing
        let drag = WindowDragState(
            windowID: 42,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 1,
            location: .zero,
            dropTarget: WindowDropTarget(spaceIndex: 1, windowIndex: 1)
        )

        #expect(StageMotion.displayedWindowCounts(actual: [3, 2], drag: drag) == [2, 3])

        // The source stage shrinks to two cards, and its survivors close the gap by taking new
        // anchors in the smaller grid rather than by being nudged within the old one.
        let sourceGrid = grid(2, capacity: 4)
        #expect(StageMotion.windowAnchorIndex(spaceIndex: 0, windowIndex: 0, drag: drag) == 0)
        #expect(StageMotion.windowAnchorIndex(spaceIndex: 0, windowIndex: 2, drag: drag) == 1)
        #expect(sourceGrid.cardOffsetFromCenter(at: 0).width == -stride / 2)
        #expect(sourceGrid.cardOffsetFromCenter(at: 1).width == stride / 2)
        for index in [0, 2] {
            #expect(StageMotion.windowSlotOffset(
                spaceIndex: 0,
                windowIndex: index,
                drag: drag,
                layout: sourceGrid
            ) == .zero)
        }

        // The target stage has already grown to three, so its cards keep their anchors there
        // and only the one after the insertion point is nudged, opening the gap.
        let target: (Int) -> CGSize = { index in
            StageMotion.windowSlotOffset(
                spaceIndex: 1,
                windowIndex: index,
                drag: drag,
                layout: self.grid(3, capacity: 4)
            )
        }
        #expect(target(0) == .zero)
        #expect(target(1) == CGSize(width: stride, height: 0))
    }

    @Test("A space untouched by the drag keeps its cards where they rest")
    func untouchedSpaceDragOffsets() {
        let layout = grid(2, capacity: 4)
        let drag = WindowDragState(
            windowID: 42,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 1,
            location: .zero,
            dropTarget: WindowDropTarget(spaceIndex: 1, windowIndex: 1)
        )

        #expect(StageMotion.windowSlotOffset(
            spaceIndex: 2,
            windowIndex: 0,
            drag: drag,
            layout: layout
        ) == .zero)
    }

    @Test("Released preview snaps to same-space, cross-space, and empty-space slots")
    func releasedPreviewDestination() {
        let metrics = StageMetrics.standard
        let stride = metrics.cardWidth + metrics.windowSpacing
        // Displayed layouts: space 0 keeps three cards for a same-space reorder, space 1 has
        // already grown to three for the incoming card, space 2 is an empty destination.
        let layouts = [grid(3, capacity: 4), grid(3, capacity: 4), grid(1, capacity: 4)]
        let stages = [
            0: CGRect(x: 0, y: 0, width: 640, height: 164),
            1: CGRect(x: 0, y: 200, width: 640, height: 164),
            2: CGRect(x: 100, y: 400, width: 300, height: 164),
        ]

        #expect(StageMotion.windowDropDestination(
            target: WindowDropTarget(spaceIndex: 0, windowIndex: 2),
            stageFrames: stages,
            layouts: layouts,
            scales: [1, 1, 1]
        ) == CGPoint(x: 320 + stride, y: 92))
        #expect(StageMotion.windowDropDestination(
            target: WindowDropTarget(spaceIndex: 1, windowIndex: 1),
            stageFrames: stages,
            layouts: layouts,
            scales: [1, 1, 1]
        ) == CGPoint(x: 320, y: 292))
        #expect(StageMotion.windowDropDestination(
            target: WindowDropTarget(spaceIndex: 2, windowIndex: 0),
            stageFrames: stages,
            layouts: layouts,
            scales: [1, 1, 1]
        ) == CGPoint(x: 250, y: 492))
    }

    @Test("A scaled destination stage lands the preview on its scaled slot")
    func releasedPreviewFollowsStageScale() {
        let metrics = StageMetrics.standard
        let stride = metrics.cardWidth + metrics.windowSpacing
        let stages = [0: CGRect(x: 0, y: 0, width: 320, height: 82)]

        #expect(StageMotion.windowDropDestination(
            target: WindowDropTarget(spaceIndex: 0, windowIndex: 2),
            stageFrames: stages,
            layouts: [grid(3, capacity: 4)],
            scales: [0.5]
        ) == CGPoint(x: 160 + stride / 2, y: 46))
    }

    @Test("A press without meaningful movement selects instead of starting a drag")
    func clickAndDragThreshold() {
        #expect(StageInteraction.isWindowClick(translation: .zero))
        #expect(StageInteraction.isWindowClick(translation: CGSize(width: 3, height: 4)))
        #expect(!StageInteraction.isWindowClick(translation: CGSize(width: 6, height: 0)))
        #expect(!StageInteraction.isWindowClick(translation: CGSize(width: 5, height: 5)))
    }

    @Test("Finishing a window drop clears drag state before requesting the move")
    func windowDropClearsDragBeforeMoveRequest() {
        var drag: WindowDragState? = WindowDragState(
            windowID: 42,
            sourceSpaceIndex: 1,
            sourceWindowIndex: 0,
            location: CGPoint(x: 100, y: 200),
            dropTarget: WindowDropTarget(spaceIndex: 2, windowIndex: 3)
        )

        let request = StageInteraction.finishWindowDrag(&drag)

        #expect(drag == nil)
        #expect(request == WindowMoveRequest(
            windowID: 42,
            fromSpaceIndex: 1,
            fromWindowIndex: 0,
            toSpaceIndex: 2,
            toWindowIndex: 3
        ))
    }

    /// A tap that resolves to nothing is otherwise indistinguishable from a tap that never
    /// arrived, so the overlay has to name what a tap landed on even when it landed on nothing.
    @Test("A tap away from the stages keeps the desktop behaviour")
    func overlayTapFallsThroughToDesktop() {
        let stageFrames = [0: CGRect(x: 100, y: 100, width: 300, height: 200)]
        let route: (CGPoint) -> OverlayTapTarget = {
            StageInteraction.overlayTapTarget(at: $0, stageFrames: stageFrames)
        }

        #expect(route(CGPoint(x: 900, y: 500)) == .desktop)
        #expect(route(CGPoint(x: 250, y: 200)) == .none)
    }

    /// Space scrolling is an overlay-wide gesture, including the bare desktop around the stages.
    @Test("The scrollable area fills the overlay")
    func spaceScrollAreaFillsOverlay() {
        let inArea: (CGFloat, CGFloat) -> Bool = {
            StageInteraction.isInSpaceScrollArea(
                CGPoint(x: $0, y: $1),
                containerSize: CGSize(width: 500, height: 600)
            )
        }

        #expect(inArea(0, 0))
        #expect(inArea(499, 599))
        #expect(inArea(10, 300))
        #expect(inArea(490, 300))
        #expect(!inArea(-1, 300))
        #expect(!inArea(500, 300))
        #expect(!inArea(250, -1))
        #expect(!inArea(250, 600))
    }

    /// A wheel reports whole notches and a trackpad a stream of points. The leftover has to
    /// survive between events, or a slow scroll would never accumulate into a step at all.
    @Test("Scroll travel accumulates into whole space steps")
    func spaceScrollAccumulatesIntoSteps() {
        var accumulator = SpaceScrollAccumulator()
        let perSpace = StageConstants.spaceScrollTravelPerSpace

        #expect(accumulator.steps(deltaY: perSpace / 3, isPrecise: true) == 0)
        #expect(accumulator.steps(deltaY: perSpace / 3, isPrecise: true) == 0)
        #expect(accumulator.steps(deltaY: perSpace / 3, isPrecise: true) == 1)
        #expect(accumulator.steps(deltaY: -perSpace, isPrecise: true) == -1)

        // One wheel notch is one space, however small its reported delta.
        var wheel = SpaceScrollAccumulator()
        #expect(wheel.steps(deltaY: 1, isPrecise: false) == 1)
        #expect(wheel.steps(deltaY: -1, isPrecise: false) == -1)
    }

    /// A flick left over from the last gesture must not leak into the next one.
    @Test("Resetting the accumulator drops the leftover travel")
    func spaceScrollResetDropsLeftover() {
        var accumulator = SpaceScrollAccumulator()
        let perSpace = StageConstants.spaceScrollTravelPerSpace

        #expect(accumulator.steps(deltaY: perSpace * 0.9, isPrecise: true) == 0)
        accumulator.reset()
        #expect(accumulator.steps(deltaY: perSpace * 0.9, isPrecise: true) == 0)
    }

    /// Scrolling stops at the ends rather than wrapping, so a long flick cannot land somewhere
    /// unrelated to where it started.
    @Test("Scrolling clamps at the ends of the stack")
    func spaceScrollDestinationClamps() {
        #expect(StageInteraction.spaceScrollDestination(current: 1, steps: -1, spaceCount: 3) == 2)
        #expect(StageInteraction.spaceScrollDestination(current: 1, steps: 1, spaceCount: 3) == 0)
        #expect(StageInteraction.spaceScrollDestination(current: 0, steps: 1, spaceCount: 3) == nil)
        #expect(StageInteraction.spaceScrollDestination(current: 2, steps: -4, spaceCount: 3) == nil)
        #expect(StageInteraction.spaceScrollDestination(current: 0, steps: -9, spaceCount: 3) == 2)
        #expect(StageInteraction.spaceScrollDestination(current: 0, steps: 0, spaceCount: 3) == nil)
        #expect(StageInteraction.spaceScrollDestination(current: 0, steps: 1, spaceCount: 0) == nil)
    }

    @Test("A stale pointer exit cannot clear the newly hovered window")
    func stalePointerExitDoesNotClearSelection() {
        let first = PointerSelection(spaceIndex: 0, windowIndex: 0)
        let second = PointerSelection(spaceIndex: 0, windowIndex: 1)

        #expect(StageInteraction.pointerSelection(current: nil, target: first, isHovering: true) == first)
        #expect(StageInteraction.pointerSelection(current: first, target: second, isHovering: true) == second)
        #expect(StageInteraction.pointerSelection(current: second, target: first, isHovering: false) == second)
        #expect(StageInteraction.pointerSelection(current: second, target: second, isHovering: false) == nil)
    }

    @Test("Only points outside every stage select the desktop")
    func desktopAreaSelection() {
        let stageFrames = [
            0: CGRect(x: 300, y: 200, width: 400, height: 300),
            1: CGRect(x: 350, y: 540, width: 300, height: 200),
        ]

        #expect(StageInteraction.isDesktopArea(
            CGPoint(x: 100, y: 100),
            stageFrames: stageFrames
        ))
        #expect(!StageInteraction.isDesktopArea(
            CGPoint(x: 500, y: 350),
            stageFrames: stageFrames
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
