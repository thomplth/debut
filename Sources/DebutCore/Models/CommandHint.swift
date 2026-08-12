import Foundation

public enum CommandHintPlacement: Equatable, Sendable {
    case stageLeading
    case nextWindow
    case plateFooter
}

public struct CommandHintPresentation: Identifiable, Equatable, Sendable {
    public let actions: [KeyAction]
    public let label: String
    public let shortcut: String
    public let placement: CommandHintPlacement
    public let iconSystemName: String?

    public var id: String {
        actions.map(\.rawValue).joined(separator: ":")
    }
}

public enum CommandHintCatalog {
    public static func stageNumberHint(
        stageIndex: Int,
        settings: AppSettings
    ) -> CommandHintPresentation? {
        guard let jumpAction = KeyAction.jumpAction(forStageIndex: stageIndex) else {
            return nil
        }
        return hint(
            label: "Jump to stage",
            actions: [jumpAction],
            placement: .stageLeading,
            iconSystemName: nil,
            settings: settings
        )
    }

    public static func plateFooterHints(
        stageIndex: Int,
        isActive: Bool,
        hasSelectedWindow: Bool,
        settings: AppSettings
    ) -> [CommandHintPresentation] {
        guard isActive else { return [] }

        var groups: [(String, [KeyAction], String)] = [
            ("Select stage", [.nextStage, .previousStage], "rectangle.stack"),
            ("New stage", [.newStageBelow, .newStageAbove], "plus"),
            ("Delete stage", [.deleteStage], "trash"),
            ("Reorder stage", [.swapStageUp, .swapStageDown], "arrow.up.arrow.down"),
        ]
        if hasSelectedWindow {
            groups.append(("Move window", [.moveWindowUp, .moveWindowDown], "arrow.up.and.down"))
        }
        return groups.compactMap { label, actions, iconSystemName in
            hint(
                label: label,
                actions: actions,
                placement: .plateFooter,
                iconSystemName: iconSystemName,
                settings: settings
            )
        }
    }

    public static func windowHints(
        windowIndex: Int,
        selectedWindowIndex: Int,
        windowCount: Int,
        settings: AppSettings
    ) -> [CommandHintPresentation] {
        guard windowCount > 1,
              (0..<windowCount).contains(selectedWindowIndex),
              windowIndex == (selectedWindowIndex + 1) % windowCount,
              let navigationHint = hint(
                label: "Select window",
                actions: [.nextWindow, .previousWindow],
                placement: .nextWindow,
                iconSystemName: nil,
                settings: settings
              )
        else { return [] }
        return [navigationHint]
    }

    private static func hint(
        label: String,
        actions: [KeyAction],
        placement: CommandHintPlacement,
        iconSystemName: String?,
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
            shortcut: shortcuts.joined(separator: " / "),
            placement: placement,
            iconSystemName: iconSystemName
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
