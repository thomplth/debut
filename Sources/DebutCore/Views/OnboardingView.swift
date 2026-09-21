import AppKit
import SwiftUI

public struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel
    private let previewDirectory: URL?
    private let iconURL: URL?

    public init(viewModel: OnboardingViewModel, previewDirectory: URL? = Bundle.main.resourceURL,
                iconURL: URL? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")) {
        _viewModel = State(initialValue: viewModel)
        self.previewDirectory = previewDirectory
        self.iconURL = iconURL
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.page != .welcome {
                        Text("\(viewModel.page.rawValue + 1) of 5").font(.caption).foregroundStyle(.secondary)
                    }
                    switch viewModel.page {
                    case .welcome: welcome
                    case .workspace: commandTab
                    case .previews: optionTab
                    case .speed: speed
                    case .ready: ready
                    }
                    if viewModel.page != .welcome && !viewModel.permissions.accessibilityGranted {
                        permissionRow("Accessibility", detail: "Required for keyboard shortcuts and window control.",
                            required: true, granted: false, action: viewModel.requestAccessibility)
                    }
                }.padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider().padding(.horizontal, 32)
            HStack {
                if viewModel.page != .welcome {
                    Button("Back") { viewModel.back() }.accessibilityIdentifier("onboarding-back")
                }
                Spacer()
                Button(viewModel.page == .welcome ? "Get started" : viewModel.page == .ready ? "Start using Debut" : "Continue") {
                    viewModel.advance()
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!viewModel.canAdvance).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding-continue")
            }.padding(.horizontal, 32).padding(.vertical, 18)
        }.frame(minWidth: 740).background(Color(nsColor: .windowBackgroundColor))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                viewModel.refreshPermissions()
                viewModel.onEnvironmentRefresh()
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("onboarding-root")
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                if let iconURL, let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                }
                Text("Debut").font(.system(size: 38, weight: .bold))
                Text("Turns the macOS Command-Tab switcher into a workspace manager")
                    .font(.system(size: 17)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.top, 6).padding(.bottom, 8)
            VStack(spacing: 12) {
                permissionRow("Accessibility", detail: "Lets Debut handle keyboard shortcuts and switch windows.",
                    required: true, granted: viewModel.permissions.accessibilityGranted, action: viewModel.requestAccessibility)
                permissionRow("Screen Recording", detail: "Shows window previews. Images stay on your Mac. You can use Debut without previews.",
                    required: false, granted: viewModel.permissions.screenRecordingGranted, action: viewModel.requestScreenRecording)
            }
            Text("Grant access in System Settings, then return here. Reopen Debut if macOS asks you to quit.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func permissionRow(_ title: String, detail: String, required: Bool, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Text(required ? "Required" : "Optional").font(.caption.weight(.medium))
                        .foregroundStyle(required ? Color.accentColor : Color.secondary)
                }
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted { Label("Allowed", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
            else { Button("Allow \(title)", action: action).controlSize(.large) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)))
    }

    private var commandTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Command-Tab", "Switch between windows on your current desktop.")
            preview(viewModel.showsWindowPreviews ? "onboarding-workspace" : "onboarding-workspace-no-previews",
                label: "Command-Tab groups windows by desktop", height: viewModel.showsDesktopGuidance ? 190 : 230)
            if !viewModel.showsDesktopGuidance {
                Text("Navigate to other desktops and organize their windows from the same switcher.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            featureToggle("Enable Debut Command-Tab", key: \.workspaceIsolation, id: "command-tab")
            if viewModel.showsDesktopGuidance {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Unlock more with multiple desktops", systemImage: "rectangle.3.group").font(.headline)
                    Text("Open Mission Control, move your pointer to the top, then click + to add a desktop. Use multiple desktops to organize your windows and unlock more of Debut.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("onboarding-desktop-guidance")
            }
        }
    }

    private var optionTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Option-Tab", "Switch between windows across all your desktops.")
            preview(viewModel.showsWindowPreviews ? "onboarding-previews" : "onboarding-no-previews",
                label: "Option-Tab brings windows from all desktops into one list")
            Text("Find the window you need in one list, wherever it lives.").font(.callout).foregroundStyle(.secondary)
            featureToggle("Enable Debut Option-Tab", key: \.optionTab, id: "option-tab")
        }
    }

    private var speed: some View {
        VStack(alignment: .leading, spacing: 30) {
            heading("Faster desktop switching", "Move between desktops without waiting for the macOS transition.")
            Image(systemName: "rectangle.3.group.fill").font(.system(size: 72, weight: .light))
                .foregroundStyle(Color.accentColor).frame(maxWidth: .infinity).padding(.vertical, 48).accessibilityHidden(true)
            featureToggle("Enable faster desktop switching", key: \.fasterDesktopSwitching, id: "faster-desktop-switching")
            Text("Customize transition speed, gestures, and shortcuts in Settings.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 26) {
            heading("You’re ready", "Start using Debut, or take a moment to explore.")
            HStack(spacing: 16) {
                destination("Start tutorial", detail: "Practice switching and organizing windows.", icon: "keyboard") { viewModel.finish(.tutorial) }
                destination("Open Settings", detail: "Make Debut work the way you do.", icon: "slider.horizontal.3") { viewModel.finish(.settings) }
            }.padding(.vertical, 24)
            Text("You can always open Tutorial and Settings from the Debut menu bar icon.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func destination(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon).font(.title).foregroundStyle(Color.accentColor)
            Text(detail).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button(title, action: action).controlSize(.large).disabled(!viewModel.canAdvance)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)))
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold))
            Text(subtitle).font(.system(size: 16)).foregroundStyle(.secondary)
        }
    }

    private func featureToggle(_ title: String, key: WritableKeyPath<FeatureSettings, Bool>, id: String) -> some View {
        Toggle(isOn: Binding(get: { viewModel.features[keyPath: key] }, set: {
            var features = viewModel.features
            features[keyPath: key] = $0
            viewModel.setFeatures(features)
        })) { Text(title).frame(maxWidth: .infinity, alignment: .leading) }
            .toggleStyle(.switch).font(.headline).padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("onboarding-\(id)")
    }

    @ViewBuilder private func preview(_ name: String, label: String, height: CGFloat = 230) -> some View {
        if let directory = previewDirectory, let image = NSImage(contentsOf: directory.appendingPathComponent("\(name).png")) {
            Image(nsImage: image).resizable().scaledToFit().frame(height: height).frame(maxWidth: .infinity)
                .accessibilityLabel(label)
        }
    }
}
