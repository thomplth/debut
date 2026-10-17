import AppKit

/// Blurs a rounded rectangle once per preview geometry, never the captured window content.
/// Geometry is expressed before stage scaling, so selection and depth animations reuse it.
@MainActor
final class PreviewShadowCache {
    static let shared = PreviewShadowCache()
    static let padding: CGFloat = 72
    /// Pixels per point. A 36-point blur has no detail a Retina raster would add, and at 2x a
    /// full overlay's shadows outgrew the cache, which then blurred them again on every render.
    static let rasterScale: CGFloat = 1
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.countLimit = 256
        images.totalCostLimit = 48 * 1024 * 1024
    }

    func image(for size: CGSize, cornerRadius: CGFloat) -> NSImage {
        // Snap to raster pixels so fractional layout noise does not churn the cache.
        let width = max(1, Int((size.width * Self.rasterScale).rounded()))
        let height = max(1, Int((size.height * Self.rasterScale).rounded()))
        let radius = max(0, Int((cornerRadius * Self.rasterScale).rounded()))
        let key = "\(width):\(height):\(radius)" as NSString
        if let image = images.object(forKey: key) { return image }
        let inner = CGSize(width: CGFloat(width) / Self.rasterScale,
                           height: CGFloat(height) / Self.rasterScale)
        let padded = CGSize(width: inner.width + Self.padding * 2,
                            height: inner.height + Self.padding * 2)
        let image = NSImage(size: padded)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(padded.width * Self.rasterScale),
            pixelsHigh: Int(padded.height * Self.rasterScale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        bitmap.size = padded
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let silhouette = NSBezierPath(
            roundedRect: CGRect(x: Self.padding, y: Self.padding,
                                width: inner.width, height: inner.height),
            xRadius: CGFloat(radius) / Self.rasterScale, yRadius: CGFloat(radius) / Self.rasterScale
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black
        // AppKit's blur is twice SwiftUI's radius; y points upwards.
        shadow.shadowBlurRadius = 36
        shadow.shadowOffset = CGSize(width: 0, height: -8)
        shadow.set()
        NSColor.black.setFill()
        silhouette.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Preserve transparent preview content: only the exterior shadow belongs here.
        context.cgContext.setBlendMode(.destinationOut)
        NSColor.black.setFill()
        silhouette.fill()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        images.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return image
    }
}
