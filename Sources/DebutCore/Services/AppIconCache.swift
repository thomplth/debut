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
    /// One 128-point raster serves a failed capture's icon (badge-sized, at most 100 points)
    /// and a native-size icon card.
    public static let placeholderIconRasterSize = StageMetrics.nativeIconCanvasSize
    public static let badgeRasterSize = StageMetrics.standard
        .scaled(by: CGFloat(AppSettings.maximumStageScale)).drawnBadgeSize

    /// An icon card at native size draws the same 128-point canvas as the placeholder, so the
    /// two share one warmed raster and the default costs nothing extra.
    public static let nativeIconSlotRasterSize = placeholderIconRasterSize
    /// Larger icon cards downsample a raster at the next size up, warmed only once the icon size
    /// is set above native: each step doubles a bitmap kept for every app.
    public static let largeIconSlotRasterSize = StageMetrics.nativeIconCanvasSize * 2
    public static let largestIconSlotRasterSize = StageMetrics.nativeIconCanvasSize
        * CGFloat(AppSettings.maximumStageScale)

    public static let overlayIconSizes: [CGFloat] = [placeholderIconRasterSize]

    /// The raster icon cards draw from at an icon size.
    public static func iconSlotRasterSize(iconScale: Double) -> CGFloat {
        if iconScale <= 1 { return nativeIconSlotRasterSize }
        return iconScale <= 2 ? largeIconSlotRasterSize : largestIconSlotRasterSize
    }

    /// Every size to warm for an app, given the icon size icon cards are drawn at.
    public static func overlayIconSizes(iconScale: Double) -> [CGFloat] {
        Array(Set(overlayIconSizes + [iconSlotRasterSize(iconScale: iconScale)])).sorted()
    }

    /// The icon size icon cards draw at, which decides what launches warm.
    public var iconScale: Double {
        get { lock.lock(); defer { lock.unlock() }; return storedIconScale }
        set { lock.lock(); storedIconScale = newValue; lock.unlock() }
    }

    /// The sizes to warm for a newly seen app.
    public var warmSizes: [CGFloat] { Self.overlayIconSizes(iconScale: iconScale) }

    /// Warmed apart from the plain sizes because the badge's bitmap carries a baked drop shadow.
    public static let overlayBadgeIconSizes: [CGFloat] = [badgeRasterSize]

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
    private var storedIconScale: Double = AppSettings.defaultIconScale

    public init(rasterize: @escaping (String, CGFloat) -> NSImage? = AppIconCache.rasterizeApplicationIcon) {
        self.rasterize = rasterize
    }

    /// How many icons, and of how many apps, are held: what retention is bounding (KHA-1105).
    public var cachedCounts: (icons: Int, apps: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (icons.count, Set(icons.keys.map(\.bundleID)).count)
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
                // Evicted while it rasterized: inserting it now would keep it with nothing left
                // to evict it again.
                if requested.contains(key) { icons[key] = icon }
                lock.unlock()
            }
        }
    }

    private func make(_ key: Key) -> NSImage? {
        guard let icon = rasterize(key.bundleID, key.size) else { return nil }
        return key.badge ? AppIconCache.withBadgeShadow(icon) : icon
    }

    /// Every size the overlay rasterizes at. Only these are managed by `retain(sizes:badgeSizes:)`;
    /// an icon drawn elsewhere at its own size, such as Settings' excluded-app list, is left alone.
    public static let overlayRasterSizes: Set<CGFloat> = [
        placeholderIconRasterSize, largeIconSlotRasterSize, largestIconSlotRasterSize,
    ]

    /// Drops the overlay icons at sizes no longer warmed, and forgets they were warmed so a later
    /// `warm` rasterizes them again.
    ///
    /// Nothing was ever evicted before: a size warmed once — the icon slider passing 2x for a
    /// moment — stayed for every app, and Core Animation keeps a copy of each icon it drew for as
    /// long as the image lives. 33 apps held ~300 MB that way (KHA-1105).
    public func retain(sizes: Set<CGFloat>, badgeSizes: Set<CGFloat>) {
        remove { key in
            key.badge
                ? !badgeSizes.contains(key.size)
                : Self.overlayRasterSizes.contains(key.size) && !sizes.contains(key.size)
        }
    }

    /// Drops every icon of these apps.
    public func evict(bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        remove { bundleIDs.contains($0.bundleID) }
    }

    private func remove(where shouldRemove: (Key) -> Bool) {
        lock.lock()
        icons = icons.filter { !shouldRemove($0.key) }
        requested = requested.filter { !shouldRemove($0) }
        lock.unlock()
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


/// Keeps the icon cache to the apps that own a window, at the sizes the overlay draws (KHA-1105).
///
/// An app is evicted when it stops owning a window, never merely for not owning one yet: a
/// launching app is warmed before its first window is assigned, and evicting it in between would
/// leave its first card to rasterize on the main thread (KHA-481). Arrivals are warmed in the same
/// step, so an app that comes back is warm again before it is drawn.
public struct AppIconRetention {
    private let cache: AppIconCache
    /// Drawn without owning a window, such as the Appearance page's sample stage.
    private let alwaysKept: Set<String>
    private var windowOwners: Set<String> = []
    private var sizes: [CGFloat]?

    public init(cache: AppIconCache = .shared, alwaysKept: Set<String> = []) {
        self.cache = cache
        self.alwaysKept = alwaysKept
    }

    public mutating func update(windowOwnerBundleIDs: Set<String>) {
        let sizes = cache.warmSizes
        let sizesChanged = sizes != self.sizes
        guard sizesChanged || windowOwnerBundleIDs != windowOwners else { return }
        if sizesChanged {
            self.sizes = sizes
            cache.retain(sizes: Set(sizes), badgeSizes: Set(AppIconCache.overlayBadgeIconSizes))
        }
        // A new size has to be warmed for every owner; otherwise only arrivals need it.
        let warming = sizesChanged ? windowOwnerBundleIDs : windowOwnerBundleIDs.subtracting(windowOwners)
        cache.evict(bundleIDs: windowOwners.subtracting(windowOwnerBundleIDs).subtracting(alwaysKept))
        windowOwners = windowOwnerBundleIDs
        cache.warm(
            bundleIDs: warming.sorted(),
            sizes: sizes,
            badgeSizes: AppIconCache.overlayBadgeIconSizes
        )
    }
}
