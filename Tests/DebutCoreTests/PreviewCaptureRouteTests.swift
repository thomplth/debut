import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing
@testable import DebutCore

private final class ExpiryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class AbandonedCall: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Int, Never>?
    private var released = false

    func neverReturning() async -> Int {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if released { continuation.resume(returning: 0) } else { waiting = continuation }
            }
        }
    }

    func release() {
        lock.withLock {
            released = true
            waiting?.resume(returning: 0)
            waiting = nil
        }
    }
}

@Suite("Preview capture route")
struct PreviewCaptureRouteTests {
    @Test("Only ScreenCaptureKit's -3811 sends a capture to the stream path")
    func fallbackCondition() {
        #expect(PreviewCaptureRoute.fallsBackToStream(
            after: NSError(domain: SCStreamErrorDomain, code: -3811)))
        #expect(!PreviewCaptureRoute.fallsBackToStream(
            after: NSError(domain: SCStreamErrorDomain, code: -3801)))
        #expect(!PreviewCaptureRoute.fallsBackToStream(
            after: NSError(domain: NSCocoaErrorDomain, code: -3811)))
    }

    @Test("A complete frame is delivered, a window that stopped drawing ends the capture, and anything else waits")
    func firstFrameDisposition() {
        #expect(FirstFrameDisposition(status: .complete) == .deliver)
        #expect(FirstFrameDisposition(status: .suspended) == .giveUp)
        #expect(FirstFrameDisposition(status: .stopped) == .giveUp)
        #expect(FirstFrameDisposition(status: .idle) == .wait)
        #expect(FirstFrameDisposition(status: .blank) == .wait)
        #expect(FirstFrameDisposition(status: .started) == .wait)
        #expect(FirstFrameDisposition(status: nil) == .wait)
    }

    @Test("A capture that never returns expires at its deadline and stops its work")
    func deadlineExpiresUnresponsiveOperation() async throws {
        let abandoned = AbandonedCall()
        let expiries = ExpiryCount()
        await #expect(throws: CaptureDeadline.Expired.self) {
            try await CaptureDeadline.race(
                within: .milliseconds(20),
                onExpiry: { expiries.increment() },
                operation: { await abandoned.neverReturning() }
            )
        }
        #expect(expiries.value == 1)
        abandoned.release()
    }

    @Test("A capture that returns in time keeps its result and does not expire")
    func deadlineKeepsTimelyResult() async throws {
        let expiries = ExpiryCount()
        let value = try await CaptureDeadline.race(
            within: .seconds(60),
            onExpiry: { expiries.increment() },
            operation: { 7 }
        )
        #expect(value == 7)
        #expect(expiries.value == 0)
    }

    @Test("A capture that fails in time reports its own error")
    func deadlineKeepsTimelyError() async {
        await #expect(throws: PreviewCaptureRoute.CaptureError.noImage) {
            try await CaptureDeadline.race(within: .seconds(60)) { () async throws -> Int in
                throw PreviewCaptureRoute.CaptureError.noImage
            }
        }
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
