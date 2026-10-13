import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Which ScreenCaptureKit call takes a preview (KHA-1081).
///
/// `captureScreenshot` (macOS 26) creates no capture stream per call; `captureImage` and
/// `captureSampleBuffer` each spin one up and tear it down. capbench (2026-10-13, macOS 27):
/// latency p50 37 vs 38ms, worst case 50 vs 93ms, and about half the in-process energy. The
/// privacy machinery's ~80 CPU-ms per capture is the same for all three.
///
/// `captureScreenshot` and `captureImage` both fail with -3811 on some windows (alt-tab-macos
/// documents fullscreen windows on a desktop that is not showing), and every one of Debut's
/// logged capture failures was -3811. `captureSampleBuffer` captures those, so it is the
/// fallback for that error only. Its frame is an IOSurface that alt-tab-macos found leaking
/// WindowServer memory when held (#5786), so it is copied into memory Debut owns at once.
enum PreviewCaptureRoute {
    static func capture(filter: SCContentFilter, width: Int, height: Int) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        do {
            let output = try await SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: configuration
            )
            guard let image = output.sdrImage else { throw CaptureError.noImage }
            return image
        } catch where fallsBackToSampleBuffer(after: error) {
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = width
            streamConfiguration.height = height
            streamConfiguration.showsCursor = false
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
            let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
                contentFilter: filter,
                configuration: streamConfiguration
            )
            guard let pixelBuffer = sampleBuffer.imageBuffer,
                  let image = image(copying: pixelBuffer)
            else { throw CaptureError.noImage }
            DiagnosticReporter.shared.report("window_preview_capture_fell_back", level: .transient)
            return image
        }
    }

    enum CaptureError: Error {
        case noImage
    }

    static func fallsBackToSampleBuffer(after error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.internalError.rawValue
    }

    /// A BGRA frame copied into packed rows Debut owns, so nothing keeps the IOSurface alive.
    static func image(copying pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = width * 4
        var bytes = Data(count: stride * height)
        bytes.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(target + row * stride, base + row * sourceStride, stride)
            }
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
