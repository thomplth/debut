import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutRecorderRow: View {
    let action: KeyAction
    @Binding var keyBindings: KeyBindings
    @State private var isRecording: Bool = false

    var body: some View {
        HStack {
            Text(action.displayName)
            Spacer()
            if isRecording {
                KeyRecorderRepresentable { combo in
                    keyBindings.bindings[action] = combo
                    isRecording = false
                } onCancel: {
                    isRecording = false
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

        // Ignore bare modifier presses
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
