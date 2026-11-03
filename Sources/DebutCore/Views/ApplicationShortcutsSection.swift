import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationShortcutsSection: View {
    @Binding var shortcuts: [ApplicationShortcut]
    let keyBindings: KeyBindings
    let recordingService: (any ShortcutRecordingService)?
    @State private var expandedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Shortcuts")
                .font(.title2.bold())

            Text("Each shortcut opens its app, brings it forward, or hides it when it is already in front. Windows on another desktop are reached with Debut's desktop switch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Add App…", action: chooseApplication)
            }

            if shortcuts.isEmpty {
                Text("No app shortcuts yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }

            ForEach($shortcuts) { $shortcut in
                ApplicationShortcutRow(
                    shortcut: $shortcut,
                    shortcuts: shortcuts,
                    keyBindings: keyBindings,
                    recordingService: recordingService,
                    isExpanded: Binding(
                        get: { expandedID == shortcut.id },
                        set: { expandedID = $0 ? shortcut.id : nil }
                    ),
                    onDelete: { [id = shortcut.id] in shortcuts.removeAll { $0.id == id } }
                )
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let shortcut = ApplicationShortcut(applicationURL: url)
        else { return }
        shortcuts.append(shortcut)
        expandedID = shortcut.id
    }
}

extension ApplicationShortcut {
    init?(applicationURL url: URL) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        self.init(
            bundleID: bundleID,
            appName: url.deletingPathExtension().lastPathComponent,
            appPath: url.path
        )
    }
}

private struct ApplicationShortcutRow: View {
    @Binding var shortcut: ApplicationShortcut
    let shortcuts: [ApplicationShortcut]
    let keyBindings: KeyBindings
    let recordingService: (any ShortcutRecordingService)?
    @Binding var isExpanded: Bool
    let onDelete: () -> Void
    @State private var isRecording = false
    @State private var pendingCombo: KeyCombo?
    @State private var conflicts: [ShortcutConflict] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "Hide options" : "Show options")

                if StageMotion.showsAppIcon(bundleID: shortcut.bundleID) {
                    AppIconImage(bundleID: shortcut.bundleID, name: shortcut.appName, iconSize: 22)
                        .frame(width: 22, height: 22)
                }
                Text(shortcut.appName)
                    .lineLimit(1)
                Spacer()
                recorder
                Toggle("Enabled", isOn: $shortcut.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(shortcut.appName)")
            }

            ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(conflict.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Use Anyway") { apply(pendingCombo) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    Button("Cancel", action: cancelRecording)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .padding(8)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if isExpanded { options.padding(.leading, 22) }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .opacity(shortcut.isEnabled ? 1 : 0.6)
    }

    private var recorder: some View {
        Button {
            if !isRecording { isRecording = true }
        } label: {
            ShortcutKeyBox(
                text: isRecording ? "Press keys…" : shortcut.combo?.displayString ?? "Record Shortcut",
                recording: isRecording
            )
        }
        .buttonStyle(.plain)
        .background {
            if isRecording {
                KeyRecorderRepresentable(recordingService: recordingService) { combo in
                    record(combo)
                } onCancel: {
                    cancelRecording()
                }
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Only hide", isOn: $shortcut.onlyHide)
            Toggle("Only show", isOn: $shortcut.onlyShow)
            Toggle("Only if the app is already running", isOn: $shortcut.onlyIfRunning)
            Toggle("Send Command-N if no windows are open", isOn: $shortcut.opensNewWindowWhenNoneOpen)
            Picker("Windows", selection: $shortcut.windows) {
                ForEach(ApplicationShortcutWindows.allCases, id: \.self) { windows in
                    Text(windows.displayName).tag(windows)
                }
            }
            .frame(maxWidth: 360)
            Picker("Other desktops", selection: $shortcut.placement) {
                ForEach(ApplicationShortcutPlacement.allCases, id: \.self) { placement in
                    Text(placement.displayName).tag(placement)
                }
            }
            .frame(maxWidth: 420)
            Text(shortcut.appPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
    }

    private func record(_ combo: KeyCombo) {
        isRecording = false
        if combo.isClearingKey {
            apply(nil)
            return
        }
        let detected = ConflictDetector.detectConflicts(
            combo: combo,
            forApplicationShortcut: shortcut.id,
            among: shortcuts,
            in: keyBindings
        )
        if detected.isEmpty {
            apply(combo)
        } else {
            pendingCombo = combo
            conflicts = detected
        }
    }

    private func apply(_ combo: KeyCombo?) {
        shortcut.combo = combo
        pendingCombo = nil
        conflicts = []
    }

    private func cancelRecording() {
        isRecording = false
        pendingCombo = nil
        conflicts = []
    }
}
