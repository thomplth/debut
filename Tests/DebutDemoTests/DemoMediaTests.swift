import CoreGraphics
import Testing
@testable import DebutDemo

struct DemoMediaTests {
    @Test func keyReleaseKeepsCommandHeldUntilCommit() {
        var keys = DemoKeyState()
        keys.update(flags: .maskCommand)
        keys.update(key: 48, down: true, flags: .maskCommand)
        #expect(keys.labels == ["⌘ Command", "Tab"])
        #expect(keys.pressed == [true, true])
        keys.update(key: 48, down: false, flags: .maskCommand)
        #expect(keys.pressed == [true, false])
        keys.update(flags: [])
        #expect(keys.pressed == [false, false])
    }

    @Test func cropFindsContentWithoutKeepingTransparentDesktopMargins() throws {
        let context = try #require(CGContext(data: nil, width: 100, height: 80,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 30, y: 20, width: 40, height: 40))
        let source = try #require(context.makeImage())
        let image = try croppedOverlay(source, padding: 6)
        #expect(image.width == 52)
        #expect(image.height == 52)
    }

    @Test func emptyCaptureCannotBecomeACover() throws {
        let context = try #require(CGContext(data: nil, width: 100, height: 80,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        #expect(throws: (any Error).self) { try croppedOverlay(image, padding: 6) }
    }

    @Test func glassCaptureUsesOverlayBoundsAndCompositedColors() throws {
        let context = try #require(CGContext(data: nil, width: 100, height: 80,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 30, y: 20, width: 40, height: 40))
        let mask = try #require(context.makeImage())
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let rendered = try #require(context.makeImage())
        let cropped = try croppedOverlay(mask, padding: 6, renderedImage: rendered)
        #expect(cropped.width == 52)
        #expect(cropped.height == 52)
        let data = try #require(cropped.dataProvider?.data)
        let pixels = try #require(CFDataGetBytePtr(data))
        #expect(pixels[2] == 255)
    }

    @Test func coverHasALightBackgroundForReadableLabelsInEitherREADMETheme() throws {
        let context = try #require(CGContext(data: nil, width: 20, height: 20,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
        let image = try overlayCoverImage(#require(context.makeImage()))
        let data = try #require(image.dataProvider?.data)
        let pixels = try #require(CFDataGetBytePtr(data))
        #expect(Array(UnsafeBufferPointer(start: pixels, count: 4)) == [255, 255, 255, 255])
        #expect(pixels[10 * image.bytesPerRow + 10 * 4] == 0)
    }
}
