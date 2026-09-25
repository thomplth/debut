import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Keyboard shortcut customization", .serialized)
struct KeyboardShortcutCustomizationTests {
    @Test("Disabling Option-Tab passes both directions through without disabling Command-Tab")
    func disabledOptionTab() throws {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        service.features = try JSONDecoder().decode(FeatureSettings.self, from: Data(#"{"optionTab":false}"#.utf8))
        #expect(service.start(delegate: delegate))
        defer { service.stop() }
        for flags: CGEventFlags in [.maskAlternate, [.maskAlternate, .maskShift]] {
            let event = keyEvent(keyCode: kVK_Tab, flags: flags)
            #expect(service.handleCGEvent(type: .keyDown, event: event) === event)
            #expect(service.handleCGEvent(type: .keyUp, event: event) === event)
        }
        #expect(delegate.receivedEvents.isEmpty)
        let commandTab = keyEvent(keyCode: kVK_Tab, flags: .maskCommand)
        #expect(service.handleCGEvent(type: .keyDown, event: commandTab) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold])
    }

    @Test("Command-Option-backtick is the alternate previous-space shortcut")
    func previousSpaceAlternateDefault() {
        let bindings = KeyBindings()

        #expect(bindings.combo(for: .activatePreviousSpaceAlternate) == KeyCombo(
            keyCode: kVK_ANSI_Grave,
            command: true,
            option: true
        ))
        #expect(
            KeyAction.activatePreviousSpaceAlternate.toKeyEvent()
                == .cmdOptionShiftTabHold
        )
    }

    @Test("Defaults include every global and Space Manager shortcut")
    func completeDefaults() {
        let bindings = KeyBindings()

        #expect(bindings.combo(for: .activateNextWindow) == KeyCombo(
            keyCode: kVK_Tab,
            command: true
        ))
        #expect(KeyAction.quickSwitchActions.allSatisfy { ($0.quickSwitchPosition ?? 10) <= 9 })
        #expect(bindings.combo(for: .nextAppWindow) == KeyCombo(
            keyCode: kVK_ANSI_Grave,
            command: true
        ))
        #expect(bindings.combo(for: .dismissOverlay) == KeyCombo(keyCode: kVK_Escape))
        // The Command modifier that opened the session is implicit here, so Return means
        // physical Command-Return while the stages are visible.
        #expect(bindings.combo(for: .nextDisplayStack) == KeyCombo(keyCode: kVK_Return))
        #expect(KeyAction.allCases.allSatisfy { bindings.combo(for: $0) != nil })
    }

    @Test("Vim selection defaults are separate from window moves and survive saved settings")
    func vimSelectionDefaults() throws {
        let defaults: [(KeyAction, Int, DebutKeyEvent)] = [
            (.selectLeft, kVK_ANSI_H, .selectLeft),
            (.selectDown, kVK_ANSI_J, .selectDown),
            (.selectUp, kVK_ANSI_K, .selectUp),
            (.selectRight, kVK_ANSI_L, .selectRight),
        ]
        #expect(KeyAction.overlaySelectionActions == defaults.map { $0.0 })
        var saved = KeyBindings()
        for (action, keyCode, event) in defaults {
            #expect(action.shortcutScope == .session)
            #expect(saved.combo(for: action) == KeyCombo(keyCode: keyCode))
            #expect(action.toKeyEvent() == event)
            saved.bindings.removeValue(forKey: action)
        }
        saved.bindings[.moveWindowLeft] = KeyCombo(keyCode: kVK_ANSI_B)
        let restored = try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(saved))
        for (action, keyCode, _) in defaults {
            #expect(restored.combo(for: action) == KeyCombo(keyCode: keyCode))
        }
        #expect(restored.combo(for: .moveWindowLeft) == KeyCombo(keyCode: kVK_ANSI_B))
    }

    @Test("New selection defaults leave older custom bindings in control of their keys")
    func vimDefaultsPreserveExistingBindings() throws {
        var saved = KeyBindings()
        saved.bindings.removeValue(forKey: .selectLeft)
        saved.bindings[.moveWindowLeft] = KeyCombo(keyCode: kVK_ANSI_H)

        let restored = try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(saved))

        #expect(restored.combo(for: .moveWindowLeft) == KeyCombo(keyCode: kVK_ANSI_H))
        #expect(restored.combo(for: .selectLeft) == nil)
        #expect(restored.action(for: KeyCombo(keyCode: kVK_ANSI_H), scope: .session)
                == .moveWindowLeft)
    }

    @Test("Configured Vim selection shortcuts dispatch only while an overlay is visible")
    func customVimSelectionShortcut() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.selectLeft] = KeyCombo(keyCode: kVK_ANSI_B)
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let commandTab = keyEvent(keyCode: kVK_Tab, flags: .maskCommand)
        #expect(service.handleCGEvent(type: .keyDown, event: commandTab) == nil)
        let custom = keyEvent(keyCode: kVK_ANSI_B, flags: .maskCommand)
        #expect(service.handleCGEvent(type: .keyDown, event: custom) === custom)
        service.overlayVisible = true
        let oldDefault = keyEvent(keyCode: kVK_ANSI_H, flags: .maskCommand)
        #expect(service.handleCGEvent(type: .keyDown, event: oldDefault) == nil)
        #expect(service.handleCGEvent(type: .keyDown, event: custom) == nil)
        #expect(service.handleCGEvent(type: .keyUp, event: custom) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold, .selectLeft])
    }

    @Test("Focused-window move shortcuts preserve all four arrow defaults")
    func focusedWindowMoveDefaults() {
        let bindings = KeyBindings()

        #expect(KeyAction.focusedWindowMoveActions == [
            .moveFocusedWindowToPreviousSpace,
            .moveFocusedWindowToPreviousSpaceAlternate,
            .moveFocusedWindowToNextSpace,
            .moveFocusedWindowToNextSpaceAlternate,
        ])
        #expect(bindings.combo(for: .moveFocusedWindowToPreviousSpace) == KeyCombo(
            keyCode: kVK_LeftArrow,
            command: true,
            option: true
        ))
        #expect(bindings.combo(for: .moveFocusedWindowToPreviousSpaceAlternate) == KeyCombo(
            keyCode: kVK_UpArrow,
            command: true,
            option: true
        ))
        #expect(bindings.combo(for: .moveFocusedWindowToNextSpace) == KeyCombo(
            keyCode: kVK_RightArrow,
            command: true,
            option: true
        ))
        #expect(bindings.combo(for: .moveFocusedWindowToNextSpaceAlternate) == KeyCombo(
            keyCode: kVK_DownArrow,
            command: true,
            option: true
        ))
    }

    @Test("Older saved bindings gain defaults for newly configurable shortcuts")
    func legacyBindingsGainNewDefaults() throws {
        var legacy = KeyBindings()
        legacy.bindings[.moveWindowLeft] = KeyCombo(keyCode: kVK_ANSI_B)
        for action in KeyAction.globalActions + [.dismissOverlay] {
            legacy.bindings.removeValue(forKey: action)
        }

        let decoded = try JSONDecoder().decode(
            KeyBindings.self,
            from: JSONEncoder().encode(legacy)
        )

        #expect(decoded.combo(for: .moveWindowLeft) == KeyCombo(keyCode: kVK_ANSI_B))
        #expect(decoded.combo(for: .activateNextWindow)?.command == true)
        #expect(decoded.combo(for: .quickSwitchSpace1)?.control == true)
        #expect(decoded.combo(for: .dismissOverlay)?.keyCode == kVK_Escape)
    }

    @Test("Space reordering is no longer a command")
    func spaceReorderActionsAreRetired() {
        #expect(KeyAction(rawValue: "swapSpaceUp") == nil)
        #expect(KeyAction(rawValue: "swapSpaceDown") == nil)
        #expect(!KeyAction.allCases.contains { $0.rawValue.hasPrefix("swapSpace") })
    }

    @Test("Retired saved actions are ignored")
    func retiredSavedActionsAreIgnored() throws {
        var saved = KeyBindings()
        saved.bindings[.moveWindowLeft] = KeyCombo(keyCode: kVK_ANSI_B)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        var encodedBindings = try #require(object["bindings"] as? [Any])
        // A settings.json written before space reordering was removed still carries its combo.
        encodedBindings.append("swapSpaceUp")
        encodedBindings.append(["keyCode": kVK_Space])
        object["bindings"] = encodedBindings

        let decoded = try JSONDecoder().decode(
            KeyBindings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.combo(for: .moveWindowLeft) == KeyCombo(keyCode: kVK_ANSI_B))
        #expect(!decoded.bindings.values.contains(KeyCombo(keyCode: kVK_Space)))
    }

    @Test("A custom global shortcut replaces Command-Tab activation")
    func customActivation() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.activateNextWindow] = KeyCombo(
            keyCode: kVK_Space,
            control: true
        )
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let commandTab = keyEvent(keyCode: kVK_Tab, flags: .maskCommand)
        #expect(service.handleCGEvent(type: .keyDown, event: commandTab) === commandTab)

        let controlSpace = keyEvent(keyCode: kVK_Space, flags: .maskControl)
        #expect(service.handleCGEvent(type: .keyDown, event: controlSpace) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold])

        let releaseControl = keyEvent(keyCode: kVK_Control, flags: [])
        #expect(service.handleCGEvent(type: .flagsChanged, event: releaseControl) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold, .cmdRelease])
    }

    @Test("Custom focused-window move shortcuts replace the arrow defaults")
    func customFocusedWindowMove() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.moveFocusedWindowToPreviousSpace] = KeyCombo(
            keyCode: kVK_ANSI_B,
            control: true,
            shift: true
        )
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let oldDefault = keyEvent(
            keyCode: kVK_LeftArrow,
            flags: [.maskCommand, .maskAlternate]
        )
        #expect(service.handleCGEvent(type: .keyDown, event: oldDefault) === oldDefault)

        let custom = keyEvent(
            keyCode: kVK_ANSI_B,
            flags: [.maskControl, .maskShift]
        )
        #expect(service.handleCGEvent(type: .keyDown, event: custom) == nil)
        #expect(delegate.receivedEvents == [.moveFocusedWindowToAdjacentSpace(-1)])

        let release = keyEvent(keyCode: kVK_ANSI_B, flags: [])
        #expect(service.handleCGEvent(type: .keyUp, event: release) == nil)
    }

    @Test("Session shortcuts are relative to the configured activation modifier")
    func customSessionShortcut() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.activateNextWindow] = KeyCombo(
            keyCode: kVK_Space,
            control: true
        )
        bindings.bindings[.moveWindowLeft] = KeyCombo(keyCode: kVK_ANSI_B)
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let controlSpace = keyEvent(keyCode: kVK_Space, flags: .maskControl)
        #expect(service.handleCGEvent(type: .keyDown, event: controlSpace) == nil)
        service.overlayVisible = true

        let controlB = keyEvent(keyCode: kVK_ANSI_B, flags: .maskControl)
        #expect(service.handleCGEvent(type: .keyDown, event: controlB) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold, .moveWindowLeft])
    }

    @Test("Legacy per-number bindings cannot move quick switch away from digit keys")
    func quickSwitchDigitsStayFixed() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.quickSwitchSpace1] = KeyCombo(
            keyCode: kVK_ANSI_B,
            option: true
        )
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let oldControlOne = keyEvent(keyCode: kVK_ANSI_1, flags: .maskControl)
        #expect(service.handleCGEvent(type: .keyDown, event: oldControlOne) == nil)

        let optionB = keyEvent(keyCode: kVK_ANSI_B, flags: .maskAlternate)
        #expect(service.handleCGEvent(type: .keyDown, event: optionB) === optionB)
        #expect(delegate.receivedEvents == [.switchToSpace(1)])
    }

    @Test("Conflicts are limited to shortcuts in the same context")
    func conflictScopes() {
        var bindings = KeyBindings()
        let commandTab = KeyCombo(keyCode: kVK_Tab, command: true)
        bindings.bindings[.activateNextWindow] = commandTab
        bindings.bindings[.nextWindow] = commandTab

        #expect(ConflictDetector.checkInternal(
            combo: commandTab,
            forAction: .activatePreviousWindow,
            in: bindings
        )?.message.contains("Open / cycle windows") == true)
        #expect(ConflictDetector.checkInternal(
            combo: commandTab,
            forAction: .previousWindow,
            in: bindings
        )?.message.contains("Next window") == true)
    }

    @Test("Modifier-free global shortcuts warn about intercepting typing")
    func globalModifierWarning() {
        let conflicts = ConflictDetector.detectConflicts(
            combo: KeyCombo(keyCode: kVK_ANSI_B),
            forAction: .activateNextWindow,
            in: KeyBindings()
        )

        #expect(conflicts.contains {
            $0.message == "A global shortcut without modifiers intercepts ordinary typing"
        })
    }

    @Test("A modifier-free activation session commits when its trigger is released")
    func modifierFreeActivation() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.activateNextWindow] = KeyCombo(keyCode: kVK_ANSI_B)
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let bDown = keyEvent(keyCode: kVK_ANSI_B, flags: [])
        #expect(service.handleCGEvent(type: .keyDown, event: bDown) == nil)
        let bUp = keyEvent(keyCode: kVK_ANSI_B, flags: [])
        #expect(service.handleCGEvent(type: .keyUp, event: bUp) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold, .cmdRelease])
    }

    @Test("Same-app cycling and overlay dismissal use configured bindings")
    func remainingConfiguredBindings() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.nextAppWindow] = KeyCombo(
            keyCode: kVK_ANSI_B,
            command: true
        )
        bindings.bindings[.dismissOverlay] = KeyCombo(keyCode: kVK_ANSI_D)
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let commandB = keyEvent(keyCode: kVK_ANSI_B, flags: .maskCommand)
        #expect(service.handleCGEvent(type: .keyDown, event: commandB) == nil)
        #expect(delegate.receivedEvents == [.cmdBacktick])

        let releaseCommand = keyEvent(keyCode: kVK_Command, flags: [])
        #expect(service.handleCGEvent(type: .flagsChanged, event: releaseCommand) == nil)
        #expect(delegate.receivedEvents == [.cmdBacktick, .cmdRelease])

        let commandTab = keyEvent(keyCode: kVK_Tab, flags: .maskCommand)
        #expect(service.handleCGEvent(type: .keyDown, event: commandTab) == nil)
        service.overlayVisible = true
        let commandD = keyEvent(keyCode: kVK_ANSI_D, flags: .maskCommand)
        #expect(service.handleCGEvent(type: .keyDown, event: commandD) == nil)
        #expect(delegate.receivedEvents.last == .escape)
    }

    private func keyEvent(keyCode: Int, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: true
        )!
        event.flags = flags
        return event
    }
}
