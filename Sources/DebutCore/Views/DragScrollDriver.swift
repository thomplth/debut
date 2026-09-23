import SwiftUI

/// Owns the asynchronous lifecycle around drag scrolling. Geometry and timing calculations stay
/// in `DragScrollState`, which tests can advance with a deterministic clock.
@MainActor
struct StageDragScrollLifecycleModifier: ViewModifier {
    @Binding var windowDrag: WindowDragState?
    @Binding var scrollState: DragScrollState?
    @Binding var spaceOrderAtDragStart: [UUID]?
    @Binding var viewportSizeAtDragStart: CGSize?
    @Binding var isFinishingWindowDrop: Bool
    @Binding var retainedFocusSpaceIndex: Int?

    let stages: [StageData]
    let currentSpaceOrder: [UUID]
    let viewportSize: CGSize
    let stackOffset: CGFloat
    let stackHeight: CGFloat
    let focusSpaceIndex: Int
    let cancellationGeneration: Int?
    let onCancel: () -> Void

    private var taskID: DragScrollTaskID? {
        guard let drag = windowDrag,
              let edge = scrollState?.edge
        else { return nil }
        return DragScrollTaskID(sessionID: drag.sessionID, edge: edge)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: windowDrag) { oldValue, newValue in
                updateWindowDrag(previous: oldValue, current: newValue)
            }
            .onChange(of: currentSpaceOrder) { _, newOrder in
                guard spaceOrderAtDragStart != nil,
                      spaceOrderAtDragStart != newOrder
                else { return }
                onCancel()
            }
            .onChange(of: viewportSize) { _, newSize in
                guard windowDrag != nil,
                      let originalSize = viewportSizeAtDragStart,
                      originalSize != newSize
                else { return }
                onCancel()
            }
            .onChange(of: stackHeight) { _, newHeight in
                guard var scrollState else { return }
                scrollState.updateStackHeight(newHeight)
                self.scrollState = scrollState
            }
            .onChange(of: cancellationGeneration) { _, _ in
                onCancel()
            }
            .task(id: taskID) {
                guard let taskID else { return }
                await runScrollTask(taskID)
            }
            .onDisappear(perform: onCancel)
    }

    private func updateWindowDrag(
        previous: WindowDragState?,
        current: WindowDragState?
    ) {
        guard let current else {
            scrollState = nil
            spaceOrderAtDragStart = nil
            viewportSizeAtDragStart = nil
            isFinishingWindowDrop = false
            return
        }

        guard !isFinishingWindowDrop else { return }

        if previous?.sessionID != current.sessionID {
            guard stages.indices.contains(current.sourceSpaceIndex),
                  stages[current.sourceSpaceIndex].windows.indices.contains(
                    current.sourceWindowIndex
                  ),
                  stages[current.sourceSpaceIndex].windows[current.sourceWindowIndex].windowID
                    == current.windowID,
                  current.sourceSpaceID == nil
                    || stages[current.sourceSpaceIndex].id == current.sourceSpaceID
            else {
                onCancel()
                return
            }

            scrollState = DragScrollState(
                stackOffset: stackOffset,
                stackHeight: stackHeight,
                viewportHeight: viewportSize.height
            )
            spaceOrderAtDragStart = currentSpaceOrder
            viewportSizeAtDragStart = viewportSize
            retainedFocusSpaceIndex = focusSpaceIndex
        }

        guard var state = scrollState else { return }
        state.updatePointer(
            y: current.location.y,
            now: ProcessInfo.processInfo.systemUptime
        )
        scrollState = state
        if state.isNavigationBand(y: current.location.y),
           current.dropTarget != nil,
           var updatedDrag = windowDrag {
            updatedDrag.dropTarget = nil
            windowDrag = updatedDrag
        }
    }

    private func runScrollTask(_ identifier: DragScrollTaskID) async {
        guard let initialState = scrollState,
              initialState.edge == identifier.edge,
              let enteredAt = initialState.edgeEnteredAt
        else { return }

        let remainingDwell = max(
            0,
            enteredAt + initialState.dwell - ProcessInfo.processInfo.systemUptime
        )
        do {
            if remainingDwell > 0 {
                let milliseconds = Int((remainingDwell * 1_000).rounded(.up))
                try await Task.sleep(for: .milliseconds(milliseconds))
            }

            while !Task.isCancelled,
                  windowDrag?.sessionID == identifier.sessionID,
                  scrollState?.edge == identifier.edge {
                try await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled,
                      windowDrag?.sessionID == identifier.sessionID,
                      var state = scrollState,
                      state.edge == identifier.edge
                else { return }
                let previousOffset = state.stackOffset
                _ = state.advance(now: ProcessInfo.processInfo.systemUptime)
                guard abs(state.stackOffset - previousOffset) > 0.001 || state.edge == nil else {
                    continue
                }
                scrollState = state
            }
        } catch is CancellationError {
            // A new edge, completed drop, or overlay teardown ends the task.
        } catch {
            assertionFailure("Drag scrolling task failed: \(error)")
        }
    }
}
