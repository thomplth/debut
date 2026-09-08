import SwiftUI

/// The production preview cards, limited to the real desktops involved in this exercise.
/// Desktop indices remain macOS indices; this view never owns or rewrites the desktop model.
struct TutorialSwitcherView: View {
    let rows: [StageData]
    let scope: TutorialSwitcherScope
    let coach: TutorialCoachmark
    let selectedWindowID: UInt32?
    let selectedDesktop: Int
    let appearance: AppSettings
    var flat = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Tutorial", systemImage: "graduationcap")
                Spacer()
                Text("Your other windows are hidden here")
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ForEach(rows) { stage in
                VStack(alignment: .leading, spacing: 8) {
                    Text(flat ? "All tutorial windows" : "Desktop \(stage.index + 1)")
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 20) {
                        Spacer(minLength: 0)
                        ForEach(stage.windows) { window in
                            WindowPreviewView(window: window, isWindowSelected: window.windowID == selectedWindowID,
                                              metrics: StageMetrics.standard, appearance: appearance)
                                .accessibilityLabel(window.displayTitle)
                        }
                        if stage.windows.isEmpty {
                            Label(stage.index == scope.target.destinationDesktop ? "Move the practice window here" : "No tutorial windows here",
                                  systemImage: stage.index == scope.target.destinationDesktop
                                    ? (scope.target.destinationDesktop > scope.target.originDesktop ? "arrow.down.to.line" : "arrow.up.to.line")
                                    : "rectangle.dashed")
                                .font(.system(size: 13)).foregroundStyle(.secondary).frame(height: 130)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(14)
                .background(Color.primary.opacity(stage.index == selectedDesktop || flat ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(stage.index == selectedDesktop || flat ? Color.accentColor : Color.clear, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(coach.title, systemImage: "keyboard").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(coach.action).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(coach.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                Text("Esc: return to the tutorial").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("tutorial-coachmark")
        }
        .padding(20).frame(width: 610)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("tutorial-switcher")
    }
}
