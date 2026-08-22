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
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
