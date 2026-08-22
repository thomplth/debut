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

    @Test("Automatic hints retire after the third use of that command")
    func automaticThreshold() {
        var settings = AppSettings()
        #expect(settings.commandHintVisibility == .automatic)
        #expect(settings.shouldShowCommandHint(for: .swapStageUp))

        for _ in 0..<2 {
            let didRecord = settings.recordCommandUsage(.swapStageUp)
            #expect(didRecord)
        }
        #expect(settings.shouldShowCommandHint(for: .swapStageUp))

        let didRecordThirdUse = settings.recordCommandUsage(.swapStageUp)
        #expect(didRecordThirdUse)
        #expect(!settings.shouldShowCommandHint(for: .swapStageUp))
        // A sibling command keeps its own count, so retiring one never retires the other.
        #expect(settings.shouldShowCommandHint(for: .swapStageDown))

        let didRecordFourthUse = settings.recordCommandUsage(.swapStageUp)
        #expect(!didRecordFourthUse)
        #expect(settings.commandUsageCounts[.swapStageUp] == 3)
    }

    @Test("Every footer command retires, collapsing the stage spacing")
    func footerHintsRetireCompletely() {
        var settings = AppSettings()
        let footerActions = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        ).flatMap(\.actions)
        #expect(!footerActions.isEmpty)

        for action in footerActions {
            for _ in 0..<3 { _ = settings.recordCommandUsage(action) }
        }

        let remaining = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        )
        #expect(remaining.isEmpty)
        #expect(
            PlateConstants.stageSpacing(hasVisibleFooterHints: !remaining.isEmpty)
                == PlateConstants.compactStageSpacing
        )
    }

    @Test("Footer hints cover every command the overlay accepts on a selected window")
    func footerHintsCoverWindowCommands() {
        let settings = AppSettings()
        let hints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        )
        let actions = Set(hints.flatMap(\.actions))

        #expect(actions.isSuperset(of: [.moveWindowLeft, .moveWindowRight]))
        #expect(actions.contains(.dismissOverlay))
    }

    @Test("Quitting the selected app is the only transitive command")
    func quitIsTheTransitiveCommand() {
        let transitive = KeyAction.allCases.filter(\.isTransitive)
        #expect(transitive == [.quitSelectedApp])
    }

    @Test("Transitive commands never earn a hint in any visibility mode")
    func transitiveCommandsAreNeverHinted() {
        var settings = AppSettings()
        #expect(!settings.shouldShowCommandHint(for: .quitSelectedApp))

        settings.commandHintVisibility = .always
        #expect(!settings.shouldShowCommandHint(for: .quitSelectedApp))
        #expect(settings.shouldShowCommandHint(for: .dismissOverlay))
    }

    @Test("A transitive command's usage is never recorded")
    func transitiveCommandUsageIsNotRecorded() {
        var settings = AppSettings()

        let didRecord = settings.recordCommandUsage(.quitSelectedApp)

        #expect(!didRecord)
        #expect(settings.commandUsageCounts[.quitSelectedApp] == nil)
    }

    @Test("The footer never offers to quit the selected app")
    func footerOmitsQuitHint() {
        var settings = AppSettings()
        settings.commandHintVisibility = .always
        let hints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        )

        #expect(!hints.flatMap(\.actions).contains(.quitSelectedApp))
    }

    @Test("Hints that need a window disappear when the stage has none")
    func footerHintsWithoutSelection() {
        let settings = AppSettings()
        let hints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: false,
            settings: settings
        )
        let actions = Set(hints.flatMap(\.actions))

        #expect(!actions.contains(.quitSelectedApp))
        #expect(!actions.contains(.moveWindowLeft))
        #expect(actions.contains(.dismissOverlay))
    }

    @Test("Never and always modes override automatic usage")
    func visibilityOverrides() {
        var settings = AppSettings()
        settings.commandHintVisibility = .never
        #expect(!settings.shouldShowCommandHint(for: .swapStageUp))

        settings.commandHintVisibility = .always
        settings.commandUsageCounts[.swapStageUp] = 99
        #expect(settings.shouldShowCommandHint(for: .swapStageUp))
    }

    @Test("Reset clears all learned command usage")
    func resetUsage() {
        var settings = AppSettings()
        _ = settings.recordCommandUsage(.swapStageUp)
        _ = settings.recordCommandUsage(.moveWindowLeft)

        settings.resetCommandHintUsage()

        #expect(settings.commandUsageCounts.isEmpty)
        #expect(settings.shouldShowCommandHint(for: .swapStageUp))
    }

    @Test("Stage number hints sit left of every plate without an icon")
    func stageHintCatalog() {
        var settings = AppSettings()
        settings.keyBindings.bindings[.swapStageUp] = KeyCombo(keyCode: kVK_ANSI_B)

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
        settings.keyBindings.bindings[.swapStageUp] = KeyCombo(keyCode: kVK_ANSI_B)

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
        #expect(activeHints.flatMap(\.actions).contains(.swapStageUp))
        #expect(activeHints.flatMap(\.actions).contains(.moveWindowLeft))
        #expect(activeHints.first(where: { $0.actions.contains(.swapStageUp) })?.shortcut.contains("B") == true)
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
        settings.commandUsageCounts[.moveWindowLeft] = 3

        let hints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        )
        let moveHint = hints.first(where: { $0.label == "Reorder window" })

        #expect(moveHint?.actions == [.moveWindowRight])
        #expect(moveHint?.shortcut == "→")
    }

    @Test("Key events map to hint usage without counting auto-repeat")
    func eventActionMapping() {
        #expect(DebutKeyEvent.cmdTabHold.commandHintAction == .nextWindow)
        #expect(DebutKeyEvent.cmdOptionTabHold.commandHintAction == .nextStage)
        #expect(DebutKeyEvent.swapStageUp.commandHintAction == .swapStageUp)
        #expect(DebutKeyEvent.jumpToLastStage.commandHintAction == .jumpToStage9)
        #expect(DebutKeyEvent.escape.commandHintAction == .dismissOverlay)
        #expect(DebutKeyEvent.nextWindowRepeat.commandHintAction == nil)
        #expect(DebutKeyEvent.cmdRelease.commandHintAction == nil)
    }
}
