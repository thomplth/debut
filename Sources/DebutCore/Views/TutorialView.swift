import AppKit
import SwiftUI

public struct TutorialView: View {
    @State private var viewModel: TutorialViewModel
    var onExit: () -> Void
    var onOpenSettings: () -> Void

    public init(viewModel: TutorialViewModel, onExit: @escaping () -> Void = {}, onOpenSettings: @escaping () -> Void = {}) {
        _viewModel = State(initialValue: viewModel)
        self.onExit = onExit
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Debut tutorial", systemImage: "keyboard").foregroundStyle(.secondary)
            Text(title).font(.system(size: 30, weight: .bold))
            Text(description).font(.title3).foregroundStyle(.secondary)
            if let result = viewModel.lastResult {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            }
            Spacer()
            if !viewModel.permissions.accessibilityGranted {
                Text("Allow Accessibility to practice window switching.")
                Button("Open Accessibility Settings") { viewModel.requestAccessibility() }
            } else if viewModel.page != .ready {
                if !viewModel.shortcutEnabled {
                    Text("This switcher is turned off. Enable it in Settings to practice, or skip this lesson.")
                    Button("Open Settings", action: onOpenSettings)
                } else if viewModel.target != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Hold \(viewModel.page == .previews ? "Option" : "Command") and press Tab")
                            .font(.title2.bold())
                        Text("Keep the modifier held and follow the guide in the switcher.")
                        Text("Only tutorial windows will appear.").foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("tutorial-practice-start")
                } else {
                    Text(viewModel.targetError ?? "Preparing the next lesson…").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Divider()
            HStack {
                if viewModel.page != .workspace || viewModel.exercise != .switchWindow {
                    Button("Back") { viewModel.back() }
                }
                Button("Exit tutorial", action: onExit)
                Spacer()
                if viewModel.page == .ready {
                    Button("Finish tutorial") { viewModel.advance() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Skip lesson") { viewModel.skipExercise() }
                    Button("Restart exercise") { viewModel.onRestartExercise() }
                }
            }
        }.padding(32).frame(minWidth: 740)
            .background(Color(nsColor: .windowBackgroundColor))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                viewModel.refreshPermissions()
                viewModel.onEnvironmentRefresh()
            }
    }

    private var title: String {
        switch viewModel.page {
        case .previews: "Switch across all desktops"
        case .ready: "Tutorial complete"
        case .workspace:
            switch viewModel.exercise {
            case .switchWindow: "Switch windows on this desktop"
            case .switchDesktop: "Switch desktops"
            case .moveWindow: "Move a window to another desktop"
            }
        }
    }
    private var description: String {
        switch viewModel.page {
        case .previews: "Option-Tab brings windows from every desktop into one switcher."
        case .ready: "You can revisit the tutorial anytime from the Debut menu bar icon."
        case .workspace:
            switch viewModel.exercise {
            case .switchWindow: "Use Command-Tab to select the next practice window."
            case .switchDesktop: "Choose another desktop in the Command-Tab switcher."
            case .moveWindow: "Move a practice window between desktops without leaving the switcher."
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
            Text("Return to the tutorial and use the switcher to open this lesson.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Return to tutorial", action: onReturn).buttonStyle(.borderedProminent)
        }.padding(40).frame(width: 600, height: 390, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
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
