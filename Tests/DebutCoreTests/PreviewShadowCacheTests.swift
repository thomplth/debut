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

    @Test("A card zoomed through every drag view scale casts one shadow raster",
          arguments: [nil, 0.5, 16.0 / 10, 4.0] as [CGFloat?])
    func zoomReusesOneRaster(aspect: CGFloat?) {
        let cache = PreviewShadowCache()
        let resting = StageMetrics.standard
        let shadows = stride(from: 0.3, through: 1.6, by: 0.013).map { zoom in
            let metrics = resting.scaled(by: zoom)
            return cache.image(for: metrics.previewShadowSize(forImageAspect: aspect),
                               cornerRadius: 7)
        }
        #expect(shadows.allSatisfy { $0 === shadows[0] })
    }

    @Test("Every card of a busy overlay keeps its shadow, in both the stack and the drag view")
    func busyOverlayKeepsEveryShadow() {
        let cache = PreviewShadowCache()
        let sizes = (0..<24).flatMap { window in
            let aspect = 0.6 + CGFloat(window) * 0.07
            let resting = StageMetrics.standard.previewShadowSize(forImageAspect: aspect)
            return [resting, CGSize(width: resting.width * 1.2, height: resting.height * 1.2)]
        }
        let first = sizes.map { cache.image(for: $0, cornerRadius: 7) }
        let second = sizes.map { cache.image(for: $0, cornerRadius: 7) }
        #expect(zip(first, second).allSatisfy { $0 === $1 })
    }
}
