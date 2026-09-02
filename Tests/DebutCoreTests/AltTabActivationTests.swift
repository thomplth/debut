import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Alt-tab activation")
struct AltTabActivationTests {
    private func key(_ code: Int, _ flags: CGEventFlags, repeats: Bool = false) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(code),
            keyDown: true
        )!
        event.flags = flags
        if repeats { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return event
    }

    @Test("Option+Tab is bound to the alt-tab switcher by default")
    func defaultBinding() {
        let bindings = KeyBindings()
        #expect(bindings.combo(for: .activateAltTabNext) == KeyCombo(keyCode: kVK_Tab, option: true))
        #expect(
            bindings.combo(for: .activateAltTabPrevious)
                == KeyCombo(keyCode: kVK_Tab, shift: true, option: true)
        )
        #expect(KeyAction.activateAltTabNext.shortcutScope == .global)
        #expect(KeyAction.activateAltTabNext.isOverlayActivation)
        #expect(KeyAction.activateAltTabNext.isCycling)
    }

    /// Backtick reaches the switcher through the session's bare-backtick binding, exactly as it
    /// does inside Cmd+Tab, so no global chord is registered for it.
    @Test("No global shortcut claims Option+backtick")
    func backtickIsNotGlobal() {
        let bindings = KeyBindings()

        #expect(KeyAction.altTabActions == [.activateAltTabNext, .activateAltTabPrevious])
        #expect(
            bindings.action(
                for: KeyCombo(keyCode: kVK_ANSI_Grave, option: true),
                scope: .global
            ) == nil
        )
        #expect(KeyAction.sessionActions.contains(.previousWindowAlternate))
    }

    @Test("Option+backtick passes through when no switcher is open")
    func backtickPassesThroughWithoutSession() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let event = key(kVK_ANSI_Grave, .maskAlternate)
        #expect(service.handleCGEvent(type: .keyDown, event: event) === event)

        #expect(delegate.receivedEvents.isEmpty)
    }

    @Test("Option+Tab opens the alt-tab switcher and is consumed")
    func opensSwitcher() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        #expect(service.handleCGEvent(type: .keyDown, event: key(kVK_Tab, .maskAlternate)) == nil)

        #expect(delegate.receivedEvents == [.altTabHold])
    }

    @Test("Option+Shift+Tab opens the switcher travelling backward")
    func opensBackward() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let flags: CGEventFlags = [.maskAlternate, .maskShift]
        #expect(service.handleCGEvent(type: .keyDown, event: key(kVK_Tab, flags)) == nil)

        #expect(delegate.receivedEvents == [.altTabShiftHold])
    }

    /// Option is the session's primary modifier and is stripped before session matching, so the
    /// physical Option+backtick resolves through the same bare-backtick binding Cmd+Tab uses.
    @Test("Option+backtick steps backward while the switcher is open")
    func alternateCyclesBackward() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        _ = service.handleCGEvent(type: .keyDown, event: key(kVK_Tab, .maskAlternate))
        service.overlayVisible = true
        #expect(
            service.handleCGEvent(
                type: .keyDown,
                event: key(kVK_ANSI_Grave, .maskAlternate)
            ) == nil
        )

        #expect(delegate.receivedEvents == [.altTabHold, .previousWindow])
    }

    /// Option is the session's primary modifier, so lifting it commits the selection through the
    /// same path Cmd+Tab uses.
    @Test("Releasing Option commits the alt-tab session")
    func releaseCommits() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        _ = service.handleCGEvent(type: .keyDown, event: key(kVK_Tab, .maskAlternate))
        let release = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        release.flags = []
        #expect(service.handleCGEvent(type: .flagsChanged, event: release) == nil)

        #expect(delegate.receivedEvents == [.altTabHold, .cmdRelease])
    }

    /// A held Tab must clamp at the end of the list rather than wrap back to the start, so a
    /// burst of repeats cannot yank the selection to the beginning mid-cycle.
    @Test("A held Option+Tab repeat clamps instead of wrapping")
    func heldRepeatClamps() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        service.heldCycleMinimumInterval = 0
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        _ = service.handleCGEvent(type: .keyDown, event: key(kVK_Tab, .maskAlternate))
        _ = service.handleCGEvent(
            type: .keyDown,
            event: key(kVK_Tab, .maskAlternate, repeats: true)
        )

        #expect(delegate.receivedEvents == [.altTabHold, .altTabHoldRepeat])
    }

    /// Cmd+Option+Tab is the stage switcher's space-cycling chord. Option+Tab must not shadow it.
    @Test("Cmd+Option+Tab still opens the stage switcher in space mode")
    func doesNotShadowStageSpaceCycling() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }

        let flags: CGEventFlags = [.maskCommand, .maskAlternate]
        #expect(service.handleCGEvent(type: .keyDown, event: key(kVK_Tab, flags)) == nil)

        #expect(delegate.receivedEvents == [.cmdOptionTabHold])
    }
}
