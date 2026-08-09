import Carbon.HIToolbox
import Foundation
import Testing
@testable import DebutCore

@Suite("Command hints")
struct CommandHintTests {
    @Test("Automatic hints retire only after a fourth use")
    func automaticThreshold() {
        var settings = AppSettings()
        #expect(settings.commandHintVisibility == .automatic)
        #expect(settings.shouldShowCommandHint(for: .newStageBelow))

        for _ in 0..<3 {
            let didRecord = settings.recordCommandUsage(.newStageBelow)
            #expect(didRecord)
        }
        #expect(settings.shouldShowCommandHint(for: .newStageBelow))

        let didRecordFourthUse = settings.recordCommandUsage(.newStageBelow)
        #expect(didRecordFourthUse)
        #expect(!settings.shouldShowCommandHint(for: .newStageBelow))
        let didRecordFifthUse = settings.recordCommandUsage(.newStageBelow)
        #expect(!didRecordFifthUse)
        #expect(settings.commandUsageCounts[.newStageBelow] == 4)
    }

    @Test("Never and always modes override automatic usage")
    func visibilityOverrides() {
        var settings = AppSettings()
        settings.commandHintVisibility = .never
        #expect(!settings.shouldShowCommandHint(for: .deleteStage))

        settings.commandHintVisibility = .always
        settings.commandUsageCounts[.deleteStage] = 99
        #expect(settings.shouldShowCommandHint(for: .deleteStage))
    }

    @Test("Reset clears all learned command usage")
    func resetUsage() {
        var settings = AppSettings()
        _ = settings.recordCommandUsage(.newStageBelow)
        _ = settings.recordCommandUsage(.moveWindowDown)

        settings.resetCommandHintUsage()

        #expect(settings.commandUsageCounts.isEmpty)
        #expect(settings.shouldShowCommandHint(for: .newStageBelow))
    }

    @Test("Stage hints are contextual and use configured shortcuts")
    func stageHintCatalog() {
        var settings = AppSettings()
        settings.keyBindings.bindings[.newStageBelow] = KeyCombo(keyCode: kVK_ANSI_B)

        let inactiveHints = CommandHintCatalog.stageHints(
            stageIndex: 0,
            isActive: false,
            settings: settings
        )
        let activeHints = CommandHintCatalog.stageHints(
            stageIndex: 0,
            isActive: true,
            settings: settings
        )

        #expect(inactiveHints.count == 1)
        #expect(inactiveHints[0].actions == [.jumpToStage1])
        #expect(activeHints.flatMap(\.actions).contains(.newStageBelow))
        #expect(activeHints.first(where: { $0.actions.contains(.newStageBelow) })?.shortcut.contains("B") == true)
    }

    @Test("Selected window hints include navigation and cross-stage movement")
    func windowHintCatalog() {
        let settings = AppSettings()

        #expect(CommandHintCatalog.windowHints(isSelected: false, settings: settings).isEmpty)
        let hints = CommandHintCatalog.windowHints(isSelected: true, settings: settings)
        let actions = hints.flatMap(\.actions)
        #expect(actions.contains(.nextWindow))
        #expect(actions.contains(.moveWindowUp))
        #expect(actions.contains(.moveWindowDown))
    }

    @Test("A hidden action is omitted from its contextual group")
    func partiallyRetiredGroup() {
        var settings = AppSettings()
        settings.commandUsageCounts[.moveWindowUp] = 4

        let hints = CommandHintCatalog.windowHints(isSelected: true, settings: settings)
        let moveHint = hints.first(where: { $0.label == "Move window" })

        #expect(moveHint?.actions == [.moveWindowDown])
        #expect(moveHint?.shortcut == "↓")
    }

    @Test("Key events map to hint usage without counting auto-repeat")
    func eventActionMapping() {
        #expect(DebutKeyEvent.cmdTabHold.commandHintAction == .nextWindow)
        #expect(DebutKeyEvent.cmdOptionTabHold.commandHintAction == .nextStage)
        #expect(DebutKeyEvent.newStageBelow.commandHintAction == .newStageBelow)
        #expect(DebutKeyEvent.jumpToLastStage.commandHintAction == .jumpToStage9)
        #expect(DebutKeyEvent.nextWindowRepeat.commandHintAction == nil)
        #expect(DebutKeyEvent.cmdRelease.commandHintAction == nil)
    }
}
