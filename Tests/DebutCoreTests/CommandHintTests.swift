import Carbon.HIToolbox
import Foundation
import Testing
@testable import DebutCore

@Suite("Command hints")
struct CommandHintTests {
    @Test("Stage spacing expands only when a footer hint is visible")
    func stageSpacing() {
        #expect(PlateConstants.stageSpacing(hasVisibleFooterHints: false) == 14)
        #expect(PlateConstants.stageSpacing(hasVisibleFooterHints: true) == 34)
    }

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

    @Test("Stage number hints sit left of every plate without an icon")
    func stageHintCatalog() {
        var settings = AppSettings()
        settings.keyBindings.bindings[.newStageBelow] = KeyCombo(keyCode: kVK_ANSI_B)

        let numberHint = CommandHintCatalog.stageNumberHint(
            stageIndex: 0,
            settings: settings
        )

        #expect(numberHint?.actions == [.jumpToStage1])
        #expect(numberHint?.placement == .stageLeading)
        #expect(numberHint?.iconSystemName == nil)
    }

    @Test("Active plate actions sit below the plate and use purpose icons")
    func plateFooterCatalog() {
        var settings = AppSettings()
        settings.keyBindings.bindings[.newStageBelow] = KeyCombo(keyCode: kVK_ANSI_B)

        let inactiveHints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: false,
            hasSelectedWindow: false,
            settings: settings
        )
        let activeHints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        )

        #expect(inactiveHints.isEmpty)
        #expect(activeHints.flatMap(\.actions).contains(.newStageBelow))
        #expect(activeHints.flatMap(\.actions).contains(.moveWindowUp))
        #expect(activeHints.first(where: { $0.actions.contains(.newStageBelow) })?.shortcut.contains("B") == true)
        #expect(activeHints.allSatisfy { $0.placement == .plateFooter })
        #expect(activeHints.allSatisfy { $0.iconSystemName != nil })
    }

    @Test("Tab hint appears on the next selectable window")
    func windowHintCatalog() {
        let settings = AppSettings()

        let currentHints = CommandHintCatalog.windowHints(
            windowIndex: 1,
            selectedWindowIndex: 1,
            windowCount: 3,
            settings: settings
        )
        let nextHints = CommandHintCatalog.windowHints(
            windowIndex: 2,
            selectedWindowIndex: 1,
            windowCount: 3,
            settings: settings
        )
        let wrappedHints = CommandHintCatalog.windowHints(
            windowIndex: 0,
            selectedWindowIndex: 2,
            windowCount: 3,
            settings: settings
        )

        #expect(currentHints.isEmpty)
        #expect(nextHints.flatMap(\.actions).contains(.nextWindow))
        #expect(nextHints.allSatisfy { $0.placement == .nextWindow })
        #expect(nextHints.allSatisfy { $0.iconSystemName == nil })
        #expect(!wrappedHints.isEmpty)
    }

    @Test("A hidden action is omitted from its contextual group")
    func partiallyRetiredGroup() {
        var settings = AppSettings()
        settings.commandUsageCounts[.moveWindowUp] = 4

        let hints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        )
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
