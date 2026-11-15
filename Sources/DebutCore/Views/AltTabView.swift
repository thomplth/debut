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
    var onWindowScrollStepped: ((Int) -> Void)?
    var onScrollRouted: ((OverlayScrollDiagnostic) -> Void)?
    var scrollRelay: OverlayScrollRelay?
    var pointerRelay: OverlayPointerRelay?

    @State private var pointerSelectionIndex: Int?
    @State private var cardFrames: [Int: CGRect] = [:]
    @State private var scrollAccumulator = ScrollStepAccumulator()
    @State private var scrollPacer = ScrollStepPacer()
    @State private var pointerMovementGate: PointerMovementGate
    @State private var lastHandledKeyboardInteractionSequence: Int

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
        _lastHandledKeyboardInteractionSequence = State(
            initialValue: viewModel.overlayKeyboardInteractionSequence
        )
    }

    public var body: some View {
        if let scope = viewModel.tutorialScope, let coach = viewModel.tutorialCoachmark {
            TutorialSwitcherView(rows: [.init(id: scope.presentationID, windows: viewModel.windows, isActive: true, index: 0)],
                scope: scope, coach: coach, selectedWindowID: viewModel.selectedWindow?.windowID,
                selectedDesktop: 0, appearance: viewModel.appearance, flat: true)
        } else { standardBody }
    }

    private var standardBody: some View {
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
                    .onTapGesture {
                        onWindowSelected?(index)
                    }
                    .background {
                        GeometryReader { card in
                            Color.clear.preference(
                                key: AltTabCardFramePreferenceKey.self,
                                value: [index: card.frame(in: .named(Self.coordinateSpace))]
                            )
                        }
                    }
                    .offset(layout.cardOffsetFromCenter(at: index))
                }
            }
            .frame(width: plateSize.width, height: plateSize.height)
            .background {
                Color.clear.modifier(LiquidGlassModifier(
                    cornerRadius: CGFloat(viewModel.switcherAppearance.stageCornerRadius)
                        * metrics.scaleFactor,
                    appearance: viewModel.switcherAppearance
                ))
                // Cast from the glass alone: filtering the card subtree re-rasterizes every
                // icon and preview during selection. Placeholders carry their own baked halo.
                .modifier(PlateShadow(
                    opacity: lift.shadowOpacity,
                    radius: lift.shadowRadius * metrics.scaleFactor,
                    y: lift.shadowY * metrics.scaleFactor,
                    glassStyle: viewModel.switcherAppearance.glassStyle
                ))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(AltTabCardFramePreferenceKey.self) { cardFrames = $0 }
        .onChange(of: pointerRelay?.latest) { _, event in
            if let event { pointerMoved(to: event.location) }
        }
        .onChange(of: scrollRelay?.latest) { _, event in
            if let event { handleScroll(event) }
        }
        .onChange(of: viewModel.overlayKeyboardInteractionSequence) { _, sequence in
            guard sequence > lastHandledKeyboardInteractionSequence else { return }
            lastHandledKeyboardInteractionSequence = sequence
            pointerSelectionIndex = nil
            pointerMovementGate.reset(at: NSEvent.mouseLocation)
        }
    }

    private static let coordinateSpace = "altTabOverlay"

    private func pointerMoved(to location: CGPoint?) {
        let target = OverlayPointerHitTest.target(at: location, in: cardFrames)
        if target != nil && !pointerMovementGate.observe(at: NSEvent.mouseLocation) { return }
        guard target != pointerSelectionIndex else { return }
        pointerSelectionIndex = target
        onPointerSelectionChanged?(target)
    }

    /// The list is one row that wraps, so both axes step through it, each in the direction
    /// opposite to the stage overlay's space scroll. The ends stop the selector rather than
    /// wrapping.
    private func handleScroll(_ event: OverlayScrollEvent) {
        if event.isGestureStart { scrollAccumulator.reset() }
        let axis = OverlayScrollAxis(deltaX: event.deltaX, deltaY: event.deltaY)
        let travel = axis == .horizontal ? event.deltaX : event.deltaY
        let steps = scrollAccumulator.steps(delta: travel, isPrecise: event.isPrecise)
        onScrollRouted?(OverlayScrollDiagnostic(
            location: event.location,
            deltaX: event.deltaX,
            deltaY: event.deltaY,
            axis: axis,
            isInScrollArea: true,
            steps: steps,
            destination: nil
        ))
        let paced = scrollPacer.admit(
            steps: steps,
            interval: viewModel.appearance.heldCycleMinimumInterval,
            now: ProcessInfo.processInfo.systemUptime,
            isGestureStart: event.isGestureStart
        )
        guard paced != 0 else { return }
        onWindowScrollStepped?(OverlayScrollAxis.windowSteps(fromScrollSteps: paced))
    }
}

private struct AltTabCardFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
