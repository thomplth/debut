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

public final class OverlayWindow: NSWindow, @unchecked Sendable {
    private var hostingView: NSHostingView<OverlaySwiftUIView>?
    private var renderedWindowIDs: Set<CGWindowID> = []
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
        if !removedWindowIDs.isEmpty {
            // SwiftUI's outgoing card transition can remain attached in this inactive,
            // non-key window until another input causes a render pass. Detach the old tree so
            // a lifecycle removal such as Command-W cannot leave that card on screen.
            hostingView?.removeFromSuperview()
            hostingView = nil
        }
        renderedWindowIDs = nextWindowIDs
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
        if let hostingView {
            hostingView.rootView = view
            hostingView.frame = contentView?.bounds ?? .zero
            return false
        } else {
            let hv = NSHostingView(rootView: view)
            hv.frame = contentView?.bounds ?? .zero
            hv.autoresizingMask = [.width, .height]
            contentView?.addSubview(hv)
            hostingView = hv
            return true
        }
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
                self?.renderedWindowIDs = []
            }
        })
    }
}
