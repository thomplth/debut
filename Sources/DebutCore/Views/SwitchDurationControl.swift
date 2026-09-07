import SwiftUI

/// The same live duration control in onboarding and Settings.
struct SwitchDurationControl: View {
    @Binding var duration: TimeInterval
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Desktop transition duration")
                Spacer()
                Text(SettingsView.switchDurationLabel(duration)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $duration,
                   in: AppSettings.minimumSpaceSwitchDuration...AppSettings.maximumSpaceSwitchDuration, step: 0.01)
                .accessibilityLabel("Desktop transition duration").accessibilityIdentifier("space-switch-duration")
            Text("Duration per desktop. Instant removes the transition.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
