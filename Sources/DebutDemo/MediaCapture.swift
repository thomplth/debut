import AppKit
@preconcurrency import AVFoundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures the disposable guest through ScreenCaptureKit, including the composed overlay.
/// The command-line screencapture recorder can wait indefinitely for its recording UI.
final class DemoMovieRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.thomplth.debut.demo-frames")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var stream: SCStream?
    private var hasFrame = false
    private var firstFrameReady: CheckedContinuation<Void, Never>?

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        writer.add(input)
    }

    func start(display: SCDisplay) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * 2
        configuration.height = display.height * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        guard writer.startWriting() else { throw writer.error ?? CaptureFailure.failed }
        try await stream.startCapture()
        // Starting the stream does not mean a frame has arrived. Do not perform
        // the opening shortcut until it can actually appear in the recording.
        await withCheckedContinuation { continuation in
            queue.async {
                if self.hasFrame { continuation.resume() }
                else { self.firstFrameReady = continuation }
            }
        }
    }

    func stop() async throws {
        try await stream?.stopCapture()
        let receivedFrame = queue.sync {
            input.markAsFinished()
            return hasFrame
        }
        guard receivedFrame else { writer.cancelWriting(); throw CaptureFailure.noFrames }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CaptureFailure.failed }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              input.isReadyForMoreMediaData else { return }
        if !hasFrame {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            hasFrame = true
            firstFrameReady?.resume()
            firstFrameReady = nil
        }
        _ = input.append(sampleBuffer)
    }
}

enum CaptureFailure: Error { case failed, noFrames, noDisplay, timedOut }

final class CaptureResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func finish(_ value: Result<Value, Error>) { lock.withLock { result = value } }
    func read() -> Result<Value, Error>? { lock.withLock { result } }
}

/// Keep the main run loop servicing macOS while an asynchronous capture finishes.
func awaitCapture<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
    let box = CaptureResult<Value>()
    Task.detached {
        do { box.finish(.success(try await operation())) }
        catch { box.finish(.failure(error)) }
    }
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if let result = box.read() { return try result.get() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    throw CaptureFailure.timedOut
}

func demoDisplay() async throws -> SCDisplay {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
        throw CaptureFailure.noDisplay
    }
    return display
}

func captureDemoStill(to url: URL) throws {
    try awaitCapture {
        let display = try await demoDisplay()
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * 2
        configuration.height = display.height * 2
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        var luminance = [UInt8](repeating: 0, count: 32 * 32)
        let varied = luminance.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32,
                                          bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let values = bytes.bindMemory(to: UInt8.self)
            return values.contains { $0 != values[0] }
        }
        guard varied else { throw CaptureFailure.noFrames }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureFailure.failed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.failed }
    }
}

func startDemoMovie(at url: URL) throws -> DemoMovieRecorder {
    try awaitCapture {
        let display = try await demoDisplay()
        let recorder = try DemoMovieRecorder(url: url, width: display.width * 2, height: display.height * 2)
        try await recorder.start(display: display)
        return recorder
    }
}
