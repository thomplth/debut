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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.page != .welcome && viewModel.page != .ready {
                        HStack(spacing: 22) {
                            step("Window and desktop switching", page: .workspace)
                            step("Window previews", page: .previews)
                            step("Instant desktop switching", page: .speed)
                        }.font(.system(size: 11))
                    }
                    if let result = viewModel.lastResult {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    switch viewModel.page {
                    case .welcome: welcome
                    case .workspace: workspace
                    case .previews: previews
                    case .speed: speed
                    case .ready: ready
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            Divider().padding(.horizontal, 24)
            footer.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(minWidth: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.onEnvironmentRefresh()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-root")
    }

    private func step(_ title: String, page: OnboardingPage) -> some View {
        HStack(spacing: 5) {
            Image(systemName: viewModel.page.rawValue > page.rawValue ? "checkmark.circle.fill" : "\(page.rawValue).circle.fill")
            Text(title)
        }.foregroundStyle(viewModel.page == page ? Color.accentColor : Color.secondary)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            if let url = previewDirectory?.appendingPathComponent("AppIcon.icns"), let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().frame(width: 100, height: 100).accessibilityHidden(true)
            }
            Text("Debut").font(.system(size: 44, weight: .bold))
            Text("Switch windows and desktops with your keyboard.").font(.title3).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 100)
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .bold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(workspaceTitle, workspaceDescription)
            if !viewModel.permissions.accessibilityGranted {
                preview("onboarding-workspace", label: "Command-Tab shows windows grouped by desktop")
                accessibilityPrompt
            } else if viewModel.desktopCount < 2 {
                instruction("Create a second desktop", icon: "rectangle.badge.plus") {
                    Text("A desktop is a separate workspace in macOS. You need two for these exercises.")
                    Text("1. Open Mission Control.\n2. Move the pointer to the top of the screen and click +.\n3. Click your original desktop to return to this tutorial.")
                    HStack {
                        Button("Open Mission Control") { viewModel.onOpenMissionControl() }
                        Button("Check again") { viewModel.onEnvironmentRefresh() }
                    }
                }
            } else {
                preview("onboarding-workspace", label: "Command-Tab shows windows grouped by desktop")
                exerciseInstructions
            }
        }
    }

    private var workspaceTitle: String {
        switch viewModel.exercise {
        case .switchWindow: "Switch windows on this desktop"
        case .switchDesktop: "Switch desktops"
        case .moveWindow: "Move a window to another desktop"
        }
    }
    private var workspaceDescription: String {
        switch viewModel.exercise {
        case .switchWindow: "Command-Tab selects windows on the current desktop. Windows on other desktops are in separate rows."
        case .switchDesktop: "Each row is a desktop. Hold Command and Option to move between rows."
        case .moveWindow: "Use the arrow keys in the switcher to move a selected window to another desktop."
        }
    }

    @ViewBuilder private var exerciseInstructions: some View {
        if let target = viewModel.target {
            instruction("Open “\(target.title)” to continue", icon: "keyboard") {
                switch viewModel.exercise {
                case .switchWindow:
                    Text("The next lesson is a window on Desktop \(target.destinationDesktop + 1).")
                    Text("1. Hold Command and press Tab.\n2. Keep holding Command. Press Tab until “\(target.title)” is selected.\n3. Release Command to open it.")
                case .switchDesktop:
                    Text("The next lesson is on Desktop \(target.destinationDesktop + 1). You are on Desktop \(target.originDesktop + 1).")
                    Text("1. Hold Command and Option. Press Tab until the row containing “\(target.title)” is enlarged.\n2. Release Option, keep Command held, and press Tab until “\(target.title)” is selected.\n3. Release Command to switch desktops and open it.")
                case .moveWindow:
                    Text("Move “\(target.title)” from Desktop \(target.originDesktop + 1) to Desktop \(target.destinationDesktop + 1).")
                    Text("1. Hold Command and press Tab until “\(target.title)” is selected.\n2. Keep Command held and press \(target.destinationDesktop > target.originDesktop ? "Down Arrow" : "Up Arrow") to move it to Desktop \(target.destinationDesktop + 1).\n3. Release Command to follow the window and open the next lesson.")
                }
                recovery
            }
        } else { preparingTarget }
    }

    private var previews: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Window previews", "Option-Tab shows windows from every desktop in one list. Selecting a window also switches to its desktop.")
            preview(viewModel.features.windowPreviews ? "onboarding-previews" : "onboarding-no-previews",
                    label: viewModel.features.windowPreviews ? "Option-Tab shows window previews from all desktops" : "Option-Tab shows app icons and window titles from all desktops")
            if !viewModel.permissions.accessibilityGranted { accessibilityPrompt }
            else if !viewModel.permissions.screenRecordingGranted && viewModel.features.windowPreviews {
                instruction("Allow Screen Recording for window previews", icon: "rectangle.dashed.badge.record") {
                    Text("Debut uses this permission to show window images and desktop wallpaper. Images stay on your Mac.")
                    HStack {
                        Button("Enable previews") { viewModel.requestScreenRecording() }.buttonStyle(.borderedProminent)
                        Button("Use without previews") { viewModel.useWithoutPreviews() }
                    }
                    Text("In System Settings, allow Debut under Privacy & Security → Screen & System Audio Recording. If macOS asks you to quit, reopen Debut to resume this lesson.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let target = viewModel.target {
                instruction("Open “\(target.title)” on Desktop \(target.destinationDesktop + 1)", icon: "keyboard") {
                    Text("1. Hold Option and press Tab.\n2. Keep holding Option. Press Tab until “\(target.title)” is selected.\n3. Release Option to open the next lesson.")
                    if !viewModel.features.windowPreviews {
                        Text("Previews are off. You can still select windows by their app icons and titles.").foregroundStyle(.secondary)
                    }
                    recovery
                }
            } else { preparingTarget }
        }
    }

    private var recovery: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Press Esc to cancel. If you open another window, return to Debut from the Dock.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Restart exercise") { viewModel.onRestartExercise() }
                .accessibilityIdentifier("onboarding-restart")
        }.padding(.top, 4)
    }

    private var preparingTarget: some View {
        instruction(viewModel.targetError ?? "Preparing the next lesson…", icon: "macwindow") {
            Text("The next lesson opens in a separate window so you can practise switching to it.")
            Button("Restart exercise") { viewModel.onRestartExercise() }
        }
    }

    private var speed: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Instant desktop switching", "Remove the macOS desktop transition, or choose a shorter duration.")
            if let url = previewDirectory?.appendingPathComponent("onboarding-speed.mp4"), FileManager.default.fileExists(atPath: url.path) {
                VStack(spacing: 6) {
                    HStack {
                        Text("macOS default").frame(maxWidth: .infinity)
                        Text("Debut Instant").frame(maxWidth: .infinity)
                    }.font(.system(size: 12, weight: .medium))
                    ZStack {
                        if let image = previewDirectory.flatMap({ NSImage(contentsOf: $0.appendingPathComponent("onboarding-speed.jpg")) }) {
                            Image(nsImage: image).resizable().scaledToFit()
                        }
                        OnboardingLoopVideo(url: url)
                    }.frame(width: 384, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Recorded desktop changes using macOS default and Debut Instant")
                }.frame(width: 384).frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Enable faster desktop switching").font(.headline)
                    Spacer()
                    Button("Enable all") { viewModel.setAllOverrides(true) }
                    Button("Disable all") { viewModel.setAllOverrides(false) }
                }.padding(.bottom, 10)
                Text("Changes apply immediately. Turning these off restores macOS controls, including its app switcher.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 14)
                SwitchDurationControl(duration: Binding(get: { viewModel.duration }, set: { viewModel.setDuration($0) }))
                Divider().padding(.vertical, 12)
                Grid(horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        featureToggle("Debut Command-Tab", detail: "Select a window on another desktop", key: \.workspaceIsolation, id: "workspace-isolation")
                        featureToggle("Control + number", detail: "Jump to Desktop 1 through 9", key: \.numberShortcuts, id: "number-shortcuts")
                    }
                    GridRow {
                        featureToggle("Control + Left / Right Arrow", detail: "Switch to an adjacent desktop", key: \.controlArrows, id: "control-arrows")
                        featureToggle("Trackpad swipe", detail: "Swipe left or right with 3 or 4 fingers", key: \.trackpadSwipes, id: "trackpad-swipes")
                    }
                }

            }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5)))
            if !viewModel.permissions.accessibilityGranted { accessibilityPrompt }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Setup complete", "You have switched windows, changed desktops, and moved a window between desktops.")
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.features.workspaceIsolation {
                    Text("Command-Tab: windows on this desktop")
                    Text("Command-Option-Tab: select another desktop")
                    Text("Up / Down Arrow in Command-Tab: move the selected window")
                } else { Text("Debut Command-Tab is off. Turn it on in Settings to use desktop rows.") }
                Text("Option-Tab: windows on all desktops")
            }.font(.system(size: 15)).padding(.vertical, 12)
            Text("Open Debut from the Dock or menu bar to change settings or repeat this tutorial.")
                .foregroundStyle(.secondary)
            Toggle("Share anonymous usage and performance data", isOn: Binding(
                get: { viewModel.shareAnonymousTelemetry }, set: { viewModel.setShareAnonymousTelemetry($0) }))
                .toggleStyle(.switch)
                .help("No screenshots, app or window names, or persistent identifiers.")
            if !viewModel.permissions.accessibilityGranted { accessibilityPrompt }
        }.padding(.vertical, 24)
    }

    private var accessibilityPrompt: some View {
        instruction("Allow Accessibility to continue", icon: "accessibility") {
            Text("Debut needs Accessibility to handle shortcuts and select your windows. In System Settings, turn on Debut under Privacy & Security → Accessibility, then return here.")
            HStack {
                Button("Open Accessibility Settings") { viewModel.requestAccessibility() }.buttonStyle(.borderedProminent)
                Button("Check again") { viewModel.refreshPermissions(); viewModel.onEnvironmentRefresh() }
            }
        }
    }

    private func instruction<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold))
            content().font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func featureToggle(_ title: String, detail: String, key: WritableKeyPath<FeatureSettings, Bool>, id: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: Binding(get: { viewModel.features[keyPath: key] }, set: {
            var features = viewModel.features
            features[keyPath: key] = $0
            viewModel.setFeatures(features)
            })).labelsHidden().toggleStyle(.switch).accessibilityIdentifier("onboarding-\(id)")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }

    @ViewBuilder private func preview(_ name: String, label: String) -> some View {
        if let directory = previewDirectory, let image = NSImage(contentsOf: directory.appendingPathComponent("\(name).jpg")) {
            VStack(spacing: 6) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 205)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel(label)
                Text("Example switcher. Use the shortcut below to see your practice window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if viewModel.page != .welcome { Button("Back") { viewModel.back() }.accessibilityIdentifier("onboarding-back") }
            Spacer()
            if viewModel.page == .speed {
                Text("Try a shortcut or swipe. Return with Option-Tab → Debut Tutorial.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if viewModel.page == .workspace || viewModel.page == .previews {
                Text("Complete the exercise to open the next lesson")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button(viewModel.page == .welcome ? "Get started" : viewModel.page == .ready ? "Start using Debut" : "Continue") {
                    viewModel.advance()
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!viewModel.canAdvance).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding-continue")
            }
        }
    }
}

struct OnboardingDestinationView: View {
    let title: String
    var onReturn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Debut tutorial", systemImage: "macwindow.on.rectangle").foregroundStyle(.secondary)
            Text(title).font(.system(size: 32, weight: .bold))
            Text("This is your next lesson.").font(.title3)
            Text("Clicking this window does not complete the exercise. Return to the tutorial, then use its shortcut instructions to select this window.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Return to tutorial", action: onReturn).buttonStyle(.borderedProminent)
        }.padding(40).frame(width: 600, height: 390, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
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
