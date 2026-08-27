import AppKit

/// Debut's mark: the active space as a full-width bar between two shorter, dimmer
/// neighbours — the overlay's stage stack reduced to what survives at 16pt.
public enum DebutGlyph {
    /// Geometry in unit coordinates with a top-left origin, matching
    /// `docs/media/icons/debut-menubar.svg`.
    private struct Space {
        let frame: CGRect
        let radius: CGFloat
        let alpha: CGFloat
    }

    private static let spaces = [
        Space(
            frame: CGRect(x: 0.1875, y: 0.15625, width: 0.625, height: 0.15625),
            radius: 0.0625,
            alpha: 0.45
        ),
        Space(
            frame: CGRect(x: 0.0625, y: 0.40625, width: 0.875, height: 0.1875),
            radius: 0.078125,
            alpha: 1
        ),
        Space(
            frame: CGRect(x: 0.1875, y: 0.6875, width: 0.625, height: 0.15625),
            radius: 0.0625,
            alpha: 0.45
        )
    ]

    public static let menuBarSize: CGFloat = 16

    /// Drawn at the requested point size rather than scaled from a raster, so the same
    /// mark stays crisp in the menu bar and in the Settings header.
    public static func image(size: CGFloat) -> NSImage {
        let image = NSImage(
            size: NSSize(width: size, height: size),
            flipped: true
        ) { _ in
            for space in spaces {
                let frame = CGRect(
                    x: space.frame.minX * size,
                    y: space.frame.minY * size,
                    width: space.frame.width * size,
                    height: space.frame.height * size
                )
                let radius = space.radius * size
                NSColor.black.withAlphaComponent(space.alpha).setFill()
                NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        // Alpha-only rendering: macOS inverts the mark for dark menu bars and for the
        // highlight drawn while the status item's menu is open.
        image.isTemplate = true
        image.accessibilityDescription = "Debut"
        return image
    }
}
