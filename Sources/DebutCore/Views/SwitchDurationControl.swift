import SwiftUI

/// The same live duration control in onboarding and Settings.
struct SwitchDurationControl: View {
    @Binding var duration: TimeInterval
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Space switch duration")
                Spacer()
                Text(SettingsView.switchDurationLabel(duration)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $duration,
                   in: AppSettings.minimumSpaceSwitchDuration...AppSettings.maximumSpaceSwitchDuration, step: 0.01)
                .accessibilityLabel("Space switch duration").accessibilityIdentifier("space-switch-duration")
            Text("Applies to desktop switches handled by Debut, per desktop crossed. Choose Instant for no transition.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
