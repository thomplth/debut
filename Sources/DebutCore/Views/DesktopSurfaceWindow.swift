import AppKit

/// A full-screen OLED-black window that sits between active and inactive stage windows
/// in z-order. The selected window is placed above it; all other windows are
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

    /// Bring the surface to front for an empty stage.
    public nonisolated func orderToFront() {
        MainActor.assumeIsolated {
            // Re-assert frame in case something moved us
            if let screen = NSScreen.main {
                setFrame(screen.frame, display: false)
            }
            orderFront(nil)
        }
    }

    /// Order the surface directly behind a destination window. If Window Server
    /// does not confirm that relationship, remove the surface rather than risk
    /// covering the destination.
    public nonisolated func orderBehind(windowID: CGWindowID) -> Bool {
        MainActor.assumeIsolated {
            guard windowID != kCGNullWindowID else {
                orderOut(nil)
                return false
            }

            if let screen = NSScreen.main {
                setFrame(screen.frame, display: false)
            }
            order(.below, relativeTo: Int(windowID))

            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[CFString: Any]]
            else {
                orderOut(nil)
                return false
            }
            let orderedWindowIDs = windowInfo.compactMap {
                $0[kCGWindowNumber] as? CGWindowID
            }
            guard windowNumber > 0 else {
                orderOut(nil)
                return false
            }
            guard Self.isOrderedBehind(
                targetWindowID: windowID,
                surfaceWindowID: CGWindowID(windowNumber),
                orderedWindowIDs: orderedWindowIDs
            ) else {
                orderOut(nil)
                return false
            }
            return true
        }
    }

    nonisolated static func isOrderedBehind(
        targetWindowID: CGWindowID,
        surfaceWindowID: CGWindowID,
        orderedWindowIDs: [CGWindowID]
    ) -> Bool {
        guard let targetIndex = orderedWindowIDs.firstIndex(of: targetWindowID),
              let surfaceIndex = orderedWindowIDs.firstIndex(of: surfaceWindowID)
        else { return false }
        return targetIndex < surfaceIndex
    }

    @objc private func screenDidChange() {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: true)
    }
}
