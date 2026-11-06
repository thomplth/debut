import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
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
/// logged capture failures was -3811. A stream's first frame captures those, so it is the
/// fallback for that error only. A frame is an IOSurface that alt-tab-macos found leaking
/// WindowServer memory when held (#5786), so it is copied into memory Debut owns at once.
///
/// Don't replace the stream with `captureSampleBuffer`, even though it is shorter: given a window
/// that is not drawing it waits for a frame, and it offers no way to stop. One such call held
/// the capture queue for 13m39s while WindowServer retried at 120Hz (KHA-1253).
enum PreviewCaptureRoute {
    /// Far beyond any capture that finished in the logs, which run in tens of milliseconds. Only
    /// a call that will not return reaches it, and each one holds up every queued preview.
    static let stepDeadline: Duration = .seconds(5)

    /// `fellBack` says the -3811 fallback took it, so a batch can count how often that happens.
    static func capture(
        filter: SCContentFilter,
        width: Int,
        height: Int
    ) async throws -> (image: CGImage, fellBack: Bool) {
        let configuration = SCScreenshotConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        let sendableFilter = SendableContentFilter(filter: filter)
        let sendableConfiguration = SendableScreenshotConfiguration(configuration: configuration)
        do {
            let image = try await CaptureDeadline.race(within: stepDeadline) {
                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: sendableFilter.filter,
                    configuration: sendableConfiguration.configuration
                )
                guard let image = output.sdrImage else { throw CaptureError.noImage }
                return SendableImage(image: image)
            }
            return (image.image, false)
        } catch where fallsBackToStream(after: error) {
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = width
            streamConfiguration.height = height
            streamConfiguration.showsCursor = false
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = FirstFrameStream(filter: filter, configuration: streamConfiguration)
            let image = try await CaptureDeadline.race(
                within: stepDeadline,
                onExpiry: { stream.stop() },
                operation: { try await stream.firstFrame() }
            )
            DiagnosticReporter.shared.report("window_preview_capture_fell_back", level: .transient)
            return (image.image, true)
        }
    }

    /// Captures land a pixel or two off the size asked for. A frame below 90% on either edge was
    /// drawn mid-animation: un-minimizing draws the window scaled down inside its frame for
    /// ~0.6s (alt-tab-macos `WindowThumbnails.isPartialFrame`). The old preview is kept.
    static func isPartialFrame(width: Int, height: Int, requestedWidth: Int, requestedHeight: Int) -> Bool {
        Double(width) < Double(requestedWidth) * 0.9 || Double(height) < Double(requestedHeight) * 0.9
    }

    enum CaptureError: Error, Equatable {
        case noImage
        case windowNotDrawing
    }

    static func fallsBackToStream(after error: Error) -> Bool {
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

private struct SendableContentFilter: @unchecked Sendable {
    let filter: SCContentFilter
}

private struct SendableScreenshotConfiguration: @unchecked Sendable {
    let configuration: SCScreenshotConfiguration
}

struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

enum FirstFrameDisposition: Equatable {
    case deliver, giveUp, wait

    /// A suspended stream was seen to deliver nothing further on windows that were not drawing,
    /// so it is an answer rather than a delay.
    init(status: SCFrameStatus?) {
        switch status {
        case .complete: self = .deliver
        case .suspended, .stopped: self = .giveUp
        default: self = .wait
        }
    }
}

/// A one-frame stream, which unlike `captureSampleBuffer` can be stopped.
final class FirstFrameStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outcome = OneShotOutcome<SendableImage>()
    private let frames = DispatchQueue(label: "com.thomplth.Debut.first-frame", qos: .userInitiated)
    private var stream: SCStream?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    func firstFrame() async throws -> SendableImage {
        try await withCheckedThrowingContinuation { continuation in
            outcome.arm(continuation)
            guard let stream else { return }
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
            } catch {
                finish(.failure(error))
                return
            }
            stream.startCapture { [weak self] error in
                if let error { self?.finish(.failure(error)) }
            }
        }
    }

    func stop() {
        finish(.failure(CaptureDeadline.Expired()))
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        switch FirstFrameDisposition(status: Self.status(of: sampleBuffer)) {
        case .wait:
            return
        case .giveUp:
            finish(.failure(PreviewCaptureRoute.CaptureError.windowNotDrawing))
        case .deliver:
            if let pixelBuffer = sampleBuffer.imageBuffer,
               let image = PreviewCaptureRoute.image(copying: pixelBuffer) {
                finish(.success(SendableImage(image: image)))
            } else {
                finish(.failure(PreviewCaptureRoute.CaptureError.noImage))
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<SendableImage, Error>) {
        guard outcome.resolve(result), let stream else { return }
        stream.stopCapture { _ in _ = stream }
    }

    private static func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        return (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
    }
}

/// Resumes a continuation with whichever answer arrives first and ignores the rest.
private final class OneShotOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    func arm(_ continuation: CheckedContinuation<Value, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
        return waiting != nil
    }
}

enum CaptureDeadline {
    struct Expired: Error {}

    /// Don't rewrite this with a task group: a group waits for its children, and
    /// ScreenCaptureKit's async calls ignore cancellation, so it would wait out the hang.
    static func race<Value: Sendable>(
        within limit: Duration,
        onExpiry: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let outcome = OneShotOutcome<Value>()
        return try await withCheckedThrowingContinuation { continuation in
            outcome.arm(continuation)
            let timer = Task {
                guard (try? await Task.sleep(for: limit)) != nil,
                      outcome.resolve(.failure(Expired()))
                else { return }
                onExpiry()
            }
            Task {
                let result = await Result(catching: operation)
                timer.cancel()
                outcome.resolve(result)
            }
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
