import AppKit

/// A full-screen OLED-black window that occludes stage windows in z-order. The selected
/// destination window is raised above it. No position/size manipulation is needed on
/// other windows.
public final class DesktopSurfaceWindow: NSWindow {

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

    /// Bring the surface to front, covering stage windows.
    /// Call this before raising the selected destination window.
    public func orderToFront() {
        // Re-assert frame in case something moved us
        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }
        orderFront(nil)
    }

    @objc private func screenDidChange() {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: true)
    }
}
