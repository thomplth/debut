import AppKit
import Foundation
import Testing
@testable import DebutCore

@Suite("Debut glyph")
struct DebutGlyphTests {
    /// Alpha at a point expressed in unit coordinates with a top-left origin, so the
    /// expectations below read in the same frame as the mark's own geometry.
    private func alpha(_ image: NSImage, x: CGFloat, y: CGFloat) -> CGFloat {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return -1
        }
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let column = min(width - 1, max(0, Int(x * CGFloat(width))))
        let rowFromTop = min(height - 1, max(0, Int(y * CGFloat(height))))
        // CGContext rasterizes bottom-up, so flip the row back into top-left space.
        let row = height - 1 - rowFromTop
        return CGFloat(pixels[(row * width + column) * 4 + 3]) / 255
    }

    @Test("The mark is a template image, so macOS inverts it for light and dark menu bars")
    func isTemplate() {
        #expect(DebutGlyph.image(size: DebutGlyph.menuBarSize).isTemplate)
    }

    @Test("The active stage is opaque and its neighbours are dimmer")
    func activeStageReadsAsSelected() {
        let mark = DebutGlyph.image(size: 64)
        let active = alpha(mark, x: 0.5, y: 0.5)
        let above = alpha(mark, x: 0.5, y: 0.234)
        let below = alpha(mark, x: 0.5, y: 0.766)

        #expect(active > 0.9)
        #expect(above > 0.25 && above < 0.65)
        #expect(abs(above - below) < 0.05)
    }

    @Test("The active stage is wider than its neighbours")
    func activeStageIsWider() {
        let mark = DebutGlyph.image(size: 64)
        #expect(alpha(mark, x: 0.1, y: 0.5) > 0.9)
        #expect(alpha(mark, x: 0.1, y: 0.234) < 0.05)
    }

    @Test("The stages are separated rather than fused into one block")
    func stagesAreSeparated() {
        #expect(alpha(DebutGlyph.image(size: 64), x: 0.5, y: 0.36) < 0.05)
    }

    @Test("A larger request scales the mark instead of padding it")
    func scalesWithRequestedSize() {
        let small = DebutGlyph.image(size: 16)
        let large = DebutGlyph.image(size: 128)

        #expect(large.size == NSSize(width: 128, height: 128))
        for (x, y) in [(0.5, 0.5), (0.1, 0.5), (0.5, 0.234), (0.5, 0.36)] {
            #expect(abs(alpha(small, x: x, y: y) - alpha(large, x: x, y: y)) < 0.12)
        }
    }
}
