import AppKit
import Foundation

/// Holds already-rasterized application icons so the overlay never rasterizes one while drawing.
///
/// `NSWorkspace.icon(forFile:)` hands back an `NSImage` backed by a lazy IconServices
/// representation. Assigning it is free; rasterizing it is a synchronous XPC round-trip to the
/// icon daemon, and it happens at draw time — on the main thread, inside the Core Animation
/// commit, once per stage. With a cold IconServices cache that measured ~250ms (KHA-481).
public final class AppIconCache: @unchecked Sendable {
    public static let shared = AppIconCache()

    /// The sizes the overlay rasterizes icons at, and therefore the set worth warming.
    ///
    /// Fixed at the largest stage scale rather than following the current one: the cache is keyed
    /// by size, so tracking the scale would throw the whole warmed set away every time the slider
    /// moved and put the rasterize back on the main thread. An image view downsamples the
    /// oversized bitmap for free.
    public static let placeholderIconRasterSize = StageMetrics.standard
        .scaled(by: CGFloat(AppSettings.maximumStageScale)).previewPlaceholderIconSize
    public static let badgeRasterSize = StageMetrics.standard
        .scaled(by: CGFloat(AppSettings.maximumStageScale)).badgeSize

    public static let overlayIconSizes: [CGFloat] = [placeholderIconRasterSize]

    /// Warmed apart from the plain sizes because the badge's bitmap carries a baked drop shadow.
    public static let overlayBadgeIconSizes: [CGFloat] = [badgeRasterSize]

    /// One halo serves every placeholder, including icons that cannot be resolved. Its center
    /// is transparent so irregular icons do not reveal an opaque silhouette behind them.
    /// Bake the active lift once; the stage's opacity attenuates it when inactive. Like the
    /// badge shadow, its blur scales with the icon instead of being rebuilt during animation.
    struct BakedIconShadow {
        static let iconSide = placeholderIconRasterSize
        static let blur: CGFloat = 36 * CGFloat(AppSettings.maximumStageScale)
        static let dy: CGFloat = 8 * CGFloat(AppSettings.maximumStageScale)
        static let opacity: CGFloat = 0.22
        static let padding: CGFloat = blur * 2
    }

    static let iconShadow: NSImage = {
        let side = BakedIconShadow.iconSide
        let padding = BakedIconShadow.padding
        let size = NSSize(width: side + padding * 2, height: side + padding * 2)
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * 2).rounded()),
            pixelsHigh: Int((size.height * 2).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Cast from outside the bitmap so only the blur lands in it, never the source shape.
        let silhouette = NSBezierPath(
            roundedRect: NSRect(x: padding, y: padding + size.height, width: side, height: side),
            xRadius: side * 0.22, yRadius: side * 0.22
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(BakedIconShadow.opacity)
        shadow.shadowOffset = NSSize(width: 0, height: -size.height - BakedIconShadow.dy)
        shadow.shadowBlurRadius = BakedIconShadow.blur
        shadow.set()
        NSColor.black.setFill()
        silhouette.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Fade the center away softly. A hard squircle cutout leaves a visible collar around
        // icons whose own transparent margins do not exactly match that shape.
        if let fade = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1),
                     CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 0.35, 1]
        ) {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.cgContext.setBlendMode(.destinationOut)
            context.cgContext.drawRadialGradient(
                fade, startCenter: center, startRadius: 0,
                endCenter: center, endRadius: side * 0.6, options: []
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        return image
    }()

    /// The badge's drop shadow, expressed in raster points so it can be drawn into the bitmap.
    ///
    /// The badge is rasterized at the maximum stage scale and framed at the drawn one, so the
    /// shadow the overlay asks for — `2 * scaleFactor` — is a constant multiple of the raster size
    /// whatever the current scale is. Baking it therefore stays correct across the scale slider.
    public struct BakedBadgeShadow {
        /// The overlay asked SwiftUI for `radius: 2 * scaleFactor`. Core Graphics takes twice that
        /// number for the same gaussian — measured by sweeping the factor and reading the mean
        /// channel delta against the unbaked render, which bottoms out at 2.
        public static let blur: CGFloat = 4 * CGFloat(AppSettings.maximumStageScale)
        public static let dy: CGFloat = CGFloat(AppSettings.maximumStageScale)
        public static let opacity: CGFloat = 0.3

        /// Room for the blur to spill outside the icon, at four standard deviations.
        public static let padding: CGFloat = blur * 2
    }

    private struct Key: Hashable {
        let bundleID: String
        let size: CGFloat
        let badge: Bool
    }

    private let rasterize: (String, CGFloat) -> NSImage?
    private let queue = DispatchQueue(label: "com.thomplth.Debut.app-icon-cache", qos: .utility)
    private let lock = NSLock()
    private var icons: [Key: NSImage] = [:]
    private var requested: Set<Key> = []

    public init(rasterize: @escaping (String, CGFloat) -> NSImage? = AppIconCache.rasterizeApplicationIcon) {
        self.rasterize = rasterize
    }

    public func cached(bundleID: String, size: CGFloat, badge: Bool = false) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return icons[Key(bundleID: bundleID, size: size, badge: badge)]
    }

    /// Cache lookup that falls back to rasterizing on the calling thread, keeping the result so
    /// a miss is paid once rather than on every SwiftUI update.
    public func cachedOrRasterize(bundleID: String, size: CGFloat, badge: Bool = false) -> NSImage? {
        if let hit = cached(bundleID: bundleID, size: size, badge: badge) { return hit }
        let key = Key(bundleID: bundleID, size: size, badge: badge)
        guard let icon = make(key) else { return nil }
        lock.lock()
        icons[key] = icon
        requested.insert(key)
        lock.unlock()
        return icon
    }

    public func warm(bundleIDs: [String], sizes: [CGFloat], badgeSizes: [CGFloat] = []) {
        let pending: [Key] = {
            lock.lock()
            defer { lock.unlock() }
            let keys = bundleIDs.flatMap { bundleID in
                sizes.map { Key(bundleID: bundleID, size: $0, badge: false) }
                    + badgeSizes.map { Key(bundleID: bundleID, size: $0, badge: true) }
            }
            .filter { !requested.contains($0) }
            requested.formUnion(keys)
            return keys
        }()
        guard !pending.isEmpty else { return }

        for key in pending {
            queue.async { [self] in
                guard let icon = make(key) else { return }
                lock.lock()
                icons[key] = icon
                lock.unlock()
            }
        }
    }

    private func make(_ key: Key) -> NSImage? {
        guard let icon = rasterize(key.bundleID, key.size) else { return nil }
        return key.badge ? AppIconCache.withBadgeShadow(icon) : icon
    }

    /// Runs once every warm request enqueued so far has finished. The queue is serial, so
    /// ordering alone gives the guarantee.
    public func whenWarmed(_ body: @escaping @Sendable () -> Void) {
        queue.async { body() }
    }

    /// Draws the icon into a padded bitmap with its drop shadow already in the pixels.
    ///
    /// A badge renders only on a card that has a preview, so its `.shadow` was an offscreen blur
    /// per badge per frame, on exactly the cards the preview mode adds. In the pixels it costs
    /// nothing to draw.
    public static func withBadgeShadow(_ icon: NSImage) -> NSImage {
        let padding = BakedBadgeShadow.padding
        let inner = icon.size
        let size = NSSize(width: inner.width + padding * 2, height: inner.height + padding * 2)
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return icon }
        bitmap.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(BakedBadgeShadow.opacity)
        // AppKit's y axis points up, so a shadow SwiftUI drops downwards has a negative offset.
        shadow.shadowOffset = NSSize(width: 0, height: -BakedBadgeShadow.dy)
        shadow.shadowBlurRadius = BakedBadgeShadow.blur
        shadow.set()
        icon.draw(in: NSRect(origin: NSPoint(x: padding, y: padding), size: inner))
        NSGraphicsContext.restoreGraphicsState()

        let baked = NSImage(size: size)
        baked.addRepresentation(bitmap)
        return baked
    }

    /// Forces the IconServices round-trip here, on whatever thread this is called from, and keeps
    /// the resulting pixels. The returned image draws without touching IconServices again.
    public static func rasterizeApplicationIcon(_ bundleID: String, _ size: CGFloat) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let points = NSSize(width: size, height: size)
        icon.size = points

        // Fixed rather than read from NSScreen, which is not safe to touch from the warming
        // queue. macOS backing scale is only ever 1 or 2, and a @2x representation downsamples
        // correctly on a 1x display.
        let pixels = Int((size * 2).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = points

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(origin: .zero, size: points))
        NSGraphicsContext.restoreGraphicsState()

        let rasterized = NSImage(size: points)
        rasterized.addRepresentation(bitmap)
        return rasterized
    }
}
