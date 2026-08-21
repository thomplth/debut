import AppKit
import Foundation

/// Holds already-rasterized application icons so the overlay never rasterizes one while drawing.
///
/// `NSWorkspace.icon(forFile:)` hands back an `NSImage` backed by a lazy IconServices
/// representation. Assigning it is free; rasterizing it is a synchronous XPC round-trip to the
/// icon daemon, and it happens at draw time — on the main thread, inside the Core Animation
/// commit, once per plate. With a cold IconServices cache that measured ~250ms (KHA-481).
public final class AppIconCache: @unchecked Sendable {
    public static let shared = AppIconCache()

    /// The sizes the overlay draws icons at, and therefore the set worth warming.
    public static let overlayIconSizes: [CGFloat] = [
        PlateConstants.previewPlaceholderIconSize,
        PlateConstants.badgeSize,
    ]

    private struct Key: Hashable {
        let bundleID: String
        let size: CGFloat
    }

    private let rasterize: (String, CGFloat) -> NSImage?
    private let queue = DispatchQueue(label: "com.thomplth.Debut.app-icon-cache", qos: .utility)
    private let lock = NSLock()
    private var icons: [Key: NSImage] = [:]
    private var requested: Set<Key> = []

    public init(rasterize: @escaping (String, CGFloat) -> NSImage? = AppIconCache.rasterizeApplicationIcon) {
        self.rasterize = rasterize
    }

    public func cached(bundleID: String, size: CGFloat) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return icons[Key(bundleID: bundleID, size: size)]
    }

    /// Cache lookup that falls back to rasterizing on the calling thread, keeping the result so
    /// a miss is paid once rather than on every SwiftUI update.
    public func cachedOrRasterize(bundleID: String, size: CGFloat) -> NSImage? {
        if let hit = cached(bundleID: bundleID, size: size) { return hit }
        let key = Key(bundleID: bundleID, size: size)
        guard let icon = rasterize(bundleID, size) else { return nil }
        lock.lock()
        icons[key] = icon
        requested.insert(key)
        lock.unlock()
        return icon
    }

    public func warm(bundleIDs: [String], sizes: [CGFloat]) {
        let pending: [Key] = {
            lock.lock()
            defer { lock.unlock() }
            let keys = bundleIDs
                .flatMap { bundleID in sizes.map { Key(bundleID: bundleID, size: $0) } }
                .filter { !requested.contains($0) }
            requested.formUnion(keys)
            return keys
        }()
        guard !pending.isEmpty else { return }

        for key in pending {
            queue.async { [self] in
                guard let icon = rasterize(key.bundleID, key.size) else { return }
                lock.lock()
                icons[key] = icon
                lock.unlock()
            }
        }
    }

    /// Runs once every warm request enqueued so far has finished. The queue is serial, so
    /// ordering alone gives the guarantee.
    public func whenWarmed(_ body: @escaping () -> Void) {
        queue.async { body() }
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
