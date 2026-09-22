import AVFoundation
import Testing
@testable import DebutCore

@MainActor
@Suite("Onboarding comparison playback")
struct OnboardingVideoTests {
    private var movieURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/media/onboarding-speed.mp4")
    }

    @Test("The captured comparison decodes, loops silently, and releases playback on exit")
    func comparisonLifecycle() async throws {
        let asset = AVURLAsset(url: movieURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let size = try await track.load(.naturalSize)
        let frameRate = try await track.load(.nominalFrameRate)
        #expect(size == CGSize(width: 2880, height: 996))
        #expect(abs(frameRate - 60) < 0.01)
        #expect(try await asset.load(.duration).seconds == 5)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)

        let surface = OnboardingVideoSurface(url: movieURL)
        defer { surface.stop() }
        #expect(surface.player.isMuted)
        #expect(surface.player.rate == 0) // No playback before the page has a window.
        // Exercise the real decoder and AVPlayerLooper without opening a host window.
        surface.player.play()
        let deadline = Date().addingTimeInterval(12)
        while surface.looper?.loopCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(surface.player.currentItem?.status == .readyToPlay)
        #expect((surface.looper?.loopCount ?? 0) >= 1)
        surface.playing = false
        #expect(surface.player.rate == 0)
        surface.stop()
        #expect(surface.looper == nil)
        #expect(surface.player.items().isEmpty)
    }
}
