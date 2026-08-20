import CoreGraphics

/// Picks the single display the overlay belongs on. Plates describe where the user's attention
/// already is, so they follow the focused window rather than covering every screen.
public enum OverlayDisplayResolver {
    /// `focusedWindowFrame` and the display frames must share a coordinate space; pass
    /// `CGDisplayBounds` for the displays, since that is the space Accessibility reports in.
    public static func resolve(
        focusedWindowFrame: CGRect?,
        displays: [DesktopScreenDescriptor],
        mainDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        let fallback = displays.first { $0.displayID == mainDisplayID } ?? displays.first
        guard let focusedWindowFrame else { return fallback?.displayID }

        // A window mid-transition can report a zero size, and an empty rectangle intersects
        // nothing, so area would discard an origin that still answers the question.
        if focusedWindowFrame.isEmpty {
            let containing = displays.first { $0.frame.contains(focusedWindowFrame.origin) }
            return containing?.displayID ?? fallback?.displayID
        }

        let overlapping = displays
            .map { ($0.displayID, $0.frame.intersection(focusedWindowFrame)) }
            .filter { !$1.isNull }
        let best = overlapping.max { lhs, rhs in
            let lhsArea = lhs.1.width * lhs.1.height
            let rhsArea = rhs.1.width * rhs.1.height
            return lhsArea == rhsArea ? lhs.0 > rhs.0 : lhsArea < rhsArea
        }
        return best?.0 ?? fallback?.displayID
    }
}
