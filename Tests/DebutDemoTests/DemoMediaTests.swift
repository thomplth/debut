import CoreGraphics
import Testing
@testable import DebutDemo

struct DemoMediaTests {
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

    @Test func coverKeepsTransparencyAndAddsRoomForTheShadow() throws {
        let context = try #require(CGContext(data: nil, width: 20, height: 20,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
        // A faint shadow at the source edge must survive framing, with margin beyond it.
        context.setFillColor(CGColor(gray: 0, alpha: 2.0 / 255))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try overlayCoverImage(#require(context.makeImage()))
        #expect(image.width == 15 + 256)
        #expect(image.height == 15 + 256)
        let data = try #require(image.dataProvider?.data)
        let pixels = try #require(CFDataGetBytePtr(data))
        #expect(Array(UnsafeBufferPointer(start: pixels, count: 4)) == [0, 0, 0, 0])
        let center = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
        #expect(Array(UnsafeBufferPointer(start: pixels + center, count: 4)) == [255, 255, 255, 255])
    }
    @Test(arguments: [UInt8(0), UInt8(255)])
    func coverRecoversRenderedGlassColorsWithoutAFringe(backdropWhite: UInt8) throws {
        func canvas() throws -> CGContext {
            try #require(CGContext(data: nil, width: 20, height: 20,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        }
        let isolated = try canvas()
        isolated.setFillColor(CGColor(gray: 0.3, alpha: 1))
        isolated.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
        isolated.setFillColor(CGColor(gray: 0, alpha: 32.0 / 255))
        isolated.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        isolated.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 1, 128.0 / 255])!)
        isolated.fill(CGRect(x: 2, y: 2, width: 1, height: 1))
        let rendered = try canvas()
        rendered.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: Array(repeating: CGFloat(backdropWhite) / 255, count: 3) + [1])!)
        rendered.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        rendered.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 1, 1])!)
        rendered.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
        rendered.setFillColor(CGColor(gray: 0, alpha: 32.0 / 255))
        rendered.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        rendered.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 1, 128.0 / 255])!)
        rendered.fill(CGRect(x: 2, y: 2, width: 1, height: 1))
        let image = try overlayCoverImage(#require(isolated.makeImage()), renderedImage: #require(rendered.makeImage()), backdropWhite: backdropWhite)
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        var sawBlue = false, sawShadow = false
        for y in 0..<image.height {
            for x in 0..<image.width {
                let p = bytes + y * image.bytesPerRow + x * 4
                if p[3] == 255 { sawBlue = true; #expect(p[0] == 0 && p[1] == 0 && p[2] == 255) }
                if p[3] == 128 { #expect(p[0] <= 1 && p[1] <= 1 && abs(Int(p[2]) - 128) <= 1) }
                if p[3] == 32 { sawShadow = true; #expect(p[0] <= 1 && p[1] <= 1 && p[2] <= 1) }
            }
        }
        #expect(sawBlue && sawShadow)
    }

}
