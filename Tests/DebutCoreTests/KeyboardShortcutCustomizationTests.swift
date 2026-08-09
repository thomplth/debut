import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Keyboard shortcut customization", .serialized)
struct KeyboardShortcutCustomizationTests {
    @Test("Defaults include every global and Stage Manager shortcut")
    func completeDefaults() {
        let bindings = KeyBindings()

        #expect(bindings.combo(for: .activateNextWindow) == KeyCombo(
            keyCode: kVK_Tab,
            command: true
        ))
        #expect(bindings.combo(for: .quickSwitchStage10) == KeyCombo(
            keyCode: kVK_ANSI_0,
            control: true
        ))
        #expect(bindings.combo(for: .nextAppWindow) == KeyCombo(
            keyCode: kVK_ANSI_Grave,
            command: true
        ))
        #expect(bindings.combo(for: .dismissOverlay) == KeyCombo(keyCode: kVK_Escape))
        #expect(KeyAction.allCases.allSatisfy { bindings.combo(for: $0) != nil })
    }

    @Test("Older saved bindings gain defaults for newly configurable shortcuts")
    func legacyBindingsGainNewDefaults() throws {
        var legacy = KeyBindings()
        legacy.bindings[.newStageBelow] = KeyCombo(keyCode: kVK_ANSI_B)
        for action in KeyAction.globalActions + [.dismissOverlay] {
            legacy.bindings.removeValue(forKey: action)
        }

        let decoded = try JSONDecoder().decode(
            KeyBindings.self,
            from: JSONEncoder().encode(legacy)
        )

        #expect(decoded.combo(for: .newStageBelow) == KeyCombo(keyCode: kVK_ANSI_B))
        #expect(decoded.combo(for: .activateNextWindow)?.command == true)
        #expect(decoded.combo(for: .quickSwitchStage1)?.control == true)
        #expect(decoded.combo(for: .dismissOverlay)?.keyCode == kVK_Escape)
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

    @Test("Session shortcuts are relative to the configured activation modifier")
    func customSessionShortcut() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.activateNextWindow] = KeyCombo(
            keyCode: kVK_Space,
            control: true
        )
        bindings.bindings[.newStageBelow] = KeyCombo(keyCode: kVK_ANSI_B)
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let controlSpace = keyEvent(keyCode: kVK_Space, flags: .maskControl)
        #expect(service.handleCGEvent(type: .keyDown, event: controlSpace) == nil)
        service.overlayVisible = true

        let controlB = keyEvent(keyCode: kVK_ANSI_B, flags: .maskControl)
        #expect(service.handleCGEvent(type: .keyDown, event: controlB) == nil)
        #expect(delegate.receivedEvents == [.cmdTabHold, .newStageBelow])
    }

    @Test("Quick switch shortcuts are data driven")
    func customQuickSwitch() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        var bindings = KeyBindings()
        bindings.bindings[.quickSwitchStage1] = KeyCombo(
            keyCode: kVK_ANSI_B,
            option: true
        )
        service.keyBindings = bindings
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let oldControlOne = keyEvent(keyCode: kVK_ANSI_1, flags: .maskControl)
        #expect(service.handleCGEvent(type: .keyDown, event: oldControlOne) === oldControlOne)

        let optionB = keyEvent(keyCode: kVK_ANSI_B, flags: .maskAlternate)
        #expect(service.handleCGEvent(type: .keyDown, event: optionB) == nil)
        #expect(delegate.receivedEvents == [.switchToStage(1)])
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
