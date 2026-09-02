import AppKit
import CoreGraphics

/// A connected display, reduced to what choosing an overlay display needs.
public struct DesktopScreenDescriptor: Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect

    public init(displayID: CGDirectDisplayID, frame: CGRect) {
        self.displayID = displayID
        self.frame = frame
    }
}

extension NSScreen {
    public var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    public var overlayTopContentInset: CGFloat {
        OverlayDisplayResolver.topContentInset(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTopInset: safeAreaInsets.top,
            menuBarHeight: NSStatusBar.system.thickness
        )
    }

    public var overlayFrame: CGRect {
        OverlayDisplayResolver.overlayFrame(
            displayFrame: frame,
            topContentInset: overlayTopContentInset
        )
    }
}
