import AppKit
import AVFoundation
import SwiftUI

/// A bundled, silent comparison. Its fixed Instant example does not change with
/// the user's duration setting, and both sides preserve the captured elapsed time.
struct OnboardingSpeedVideo: View {
    let directory: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paused = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let poster = directory?.appendingPathComponent("onboarding-speed.png"),
                   let image = NSImage(contentsOf: poster) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                if let movie = directory?.appendingPathComponent("onboarding-speed.mp4"),
                   FileManager.default.fileExists(atPath: movie.path) {
                    LoopingOnboardingVideo(url: movie, playing: !paused)
                }
            }
            .aspectRatio(2880.0 / 996, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Side-by-side video: macOS default desktop switching and Debut Instant")
            HStack {
                Text("Same shortcut. Actual speed.").foregroundStyle(.secondary)
                Spacer()
                Button { paused.toggle() } label: {
                    Label(paused ? "Play comparison" : "Pause comparison", systemImage: paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("onboarding-video-playback")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 2)
        }
        .onAppear { paused = reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in paused = reduced }
    }
}

private struct LoopingOnboardingVideo: NSViewRepresentable {
    let url: URL
    let playing: Bool

    func makeNSView(context: Context) -> OnboardingVideoSurface {
        OnboardingVideoSurface(url: url)
    }

    func updateNSView(_ view: OnboardingVideoSurface, context: Context) {
        view.playing = playing
    }

    static func dismantleNSView(_ view: OnboardingVideoSurface, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class OnboardingVideoSurface: NSView {
    let player = AVQueuePlayer()
    private(set) var looper: AVPlayerLooper?
    private let videoLayer = AVPlayerLayer()
    var playing = true { didSet { updatePlayback() } }

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        videoLayer.player = player
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(updatePlayback),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updatePlayback()
    }

    @objc private func updatePlayback() {
        if playing, window?.occlusionState.contains(.visible) == true { player.play() }
        else { player.pause() }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        videoLayer.player = nil
    }
}
