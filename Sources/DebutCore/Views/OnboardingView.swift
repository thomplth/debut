import AppKit
import SwiftUI

public struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        self._viewModel = State(initialValue: viewModel)
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
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 116, height: 116)
                Image(systemName: "rectangle.stack.badge.play")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 12) {
                Text("Meet Debut")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text(viewModel.introduction)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 22) {
                welcomeFeature(icon: "macwindow.on.rectangle", label: "See every window")
                welcomeFeature(icon: "rectangle.3.group", label: "Organize stages")
                welcomeFeature(icon: "keyboard", label: "Stay on the keyboard")
            }

            Spacer()

            Button("Continue") {
                viewModel.continueFromWelcome()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding-continue")
        }
    }

    private func welcomeFeature(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var permissionsPage: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 22)

            VStack(spacing: 8) {
                Text("A little access, clearly explained")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Debut only asks for what makes the switcher work.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                permissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "Required to discover, focus, and arrange your app windows. Debut cannot manage stages without it.",
                    badge: "Required",
                    isGranted: viewModel.permissions.accessibilityGranted,
                    action: viewModel.requestAccessibility
                )
                permissionCard(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: "Optional. Used only to draw live window previews. Without it, Debut shows app icons and placeholders.",
                    badge: "Optional",
                    isGranted: viewModel.permissions.screenRecordingGranted,
                    action: viewModel.requestScreenRecording
                )
            }
            .frame(maxWidth: 620)

            if !viewModel.permissions.accessibilityGranted {
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
                    viewModel.returnToWelcome()
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
                Text("Try it now")
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
            VStack(spacing: 20) {
                Image(systemName: content.icon)
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 62)

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
                detail: "Press Command–Tab, then keep holding Command. Release Command when the window you want is selected.",
                shortcut: "⌘ Tab · hold ⌘"
            )
        case .createStage:
            TutorialContent(
                icon: "rectangle.stack.badge.plus",
                shortTitle: "Create",
                title: "Create a new stage",
                detail: "With the switcher open, press N. Debut creates a stage below the current one and moves focus to it.",
                shortcut: "N"
            )
        case .moveWindow:
            TutorialContent(
                icon: "rectangle.portrait.and.arrow.forward",
                shortTitle: "Move",
                title: "Move a window between stages",
                detail: "Select a window and press the Down Arrow, or drag its card onto another stage. Debut keeps each window in one stage.",
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
            Label("Debut lives here", systemImage: "theatermask.and.paintbrush")
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
