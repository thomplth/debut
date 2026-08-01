import AppKit

/// A full-screen OLED-black window that sits between active and inactive stage windows
/// in z-order. Active stage windows are raised above it; inactive stage windows are
/// occluded behind it. No position/size manipulation needed on other windows.
public final class DesktopSurfaceWindow: NSWindow, DesktopSurfacePresenting {

    public init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = .normal
        self.isOpaque = true
        self.hasShadow = false
        self.backgroundColor = .black
        self.collectionBehavior = [.stationary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.ignoresMouseEvents = false

        // Observe screen changes to resize
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // Prevent becoming key/main or reordering on click
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    public override func mouseDown(with event: NSEvent) {}

    /// Bring the surface to front, covering all inactive stage windows.
    /// Call this BEFORE raising active stage windows.
    public nonisolated func orderToFront() {
        MainActor.assumeIsolated {
            // Re-assert frame in case something moved us
            if let screen = NSScreen.main {
                setFrame(screen.frame, display: false)
            }
            orderFront(nil)
        }
    }

    @objc private func screenDidChange() {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: true)
    }
}
