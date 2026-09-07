import AppKit
import SwiftUI

public struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel

    private let workspacePreviewImage: NSImage?
    private let allWindowsPreviewImage: NSImage?

    public init(viewModel: OnboardingViewModel, previewDirectory: URL? = Bundle.main.resourceURL) {
        self._viewModel = State(initialValue: viewModel)
        self.workspacePreviewImage = previewDirectory.flatMap { NSImage(contentsOf: $0.appendingPathComponent("overlay.jpg")) }
        self.allWindowsPreviewImage = previewDirectory.flatMap { NSImage(contentsOf: $0.appendingPathComponent("all-windows.jpg")) }
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.12),
                    Color(nsColor: .windowBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                pageIndicator
                    .padding(.top, 24)

                Group {
                    switch viewModel.page {
                    case .welcome:
                        welcomePage
                    case .features:
                        featuresPage
                    case .permissions:
                        permissionsPage
                    case .tutorial:
                        tutorialPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .padding(.horizontal, 44)
            .padding(.bottom, 34)
        }
        .frame(minWidth: 720, minHeight: 520)
        .animation(.spring(duration: 0.3, bounce: 0.05), value: viewModel.page)
        .animation(.spring(duration: 0.25, bounce: 0.05), value: viewModel.tutorialStep)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
        .accessibilityIdentifier("onboarding-root")
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases, id: \.self) { page in
                Capsule()
                    .fill(page.rawValue <= viewModel.page.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: page == viewModel.page ? 28 : 8, height: 8)
            }
        }
        .accessibilityLabel("Onboarding step \(viewModel.page.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 10)
            Text("Make room for focused work.")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("See the right window. Stay in your workspace. Get there faster.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            onboardingPreview(allWindows: false)
            HStack(alignment: .top, spacing: 20) {
                benefit("See your windows", detail: "Screenshot previews in both switchers.", icon: "macwindow.on.rectangle")
                benefit("Focus this workspace", detail: "Command–Tab stays on this desktop.", icon: "rectangle.3.group")
                benefit("Switch faster", detail: "Your shortcuts and trackpad, your pace.", icon: "bolt")
            }
            Spacer(minLength: 10)
            Button("Make it yours") { viewModel.continueFromWelcome() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-continue")
        }
    }

    private func benefit(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func onboardingPreview(allWindows: Bool) -> some View {
        if let image = allWindows ? allWindowsPreviewImage : workspacePreviewImage {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxHeight: 230)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel(allWindows ? "All-windows switcher" : "Windows grouped by desktop in Debut")
        } else {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 80, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(height: 180)
        }
    }

    private var featuresPage: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Your desktop. Your workspace.")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(viewModel.introduction)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            ScrollView {
                FeatureControlsView(features: Binding(
                    get: { viewModel.features },
                    set: { viewModel.setFeatures($0) }
                ))
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            Text("Spaces are your real macOS desktops. Add or remove them in Mission Control.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Change any choice later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Back") { viewModel.returnToWelcome() }
                Button("Continue") { viewModel.continueFromFeatures() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding-continue")
            }
        }
    }

    private var permissionsPage: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 22)

            VStack(spacing: 8) {
                Text("Enable Debut on your Mac")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Debut only asks for what makes the switcher work.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                permissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "Used to handle your shortcuts and focus or move windows between desktops.",
                    badge: "Required",
                    isGranted: viewModel.permissions.accessibilityGranted,
                    action: viewModel.requestAccessibility
                )
                permissionCard(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: viewModel.screenRecordingRequirement.detail,
                    badge: viewModel.screenRecordingRequirement.isRequired ? "Required" : "Optional",
                    isGranted: viewModel.permissions.screenRecordingGranted,
                    action: viewModel.requestScreenRecording
                )
            }
            .frame(maxWidth: 620)

            Toggle("Share anonymous usage and performance data", isOn: Binding(
                get: { viewModel.shareAnonymousTelemetry },
                set: { viewModel.setShareAnonymousTelemetry($0) }
            ))
            .toggleStyle(.switch)
            .help("Only bucketed measurements. No screenshots, app or window names, or persistent identifiers.")
            .accessibilityIdentifier("onboarding-anonymous-telemetry")

            if !viewModel.canStartTutorial {
                Label(
                    "After allowing access in System Settings, return to Debut to continue.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button("Back") {
                    viewModel.returnToFeatures()
                }
                .controlSize(.large)

                Spacer()

                Button("Get Started") {
                    viewModel.startTutorial()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canStartTutorial)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-get-started")
            }
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        detail: String,
        badge: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(isGranted ? Color.green : Color.accentColor)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var tutorialPage: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Text("A few shortcuts to get you moving")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Step \(viewModel.tutorialStep.rawValue + 1) of \(OnboardingTutorialStep.allCases.count)")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(OnboardingTutorialStep.allCases, id: \.self) { step in
                    tutorialStepChip(step)
                }
            }

            let content = tutorialContent(for: viewModel.tutorialStep)
            VStack(spacing: 10) {
                onboardingPreview(allWindows: viewModel.tutorialStep == .allWindows)
                    .frame(maxHeight: 150)

                Text(content.title)
                    .font(.title2.bold())
                Text(content.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)

                Text(content.shortcut)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .id(viewModel.tutorialStep)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

            Spacer()

            HStack {
                Button("Back") {
                    viewModel.returnToPermissions()
                }
                .controlSize(.large)

                Spacer()

                Button(viewModel.tutorialStep == .moveWindow ? "Finish" : "Next") {
                    viewModel.advanceTutorial()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-tutorial-next")
            }
        }
    }

    private func tutorialStepChip(_ step: OnboardingTutorialStep) -> some View {
        let isCurrent = step == viewModel.tutorialStep
        let isComplete = step.rawValue < viewModel.tutorialStep.rawValue
        return HStack(spacing: 6) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle.fill")
            Text(tutorialContent(for: step).shortTitle)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
    }

    private func tutorialContent(for step: OnboardingTutorialStep) -> TutorialContent {
        switch step {
        case .switchWindows:
            TutorialContent(
                icon: "command",
                shortTitle: "Switch",
                title: "Open Debut’s switcher",
                detail: viewModel.features.workspaceIsolation
                    ? "Hold Command–Tab to see this desktop’s windows. Release Command to focus your selection. Other work stays on its own desktop."
                    : "Workspace isolation is off, so Command–Tab uses the native app switcher. You can enable workspace switching later in Settings.",
                shortcut: "⌘ Tab · hold ⌘"
            )
        case .switchSpaces:
            TutorialContent(
                icon: "rectangle.3.group", shortTitle: "Spaces",
                title: "Move to another workspace",
                detail: "Hold Command–Option–Tab to browse your desktops. Release to switch. The numbered shortcuts and gestures you enabled offer a direct route.",
                shortcut: "⌘ ⌥ Tab"
            )
        case .allWindows:
            TutorialContent(
                icon: "macwindow.on.rectangle", shortTitle: "All windows",
                title: "Find a window across your Mac",
                detail: "Option–Tab shows windows from every desktop in one visual list. Choose one and Debut takes you to its workspace.",
                shortcut: "⌥ Tab · hold ⌥"
            )
        case .moveWindow:
            TutorialContent(
                icon: "rectangle.portrait.and.arrow.forward",
                shortTitle: "Move",
                title: "Move a window between spaces",
                detail: "Hold Command–Option–Tab, then move a selected window with Up or Down, or drag it onto another desktop’s card. Add desktops in Mission Control first.",
                shortcut: "↓  or  drag"
            )
        }
    }

    private struct TutorialContent {
        let icon: String
        let shortTitle: String
        let title: String
        let detail: String
        let shortcut: String
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
