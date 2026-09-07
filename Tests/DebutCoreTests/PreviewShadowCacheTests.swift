import AppKit
import Testing
@testable import DebutCore

@MainActor
@Suite("Preview shadow cache")
struct PreviewShadowCacheTests {
    @Test("Preview shadows reuse geometry without depending on captured content")
    func reusesGeometry() throws {
        let cache = PreviewShadowCache()
        let size = CGSize(width: 160, height: 100)
        let shadow = cache.image(for: size, cornerRadius: 7)
        #expect(cache.image(for: size, cornerRadius: 7) === shadow)
        #expect(cache.image(for: CGSize(width: 52, height: 100), cornerRadius: 7) !== shadow)
        #expect(cache.image(for: size, cornerRadius: 12) !== shadow)
    }

    @Test("The cached rectangle casts pixels outside the preview and leaves its center clear")
    func containsShadowPixels() throws {
        let shadow = PreviewShadowCache().image(for: CGSize(width: 160, height: 100), cornerRadius: 7)
        let rep = try #require(shadow.representations.first as? NSBitmapImageRep)
        let scale = CGFloat(rep.pixelsWide) / shadow.size.width
        let padding = PreviewShadowCache.padding
        let right = try #require(rep.colorAt(
            x: Int((padding + 160 + 4) * scale), y: rep.pixelsHigh / 2
        ))
        #expect(right.alphaComponent > 0.2)
        let center = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        #expect(center.alphaComponent < 0.01)
        let corner = try #require(rep.colorAt(x: 0, y: 0))
        #expect(corner.alphaComponent < 0.01)
    }
}
