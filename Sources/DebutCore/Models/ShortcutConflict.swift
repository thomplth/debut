import Foundation
import Carbon.HIToolbox

public enum ConflictType: Sendable {
    case `internal`(existingAction: KeyAction)
    case system(description: String)
}

public struct ShortcutConflict: Sendable {
    public let type: ConflictType
    public let combo: KeyCombo

    public var message: String {
        switch type {
        case .internal(let action):
            "Already assigned to \"\(action.displayName)\""
        case .system(let desc):
            "Overlaps with system shortcut: \(desc)"
        }
    }
}

public struct ConflictDetector: Sendable {
    private static let systemAdvisory: [KeyCombo: String] = [
        KeyCombo(keyCode: kVK_Tab): "Tab is also used for overlay activation",
        KeyCombo(keyCode: kVK_ANSI_Grave): "Backtick passes through as Cmd+` after Esc",
        KeyCombo(keyCode: kVK_ANSI_Q): "Cmd+Q quits apps outside the overlay",
        KeyCombo(keyCode: kVK_ANSI_W): "Cmd+W closes windows outside the overlay",
    ]

    public static func checkInternal(
        combo: KeyCombo,
        forAction action: KeyAction,
        in bindings: KeyBindings
    ) -> ShortcutConflict? {
        if let existing = bindings.action(for: combo), existing != action {
            return ShortcutConflict(type: .internal(existingAction: existing), combo: combo)
        }
        return nil
    }

    public static func checkSystem(combo: KeyCombo) -> ShortcutConflict? {
        if let desc = systemAdvisory[combo] {
            return ShortcutConflict(type: .system(description: desc), combo: combo)
        }
        return nil
    }

    public static func detectConflicts(
        combo: KeyCombo,
        forAction action: KeyAction,
        in bindings: KeyBindings
    ) -> [ShortcutConflict] {
        var conflicts: [ShortcutConflict] = []
        if let c = checkInternal(combo: combo, forAction: action, in: bindings) {
            conflicts.append(c)
        }
        if let c = checkSystem(combo: combo) {
            conflicts.append(c)
        }
        return conflicts
    }
}
