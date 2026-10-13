import AppKit
@testable import DebutCore

/// No test may draw on a real display (KHA-1075). A window the test must order in, so the window
/// server gives it a number, a level or a Space, goes far outside every display instead.
enum OffDesktop {
    static let origin = CGPoint(x: -30_000, y: -30_000)

    /// A frame no display reaches, so ordering a window in there shows nothing anywhere.
    static func frame(width: CGFloat = 1_440, height: CGFloat = 900) -> CGRect {
        CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// Hides a window that AppKit would pull back onto a display when it is ordered in, which it
    /// does to any titled window it cannot keep off-screen.
    @MainActor
    static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(origin)
    }
}

/// A titled window that stays where the test put it instead of being constrained onto a display.
final class OffDesktopWindow: NSWindow {
    @MainActor
    init(size: CGSize = CGSize(width: 120, height: 80)) {
        super.init(
            contentRect: CGRect(origin: OffDesktop.origin, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // Closing an NSWindow releases it by default, which over-releases the reference a test
        // still holds and segfaults the *next* test rather than this one.
        isReleasedWhenClosed = false
        alphaValue = 0
        ignoresMouseEvents = true
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension OverlayWindow {
    /// An overlay aimed at a frame no display reaches, so showing it draws nothing.
    @MainActor
    static func offDesktop() -> OverlayWindow {
        let window = OverlayWindow()
        window.targetScreenFrame = OffDesktop.frame()
        return window
    }
}
