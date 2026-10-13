import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing
@testable import DebutCore

@Suite("Preview capture route")
struct PreviewCaptureRouteTests {
    @Test("Only ScreenCaptureKit's -3811 sends a capture to the sample-buffer path")
    func fallbackCondition() {
        #expect(PreviewCaptureRoute.fallsBackToSampleBuffer(
            after: NSError(domain: SCStreamErrorDomain, code: -3811)))
        #expect(!PreviewCaptureRoute.fallsBackToSampleBuffer(
            after: NSError(domain: SCStreamErrorDomain, code: -3801)))
        #expect(!PreviewCaptureRoute.fallsBackToSampleBuffer(
            after: NSError(domain: NSCocoaErrorDomain, code: -3811)))
    }

    @Test("A sample buffer becomes a CGImage that owns its pixels")
    func pixelBufferCopy() throws {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<2 { for x in 0..<3 {
            let p = base + y * stride + x * 4
            p[0] = 10; p[1] = 20; p[2] = UInt8(100 + x); p[3] = 255   // BGRA
        } }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let image = try #require(PreviewCaptureRoute.image(copying: pixelBuffer))
        // Overwrite the source: the image must not still be reading it.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(base, 0, stride * 2)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        #expect(image.width == 3 && image.height == 2)
        let data = try #require(image.dataProvider?.data) as Data
        #expect(image.bytesPerRow == 12, "rows are packed")
        #expect(Array(data[8..<12]) == [10, 20, 102, 255], "the third pixel survives the source being cleared")
    }
}
