import CoreGraphics

/// What the overlay needs to know about the frontmost app's focused window: where it sits, so
/// the stages can open on that display, and whether it is fullscreen.
///
/// The frame is in Quartz global coordinates, matching `CGDisplayBounds` and the Accessibility
/// API it is read from.
public struct FocusedWindowSnapshot: Equatable, Sendable {
    public var frame: CGRect?
    public var isFullscreen: Bool

    public init(frame: CGRect?, isFullscreen: Bool) {
        self.frame = frame
        self.isFullscreen = isFullscreen
    }

    /// Nothing is focused, or the probe could not answer.
    public static let unfocused = FocusedWindowSnapshot(frame: nil, isFullscreen: false)
}
