import AppKit

/// Briefly covers normal application windows while a destination stage is
/// reconstructed. Its floating level remains below the status-bar overlay, so
/// overlay-driven switches keep showing the stage picker during reconstruction.
public final class StageTransitionWindow: NSWindow, StageTransitionPresenting {
    private var transitionGeneration = 0

    public init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        collectionBehavior = [.stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public nonisolated func beginTransition() {
        MainActor.assumeIsolated {
            transitionGeneration += 1
            alphaValue = 1
            if let screen = NSScreen.main {
                setFrame(screen.frame, display: false)
            }
            orderFrontRegardless()
        }
    }

    public nonisolated func completeTransition() {
        MainActor.assumeIsolated {
            let completedGeneration = transitionGeneration
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.08
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          self.transitionGeneration == completedGeneration
                    else { return }
                    self.orderOut(nil)
                    self.alphaValue = 1
                }
            })
        }
    }
}
