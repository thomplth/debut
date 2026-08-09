import AppKit
import SwiftUI

public final class OverlayWindow: NSWindow, @unchecked Sendable {
    private var hostingView: NSHostingView<OverlaySwiftUIView>?
    public var onWindowSelected: ((Int, Int) -> Void)?
    public var onWindowMoved: ((CGWindowID, Int, Int) -> Void)?
    public var onStageReordered: ((Int, Int) -> Void)?
    public var onStageHandleVisibilityChanged: ((Int, Bool) -> Void)?
    public var onPointerSelectionChanged: ((Int?, Int?) -> Void)?

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

    public func update(viewModel: OverlayViewModel) {
        let view = OverlaySwiftUIView(
            viewModel: viewModel,
            onWindowSelected: onWindowSelected,
            onWindowMoved: onWindowMoved,
            onStageReordered: onStageReordered,
            onStageHandleVisibilityChanged: onStageHandleVisibilityChanged,
            onPointerSelectionChanged: onPointerSelectionChanged
        )
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hv = NSHostingView(rootView: view)
            hv.frame = contentView?.bounds ?? .zero
            hv.autoresizingMask = [.width, .height]
            contentView?.addSubview(hv)
            hostingView = hv
        }
    }

    public func showOverlay() {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: true)
        hostingView?.frame = contentView?.bounds ?? .zero
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
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
