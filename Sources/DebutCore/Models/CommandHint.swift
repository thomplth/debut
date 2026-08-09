import Foundation

public struct CommandHintPresentation: Identifiable, Equatable, Sendable {
    public let actions: [KeyAction]
    public let label: String
    public let shortcut: String

    public var id: String {
        actions.map(\.rawValue).joined(separator: ":")
    }
}

public enum CommandHintCatalog {
    public static func stageHints(
        stageIndex: Int,
        isActive: Bool,
        settings: AppSettings
    ) -> [CommandHintPresentation] {
        var hints: [CommandHintPresentation] = []
        if let jumpAction = KeyAction.jumpAction(forStageIndex: stageIndex),
           let jumpHint = hint(label: "Jump to stage", actions: [jumpAction], settings: settings) {
            hints.append(jumpHint)
        }

        guard isActive else { return hints }

        let groups: [(String, [KeyAction])] = [
            ("Select stage", [.nextStage, .previousStage]),
            ("New stage", [.newStageBelow, .newStageAbove]),
            ("Delete stage", [.deleteStage]),
            ("Save template", [.saveAsTemplate]),
            ("Reorder stage", [.swapStageUp, .swapStageDown]),
        ]
        hints.append(contentsOf: groups.compactMap { label, actions in
            hint(label: label, actions: actions, settings: settings)
        })
        return hints
    }

    public static func windowHints(
        isSelected: Bool,
        settings: AppSettings
    ) -> [CommandHintPresentation] {
        guard isSelected else { return [] }
        let groups: [(String, [KeyAction])] = [
            ("Select window", [.nextWindow, .previousWindow]),
            ("Move window", [.moveWindowUp, .moveWindowDown]),
        ]
        return groups.compactMap { label, actions in
            hint(label: label, actions: actions, settings: settings)
        }
    }

    private static func hint(
        label: String,
        actions: [KeyAction],
        settings: AppSettings
    ) -> CommandHintPresentation? {
        let visibleActions = actions.filter(settings.shouldShowCommandHint(for:))
        let shortcuts = visibleActions.compactMap { action in
            settings.keyBindings.combo(for: action)?.commandHintDisplayString
        }
        guard !visibleActions.isEmpty, !shortcuts.isEmpty else { return nil }
        return CommandHintPresentation(
            actions: visibleActions,
            label: label,
            shortcut: shortcuts.joined(separator: " / ")
        )
    }
}

extension KeyCombo {
    var commandHintDisplayString: String {
        displayString
            .replacingOccurrences(of: "Shift+", with: "⇧")
            .replacingOccurrences(of: "Option+", with: "⌥")
            .replacingOccurrences(of: "Delete", with: "⌫")
    }
}
