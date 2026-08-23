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
        #expect(settings.shouldShowCommandHint(for: .moveWindowLeft))

        for _ in 0..<2 {
            let didRecord = settings.recordCommandUsage(.moveWindowLeft)
            #expect(didRecord)
        }
        #expect(settings.shouldShowCommandHint(for: .moveWindowLeft))

        let didRecordThirdUse = settings.recordCommandUsage(.moveWindowLeft)
        #expect(didRecordThirdUse)
        #expect(!settings.shouldShowCommandHint(for: .moveWindowLeft))
        // A sibling command keeps its own count, so retiring one never retires the other.
        #expect(settings.shouldShowCommandHint(for: .moveWindowRight))

        let didRecordFourthUse = settings.recordCommandUsage(.moveWindowLeft)
        #expect(!didRecordFourthUse)
        #expect(settings.commandUsageCounts[.moveWindowLeft] == 3)
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

    @Test("The footer never offers to reorder stages")
    func footerOmitsStageReorderHint() {
        var settings = AppSettings()
        settings.commandHintVisibility = .always
        let hints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        )

        #expect(!hints.contains { $0.label == "Reorder stage" })
        #expect(!hints.flatMap(\.actions).contains { $0.rawValue.hasPrefix("swapStage") })
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
        #expect(!settings.shouldShowCommandHint(for: .moveWindowLeft))

        settings.commandHintVisibility = .always
        settings.commandUsageCounts[.moveWindowLeft] = 99
        #expect(settings.shouldShowCommandHint(for: .moveWindowLeft))
    }

    @Test("Reset clears all learned command usage")
    func resetUsage() {
        var settings = AppSettings()
        _ = settings.recordCommandUsage(.moveWindowLeft)
        _ = settings.recordCommandUsage(.moveWindowDown)

        settings.resetCommandHintUsage()

        #expect(settings.commandUsageCounts.isEmpty)
        #expect(settings.shouldShowCommandHint(for: .moveWindowLeft))
    }

    @Test("Stage hints combine the number with the shortcuts that cycle to their plate")
    func stageHintCatalog() {
        var settings = AppSettings()
        settings.keyBindings.bindings[.moveWindowLeft] = KeyCombo(keyCode: kVK_ANSI_B)

        let previousDestination = CommandHintCatalog.stageHint(
            stageIndex: 0, activeStageIndex: 1, stageCount: 3, settings: settings
        )
        let nextDestination = CommandHintCatalog.stageHint(
            stageIndex: 2, activeStageIndex: 1, stageCount: 3, settings: settings
        )

        #expect(previousDestination?.actions == [.jumpToStage1, .previousStage])
        #expect(previousDestination?.shortcut == "1 / ⇧⌥Tab")
        #expect(nextDestination?.actions == [.jumpToStage3, .nextStage])
        #expect(nextDestination?.shortcut == "3 / ⌥Tab")
        #expect(nextDestination?.placement == .stageLeading)
    }

    @Test("Stage cycling hints wrap and share a destination when there are two stages")
    func stageHintCyclingWraps() {
        let settings = AppSettings()

        let wrappedNext = CommandHintCatalog.stageHint(
            stageIndex: 0, activeStageIndex: 2, stageCount: 3, settings: settings
        )
        let sharedDestination = CommandHintCatalog.stageHint(
            stageIndex: 1, activeStageIndex: 0, stageCount: 2, settings: settings
        )

        #expect(wrappedNext?.actions == [.jumpToStage1, .nextStage])
        #expect(sharedDestination?.actions == [.jumpToStage2, .nextStage, .previousStage])
        #expect(sharedDestination?.shortcut == "2 / ⌥Tab / ⇧⌥Tab")
    }

    @Test("Active plate actions sit below the plate and use concise text labels")
    func plateFooterCatalog() {
        var settings = AppSettings()
        settings.keyBindings.bindings[.moveWindowLeft] = KeyCombo(keyCode: kVK_ANSI_B)

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
        #expect(activeHints.flatMap(\.actions).contains(.moveWindowLeft))
        #expect(activeHints.flatMap(\.actions).contains(.moveWindowUp))
        #expect(!activeHints.flatMap(\.actions).contains(.nextStage))
        #expect(!activeHints.flatMap(\.actions).contains(.previousStage))
        #expect(activeHints.first(where: { $0.actions.contains(.moveWindowLeft) })?.shortcut.contains("B") == true)
        #expect(activeHints.allSatisfy { $0.placement == .plateFooter })
        #expect(activeHints.map(\.label) == ["Move window", "Reorder window", "Close"])
    }

    @Test("Forward and backward Tab hints appear on their respective windows")
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
            selectedWindowIndex: 1,
            windowCount: 3,
            settings: settings
        )

        #expect(currentHints.isEmpty)
        #expect(nextHints.flatMap(\.actions) == [.nextWindow])
        #expect(nextHints.first?.shortcut == "Tab")
        #expect(wrappedHints.flatMap(\.actions) == [.previousWindow])
        #expect(wrappedHints.first?.shortcut == "⇧Tab")
        #expect(nextHints.allSatisfy { $0.placement == .nextWindow })
        #expect(!wrappedHints.isEmpty)
    }

    @Test("Two-window cycles combine both directions on the other window")
    func twoWindowCycleHintsShareDestination() {
        let hints = CommandHintCatalog.windowHints(
            windowIndex: 1,
            selectedWindowIndex: 0,
            windowCount: 2,
            settings: AppSettings()
        )

        #expect(hints.flatMap(\.actions) == [.nextWindow, .previousWindow])
        #expect(hints.first?.shortcut == "Tab / ⇧Tab")
    }

    @Test("Command hints name arrow keys instead of representing them with symbols")
    func arrowKeyLegends() {
        #expect(KeyCombo(keyCode: kVK_UpArrow).commandHintDisplayString == "Up")
        #expect(KeyCombo(keyCode: kVK_DownArrow).commandHintDisplayString == "Down")
        #expect(KeyCombo(keyCode: kVK_LeftArrow).commandHintDisplayString == "Left")
        #expect(KeyCombo(keyCode: kVK_RightArrow).commandHintDisplayString == "Right")
    }

    @Test("Leading and footer hints use the same distance from their plate")
    func plateHintPadding() {
        #expect(PlateConstants.commandHintLeadingGap == PlateConstants.commandHintFooterOffset)
    }

    @Test("A hidden action is omitted from its contextual group")
    func partiallyRetiredGroup() {
        var settings = AppSettings()
        settings.commandUsageCounts[.moveWindowUp] = 3

        let hints = CommandHintCatalog.plateFooterHints(
            stageIndex: 0,
            isActive: true,
            hasSelectedWindow: true,
            settings: settings
        )
        let moveHint = hints.first(where: { $0.label == "Move window" })

        #expect(moveHint?.actions == [.moveWindowDown])
        #expect(moveHint?.shortcut == "Down")
    }

    @Test("Key events map to hint usage without counting auto-repeat")
    func eventActionMapping() {
        #expect(DebutKeyEvent.cmdTabHold.commandHintAction == .nextWindow)
        #expect(DebutKeyEvent.cmdOptionTabHold.commandHintAction == .nextStage)
        #expect(DebutKeyEvent.moveWindowLeft.commandHintAction == .moveWindowLeft)
        #expect(DebutKeyEvent.jumpToLastStage.commandHintAction == .jumpToStage9)
        #expect(DebutKeyEvent.escape.commandHintAction == .dismissOverlay)
        #expect(DebutKeyEvent.nextWindowRepeat.commandHintAction == nil)
        #expect(DebutKeyEvent.cmdRelease.commandHintAction == nil)
    }
}
