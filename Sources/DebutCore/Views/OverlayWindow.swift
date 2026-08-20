import AppKit
import SwiftUI

public final class OverlayWindow: NSWindow, @unchecked Sendable {
    private var hostingView: NSHostingView<OverlaySwiftUIView>?
    public var onWindowSelected: ((Int, Int) -> Void)?
    public var onWindowMoved: ((CGWindowID, Int, Int, Int, Int) -> Void)?
    public var onStageReordered: ((Int, Int) -> Void)?
    public var onStageHandleVisibilityChanged: ((Int, Bool) -> Void)?
    public var onStageInsertRequested: ((StageInsertionEdge) -> Void)?
    public var onStageDeleteRequested: ((Int) -> Void)?
    public var onPointerSelectionChanged: ((Int?, Int?) -> Void)?
    public var onDesktopSelected: (() -> Void)?
    var onOverlayTapRouted: ((OverlayTapDiagnostic) -> Void)?
    var onStageButtonRevealed: ((String, CGPoint?) -> Void)?
    var onOverlayPointerRegionChanged: ((OverlayPointerRegionDiagnostic) -> Void)?

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
        synchronizeFrameToMainScreen(display: false)
        var view = OverlaySwiftUIView(
            viewModel: viewModel,
            onWindowSelected: onWindowSelected,
            onWindowMoved: onWindowMoved,
            onStageReordered: onStageReordered,
            onStageHandleVisibilityChanged: onStageHandleVisibilityChanged,
            onStageInsertRequested: onStageInsertRequested,
            onStageDeleteRequested: onStageDeleteRequested,
            onPointerSelectionChanged: onPointerSelectionChanged,
            onDesktopSelected: onDesktopSelected
        )
        view.onOverlayTapRouted = onOverlayTapRouted
        view.onStageButtonRevealed = onStageButtonRevealed
        view.onOverlayPointerRegionChanged = onOverlayPointerRegionChanged
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
        synchronizeFrameToMainScreen(display: true)
        hostingView?.frame = contentView?.bounds ?? .zero
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

    private func synchronizeFrameToMainScreen(display: Bool) {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: display)
    }

    public func hideOverlay() {
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
            }
        })
    }
}
