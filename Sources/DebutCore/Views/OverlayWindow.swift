import AppKit
import SwiftUI

/// A scroll the window received, in the hosting view's coordinate space. The sequence number is
/// what makes two identical scrolls distinguishable to `onChange`.
struct OverlayScrollEvent: Equatable {
    let deltaY: CGFloat
    let isPrecise: Bool
    let isGestureStart: Bool
    let location: CGPoint
    let sequence: Int
}

/// SwiftUI has no scroll-wheel modifier, and only the window sits low enough in the responder
/// chain to see a scroll the plates did not consume. The relay carries it back into the view,
/// which is the only place that knows where the plates currently are.
@Observable
final class OverlayScrollRelay {
    var latest: OverlayScrollEvent?
}

@Observable
private final class OverlayContentState {
    var rootView: OverlaySwiftUIView

    init(rootView: OverlaySwiftUIView) {
        self.rootView = rootView
    }
}

private struct OverlayContentRootView: View {
    let state: OverlayContentState

    var body: some View {
        state.rootView
    }
}

public final class OverlayWindow: NSWindow, @unchecked Sendable {
    private var hostingView: NSHostingView<OverlayContentRootView>?
    private var contentState: OverlayContentState?
    private var renderedWindowIDs: Set<CGWindowID> = []
    private var renderGeneration = 0
    private let scrollRelay = OverlayScrollRelay()
    private var scrollSequence = 0
    private var scrollMonitor: Any?
    public var onStageScrollSelected: ((Int) -> Void)?
    var onStageScrollRouted: ((OverlayScrollDiagnostic) -> Void)?
    public var onWindowSelected: ((Int, Int) -> Void)?
    public var onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)?
    public var onPointerSelectionChanged: ((Int?, Int?) -> Void)?
    public var onDesktopSelected: (() -> Void)?
    var onOverlayTapRouted: ((OverlayTapDiagnostic) -> Void)?
    var onOverlayPointerRegionChanged: ((OverlayPointerRegionDiagnostic) -> Void)?

    /// The display the overlay should cover, in Cocoa screen coordinates. `nil` keeps it on the
    /// main screen.
    public var targetScreenFrame: CGRect?

    public init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    @discardableResult
    public func update(viewModel: OverlayViewModel) -> Bool {
        synchronizeFrameToTargetScreen(display: false)
        let nextWindowIDs = Set(
            viewModel.stageManager.allStages.flatMap { $0.windows.map(\.windowID) }
        )
        let removedWindowIDs = renderedWindowIDs.subtracting(nextWindowIDs)
        renderedWindowIDs = nextWindowIDs
        if !removedWindowIDs.isEmpty {
            renderGeneration += 1
        }
        let generation = renderGeneration
        var view = OverlaySwiftUIView(
            viewModel: viewModel,
            onWindowSelected: onWindowSelected,
            onWindowMoved: onWindowMoved,
            onPointerSelectionChanged: onPointerSelectionChanged,
            onDesktopSelected: onDesktopSelected
        )
        view.onOverlayTapRouted = onOverlayTapRouted
        view.onOverlayPointerRegionChanged = onOverlayPointerRegionChanged
        view.scrollRelay = scrollRelay
        view.onStageScrollSelected = onStageScrollSelected
        view.onStageScrollRouted = onStageScrollRouted
        if let hostingView, let contentState {
            // Mutating observable content preserves the SwiftUI tree, so removals run the
            // card transition and animate the surviving cards into their new positions.
            if removedWindowIDs.isEmpty {
                contentState.rootView = view
            } else {
                let transition = PlateMotion.windowRemovalTransition(
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                )
                withAnimation(transition.animation) {
                    contentState.rootView = view
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = transition.duration
                    // Give AppKit a real animation to complete alongside SwiftUI's card
                    // transition. The imperceptible alpha delta leaves the overlay unchanged.
                    hostingView.animator().alphaValue = generation.isMultiple(of: 2)
                        ? 0.999_999
                        : 0.999_998
                } completionHandler: { [weak self] in
                    DispatchQueue.main.async {
                        self?.rebaseRenderedTree(after: generation)
                    }
                }
            }
            hostingView.frame = contentView?.bounds ?? .zero
            return false
        } else {
            let state = OverlayContentState(rootView: view)
            let hv = NSHostingView(rootView: OverlayContentRootView(state: state))
            hv.frame = contentView?.bounds ?? .zero
            hv.autoresizingMask = [.width, .height]
            contentView?.addSubview(hv)
            contentState = state
            hostingView = hv
            return true
        }
    }

    /// SwiftUI keeps an outgoing selected card attached in an inactive, non-key window even
    /// after its removal transition reports completion. Preserve the existing tree for motion,
    /// then rebuild it from the latest value so the completed card cannot await another input.
    private func rebaseRenderedTree(after generation: Int) {
        guard generation == renderGeneration, let contentState else { return }
        hostingView?.removeFromSuperview()
        let state = OverlayContentState(rootView: contentState.rootView)
        let replacement = NSHostingView(rootView: OverlayContentRootView(state: state))
        replacement.frame = contentView?.bounds ?? .zero
        replacement.autoresizingMask = [.width, .height]
        contentView?.addSubview(replacement)
        self.contentState = state
        hostingView = replacement
    }

    public func showOverlay(
        revealDuration: TimeInterval = 0.15,
        onRevealCompleted: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        synchronizeFrameToTargetScreen(display: true)
        hostingView?.frame = contentView?.bounds ?? .zero
        startWatchingScroll()
        alphaValue = 0
        // A borderless window cannot become key, and Debut is an accessory app
        // that is inactive when the overlay opens. Asking for key status buys
        // nothing and makes the ordering conditional on app activation.
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = max(0, revealDuration)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }, completionHandler: {
            DispatchQueue.main.async { onRevealCompleted() }
        })
    }

    /// SwiftUI has no scroll-wheel modifier, and a scroll delivered through the responder chain
    /// can be swallowed before it reaches the window. A monitor sees it either way.
    private func startWatchingScroll() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.relayScroll(event)
            return event
        }
    }

    private func stopWatchingScroll() {
        guard let scrollMonitor else { return }
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
    }

    /// A trackpad flick keeps sending events after the fingers lift. Letting momentum through
    /// would sail past whichever stage the user was aiming at.
    private func relayScroll(_ event: NSEvent) {
        guard event.momentumPhase == [], event.window === self, let contentView else { return }
        let inWindow = event.locationInWindow
        scrollSequence += 1
        scrollRelay.latest = OverlayScrollEvent(
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            isGestureStart: event.phase == .began,
            location: CGPoint(x: inWindow.x, y: contentView.bounds.height - inWindow.y),
            sequence: scrollSequence
        )
    }

    private func synchronizeFrameToTargetScreen(display: Bool) {
        guard let frame = targetScreenFrame ?? NSScreen.main?.frame else { return }
        setFrame(frame, display: display)
    }

    public func hideOverlay() {
        stopWatchingScroll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.orderOut(nil)
                // Remove the hosting view to stop SwiftUI layout passes
                self?.hostingView?.removeFromSuperview()
                self?.hostingView = nil
                self?.contentState = nil
                self?.renderedWindowIDs = []
                self?.renderGeneration += 1
            }
        })
    }
}
