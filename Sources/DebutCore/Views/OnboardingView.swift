import AppKit
import SwiftUI

public struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme
    private let previewDirectory: URL?
    private let iconURL: URL?

    public init(viewModel: OnboardingViewModel, previewDirectory: URL? = Bundle.main.resourceURL,
                iconURL: URL? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")) {
        _viewModel = State(initialValue: viewModel)
        self.previewDirectory = previewDirectory
        self.iconURL = iconURL
    }

    public var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 610
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        switch viewModel.page {
                        case .welcome: welcome(compact: compact)
                        case .workspace: commandTab(compact: compact)
                        case .previews: optionTab(compact: compact)
                        case .speed: speed(compact: compact)
                        case .ready: ready(compact: compact)
                        }
                        if viewModel.page != .welcome && !viewModel.permissions.accessibilityGranted {
                            permissionRow("Accessibility", icon: "hand.raised", detail: "Required for keyboard shortcuts and window control.",
                                required: true, granted: false, action: viewModel.requestAccessibility)
                        }
                    }
                    .padding(.horizontal, 40).padding(.vertical, viewModel.page == .speed ? 12 : compact ? 20 : 28)
                    .frame(maxWidth: 820)
                    .frame(minHeight: max(0, geometry.size.height - 80), alignment: .center)
                    .frame(maxWidth: .infinity)
                }
                footer
            }
        }
        .frame(minWidth: 740)
        .background(canvas)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
            viewModel.onEnvironmentRefresh()
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("onboarding-root")
    }

    private var canvas: Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.14) : Color(red: 0.975, green: 0.978, blue: 0.985)
    }

    private var card: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : .white
    }

    private var border: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.07)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(border).frame(height: 1)
            HStack {
                Group {
                    if viewModel.page != .welcome {
                        Button { viewModel.back() } label: { Label("Back", systemImage: "chevron.left") }
                            .accessibilityIdentifier("onboarding-back")
                    } else { Color.clear.frame(width: 1, height: 1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                        Capsule().fill(page == viewModel.page ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: page == viewModel.page ? 20 : 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(viewModel.page.rawValue + 1) of 5")
                Button(viewModel.page == .welcome ? "Get started" : viewModel.page == .ready ? "Start using Debut" : "Continue") {
                    viewModel.advance()
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!viewModel.canAdvance).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-continue")
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 40).frame(height: 79)
        }
    }

    private func welcome(compact: Bool) -> some View {
        VStack(spacing: compact ? 20 : 28) {
            VStack(spacing: 12) {
                if let iconURL, let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon).resizable().frame(width: compact ? 56 : 68, height: compact ? 56 : 68)
                        .accessibilityHidden(true)
                }
                Text("Debut").font(.system(size: 36, weight: .bold))
                Text("Turns the macOS Command-Tab switcher into a workspace manager")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 510)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                permissionRow("Accessibility", icon: "hand.raised", detail: "Lets Debut handle keyboard shortcuts and switch windows.",
                    required: true, granted: viewModel.permissions.accessibilityGranted,
                    action: viewModel.requestAccessibility, onRestart: {})
                permissionRow("Screen Recording", icon: "macwindow", detail: "Adds window previews. Images stay on your Mac.",
                    required: false, granted: viewModel.permissions.screenRecordingGranted,
                    requiresRelaunch: viewModel.screenRecordingRequiresRelaunch,
                    action: viewModel.requestScreenRecording, onRestart: viewModel.restartDebut)
            }
            Text(welcomePermissionHint)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcomePermissionHint: String {
        if viewModel.screenRecordingRequiresRelaunch {
            return "Quit and reopen Debut to use Screen Recording. Setup will continue where you left off."
        }
        if !viewModel.permissions.accessibilityGranted {
            return "Allow Accessibility in System Settings, then return here. If macOS asks, choose Quit & Reopen; setup will continue here."
        }
        return "You can change permissions anytime in System Settings. Screen Recording is optional."
    }

    private func permissionRow(
        _ title: String,
        icon: String,
        detail: String,
        required: Bool,
        granted: Bool,
        requiresRelaunch: Bool = false,
        action: @escaping () -> Void,
        onRestart: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(required ? "Required" : "Optional").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(required ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background((required ? Color.accentColor : Color.secondary).opacity(0.08), in: Capsule())
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if requiresRelaunch {
                Button("Restart Debut", action: onRestart).controlSize(.regular)
            } else if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            } else {
                Button("Allow \(title)", action: action).controlSize(.regular)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(border))
    }

    private func commandTab(compact: Bool) -> some View {
        VStack(spacing: 16) {
            heading("Command-Tab", "Your windows, organized by desktop.", shortcut: "⌘")
            preview(viewModel.showsWindowPreviews ? "onboarding-workspace" : "onboarding-workspace-no-previews",
                label: "Command-Tab groups windows by desktop",
                height: compact ? 246 : 310, showsDesktopGuidance: viewModel.showsDesktopGuidance)
            featureToggle("Enable Debut Command-Tab", detail: "Switch windows and manage desktops from one place.",
                key: \.workspaceIsolation, id: "command-tab")
        }
    }

    private var desktopGuidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "rectangle.3.group").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Unlock more with multiple desktops").font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Open Mission Control, move your pointer to the top, then click + to add a desktop.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Give your windows room to spread out.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 240, alignment: .leading)
        .accessibilityIdentifier("onboarding-desktop-guidance")
    }

    private func optionTab(compact: Bool) -> some View {
        VStack(spacing: 16) {
            heading("Option-Tab", "Every window. Every desktop. One list.", shortcut: "⌥")
            preview(viewModel.showsWindowPreviews ? "onboarding-previews" : "onboarding-no-previews",
                label: "Option-Tab brings windows from all desktops into one list", height: compact ? 246 : 310)
            featureToggle("Enable Debut Option-Tab", detail: "Jump straight to any window, wherever it lives.",
                key: \.optionTab, id: "option-tab")
        }
    }

    private func speed(compact: Bool) -> some View {
        VStack(spacing: compact ? 14 : 18) {
            heading("Faster desktop switching", "Move between desktops without the wait.")
            OnboardingSpeedVideo(directory: previewDirectory)
                .frame(maxWidth: compact ? 560 : .infinity)
            VStack(spacing: 0) {
                featureToggle("Enable faster desktop switching", detail: "Choose an instant jump or a shorter transition.",
                    key: \.fasterDesktopSwitching, id: "faster-desktop-switching", inset: true)
                Rectangle().fill(border).frame(height: 1).padding(.horizontal, 17)
                SwitchDurationControl(duration: Binding(
                    get: { viewModel.spaceSwitchDuration }, set: { viewModel.setSpaceSwitchDuration($0) }))
                    .disabled(!viewModel.features.fasterDesktopSwitching)
                    .padding(.horizontal, 17).padding(.vertical, 13)
            }
            .background(card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(border))
        }
    }

    private func ready(compact: Bool) -> some View {
        VStack(spacing: compact ? 24 : 32) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark").font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor).frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.09), in: Circle()).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("You’re ready").font(.system(size: 32, weight: .bold))
                    Text("Your next workspace starts with a shortcut.")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity)
            HStack(spacing: 16) {
                destination("Start tutorial", detail: "Try a few guided exercises at your own pace.", icon: "keyboard") { viewModel.finish(.tutorial) }
                destination("Open Settings", detail: "Make the shortcuts, look, and behavior yours.", icon: "slider.horizontal.3") { viewModel.finish(.settings) }
            }
            Text("Tutorial and Settings are always in the Debut menu bar.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func destination(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon).font(.system(size: 23, weight: .regular)).foregroundStyle(Color.accentColor)
                    .frame(height: 27)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                    }
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(OnboardingCardButtonStyle(fill: card, border: border))
        .disabled(!viewModel.canAdvance).accessibilityLabel(title)
    }

    private func heading(_ title: String, _ subtitle: String, shortcut: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 29, weight: .bold))
                Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let shortcut {
                HStack(spacing: 5) {
                    keycap(shortcut)
                    keycap("⇥")
                }.accessibilityHidden(true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keycap(_ symbol: String) -> some View {
        Text(symbol).font(.system(size: 23, weight: .regular))
            .foregroundStyle(.secondary).frame(width: 42, height: 42)
            .background(card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(border))
            .shadow(color: .black.opacity(0.035), radius: 0, y: 2)
    }

    private func featureToggle(_ title: String, detail: String, key: WritableKeyPath<FeatureSettings, Bool>, id: String, inset: Bool = false) -> some View {
        Toggle(isOn: Binding(get: { viewModel.features[keyPath: key] }, set: {
            var features = viewModel.features
            features[keyPath: key] = $0
            viewModel.setFeatures(features)
        })) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).padding(17)
        .background(inset ? Color.clear : card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(inset ? Color.clear : border))
        .accessibilityIdentifier("onboarding-\(id)")
    }

    private var gallery: LinearGradient {
        LinearGradient(colors: colorScheme == .dark
            ? [Color(red: 0.17, green: 0.19, blue: 0.23), Color(red: 0.135, green: 0.15, blue: 0.18)]
            : [Color(red: 0.91, green: 0.935, blue: 0.965), Color(red: 0.945, green: 0.955, blue: 0.975)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder private func preview(_ name: String, label: String, height: CGFloat, showsDesktopGuidance: Bool = false) -> some View {
        if let directory = previewDirectory, let image = NSImage(contentsOf: directory.appendingPathComponent("\(name).png")) {
            HStack(spacing: 20) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .accessibilityLabel(label)
                if showsDesktopGuidance { desktopGuidance.padding(.trailing, 16) }
            }
            .padding(8).frame(height: height).frame(maxWidth: .infinity)
            .background(gallery, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(border))
        }
    }
}

private struct OnboardingCardButtonStyle: ButtonStyle {
    let fill: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.1) : fill, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(configuration.isPressed ? Color.accentColor.opacity(0.4) : border))
    }
}
