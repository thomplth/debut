import AppKit
import AVKit
import SwiftUI

public struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel
    private let previewDirectory: URL?

    public init(viewModel: OnboardingViewModel, previewDirectory: URL? = Bundle.main.resourceURL) {
        _viewModel = State(initialValue: viewModel)
        self.previewDirectory = previewDirectory
    }

    public var body: some View {
        VStack(spacing: 0) {
            if viewModel.page != .welcome && viewModel.page != .ready {
                HStack(spacing: 24) {
                    step("Focus", page: .workspace)
                    step("See", page: .previews)
                    step("Move", page: .speed)
                }.padding(.top, 28).padding(.bottom, 24)
            }
            GeometryReader { geometry in
                ScrollView {
                    VStack {
                        switch viewModel.page {
                        case .welcome: welcome
                        case .workspace: workspace
                        case .previews: previews
                        case .speed: speed
                        case .ready: ready
                        }
                    }.frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer.padding(.top, 20).padding(.bottom, 26)
        }
        .padding(.horizontal, 36)
        .frame(minWidth: 860)
        .background {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.onEnvironmentRefresh()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-root")
    }

    private func step(_ title: String, page: OnboardingPage) -> some View {
        HStack(spacing: 7) {
            Image(systemName: viewModel.page.rawValue > page.rawValue ? "checkmark.circle.fill" : "\(page.rawValue).circle.fill")
            Text(title).fontWeight(.semibold)
        }
        .foregroundStyle(viewModel.page == page ? Color.accentColor : Color.secondary)
        .accessibilityLabel("\(title), step \(page.rawValue) of 3")
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            if let url = previewDirectory?.appendingPathComponent("AppIcon.icns"), let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().frame(width: 112, height: 112).accessibilityHidden(true)
            }
            Text("Debut").font(.system(size: 56, weight: .bold, design: .rounded))
            Text("The right window. The right desktop.")
                .font(.system(size: 23)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workspace: some View {
        VStack(spacing: 18) {
            heading("One desktop. One focus.", "Command–Tab switches between windows on this desktop. Your other work stays out of the way.")
            preview("onboarding-workspace", fallback: "overlay", label: "Debut’s Command–Tab switcher on a real desktop")
            if !viewModel.permissions.accessibilityGranted {
                accessibilityPrompt
            } else if viewModel.desktopCount < 2 {
                instruction("Make room for another desktop", icon: "rectangle.badge.plus") {
                    Text("Open Mission Control, move your pointer to the top, and click + at the top right. Then click a desktop to return here.")
                    HStack {
                        Button("Open Mission Control") { viewModel.onOpenMissionControl() }
                        Button("Check again") { viewModel.onEnvironmentRefresh() }
                    }
                }
            } else if viewModel.workspacePracticed {
                success("You switched a window on this desktop.", detail: "Command–Tab leaves windows on your other desktops out of the cycle.")
            } else {
                instruction("Try it now", icon: "keyboard") {
                    Text(viewModel.windowCount == 0
                         ? "Open a window in another app on this desktop, then come back to Debut."
                         : "Hold ⌘ and press Tab. Keep holding ⌘ to see your windows, then release it to choose one.")
                    Text("Click Debut in the Dock to return here. Use Esc to cancel and try again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Check windows again") { viewModel.onEnvironmentRefresh() }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var previews: some View {
        VStack(spacing: 18) {
            heading("Find it by sight.", "Option–Tab brings windows from every desktop into one list.")
            preview(viewModel.features.windowPreviews ? "onboarding-previews" : "onboarding-no-previews",
                    fallback: "all-windows", label: "Debut’s Option–Tab all-windows switcher")
            if !viewModel.permissions.accessibilityGranted {
                accessibilityPrompt
            } else if !viewModel.permissions.screenRecordingGranted && viewModel.features.windowPreviews {
                instruction("See live window previews", icon: "rectangle.dashed.badge.record") {
                    Text("Allow Screen Recording for window images and desktop wallpaper. Images stay in memory on your Mac and are never uploaded.")
                    HStack {
                        Button("Enable previews") { viewModel.requestScreenRecording() }.buttonStyle(.borderedProminent)
                        Button("Use without previews") { viewModel.useWithoutPreviews() }
                    }
                    Text("After allowing access in System Settings, return here. If macOS asks, quit and reopen Debut.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if viewModel.allWindowsPracticed {
                success("You found a window across your Mac.", detail: "Option–Tab also takes you to the window’s desktop.")
            } else {
                instruction("Try Option–Tab", icon: "keyboard") {
                    Text("Hold ⌥ and press Tab. Keep holding ⌥ to browse, then release it to choose a window. Click Debut in the Dock to return here.")
                    if !viewModel.features.windowPreviews {
                        Text("Previews are off. App icons and window titles still help you choose.").font(.caption).foregroundStyle(.secondary)
                        Button("Enable previews instead") { viewModel.requestScreenRecording() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var speed: some View {
        VStack(spacing: 16) {
            heading("Your next desktop. Without the wait.", "Tune desktop changes through Debut. Try a shortcut or swipe—changes apply immediately.")
            if let url = previewDirectory?.appendingPathComponent("onboarding-speed.mp4"), FileManager.default.fileExists(atPath: url.path) {
                ZStack {
                    if let poster = previewDirectory.flatMap({ NSImage(contentsOf: $0.appendingPathComponent("onboarding-speed.jpg")) }) {
                        Image(nsImage: poster).resizable().scaledToFit()
                    }
                    OnboardingLoopVideo(url: url)
                }.frame(height: 195)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Recorded comparison of Debut at 400 milliseconds and Instant")
            } else {
                preview("onboarding-workspace", fallback: "overlay", label: "Debut desktop switcher")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Let Debut handle").font(.headline)
                    Spacer()
                    Button("Enable all") { viewModel.setAllOverrides(true) }
                    Button("Disable all") { viewModel.setAllOverrides(false) }
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 10) {
                        featureToggle("Window switching · ⌘ Tab", key: \.workspaceIsolation, id: "workspace-isolation")
                        featureToggle("Numbered shortcuts · ⌃ 1–9", key: \.numberShortcuts, id: "number-shortcuts")
                    }
                    VStack(spacing: 10) {
                        featureToggle("Control + ← / →", key: \.controlArrows, id: "control-arrows")
                        featureToggle("Trackpad desktop swipe", key: \.trackpadSwipes, id: "trackpad-swipes")
                    }
                }
                SwitchDurationControl(duration: Binding(get: { viewModel.duration }, set: { viewModel.setDuration($0) }))
            }.padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            Text("Try an enabled shortcut or swipe now—changes apply immediately.\nIn Debut’s switcher, hold Command–Option and press Tab to choose another desktop.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !viewModel.permissions.accessibilityGranted { accessibilityPrompt }
            Spacer(minLength: 0)
        }
    }

    private var ready: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(Color.accentColor)
            heading("You’re ready.", "Your windows, a shortcut away.")
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.features.workspaceIsolation { Label("⌘ Tab — windows on this desktop", systemImage: "rectangle.3.group") }
                Label("⌥ Tab — windows across your Mac", systemImage: "macwindow.on.rectangle")
                if viewModel.features.numberShortcuts { Label("⌃ 1–9 — go straight to a desktop", systemImage: "arrow.right.square") }
            }.font(.title3).padding(24)
            Text("Find settings and this guide in Debut’s menu bar icon.").foregroundStyle(.secondary)
            Toggle("Share anonymous usage and performance data", isOn: Binding(
                get: { viewModel.shareAnonymousTelemetry }, set: { viewModel.setShareAnonymousTelemetry($0) }))
                .toggleStyle(.switch).fixedSize()
                .help("Only bucketed measurements. No screenshots, app or window names, or persistent identifiers.")
            Spacer()
            if !viewModel.permissions.accessibilityGranted { accessibilityPrompt }
        }
    }

    private var accessibilityPrompt: some View {
        instruction("Allow Accessibility to use Debut", icon: "accessibility") {
            Text("Debut needs this permission to handle shortcuts and focus your windows. In System Settings, turn on Debut under Privacy & Security → Accessibility, then return here.")
            HStack {
                Button("Open Accessibility Settings") { viewModel.requestAccessibility() }.buttonStyle(.borderedProminent)
                Button("Check again") { viewModel.refreshPermissions(); viewModel.onEnvironmentRefresh() }
            }
        }
    }

    private func instruction<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content().font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private func success(_ title: String, detail: String) -> some View {
        instruction(title, icon: "checkmark.circle.fill") { Text(detail) }
    }

    private func featureToggle(_ title: String, key: WritableKeyPath<FeatureSettings, Bool>, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { viewModel.features[keyPath: key] }, set: {
            var features = viewModel.features
            features[keyPath: key] = $0
            viewModel.setFeatures(features)
        })).toggleStyle(.switch).accessibilityIdentifier("onboarding-\(id)")
    }

    @ViewBuilder private func preview(_ name: String, fallback: String, label: String) -> some View {
        if let directory = previewDirectory,
           let image = NSImage(contentsOf: directory.appendingPathComponent("\(name).jpg"))
            ?? NSImage(contentsOf: directory.appendingPathComponent("\(fallback).jpg")) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 270)
                .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityLabel(label)
        }
    }

    private var footer: some View {
        HStack {
            if viewModel.page != .welcome { Button("Back") { viewModel.back() }.accessibilityIdentifier("onboarding-back") }
            Spacer()
            if !viewModel.canAdvance && viewModel.permissions.accessibilityGranted {
                Text(viewModel.page == .workspace && viewModel.desktopCount < 2 ? "Add a desktop to continue" : "Try the shortcut to continue")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(viewModel.page == .welcome ? "Get started" : viewModel.page == .ready ? "Start using Debut" : "Continue") {
                viewModel.advance()
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!viewModel.canAdvance).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-continue")
        }
    }
}

private struct OnboardingLoopVideo: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = context.coordinator.player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        context.coordinator.player.play()
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) { coordinator.player.pause() }
    final class Coordinator {
        let player = AVQueuePlayer()
        let looper: AVPlayerLooper
        init(url: URL) {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.isMuted = true
        }
    }
}

public struct MenuBarCoachmarkView: View {
    public var onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Debut lives here")
            } icon: {
                Image(nsImage: DebutGlyph.image(size: DebutGlyph.menuBarSize))
                    .renderingMode(.template)
            }
            .font(.headline)
            Text("Use the menu bar icon to open Settings, revisit the tutorial, or quit Debut.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
