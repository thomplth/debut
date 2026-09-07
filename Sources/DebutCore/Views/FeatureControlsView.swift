import SwiftUI

extension Notification.Name {
    static let debutSettingsChanged = Notification.Name("DebutSettingsChanged")
}

/// One vocabulary and one set of bindings in onboarding and Settings.
struct FeatureControlsView: View {
    @Binding var features: FeatureSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            feature("See the window before you switch", icon: "macwindow.on.rectangle",
                    detail: "Screenshot previews in the workspace and all-windows overlays.",
                    value: $features.windowPreviews, id: "window-previews")
            feature("Keep Command–Tab in this workspace", icon: "rectangle.3.group",
                    detail: "Cycle windows on this desktop. Off restores native Command–Tab and Command–`.",
                    value: $features.workspaceIsolation, id: "workspace-isolation")
            VStack(alignment: .leading, spacing: 10) {
                Label("Move between desktops faster", systemImage: "bolt")
                    .font(.headline)
                Text("Choose which interactions Debut handles.")
                    .font(.subheadline).foregroundStyle(.secondary)
                featureToggle("Numbered shortcuts · Control + 1–9 by default", value: $features.numberShortcuts)
                    .accessibilityIdentifier("feature-number-shortcuts")
                featureToggle("Control + ← / →", value: $features.controlArrows)
                    .accessibilityIdentifier("feature-control-arrows")
                featureToggle("Trackpad desktop swipe", value: $features.trackpadSwipes)
                    .accessibilityIdentifier("feature-trackpad-swipes")
                Text("Uses your macOS three- or four-finger desktop gesture. Other gestures keep their normal behavior.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
        }
    }

    private func featureToggle(_ title: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch)
        }
    }

    private func feature(_ title: String, icon: String, detail: String,
                         value: Binding<Bool>, id: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: icon).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch)
        }
        .accessibilityIdentifier("feature-\(id)")
    }
}
