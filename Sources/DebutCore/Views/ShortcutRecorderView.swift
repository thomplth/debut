import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutRecorderRow: View {
    let action: KeyAction
    @Binding var keyBindings: KeyBindings
    @State private var isRecording: Bool = false
    @State private var pendingCombo: KeyCombo?
    @State private var conflicts: [ShortcutConflict] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.displayName)
                Spacer()
                if isRecording {
                    KeyRecorderRepresentable { combo in
                        onKeyRecorded(combo)
                    } onCancel: {
                        cancelRecording()
                    }
                    .frame(width: 140, height: 28)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        Text("Press keys…")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.orange)
                    )
                } else {
                    Button {
                        isRecording = true
                    } label: {
                        Text(keyBindings.combo(for: action)?.displayString ?? "None")
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
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
        let detected = ConflictDetector.detectConflicts(
            combo: combo, forAction: action, in: keyBindings
        )
        if detected.isEmpty {
            keyBindings.bindings[action] = combo
            pendingCombo = nil
            conflicts = []
        } else {
            pendingCombo = combo
            conflicts = detected
        }
    }

    private func applyBinding() {
        guard let combo = pendingCombo else { return }
        if let existing = keyBindings.action(for: combo), existing != action {
            keyBindings.bindings.removeValue(forKey: existing)
        }
        keyBindings.bindings[action] = combo
        pendingCombo = nil
        conflicts = []
    }

    private func cancelRecording() {
        isRecording = false
        pendingCombo = nil
        conflicts = []
    }
}

struct KeyRecorderRepresentable: NSViewRepresentable {
    var onKeyRecorded: (KeyCombo) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onKeyRecorded = onKeyRecorded
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
        nsView.onKeyRecorded = onKeyRecorded
        nsView.onCancel = onCancel
    }
}

final class KeyRecorderNSView: NSView {
    var onKeyRecorded: ((KeyCombo) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)

        if keyCode == kVK_Escape {
            onCancel?()
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
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option)
        )
        onKeyRecorded?(combo)
    }
}
