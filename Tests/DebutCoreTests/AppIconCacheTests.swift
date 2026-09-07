import AppKit
import Foundation
import Testing
@testable import DebutCore

@Suite("App icon cache")
struct AppIconCacheTests {
    private func stubIcon(_ size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size))
    }

    private func waitForWarm(_ cache: AppIconCache) {
        let done = DispatchSemaphore(value: 0)
        cache.whenWarmed { done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    @Test("A cold cache reports a miss rather than resolving on the calling thread")
    func coldMiss() {
        let cache = AppIconCache { _, size in self.stubIcon(size) }
        #expect(cache.cached(bundleID: "com.example.a", size: 32) == nil)
    }

    @Test("Warming makes the icon available to a later synchronous lookup")
    func warmThenHit() throws {
        let cache = AppIconCache { _, size in self.stubIcon(size) }
        cache.warm(bundleIDs: ["com.example.a"], sizes: [32])
        waitForWarm(cache)
        let icon = try #require(cache.cached(bundleID: "com.example.a", size: 32))
        #expect(icon.size == NSSize(width: 32, height: 32))
    }

    @Test("Each bundle and size is rasterized once no matter how often warming is asked for")
    func rasterizesOncePerKey() {
        let counter = Counter()
        let cache = AppIconCache { bundleID, size in
            counter.record("\(bundleID)@\(size)")
            return self.stubIcon(size)
        }
        for _ in 0..<3 {
            cache.warm(bundleIDs: ["com.example.a", "com.example.b"], sizes: [32, 64])
            waitForWarm(cache)
        }
        #expect(counter.total == 4)
    }

    // SwiftUI calls updateNSView repeatedly during stage cycling (KHA-448), so a miss that
    // rasterized every time would be worse than the lazy icon it replaced.
    @Test("A cache miss rasterizes once and is served from the cache thereafter")
    func missRasterizesOnce() {
        let counter = Counter()
        let cache = AppIconCache { _, size in
            counter.record("hit")
            return self.stubIcon(size)
        }
        for _ in 0..<3 {
            #expect(cache.cachedOrRasterize(bundleID: "com.example.a", size: 32) != nil)
        }
        #expect(counter.total == 1)
    }

    @Test("A later warm does not re-rasterize what a miss already cached")
    func missSuppressesLaterWarm() {
        let counter = Counter()
        let cache = AppIconCache { _, size in
            counter.record("hit")
            return self.stubIcon(size)
        }
        _ = cache.cachedOrRasterize(bundleID: "com.example.a", size: 32)
        cache.warm(bundleIDs: ["com.example.a"], sizes: [32])
        waitForWarm(cache)
        #expect(counter.total == 1)
    }

    @Test("An unresolvable bundle identifier is not cached and does not fail the warm")
    func unresolvableBundleID() {
        let cache = AppIconCache { _, _ in nil }
        cache.warm(bundleIDs: ["com.example.missing"], sizes: [32])
        waitForWarm(cache)
        #expect(cache.cached(bundleID: "com.example.missing", size: 32) == nil)
    }

    // The whole point of the cache: the image handed to the view must already hold pixels.
    // NSWorkspace returns an NSImage backed by a lazy IconServices representation whose
    // rasterization is deferred to draw time, where it becomes a synchronous XPC round-trip
    // on the main thread inside the Core Animation commit (KHA-481).
    @Test("The real rasterizer returns pixels, not a lazy IconServices representation")
    func rasterizerProducesBitmap() throws {
        let icon = try #require(AppIconCache.rasterizeApplicationIcon("com.apple.finder", 32))
        let rep = try #require(icon.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == 64)  // rasterized @2x for the point size

        // Drawing happens off the main thread, where a silent failure yields a blank bitmap
        // rather than an error. A non-nil image is not proof that it contains an icon.
        var distinct: Set<UInt32> = []
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let packed = UInt32(color.redComponent * 255) << 16
                    | UInt32(color.greenComponent * 255) << 8
                    | UInt32(color.alphaComponent * 255)
                distinct.insert(packed)
            }
        }
        #expect(distinct.count > 1)
    }

    @Test("Rasterizing off the main thread still produces a populated icon")
    func rasterizesOffMainThread() throws {
        let cache = AppIconCache()
        cache.warm(bundleIDs: ["com.apple.finder"], sizes: [32])
        waitForWarm(cache)
        let icon = try #require(cache.cached(bundleID: "com.apple.finder", size: 32))
        let rep = try #require(icon.representations.first as? NSBitmapImageRep)
        #expect(rep.colorAt(x: 32, y: 32)?.alphaComponent ?? 0 > 0)
    }

    @Test("A lazily resolved workspace icon is the representation the cache must avoid")
    func workspaceIconIsLazy() throws {
        let url = try #require(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        )
        let lazyIcon = NSWorkspace.shared.icon(forFile: url.path)
        let rep = try #require(lazyIcon.representations.first)
        #expect(!(rep is NSBitmapImageRep))
    }

    @Test("The warmed sizes do not move with the stage scale")
    func warmedSizesAreScaleIndependent() {
        // The cache is keyed by size, so following the scale would discard every warmed icon
        // whenever the slider moved and put the KHA-481 rasterize back on the main thread.
        let largest = StageMetrics.standard.scaled(by: CGFloat(AppSettings.maximumStageScale))
        #expect(AppIconCache.badgeRasterSize == largest.badgeSize)
        #expect(AppIconCache.placeholderIconRasterSize == largest.previewPlaceholderIconSize)
        #expect(AppIconCache.overlayIconSizes == [AppIconCache.placeholderIconRasterSize])
        #expect(AppIconCache.overlayBadgeIconSizes == [AppIconCache.badgeRasterSize])
    }

    // A badge draws only on a card that has a preview, so its SwiftUI `.shadow` was an offscreen
    // blur per badge per frame on exactly the cards the preview mode adds — the whole gap between
    // cycling with previews and without (KHA-641). In the bitmap it costs nothing per frame.
    @Test("The badge bitmap carries its drop shadow in the pixels")
    func badgeShadowIsBaked() throws {
        let side: CGFloat = 40
        let baked = AppIconCache.withBadgeShadow(opaqueIcon(side))
        let padding = AppIconCache.BakedBadgeShadow.padding
        #expect(baked.size == NSSize(width: side + padding * 2, height: side + padding * 2))

        // Size alone proves only that the bitmap was padded. A shadow that silently failed to
        // draw leaves that padding empty, so assert the pixels under the icon are actually dark.
        let rep = try #require(baked.representations.first as? NSBitmapImageRep)
        let scale = CGFloat(rep.pixelsWide) / baked.size.width
        let centerX = Int(baked.size.width / 2 * scale)
        // AppKit draws bottom-up and the shadow falls downwards, so it lands below the icon here.
        let belowIcon = Int((padding - AppIconCache.BakedBadgeShadow.dy) * scale)
        let shadowPixel = try #require(rep.colorAt(x: centerX, y: rep.pixelsHigh - 1 - belowIcon))
        #expect(shadowPixel.alphaComponent > 0.05)

        // The far corner is past four standard deviations, so a bitmap that merely tinted its
        // whole padding would not pass.
        let corner = try #require(rep.colorAt(x: 0, y: 0))
        #expect(corner.alphaComponent < 0.01)
    }

    @Test("The shadowed badge is cached apart from the plain icon of the same size")
    func badgeVariantIsItsOwnKey() throws {
        let cache = AppIconCache { _, size in self.opaqueIcon(size) }
        let plain = try #require(cache.cachedOrRasterize(bundleID: "com.example.a", size: 40))
        let badge = try #require(
            cache.cachedOrRasterize(bundleID: "com.example.a", size: 40, badge: true)
        )
        #expect(plain.size == NSSize(width: 40, height: 40))
        #expect(badge.size.width > plain.size.width)
        #expect(cache.cached(bundleID: "com.example.a", size: 40)?.size == plain.size)
    }

    @Test("Warming reaches the shadowed badge, not just the plain icon")
    func warmsBadgeVariant() throws {
        let cache = AppIconCache { _, size in self.opaqueIcon(size) }
        cache.warm(bundleIDs: ["com.example.a"], sizes: [64], badgeSizes: [40])
        waitForWarm(cache)
        #expect(cache.cached(bundleID: "com.example.a", size: 64) != nil)
        #expect(cache.cached(bundleID: "com.example.a", size: 40, badge: true) != nil)
        #expect(cache.cached(bundleID: "com.example.a", size: 40) == nil)
    }

    private func opaqueIcon(_ size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    func record(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        keys.append(key)
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return keys.count
    }
}
