import Foundation
import Carbon.HIToolbox

public enum ConflictType: Sendable {
    case `internal`(existingAction: KeyAction)
    case system(description: String)
    case requirement(description: String)
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
        case .requirement(let desc):
            desc
        }
    }
}

public struct ConflictDetector: Sendable {
    private static let systemAdvisory: [KeyCombo: String] = [
        KeyCombo(keyCode: kVK_Tab, command: true): "Command-Tab is the macOS app switcher",
        KeyCombo(keyCode: kVK_ANSI_Grave, command: true): "Command-` cycles app windows",
        KeyCombo(keyCode: kVK_ANSI_Q, command: true): "Command-Q quits apps",
        KeyCombo(keyCode: kVK_ANSI_W, command: true): "Command-W closes windows",
    ]

    public static func checkInternal(
        combo: KeyCombo,
        forAction action: KeyAction,
        in bindings: KeyBindings
    ) -> ShortcutConflict? {
        if let existing = bindings.action(for: combo, scope: action.shortcutScope),
           existing != action {
            return ShortcutConflict(type: .internal(existingAction: existing), combo: combo)
        }
        return nil
    }

    public static func checkSystem(
        combo: KeyCombo,
        forAction action: KeyAction
    ) -> ShortcutConflict? {
        guard action.shortcutScope == .global else { return nil }
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
        if action.shortcutScope == .global,
           !combo.command, !combo.control, !combo.shift, !combo.option {
            conflicts.append(ShortcutConflict(
                type: .requirement(
                    description: "A global shortcut without modifiers intercepts ordinary typing"
                ),
                combo: combo
            ))
        }
        if let c = checkInternal(combo: combo, forAction: action, in: bindings) {
            conflicts.append(c)
        }
        if let c = checkSystem(combo: combo, forAction: action) {
            conflicts.append(c)
        }
        return conflicts
    }
}
