import AppKit
import SwiftUI

/// The flat switcher: one plate holding every window from every space, in global MRU order.
///
/// Structurally this is a single stage that happens to contain the whole session, so it draws
/// with the stage's own card, grid and glass rather than a parallel set that could drift from
/// them. What it deliberately does not inherit is the stack: there are no spaces to focus,
/// scroll between, or drop a window onto.
public struct AltTabOverlayView: View {
    public let viewModel: AltTabOverlayViewModel
    public var onWindowSelected: ((Int) -> Void)?
    public var onPointerSelectionChanged: ((Int?) -> Void)?

    @State private var pointerSelectionIndex: Int?
    @State private var pointerMovementGate: PointerMovementGate

    public init(
        viewModel: AltTabOverlayViewModel,
        onWindowSelected: ((Int) -> Void)? = nil,
        onPointerSelectionChanged: ((Int?) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onWindowSelected = onWindowSelected
        self.onPointerSelectionChanged = onPointerSelectionChanged
        _pointerSelectionIndex = State(initialValue: nil)
        _pointerMovementGate = State(
            initialValue: PointerMovementGate(initialLocation: NSEvent.mouseLocation)
        )
    }

    public var body: some View {
        GeometryReader { geo in
            let metrics = viewModel.metrics(containerSize: geo.size)
            let layout = viewModel.layout(containerSize: geo.size)
            let plateSize = layout.stageSize
            let lift = viewModel.overlayLift
            let selectedIndex = pointerSelectionIndex ?? viewModel.selectedIndex

            ZStack {
                ForEach(Array(viewModel.windows.enumerated()), id: \.element.id) { index, window in
                    WindowPreviewView(
                        window: window,
                        isWindowSelected: selectedIndex == index,
                        metrics: layout.cardMetrics(at: index),
                        appearance: viewModel.appearance
                    )
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        let nextSelection: Int?
                        switch phase {
                        case .active:
                            guard pointerMovementGate.observe(at: NSEvent.mouseLocation) else {
                                return
                            }
                            nextSelection = AltTabInteraction.pointerSelection(
                                current: pointerSelectionIndex,
                                target: index,
                                isHovering: true
                            )
                        case .ended:
                            nextSelection = AltTabInteraction.pointerSelection(
                                current: pointerSelectionIndex,
                                target: index,
                                isHovering: false
                            )
                        }
                        guard nextSelection != pointerSelectionIndex else { return }
                        pointerSelectionIndex = nextSelection
                        onPointerSelectionChanged?(nextSelection)
                    }
                    .onTapGesture {
                        onWindowSelected?(index)
                    }
                    .offset(layout.cardOffsetFromCenter(at: index))
                }
            }
            .frame(width: plateSize.width, height: plateSize.height)
            .background {
                Color.clear.modifier(LiquidGlassModifier(
                    cornerRadius: CGFloat(viewModel.appearance.stageCornerRadius)
                        * metrics.scaleFactor,
                    appearance: viewModel.appearance
                ))
            }
            .shadow(
                color: .black.opacity(lift.shadowOpacity),
                radius: lift.shadowRadius * metrics.scaleFactor,
                y: lift.shadowY * metrics.scaleFactor
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
