import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutRecorderRow: View {
    let action: KeyAction
    @Binding var keyBindings: KeyBindings
    let recordingService: (any ShortcutRecordingService)?
    @State private var isRecording: Bool = false
    @State private var pendingCombo: KeyCombo?
    @State private var conflicts: [ShortcutConflict] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.displayName)
                Spacer()
                Button {
                    if !isRecording { isRecording = true }
                } label: {
                    ShortcutKeyBox(
                        text: isRecording
                            ? "Press keys…"
                            : keyBindings.combo(for: action)?.displayString ?? "None",
                        recording: isRecording
                    )
                }
                .buttonStyle(.plain)
                .background {
                    if isRecording {
                        KeyRecorderRepresentable(recordingService: recordingService) { combo in
                            onKeyRecorded(combo)
                        } onCancel: {
                            cancelRecording()
                        }
                    }
                }
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
                    Button("Use Anyway") {
                        applyBinding()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    Button("Cancel") {
                        cancelRecording()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func onKeyRecorded(_ combo: KeyCombo) {
        isRecording = false
        if (combo.keyCode == kVK_Delete || combo.keyCode == kVK_ForwardDelete)
            && !combo.command && !combo.control
            && !combo.shift && !combo.option {
            keyBindings.record(combo, for: action)
            pendingCombo = nil
            conflicts = []
            return
        }
        let detected = ConflictDetector.detectConflicts(
            combo: combo, forAction: action, in: keyBindings
        )
        if detected.isEmpty {
            keyBindings.record(combo, for: action)
            pendingCombo = nil
            conflicts = []
        } else {
            pendingCombo = combo
            conflicts = detected
        }
    }

    private func applyBinding() {
        guard let combo = pendingCombo else { return }
        for existing in KeyAction.allCases where existing != action
            && existing.shortcutScope == action.shortcutScope
            && keyBindings.combo(for: existing) == combo {
            keyBindings.clear(existing)
        }
        keyBindings.record(combo, for: action)
        pendingCombo = nil
        conflicts = []
    }

    private func cancelRecording() {
        isRecording = false
        pendingCombo = nil
        conflicts = []
    }
}

private struct ShortcutKeyBox: View {
    let text: String
    let recording: Bool

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(recording ? Color.orange : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                recording
                    ? AnyShapeStyle(Color.orange.opacity(0.1))
                    : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}

struct KeyRecorderRepresentable: NSViewRepresentable {
    let recordingService: (any ShortcutRecordingService)?
    var onKeyRecorded: (KeyCombo) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onKeyRecorded = onKeyRecorded
        view.onCancel = onCancel
        view.startRecording(using: recordingService)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
        nsView.onKeyRecorded = onKeyRecorded
        nsView.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: KeyRecorderNSView, coordinator: ()) {
        nsView.stopRecording()
    }
}

final class KeyRecorderNSView: NSView, @unchecked Sendable {
    var onKeyRecorded: ((KeyCombo) -> Void)?
    var onCancel: (() -> Void)?
    private weak var recordingService: (any ShortcutRecordingService)?

    override var acceptsFirstResponder: Bool { true }

    func startRecording(using service: (any ShortcutRecordingService)?) {
        recordingService = service
        service?.beginShortcutRecording { [weak self] combo in
            guard let self else { return }
            if let combo {
                self.finishRecording(combo)
            } else {
                self.cancelRecording()
            }
        }
    }

    func stopRecording() {
        recordingService?.endShortcutRecording()
        recordingService = nil
    }

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)

        if keyCode == kVK_Escape {
            cancelRecording()
            return
        }

        if keyCode == kVK_Shift || keyCode == kVK_RightShift
            || keyCode == kVK_Option || keyCode == kVK_RightOption
            || keyCode == kVK_Command || keyCode == kVK_RightCommand
            || keyCode == kVK_Control || keyCode == kVK_RightControl {
            return
        }

        let combo = KeyCombo(
            keyCode: keyCode,
            command: event.modifierFlags.contains(.command),
            control: event.modifierFlags.contains(.control),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option)
        )
        finishRecording(combo)
    }

    private func finishRecording(_ combo: KeyCombo) {
        stopRecording()
        onKeyRecorded?(combo)
    }

    private func cancelRecording() {
        stopRecording()
        onCancel?()
    }
}
